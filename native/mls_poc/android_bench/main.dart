// docs/PROTOCOL.md B13: on-device measurements of the MLS PoC.
//
// A throwaway Flutter app, not part of the messenger: CI creates an empty
// Flutter project, copies this file in as lib/main.dart, puts
// libmls_poc.so (cargo-ndk, arm64-v8a) into its jniLibs and builds an APK
// (workflow mls-poc.yml, job "Android bench APK"). Install it, tap Run,
// and send the copied report.
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _runs = 20;

typedef _BenchC = Pointer<Uint8> Function(Uint32);
typedef _BenchDart = Pointer<Uint8> Function(int);
typedef _FreeC = Void Function(Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Uint8>);

/// Runs the Rust bench; returns its JSON report.
String _bench(int runs) {
  final lib = DynamicLibrary.open('libmls_poc.so');
  final bench = lib.lookupFunction<_BenchC, _BenchDart>('p2pc_mls_poc_bench');
  final free = lib.lookupFunction<_FreeC, _FreeDart>('p2pc_mls_poc_free');
  final watch = Stopwatch()..start();
  final buf = bench(runs);
  watch.stop();
  try {
    final len = buf.cast<Uint64>().value;
    final json = Pointer<Uint8>.fromAddress(buf.address + 8).asTypedList(len);
    final report = jsonDecode(utf8.decode(json)) as Map<String, dynamic>;
    report['wall_ms_total'] = watch.elapsedMilliseconds;
    return const JsonEncoder.withIndent(' ').convert(report);
  } finally {
    free(buf);
  }
}

String _summary(String json) {
  final r = jsonDecode(json) as Map<String, dynamic>;
  final out = StringBuffer()
    ..writeln('ok: ${r['ok']}  runs: ${r['runs']}  ${r['os']}/${r['arch']}')
    ..writeln(
      'RSS KiB: before ${r['rss_kib_before']}, after ${r['rss_kib_after']}, '
      'peak ${r['rss_kib_peak']}',
    )
    ..writeln()
    ..writeln('operation: first / median / max ms');
  final first = {for (final e in r['first_ms'] as List) e[0]: e[1]};
  final max = {for (final e in r['max_ms'] as List) e[0]: e[1]};
  for (final e in r['median_ms'] as List) {
    String ms(Object? v) => (v as num).toStringAsFixed(2);
    out.writeln('${e[0]}: ${ms(first[e[0]])} / ${ms(e[1])} / ${ms(max[e[0]])}');
  }
  return out.toString();
}

void main() => runApp(const MaterialApp(home: _BenchPage()));

class _BenchPage extends StatefulWidget {
  const _BenchPage();

  @override
  State<_BenchPage> createState() => _BenchPageState();
}

class _BenchPageState extends State<_BenchPage> {
  String? _json;
  String _text = 'Tap Run. It takes a few seconds.';
  bool _running = false;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _text = 'Running $_runs times...';
    });
    try {
      final json = await Isolate.run(() => _bench(_runs));
      setState(() {
        _json = json;
        _text = _summary(json);
      });
    } catch (e) {
      setState(() => _text = 'Failed: $e');
    } finally {
      setState(() => _running = false);
    }
  }

  Future<void> _copy() async {
    final json = _json;
    if (json == null) return;
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Report copied')));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('MLS PoC bench')),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(
        _text,
        style: const TextStyle(fontFamily: 'monospace'),
      ),
    ),
    floatingActionButton: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_json != null)
          FloatingActionButton.extended(
            heroTag: 'copy',
            onPressed: _copy,
            icon: const Icon(Icons.copy),
            label: const Text('Copy report'),
          ),
        const SizedBox(width: 12),
        FloatingActionButton.extended(
          heroTag: 'run',
          onPressed: _running ? null : _run,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Run'),
        ),
      ],
    ),
  );
}
