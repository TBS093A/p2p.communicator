import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:veilid/veilid.dart';

import '../core/veilid_node.dart';

/// Small conveniences over the Veilid routing context.
class Dht {
  Dht._();

  static VeilidRoutingContext get rc => VeilidNode.instance.routing;

  /// Runs [op], retrying the errors Veilid documents as retryable.
  static Future<T> retry<T>(
    Future<T> Function() op, {
    int attempts = 6,
    Duration delay = const Duration(seconds: 2),
  }) async {
    for (var i = 1; ; i++) {
      try {
        return await op();
      } on VeilidAPIExceptionTryAgain {
        if (i >= attempts) rethrow;
      } on VeilidAPIExceptionTimeout {
        if (i >= attempts) rethrow;
      } on VeilidAPIExceptionNoConnection {
        if (i >= attempts) rethrow;
      }
      await Future<void>.delayed(delay * i);
    }
  }

  static Future<Uint8List?> get(
    RecordKey key,
    int subkey, {
    bool refresh = true,
  }) async {
    final v = await retry(
      () => rc.getDHTValue(key, subkey, forceRefresh: refresh),
    );
    if (v == null || v.data.isEmpty) return null;
    return v.data;
  }

  static Future<Map<String, dynamic>?> getJson(
    RecordKey key,
    int subkey, {
    bool refresh = true,
  }) async {
    final data = await get(key, subkey, refresh: refresh);
    if (data == null) return null;
    try {
      return jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
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
    final newer = await retry(() => rc.setDHTValue(key, subkey, data));
    return newer?.data;
  }

  static Future<void> setJson(
    RecordKey key,
    int subkey,
    Map<String, dynamic> json,
  ) => set(key, subkey, Uint8List.fromList(utf8.encode(jsonEncode(json))));

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
}
