// docs/PROTOCOL.md B13: the minimal MLS scenario called from Flutter
// through dart:ffi, the way the app would call a Rust core.
//
// Not part of the normal `flutter test` run (it needs the Rust library):
//
//   cargo build --manifest-path native/mls_poc/Cargo.toml
//   flutter test native/mls_poc/flutter_test
//
// MLS_POC_LIB overrides the library path.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

typedef _RunC = Pointer<Uint8> Function();
typedef _FreeC = Void Function(Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Uint8>);

String _libraryPath() {
  final override = Platform.environment['MLS_POC_LIB'];
  if (override != null && override.isNotEmpty) return override;
  final name = Platform.isMacOS
      ? 'libmls_poc.dylib'
      : Platform.isWindows
      ? 'mls_poc.dll'
      : 'libmls_poc.so';
  return 'native/mls_poc/target/debug/$name';
}

void main() {
  test('minimal MLS scenario through FFI', () {
    final path = _libraryPath();
    expect(
      File(path).existsSync(),
      isTrue,
      reason:
          'build it first: cargo build --manifest-path '
          'native/mls_poc/Cargo.toml',
    );
    final lib = DynamicLibrary.open(path);
    final run = lib.lookupFunction<_RunC, _RunC>('p2pc_mls_poc_run');
    final free = lib.lookupFunction<_FreeC, _FreeDart>('p2pc_mls_poc_free');

    final watch = Stopwatch()..start();
    final buf = run();
    watch.stop();
    expect(buf.address, isNot(0));
    final Map<String, dynamic> report;
    try {
      final len = buf.cast<Uint64>().value;
      final json = Pointer<Uint8>.fromAddress(buf.address + 8).asTypedList(len);
      report = jsonDecode(utf8.decode(json)) as Map<String, dynamic>;
    } finally {
      free(buf);
    }

    for (final s in (report['steps'] as List).cast<Map<String, dynamic>>()) {
      // ignore: avoid_print
      print('[${s['ok'] == true ? 'ok' : 'FAIL'}] ${s['name']} ${s['detail']}');
    }
    // ignore: avoid_print
    print('whole scenario over FFI: ${watch.elapsedMilliseconds} ms');
    expect(report['ok'], isTrue, reason: jsonEncode(report['steps']));
    expect(report['ciphersuite'], contains('0x0003'));
    final sizes = {
      for (final e in (report['sizes'] as List).cast<List<dynamic>>())
        e[0] as String: e[1] as int,
    };
    expect(sizes['Welcome (2 members)'], lessThan(32 * 1024));
  });
}
