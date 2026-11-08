import 'dart:math';
import 'dart:typed_data';

import 'package:veilid/veilid.dart';

import '../core/crypto.dart';
import 'dht.dart';
import 'message.dart';

class MediaCorruptException implements Exception {}

/// Stores files in the DHT as chunk records: 32 000-byte chunks (subkey limit
/// is 32 KiB), 30 chunks per record (record limit is 1 MiB). Each record has a
/// fresh random owner and its own encryption secret, and the list of record
/// keys travels only inside a room message, so only room members can find or
/// read the file. A 20 MB video is about 21 records.
class BlobStore {
  BlobStore._();

  static const chunkSize = 32000;
  static const chunksPerRecord = 30;
  static const _parallel = 4;

  static Future<MediaRef> upload(
    Uint8List bytes, {
    required String mime,
    int? width,
    int? height,
    int? durationMs,
    void Function(double progress)? onProgress,
  }) async {
    final hash = await Crypto.hashHex(bytes);
    final chunks = (bytes.length + chunkSize - 1) ~/ chunkSize;
    final recordCount = (chunks + chunksPerRecord - 1) ~/ chunksPerRecord;
    final records = <String>[];
    var done = 0;

    for (var r = 0; r < recordCount; r++) {
      final first = r * chunksPerRecord;
      final count = min(chunksPerRecord, chunks - first);
      final desc = await Dht.rc.createDHTRecord(
        bestCryptoKind,
        DHTSchema.dflt(oCnt: count),
      );
      try {
        await Dht.pool(count, _parallel, (j) async {
          final start = (first + j) * chunkSize;
          final end = min(start + chunkSize, bytes.length);
          await Dht.set(desc.key, j, Uint8List.sublistView(bytes, start, end));
          onProgress?.call(++done / chunks);
        });
      } finally {
        await Dht.close(desc.key);
      }
      records.add(desc.key.toString());
    }

    return MediaRef(
      mime: mime,
      size: bytes.length,
      hash: hash,
      records: records,
      chunkSize: chunkSize,
      chunksPerRecord: chunksPerRecord,
      width: width,
      height: height,
      durationMs: durationMs,
    );
  }

  static Future<Uint8List> download(
    MediaRef ref, {
    void Function(double progress)? onProgress,
  }) async {
    final out = Uint8List(ref.size);
    final total = ref.chunkCount;
    var done = 0;

    for (var r = 0; r < ref.records.length; r++) {
      final key = RecordKey.fromString(ref.records[r]);
      final first = r * ref.chunksPerRecord;
      final count = min(ref.chunksPerRecord, total - first);
      await Dht.retry(() => Dht.rc.openDHTRecord(key));
      try {
        await Dht.pool(count, _parallel, (j) async {
          final data = await _chunk(key, j);
          out.setRange(
            (first + j) * ref.chunkSize,
            (first + j) * ref.chunkSize + data.length,
            data,
          );
          onProgress?.call(++done / total);
        });
      } finally {
        await Dht.close(key);
      }
    }

    if (await Crypto.hashHex(out) != ref.hash) throw MediaCorruptException();
    return out;
  }

  /// A chunk the sender wrote moments ago may not have spread yet.
  static Future<Uint8List> _chunk(RecordKey key, int subkey) async {
    for (var attempt = 1; ; attempt++) {
      final data = await Dht.get(key, subkey);
      if (data != null) return data;
      if (attempt >= 8) throw MediaCorruptException();
      await Future<void>.delayed(Duration(seconds: 2 * attempt));
    }
  }
}
