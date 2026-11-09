import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:veilid/veilid.dart';

import '../core/crypto.dart';
import 'room_secrets.dart';

/// Where some encrypted local state lives: a data file and a media folder,
/// both named after [slotId] and sealed with [key].
abstract class VaultArea {
  String get slotId;
  SharedSecret get key;
}

/// A room and the secrets needed to reconnect to it. Private rooms come from
/// a password slot; public rooms get an area derived from the app key.
class UnlockedRoom implements VaultArea {
  UnlockedRoom(this.slotId, this.key, this.secrets);
  @override
  final String slotId;
  @override
  final SharedSecret key;
  final RoomSecrets secrets;
}

/// The app itself, opened with the app PIN: identity and public room list.
class UnlockedApp implements VaultArea {
  UnlockedApp(this.slotId, this.key, this.payload);
  @override
  final String slotId;
  @override
  final SharedSecret key;
  final Map<String, dynamic> payload;
}

class VaultLockedOut implements Exception {
  VaultLockedOut(this.remaining);
  final Duration remaining;
}

/// Secret -> slot vault. Two kinds of secret open slots:
///
/// * the **app PIN** opens the app slot (identity, public rooms);
/// * a **private-room password** opens that one private room.
///
/// They use separate key domains, so an app PIN and a password with the same
/// characters open different slots and can never open each other's.
///
/// * master = Argon2(domain || secret || devicePepper, vaultSalt). The pepper
///   is 32 random bytes kept in Android Keystore-backed storage, so a copy of
///   the app's files alone cannot be brute-forced offline, however short the
///   secret.
/// * The slot file name is derived from master, so one attempt means one
///   Argon2 run and a direct file lookup; there is no list of private rooms
///   anywhere.
/// * Every slot is padded to the same size and decoy slots are written next to
///   real ones, so the folder does not show how many private rooms exist.
/// * A wrong password and "no room for this password" are the same thing:
///   nothing opens.
class PinVault {
  PinVault._();
  static final PinVault instance = PinVault._();

  static const _slotPlainSize = 4096;
  static const _maxFreeAttempts = 5;
  static const _pepperKey = 'vault_pepper_v1';
  static const _failsKey = 'vault_fails';
  static const _lockUntilKey = 'vault_lock_until';
  static const _appSetKey = 'vault_app_set_v1';

  /// Key domain of the app PIN. Private-room passwords use the empty domain,
  /// which is also how v0.1 PIN rooms were stored: they keep opening with
  /// their old PIN, now as a private-room password.
  static const _appDomain = 'app';

  final _secure = const FlutterSecureStorage();
  final _rng = Random.secure();
  late Directory _dir;
  late Uint8List _salt;
  Uint8List? _pepper;

  Future<void> init() async {
    final base = await getApplicationSupportDirectory();
    _dir = Directory(p.join(base.path, 'vault'));
    final fresh = !await _dir.exists();
    await _dir.create(recursive: true);

    final saltFile = File(p.join(_dir.path, 'salt.bin'));
    if (await saltFile.exists()) {
      _salt = await saltFile.readAsBytes();
    } else {
      _salt = await Crypto.randomBytes(await Crypto.saltLength());
      await saltFile.writeAsBytes(_salt, flush: true);
    }

    final stored = await _secure.read(key: _pepperKey);
    if (stored != null) {
      _pepper = base64Decode(stored);
    } else {
      _pepper = await Crypto.randomBytes(32);
      await _secure.write(key: _pepperKey, value: base64Encode(_pepper!));
    }

    if (fresh) await _writeDecoys(8 + _rng.nextInt(9));
  }

  // ---------------------------------------------------------------- unlock

  Future<Duration?> lockoutRemaining() async {
    final until = int.tryParse(await _secure.read(key: _lockUntilKey) ?? '');
    if (until == null) return null;
    final left = DateTime.fromMillisecondsSinceEpoch(
      until,
    ).difference(DateTime.now());
    return left.isNegative ? null : left;
  }

  /// Returns the private room for [password], or null. Throws
  /// [VaultLockedOut] while attempts are throttled.
  Future<UnlockedRoom?> unlock(String password) async {
    final opened = await _open(password, '');
    if (opened == null) return null;
    final (slot, json) = opened;
    return UnlockedRoom(slot.id, slot.key, RoomSecrets.fromJson(json));
  }

