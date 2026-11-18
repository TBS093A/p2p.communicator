import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:veilid/veilid.dart';

import '../app_state/app_session.dart';
import '../core/media_cache.dart';
import '../v2/private_v2.dart';
import '../vault/pin_vault.dart';
import '../vault/room_secrets.dart';
import 'migration_archive.dart';

/// A private room picked for the move: its password re-creates its slot on
/// the new phone (slots are bound to each phone's Keystore pepper, so they
/// cannot simply be copied).
class PrivateRoomToMove {
  PrivateRoomToMove(this.password, this.slot, this.name, {this.room});
  final String password;
  final PrivateSlot slot;

  /// What the list shows.
  final String name;

  /// An old v1 room in the slot (it moves to v2 when next opened).
  final UnlockedRoom? room;

  /// Opens [password]'s slot for the move, or null for a wrong password.
  static Future<PrivateRoomToMove?> open(String password) async {
    final vault = PinVault.instance;
    final slot = await vault.openPrivate(password);
    if (slot == null) return null;
    final v1 = slot.v1;
    var name = v1?.roomName ?? 'Rozmowa prywatna';
    if (slot.hasV2) {
      final ids = await _v2Groups(slot);
      if (ids.isNotEmpty) name = ids.first.$2;
    }
    return PrivateRoomToMove(
      password,
      slot,
      name,
      room: v1 == null ? null : UnlockedRoom(slot.slotId, slot.key, v1),
    );
  }
}

/// The v2 conversation(s) in a private slot (§B11.1): (id, name).
Future<List<(String, String)>> _v2Groups(PrivateSlot slot) async {
  final vault = PinVault.instance;
  final raw = await vault.readData(
    await vault.derivedDataArea(slot, PrivateV2.stateLabel),
  );
  if (raw == null) return const [];
  try {
    return [
      for (final g in jsonDecode(utf8.decode(raw)) as List)
        ((g as Map)['id'] as String, g['name'] as String? ?? ''),
    ];
  } on Object {
    return const [];
  }
}

/// Packs everything into a migration file sealed to the new phone, and
/// unpacks it there.
///
/// What moves: identity and global profile record, the DM and group list
/// with every room's message history, all cached media (photos, video,
/// voice notes, avatars, backgrounds, emoji), and the private rooms you
/// unlocked for the move. Everything is re-encrypted on the new phone with
/// its own app PIN and Keystore pepper.
class MigrationService {
  MigrationService._();

  static Future<File> export({
    required AppSession app,
    required PublicKey to,
    required List<PrivateRoomToMove> privateRooms,
    required File out,
    void Function(String step)? onProgress,
  }) async {
    final vault = PinVault.instance;
    final unlocked = await app.exportState();
    final w = await MigrationWriter.create(out, to);
    try {
      onProgress?.call('Profil i lista rozmów');
      await w.addJson('app/payload', unlocked.payload);
      await w.add('app/data', await vault.readData(unlocked) ?? const []);
      await _media(w, 'app', unlocked);

      for (final (i, r) in app.rooms.indexed) {
        onProgress?.call('Rozmowa ${i + 1}/${app.rooms.length}');
        final area = r.session.room;
        await w.addJson('pub/$i/secrets', area.secrets.toJson());
        await w.add('pub/$i/cache', await vault.readData(area) ?? const []);
        await _media(w, 'pub/$i', area);
      }

      // v2 groups: their core state is in app/data above; here the
      // conversation cache and media, in an area named like a public room's.
      for (final (i, r) in app.v2.rooms.indexed) {
        onProgress?.call('Grupa v2 ${i + 1}/${app.v2.rooms.length}');
        await w.addJson('v2/$i/secrets', r.room.secrets.toJson());
        await w.add('v2/$i/cache', await vault.readData(r.room) ?? const []);
        await _media(w, 'v2/$i', r.room);
      }

      for (final (i, p) in privateRooms.indexed) {
        onProgress?.call('Pokój prywatny ${i + 1}/${privateRooms.length}');
        final v1 = p.room;
        if (v1 != null) {
          await w.addJson('priv/$i/secrets', {
            'password': p.password,
            'secrets': v1.secrets.toJson(),
            if (p.slot.hasV2) 'v2': true,
          });
          await w.add('priv/$i/cache', await vault.readData(v1) ?? const []);
          await _media(w, 'priv/$i', v1);
        }
        if (!p.slot.hasV2) continue;
        // §B11.1: the v2 conversation's core state and, per group, its
        // conversation cache and media, all derived from the slot.
        await w.addJson('pv2/$i/secrets', {
          'password': p.password,
          'v1': v1 != null,
        });
        final state = await vault.derivedDataArea(p.slot, PrivateV2.stateLabel);
        await w.add('pv2/$i/cache', await vault.readData(state) ?? const []);
        for (final (j, (id, _)) in (await _v2Groups(p.slot)).indexed) {
          final area = await vault.derivedDataArea(
            p.slot,
            PrivateV2.roomLabel(id),
          );
          await w.addJson('pr2/$i-$j/secrets', {
            'slot': i,
            'label': PrivateV2.roomLabel(id),
          });
          await w.add(
            'pr2/$i-$j/cache',
            await vault.readData(area) ?? const [],
          );
          await _media(w, 'pr2/$i-$j', area);
        }
      }
      onProgress?.call('Zamykam plik');
    } finally {
      await w.close();
    }
    return out;
  }

