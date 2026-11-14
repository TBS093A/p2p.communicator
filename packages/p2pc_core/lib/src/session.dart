// One conversation member in the Rust core (native/mls_poc/src/api.rs),
// through its C ABI. Every call is synchronous and does no networking.
//
// The same code asset as lib/p2pc_core.dart (hook/build.dart's _assetName).
@DefaultAsset('package:p2pc_core/p2pc_core.dart')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class _Session extends Opaque {}

@Native<Pointer<_Session> Function(Pointer<Uint8>, Size)>(
  symbol: 'p2pc_core_new',
)
external Pointer<_Session> _new(Pointer<Uint8> name, int len);

@Native<Pointer<_Session> Function(Pointer<Uint8>, Size)>(
  symbol: 'p2pc_core_restore',
)
external Pointer<_Session> _restore(Pointer<Uint8> bytes, int len);

@Native<Pointer<Uint8> Function(Pointer<_Session>)>(symbol: 'p2pc_core_save')
external Pointer<Uint8> _save(Pointer<_Session> s);

@Native<Pointer<Uint8> Function(Pointer<_Session>, Pointer<Uint8>, Size)>(
  symbol: 'p2pc_core_round',
)
external Pointer<Uint8> _round(
  Pointer<_Session> s,
  Pointer<Uint8> req,
  int len,
);

@Native<Pointer<Uint8> Function(Pointer<_Session>, Uint64)>(
  symbol: 'p2pc_core_info',
)
external Pointer<Uint8> _info(Pointer<_Session> s, int since);

@Native<Void Function(Pointer<_Session>)>(symbol: 'p2pc_core_close')
external void _close(Pointer<_Session> s);

@Native<Void Function(Pointer<Uint8>)>(symbol: 'p2pc_mls_poc_free')
external void _free(Pointer<Uint8> buf);

/// Copies a Rust-owned `[len: u64 LE][bytes]` buffer and frees it.
Uint8List _take(Pointer<Uint8> buf) {
  try {
    final len = buf.cast<Uint64>().value;
    return Uint8List.fromList(
      Pointer<Uint8>.fromAddress(buf.address + 8).asTypedList(len),
    );
  } finally {
    _free(buf);
  }
}

/// Runs [f] with [bytes] copied to native memory.
T _withBytes<T>(Uint8List bytes, T Function(Pointer<Uint8> p, int len) f) {
  final p = malloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  try {
    p.asTypedList(bytes.length).setAll(0, bytes);
    return f(p, bytes.length);
  } finally {
    malloc.free(p);
  }
}

class CoreSession {
  CoreSession._(this._ptr);

  Pointer<_Session> _ptr;

  /// A new member with a fresh conversation identity.
  factory CoreSession.create(String name) {
    final p = _withBytes(utf8.encode(name), _new);
    if (p == nullptr) throw StateError('core: cannot create a session');
    return CoreSession._(p);
  }

  /// A member from [save]'s bytes; null if they are not a valid state.
  static CoreSession? restore(Uint8List state) {
    final p = _withBytes(state, _restore);
    return p == nullptr ? null : CoreSession._(p);
  }

  void _check() {
    if (_ptr == nullptr) throw StateError('core: session closed');
  }

  /// The whole state, to keep (encrypted) in the PIN vault. Save after
  /// every committed round, before performing its writes.
  Uint8List save() {
    _check();
    return _take(_save(_ptr));
  }

  /// One round of the host loop (see CoreHost).
  Map<String, dynamic> round(Map<String, dynamic> request) {
    _check();
    final out = _withBytes(
      utf8.encode(jsonEncode(request)),
      (p, len) => _round(_ptr, p, len),
    );
    return jsonDecode(utf8.decode(_take(out))) as Map<String, dynamic>;
  }

  /// Identity, group, members, messages from index [since], warnings.
  Map<String, dynamic> info({int since = 0}) {
    _check();
    return jsonDecode(utf8.decode(_take(_info(_ptr, since))))
        as Map<String, dynamic>;
  }

  void close() {
    if (_ptr == nullptr) return;
    _close(_ptr);
    _ptr = nullptr;
  }
}