  // ------------------------------------------------------------------- app

  /// Whether the app PIN was set up. Not secret: everyone knows the app has
  /// a PIN; what stays hidden is which private rooms exist.
  Future<bool> isAppSet() async => await _secure.read(key: _appSetKey) == '1';

  Future<UnlockedApp> createApp(
    String pin,
    Map<String, dynamic> payload,
  ) async {
    final slot = await _slotFor(pin, domain: _appDomain);
    await _writeSlot(slot, payload);
    await _secure.write(key: _appSetKey, value: '1');
    await _writeDecoys(_rng.nextInt(3));
    return UnlockedApp(slot.id, slot.key, payload);
  }

  /// Opens the app with its PIN, or null. Throws [VaultLockedOut] while
  /// attempts are throttled (shared with private-room attempts).
  Future<UnlockedApp?> unlockApp(String pin) async {
    final opened = await _open(pin, _appDomain);
    if (opened == null) return null;
    final (slot, json) = opened;
    return UnlockedApp(slot.id, slot.key, json);
  }

  /// Rewrites the app slot's payload (e.g. after a profile change).
  Future<void> updateApp(UnlockedApp app, Map<String, dynamic> payload) =>
      _writeSlot(_Slot(app.slotId, app.key), payload, keepData: true);

  Future<(_Slot, Map<String, dynamic>)?> _open(
    String secret,
    String domain,
  ) async {
    final left = await lockoutRemaining();
    if (left != null) throw VaultLockedOut(left);

    final slot = await _slotFor(secret, domain: domain);
    final file = _slotFile(slot.id);
    if (await file.exists()) {
      try {
        final plain = await Crypto.open(
          slot.key,
          await file.readAsBytes(),
          context: 'slot',
        );
        await _secure.delete(key: _failsKey);
        await _secure.delete(key: _lockUntilKey);
        return (slot, _unpad(plain));
      } on Object {
        // Name collision with a decoy or a damaged file: treat as wrong.
      }
    }
    await _registerFailure();
    return null;
  }

  /// Area for a public room's cache and media, derived from the app key so
  /// nothing about it is readable without the app PIN.
  Future<UnlockedRoom> publicRoomArea(
    UnlockedApp app,
    RoomSecrets secrets,
  ) async {
    final label = 'public-room:${secrets.rosterKey}';
    final id = Crypto.hex(
      Uint8List.sublistView(await Crypto.subkey(app.key, '$label:id'), 0, 16),
    );
    return UnlockedRoom(
      id,
      await Crypto.subsecret(app.key, '$label:key'),
      secrets,
    );
  }

  Future<void> _registerFailure() async {
    final fails = int.parse(await _secure.read(key: _failsKey) ?? '0') + 1;
    await _secure.write(key: _failsKey, value: '$fails');
    if (fails >= _maxFreeAttempts) {
      final seconds = min(30 * pow(2, fails - _maxFreeAttempts).toInt(), 3600);
      final until = DateTime.now().add(Duration(seconds: seconds));
      await _secure.write(
        key: _lockUntilKey,
        value: '${until.millisecondsSinceEpoch}',
      );
    }
  }

  // ----------------------------------------------------------------- store

  Future<bool> isPinFree(String password) async =>
      !await _slotFile((await _slotFor(password)).id).exists();

  Future<UnlockedRoom> store(String password, RoomSecrets secrets) async {
    final slot = await _slotFor(password);
    final file = _slotFile(slot.id);
    if (await file.exists()) {
      throw StateError('Password already used by another room');
    }
    await _writeSlot(slot, secrets.toJson());
    // A few extra decoys each time keeps the file count noisy.
    await _writeDecoys(_rng.nextInt(3));
    return UnlockedRoom(slot.id, slot.key, secrets);
  }

  /// Removes everything the vault holds on this phone (after moving to a
  /// new one): every slot, data file and media, the salt, and the device
  /// pepper in the Keystore, so nothing left on disk can be opened again.
  /// [init] then starts a fresh, empty vault.
  Future<void> wipe() async {
    if (await _dir.exists()) await _dir.delete(recursive: true);
    for (final k in [_pepperKey, _appSetKey, _failsKey, _lockUntilKey]) {
      await _secure.delete(key: k);
    }
    _pepper = null;
    await init();
  }

