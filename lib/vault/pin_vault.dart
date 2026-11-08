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

/// A room opened with its PIN: the slot it lives in, the slot key, and the
/// secrets needed to reconnect to it.
class UnlockedRoom {
  UnlockedRoom(this.slotId, this.key, this.secrets);
  final String slotId;
  final SharedSecret key;
  final RoomSecrets secrets;
}

class VaultLockedOut implements Exception {
  VaultLockedOut(this.remaining);
  final Duration remaining;
}

/// PIN -> room vault.
///
/// * master = Argon2(PIN || devicePepper, vaultSalt). The pepper is 32 random
///   bytes kept in Android Keystore-backed storage, so a copy of the app's files
///   alone cannot be brute-forced offline, however short the PIN.
/// * The slot file name is derived from master, so one PIN means one Argon2 run
///   and a direct file lookup; there is no list of rooms anywhere.
/// * Every slot is padded to the same size and decoy slots are written next to
///   real ones, so the folder does not show how many rooms exist.
/// * A wrong PIN and "no room for this PIN" are the same thing: nothing opens.
class PinVault {
  PinVault._();
  static final PinVault instance = PinVault._();

  static const _slotPlainSize = 4096;
  static const _maxFreeAttempts = 5;
  static const _pepperKey = 'vault_pepper_v1';
  static const _failsKey = 'vault_fails';
  static const _lockUntilKey = 'vault_lock_until';

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

  /// Returns the room for [pin], or null. Throws [VaultLockedOut] while
  /// attempts are throttled.
  Future<UnlockedRoom?> unlock(String pin) async {
    final left = await lockoutRemaining();
    if (left != null) throw VaultLockedOut(left);

    final slot = await _slotFor(pin);
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
        return UnlockedRoom(slot.id, slot.key, _unpad(plain));
      } on Object {
        // Name collision with a decoy or a damaged file: treat as wrong PIN.
      }
    }
    await _registerFailure();
    return null;
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

  Future<bool> isPinFree(String pin) async =>
      !await _slotFile((await _slotFor(pin)).id).exists();

  Future<UnlockedRoom> store(String pin, RoomSecrets secrets) async {
    final slot = await _slotFor(pin);
    final file = _slotFile(slot.id);
    if (await file.exists()) {
      throw StateError('PIN already used by another room');
    }
    await _writeSlot(slot, secrets);
    // A few extra decoys each time keeps the file count noisy.
    await _writeDecoys(_rng.nextInt(3));
    return UnlockedRoom(slot.id, slot.key, secrets);
  }

  /// Forget a room on this device. Its files are overwritten by a decoy of the
  /// same shape so the folder looks the same as before.
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

  /// Encrypted per-room blob (message cache). Null if never written.
  Future<Uint8List?> readData(UnlockedRoom room) async {
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

  Future<void> writeData(UnlockedRoom room, Uint8List plain) async {
    final sealed = await Crypto.seal(room.key, plain, context: 'data');
    final f = _dataFile(room.slotId);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(sealed, flush: true);
    await tmp.rename(f.path);
  }

  /// Folder for this room's encrypted media, named so it cannot be matched
  /// to a slot file.
  Future<Directory> mediaDir(UnlockedRoom room) async {
    final name = Crypto.hex(await Crypto.subkey(room.key, 'media-dir'));
    final d = Directory(p.join(_dir.path, 'm', name.substring(0, 32)));
    await d.create(recursive: true);
    return d;
  }

  // -------------------------------------------------------------- helpers

  Future<_Slot> _slotFor(String pin) async {
    final password =
        (BytesBuilder(copy: false)
              ..add(utf8.encode(pin))
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

  Future<void> _writeSlot(_Slot slot, RoomSecrets secrets) async {
    final sealed = await Crypto.seal(slot.key, _pad(secrets), context: 'slot');
    await _slotFile(slot.id).writeAsBytes(sealed, flush: true);
    await _dataFile(
      slot.id,
    ).writeAsBytes(await Crypto.randomBytes(1024 + _rng.nextInt(60000)));
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

  Uint8List _pad(RoomSecrets s) {
    final json = utf8.encode(jsonEncode(s.toJson()));
    if (json.length > _slotPlainSize - 4) {
      throw StateError('room secrets too large for a slot');
    }
    final out = Uint8List(_slotPlainSize);
    ByteData.sublistView(out).setUint32(0, json.length);
    out.setRange(4, 4 + json.length, json);
    return out;
  }

  RoomSecrets _unpad(Uint8List plain) {
    final len = ByteData.sublistView(plain).getUint32(0);
    final json = utf8.decode(Uint8List.sublistView(plain, 4, 4 + len));
    return RoomSecrets.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }
}

class _Slot {
  _Slot(this.id, this.key);
  final String id;
  final SharedSecret key;
}