  static Future<void> _media(
    MigrationWriter w,
    String prefix,
    VaultArea area,
  ) async {
    final cache = await MediaCache.open(area);
    try {
      for (final hash in await cache.hashes()) {
        final bytes = await cache.load(hash);
        if (bytes != null) await w.add('$prefix/media/$hash', bytes);
      }
    } finally {
      await cache.close();
    }
  }

  /// Unpacks [file] (sealed to [me]) into this phone's empty vault under the
  /// new [pin]. Afterwards the app opens with that PIN as usual.
  static Future<void> import({
    required File file,
    required KeyPair me,
    required String pin,
    void Function(String step)? onProgress,
  }) async {
    final vault = PinVault.instance;
    if (await vault.isAppSet()) {
      throw MigrationException('Na tym telefonie jest już konto');
    }
    final reader = await MigrationReader.open(file, me);

    UnlockedApp? app;
    final areas = <String, VaultArea>{};
    final caches = <String, MediaCache>{};
    final slots = <String, PrivateSlot>{};
    var count = 0;

    Future<MediaCache> cacheFor(String prefix) async => caches[prefix] ??=
        await MediaCache.open(prefix == 'app' ? app! : areas[prefix]!);

    try {
      await for (final (name, data) in reader.entries()) {
        if (++count % 20 == 0) onProgress?.call('Odtworzono $count elementów');
        final parts = name.split('/');
        if (name == 'app/payload') {
          final payload = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
          app = await vault.createApp(pin, payload);
        } else if (app == null) {
          throw MigrationException('Plik przeniesienia jest uszkodzony');
        } else if (name == 'app/data') {
          await vault.writeData(app, data);
        } else if (parts.length == 3 && parts[2] == 'secrets') {
          final prefix = '${parts[0]}/${parts[1]}';
          final j = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
          if (parts[0] == 'pub' || parts[0] == 'v2') {
            areas[prefix] = await vault.publicRoomArea(
              app,
              RoomSecrets.fromJson(j),
            );
          } else if (parts[0] == 'pv2') {
            // A private v2 conversation: its slot (with the v1 room the
            // `priv` entry already stored, if any), then its state.
            final password = j['password'] as String;
            var slot = j['v1'] == true
                ? await vault.openPrivate(password)
                : null;
            slot = slot == null
                ? await vault.storePrivateV2(password)
                : await vault.markMovedToV2(slot);
            slots[parts[1]] = slot;
            areas[prefix] = await vault.derivedDataArea(
              slot,
              PrivateV2.stateLabel,
            );
          } else if (parts[0] == 'pr2') {
            final slot = slots['${j['slot']}'];
            if (slot == null) continue;
            areas[prefix] = await vault.derivedDataArea(
              slot,
              j['label'] as String,
            );
          } else {
            final password = j['password'] as String;
            final secrets = RoomSecrets.fromJson(
              (j['secrets'] as Map).cast<String, dynamic>(),
            );
            areas[prefix] = await vault.store(password, secrets);
          }
        } else if (parts.length == 3 && parts[2] == 'cache') {
          final area = areas['${parts[0]}/${parts[1]}'];
          if (area != null && data.isNotEmpty) {
            await vault.writeData(area, data);
          }
        } else if (parts.length >= 3 && parts[parts.length - 2] == 'media') {
          final prefix = parts.sublist(0, parts.length - 2).join('/');
          await (await cacheFor(prefix)).store(parts.last, data);
        } else {
          debugPrint('[move] skipping unknown entry kind');
        }
      }
      if (app == null) {
        throw MigrationException('Plik przeniesienia jest pusty');
      }
    } finally {
      for (final c in caches.values) {
        await c.close();
      }
    }
  }
}
