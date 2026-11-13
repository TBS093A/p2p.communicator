// The v2 protocol core (Rust) as seen from Dart. Phase 1b of
// docs/V2_PLAN.md: the library is built into the app and reachable; the
// protocol API (sans-IO rounds) follows in the next phase.
//
// @DefaultAsset names the asset hook/build.dart declares as `_assetName`.
@DefaultAsset('package:p2pc_core/p2pc_core.dart')
library;

import 'dart:convert';
import 'dart:ffi';

@Native<Pointer<Uint8> Function()>(symbol: 'p2pc_mls_poc_run')
external Pointer<Uint8> _run();

@Native<Void Function(Pointer<Uint8>)>(symbol: 'p2pc_mls_poc_free')
external void _free(Pointer<Uint8> buf);

/// Runs the core's built-in end-to-end scenario (two identities, group,
/// join, messages, epoch rotation, restart, removal) on an in-memory DHT and
/// returns its report: `ok`, the steps, sizes and timings. Proves the
/// library is in the build and works on this device. Takes well under a
/// second; call it off the UI thread anyway (Isolate.run).
Map<String, dynamic> coreSelfTest() {
  final buf = _run();
  try {
    final len = buf.cast<Uint64>().value;
    final json = Pointer<Uint8>.fromAddress(buf.address + 8).asTypedList(len);
    return jsonDecode(utf8.decode(json)) as Map<String, dynamic>;
  } finally {
    _free(buf);
  }
}