  /// Forget a private room on this device. Its files are overwritten by a
  /// decoy of the same shape so the folder looks the same as before.
  Future<void> forget(UnlockedRoom room) async {
    await _slotFile(room.slotId).writeAsBytes(
      await Crypto.randomBytes(await _sealedSlotSize()),
      flush: true,
    );
    await _dataFile(
      room.slotId,
    ).writeAsBytes(await Crypto.randomBytes(1024 + _rng.nextInt(60000)));
  }

  // ------------------------------------------------------- per-room data

  /// Encrypted blob of an area (room message cache, app room list). Null if
  /// never written.
  Future<Uint8List?> readData(VaultArea room) async {
    final f = _dataFile(room.slotId);
    if (!await f.exists()) return null;
    try {
      return await Crypto.open(
        room.key,
        await f.readAsBytes(),
        context: 'data',
      );
    } on Object {
      return null; // decoy content from a fresh slot
    }
  }

  Future<void> writeData(VaultArea room, Uint8List plain) async {
    final sealed = await Crypto.seal(room.key, plain, context: 'data');
    final f = _dataFile(room.slotId);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(sealed, flush: true);
    await tmp.rename(f.path);
  }

  /// Folder for this room's encrypted media, named so it cannot be matched
  /// to a slot file.
  Future<Directory> mediaDir(VaultArea room) async {
    final name = Crypto.hex(await Crypto.subkey(room.key, 'media-dir'));
    final d = Directory(p.join(_dir.path, 'm', name.substring(0, 32)));
    await d.create(recursive: true);
    return d;
  }

  // -------------------------------------------------------------- helpers

  Future<_Slot> _slotFor(String secret, {String domain = ''}) async {
    final password =
        (BytesBuilder(copy: false)
              // Empty domain = no prefix, byte-identical to v0.1 slots.
              ..add(
                domain.isEmpty ? const [] : utf8.encode('\u0000$domain\u0000'),
              )
              ..add(utf8.encode(secret))
              ..add(_pepper!))
            .toBytes();
    final master = await Crypto.deriveFromPassword(password, _salt);
    final id = Crypto.hex(
      Uint8List.sublistView(await Crypto.subkey(master, 'slot-id'), 0, 16),
    );
    return _Slot(id, await Crypto.subsecret(master, 'slot-enc'));
  }

  File _slotFile(String id) => File(p.join(_dir.path, '$id.slot'));
  File _dataFile(String id) => File(p.join(_dir.path, '$id.data'));

  Future<void> _writeSlot(
    _Slot slot,
    Map<String, dynamic> payload, {
    bool keepData = false,
  }) async {
    final sealed = await Crypto.seal(slot.key, _pad(payload), context: 'slot');
    final f = _slotFile(slot.id);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(sealed, flush: true);
    await tmp.rename(f.path);
    if (!keepData) {
      await _dataFile(
        slot.id,
      ).writeAsBytes(await Crypto.randomBytes(1024 + _rng.nextInt(60000)));
    }
  }

  /// Decoys must match real slots byte for byte in length.
  Future<int> _sealedSlotSize() async =>
      await Crypto.nonceLength() + _slotPlainSize + await Crypto.aeadOverhead();

  Future<void> _writeDecoys(int count) async {
    final size = await _sealedSlotSize();
    for (var i = 0; i < count; i++) {
      final id = Crypto.hex(await Crypto.randomBytes(16));
      await _slotFile(id).writeAsBytes(await Crypto.randomBytes(size));
      await _dataFile(
        id,
      ).writeAsBytes(await Crypto.randomBytes(1024 + _rng.nextInt(60000)));
    }
  }

  Uint8List _pad(Map<String, dynamic> payload) {
    final json = utf8.encode(jsonEncode(payload));
    if (json.length > _slotPlainSize - 4) {
      throw StateError('slot payload too large');
    }
    final out = Uint8List(_slotPlainSize);
    ByteData.sublistView(out).setUint32(0, json.length);
    out.setRange(4, 4 + json.length, json);
    return out;
  }

  Map<String, dynamic> _unpad(Uint8List plain) {
    final len = ByteData.sublistView(plain).getUint32(0);
    final json = utf8.decode(Uint8List.sublistView(plain, 4, 4 + len));
    return jsonDecode(json) as Map<String, dynamic>;
  }
}

class _Slot {
  _Slot(this.id, this.key);
  final String id;
  final SharedSecret key;
}
