import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:veilid/veilid.dart';

import '../app_state/app_session.dart';
import '../core/media_cache.dart';
import '../vault/pin_vault.dart';
import '../vault/room_secrets.dart';
import 'migration_archive.dart';

/// A private room picked for the move: its password re-creates its slot on
/// the new phone (slots are bound to each phone's Keystore pepper, so they
/// cannot simply be copied).
class PrivateRoomToMove {
  PrivateRoomToMove(this.password, this.room);
  final String password;
  final UnlockedRoom room;
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

      for (final (i, p) in privateRooms.indexed) {
        onProgress?.call('Pokój prywatny ${i + 1}/${privateRooms.length}');
        await w.addJson('priv/$i/secrets', {
          'password': p.password,
          'secrets': p.room.secrets.toJson(),
        });
        await w.add('priv/$i/cache', await vault.readData(p.room) ?? const []);
        await _media(w, 'priv/$i', p.room);
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
          if (parts[0] == 'pub') {
            areas[prefix] = await vault.publicRoomArea(
              app,
              RoomSecrets.fromJson(j),
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
