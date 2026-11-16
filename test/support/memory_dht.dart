import 'dart:math';
import 'dart:typed_data';

import 'package:p2pc_core/p2pc_core.dart';

/// An in-memory DHT for the host loop: what the app implements over Veilid.
class MemoryDht implements CoreDht {
  final _values = <String, Uint8List>{};
  final _rng = Random(7);
  var _next = 0;
  int reads = 0;
  int writes = 0;

  @override
  int now = 0;

  Uint8List _secret() =>
      Uint8List.fromList(List.generate(32, (_) => _rng.nextInt(256)));

  @override
  Future<Uint8List?> get(String record, int subkey) async {
    reads++;
    return _values['$record#$subkey'];
  }

  @override
  Future<void> set(
    String record,
    int subkey,
    Uint8List value,
    Uint8List writer,
  ) async {
    writes++;
    _values['$record#$subkey'] = value;
  }

  @override
  Future<(String, Uint8List)> createRecord() async =>
      ('rec${_next++}', _secret());

  @override
  Future<(String, Uint8List, Uint8List)> createRendezvous() async =>
      ('rv${_next++}', _secret(), _secret());
}
