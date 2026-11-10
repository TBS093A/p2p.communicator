import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:veilid/veilid.dart';

import '../core/veilid_node.dart';

/// Small conveniences over the Veilid routing context.
class Dht {
  Dht._();

  static VeilidRoutingContext get rc => VeilidNode.instance.routing;

  /// Runs [op], retrying the errors Veilid documents as retryable. Bounded:
  /// at most [attempts] tries and a few seconds of waiting in between.
  static Future<T> retry<T>(
    Future<T> Function() op, {
    int attempts = 3,
    String what = 'dht op',
  }) async {
    for (var i = 1; ; i++) {
      final sw = Stopwatch()..start();
      try {
        final r = await op();
        _log('$what ok in ${sw.elapsedMilliseconds} ms (try $i)');
        return r;
      } on VeilidAPIExceptionTryAgain catch (e) {
        _log('$what try-again after ${sw.elapsedMilliseconds} ms: $e');
        if (i >= attempts) rethrow;
      } on VeilidAPIExceptionTimeout catch (e) {
        _log('$what timeout after ${sw.elapsedMilliseconds} ms: $e');
        if (i >= attempts) rethrow;
      } on VeilidAPIExceptionNoConnection catch (e) {
        _log('$what no-connection after ${sw.elapsedMilliseconds} ms: $e');
        if (i >= attempts) rethrow;
      }
      await Future<void>.delayed(Duration(seconds: 2 * i));
    }
  }

  static Future<Uint8List?> get(
    RecordKey key,
    int subkey, {
    bool refresh = true,
  }) async => (await getValue(key, subkey, refresh: refresh))?.data;

  /// Like [get], but keeps the value's sequence number, so a caller can
  /// tell a newer value from an older one (lagging replica, late update).
  static Future<ValueData?> getValue(
    RecordKey key,
    int subkey, {
    bool refresh = true,
  }) async {
    final v = await retry(
      () => rc.getDHTValue(key, subkey, forceRefresh: refresh),
      what: 'get ${_short(key)}#$subkey',
    );
    if (v == null || v.data.isEmpty) return null;
    return v;
  }

  static Future<Map<String, dynamic>?> getJson(
    RecordKey key,
    int subkey, {
    bool refresh = true,
  }) async => decodeJson(await get(key, subkey, refresh: refresh));

  /// A JSON object from DHT bytes; null for empty or malformed data.
  static Map<String, dynamic>? decodeJson(Uint8List? data) {
    if (data == null || data.isEmpty) return null;
    try {
      final j = jsonDecode(utf8.decode(data));
      return j is Map<String, dynamic> ? j : null;
    } on FormatException {
      return null;
    }
  }

  /// Writes a subkey. Returns null when our value stands, or the value the
  /// network holds instead (someone else won the write).
  static Future<Uint8List?> set(
    RecordKey key,
    int subkey,
    Uint8List data,
  ) async {
    final newer = await retry(
      () => rc.setDHTValue(key, subkey, data),
      what: 'set ${_short(key)}#$subkey (${data.length} B)',
    );
    return newer?.data;
  }

  static Future<void> setJson(
    RecordKey key,
    int subkey,
    Map<String, dynamic> json,
  ) => set(key, subkey, Uint8List.fromList(utf8.encode(jsonEncode(json))));

  /// Local-first write for records only we write to (fresh rooms, our own
  /// outbox): Veilid stores the value locally at once and pushes it to the
  /// network itself, so wait at most [budget] for the push and let it finish
  /// in the background.
  static Future<void> setJsonSoon(
    RecordKey key,
    int subkey,
    Map<String, dynamic> json, {
    Duration budget = const Duration(seconds: 8),
  }) async {
    final write = setJson(key, subkey, json);
    try {
      await write.timeout(budget);
    } on TimeoutException {
      _log('set ${_short(key)}#$subkey continues in background');
      unawaited(
        write.catchError(
          (Object e) => _log('background set ${_short(key)}#$subkey: $e'),
        ),
      );
    }
  }

  static Future<void> close(RecordKey key) async {
    try {
      await rc.closeDHTRecord(key);
    } on VeilidAPIException {
      // Already closed or never opened.
    }
  }

  /// Runs [count] jobs with at most [parallel] in flight.
  static Future<void> pool(
    int count,
    int parallel,
    Future<void> Function(int i) job,
  ) async {
    var next = 0;
    Future<void> worker() async {
      while (next < count) {
        final i = next++;
        await job(i);
      }
    }

    await Future.wait(List.generate(parallel, (_) => worker()));
  }

  /// Short, non-secret record label for logs: the start of the opaque key
  /// only, never the encryption secret.
  static String _short(RecordKey key) {
    final s = key.opaque.value.toString();
    return s.length > 8 ? s.substring(0, 8) : s;
  }

  static void _log(String msg) => debugPrint('[dht] $msg');
}
