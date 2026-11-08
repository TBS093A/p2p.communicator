import 'dart:convert';
import 'dart:typed_data';

import 'package:veilid/veilid.dart';

import 'veilid_node.dart';

/// Thin helpers over the Veilid cryptosystem (VLD0: XChaCha20-Poly1305,
/// BLAKE3, Argon2), so the whole app uses one audited native crypto stack.
class Crypto {
  Crypto._();

  static VeilidCryptoSystem get _cs => VeilidNode.instance.crypto;

  static Future<Uint8List> randomBytes(int n) => _cs.randomBytes(n);

  /// Encrypts [plain]; output is `nonce || ciphertext+tag`.
  static Future<Uint8List> seal(
    SharedSecret key,
    Uint8List plain, {
    String? context,
  }) async {
    final nonce = await _cs.randomNonce();
    final ct = await _cs.encryptAead(plain, nonce, key, _ad(context));
    return (BytesBuilder(copy: false)
          ..add(nonce.toBytes())
          ..add(ct))
        .toBytes();
  }

  /// Reverses [seal]. Throws if the key is wrong or the data was altered.
  static Future<Uint8List> open(
    SharedSecret key,
    Uint8List sealed, {
    String? context,
  }) async {
    final n = await _cs.nonceLength();
    if (sealed.length <= n) {
      throw const FormatException('sealed data too short');
    }
    final nonce = Nonce.fromBytes(Uint8List.sublistView(sealed, 0, n));
    return _cs.decryptAead(
      Uint8List.sublistView(sealed, n),
      nonce,
      key,
      _ad(context),
    );
  }

  /// Argon2 over [password] and [salt] (native, in veilid-core).
  static Future<SharedSecret> deriveFromPassword(
    Uint8List password,
    Uint8List salt,
  ) => _cs.deriveSharedSecret(password, salt);

  static Future<int> saltLength() => _cs.defaultSaltLength();
  static Future<int> nonceLength() => _cs.nonceLength();
  static Future<int> aeadOverhead() => _cs.aeadOverhead();

  /// Domain-separated subkey: BLAKE3(label || key).
  static Future<Uint8List> subkey(SharedSecret key, String label) async {
    final digest = await _cs.generateHash(
      (BytesBuilder(copy: false)
            ..add(utf8.encode(label))
            ..addByte(0)
            ..add(key.value.toBytes()))
          .toBytes(),
    );
    return digest.value.toBytes();
  }

  static Future<SharedSecret> subsecret(SharedSecret key, String label) async =>
      secretFromBytes(await subkey(key, label));

  static SharedSecret secretFromBytes(Uint8List bytes) =>
      SharedSecret(kind: _cs.kind(), value: BareSharedSecret.fromBytes(bytes));

  static Future<String> hashHex(Uint8List data) async {
    final digest = await _cs.generateHash(data);
    return hex(digest.value.toBytes());
  }

  static String hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List? _ad(String? context) =>
      context == null ? null : Uint8List.fromList(utf8.encode(context));
}
