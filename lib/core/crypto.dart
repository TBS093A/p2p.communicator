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
  ///
  /// [context] binds the ciphertext to its purpose: data sealed for one
  /// context does not open under another. It is applied as a per-context key
  /// rather than AEAD associated data, because veilid-flutter 0.5.8 passes
  /// associated data over FFI as a JSON array where veilid-core expects
  /// base64, so every call with associated data fails with a ParseError.
  static Future<Uint8List> seal(
    SharedSecret key,
    Uint8List plain, {
    String? context,
  }) async {
    final k = await _contextKey(key, context);
    final nonce = await _cs.randomNonce();
    final ct = await _cs.encryptAead(plain, nonce, k, null);
    return (BytesBuilder(copy: false)
          ..add(nonce.toBytes())
          ..add(ct))
        .toBytes();
  }

  /// Reverses [seal]. Throws if the key or context is wrong or the data was
  /// altered.
  static Future<Uint8List> open(
    SharedSecret key,
    Uint8List sealed, {
    String? context,
  }) async {
    final n = await _cs.nonceLength();
    if (sealed.length <= n) {
      throw const FormatException('sealed data too short');
    }
    final k = await _contextKey(key, context);
    final nonce = Nonce.fromBytes(Uint8List.sublistView(sealed, 0, n));
    return _cs.decryptAead(Uint8List.sublistView(sealed, n), nonce, k, null);
  }

  /// Encrypts [plain] so that only the holder of the secret key matching the
  /// signing public key [to] can read it (HPKE; ed25519 identity keys are
  /// bridged to x25519). [context] is authenticated, must match on open.
  static Future<Uint8List> sealTo(
    PublicKey to,
    Uint8List plain, {
    required String context,
  }) async {
    final recipient = await _cs.encapsulationKeyFromSigningKey(to);
    return _cs.hpkeSeal(
      recipient,
      Uint8List.fromList(utf8.encode(context)),
      plain,
    );
  }

  /// Reverses [sealTo] with our own identity key pair. Throws if the blob
  /// was not sealed to us, the context differs, or it was altered.
  static Future<Uint8List> openWith(
    KeyPair me,
    Uint8List sealed, {
    required String context,
  }) async {
    final secret = await _cs.decapsulationKeyFromSigningSecret(me.secret);
    return _cs.hpkeOpen(
      secret,
      Uint8List.fromList(utf8.encode(context)),
      sealed,
    );
  }

  static Future<KeyPair> newIdentity() => _cs.generateKeyPair();

  static Future<SharedSecret> _contextKey(
    SharedSecret key,
    String? context,
  ) async => context == null ? key : subsecret(key, 'aead:$context');

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
}
