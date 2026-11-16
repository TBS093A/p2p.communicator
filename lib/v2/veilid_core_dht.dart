// The v2 core's DHT (packages/p2pc_core CoreDht) over the real Veilid node
// (docs/V2_PLAN.md phase 2). The core sees records as opaque strings and
// writers as opaque bytes; here they are a RecordKey string and the UTF-8 of
// a `kind:public:secret` KeyPair string.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:p2pc_core/p2pc_core.dart';
import 'package:veilid/veilid.dart';

import '../core/veilid_node.dart';
import '../room/dht.dart';

/// Subkeys of every plain record the core asks for: the largest it uses is
/// an outbox, 1 head + OUTBOX_RING (docs/PROTOCOL.md §B3.1). A control
/// record (1 + 28) uses the first ones only; empty subkeys cost nothing.
const coreRecordSubkeys = 1 + 200;

/// One-time rendezvous (PROTOCOL §B3.1): the owner (admin) answers in
/// subkeys 0..3, the joiner, holding the slot key pair from the invite,
/// writes its request in 4..7. Veilid SMPL puts the owner's subkeys first.
const rendezvousOwnerSubkeys = 4;
const rendezvousSlotSubkeys = 4;

class VeilidCoreDht implements CoreDht {
  VeilidCoreDht({this.writeBudget = const Duration(seconds: 8)});

  /// How long a write waits for the network before it carries on in the
  /// background (Veilid has already stored it locally and keeps pushing).
  final Duration writeBudget;

  // Records this object has open, with the writer they are open with
  // (null: read-only). Re-opening replaces the writer.
  final _open = <String, String?>{};

  @override
  int get now =>
      DateTime.now().millisecondsSinceEpoch ~/ Duration.millisecondsPerHour;

  Future<RecordKey> _ensureOpen(String record, {String? writer}) async {
    final key = RecordKey.fromString(record);
    final have = _open.containsKey(record);
    // Reading never drops a writer we already hold.
    if (have && (writer == null || _open[record] == writer)) return key;
    await Dht.retry(
      () => Dht.rc.openDHTRecord(
        key,
        writer: writer == null ? null : KeyPair.fromString(writer),
      ),
      what: 'open core record',
    );
    _open[record] = writer ?? _open[record];
    return key;
  }

  @override
  Future<Uint8List?> get(String record, int subkey) async {
    try {
      final key = await _ensureOpen(record);
      return await Dht.get(key, subkey);
    } on VeilidAPIException catch (e) {
      // Not found or unreachable reads as "not propagated yet": the core
      // treats an empty subkey as the end of what is there and asks again on
      // the next sync.
      _log('get #$subkey: $e');
      return null;
    }
  }

  @override
  Future<void> set(
    String record,
    int subkey,
    Uint8List value,
    Uint8List writer,
  ) async {
    final key = await _ensureOpen(record, writer: utf8.decode(writer));
    final write = Dht.set(key, subkey, value);
    try {
      final newer = await write.timeout(writeBudget);
      if (newer != null) {
        // Every subkey has a single writer in the v2 layout, so this is our
        // own older value or a replica lagging behind; the core detects real
        // conflicts itself (hash chain, positions).
        _log('set #$subkey: network kept another value');
      }
    } on TimeoutException {
      unawaited(
        write.then<void>(
          (_) {},
          onError: (Object e) => _log('background set #$subkey: $e'),
        ),
      );
    }
  }

  @override
  Future<(String, Uint8List)> createRecord() async {
    final d = await Dht.retry(
      () => Dht.rc.createDHTRecord(
        bestCryptoKind,
        const DHTSchema.dflt(oCnt: coreRecordSubkeys),
      ),
      what: 'create core record',
    );
    final owner = d.ownerKeyPair!.toString();
    _open[d.key.toString()] = owner;
    return (d.key.toString(), Uint8List.fromList(utf8.encode(owner)));
  }

  @override
  Future<(String, Uint8List, Uint8List)> createRendezvous() async {
    final slot = await VeilidNode.instance.crypto.generateKeyPair();
    final member = await DHTSchemaMember.fromPublicKey(
      Veilid.instance,
      slot.key,
      rendezvousSlotSubkeys,
    );
    final d = await Dht.retry(
      () => Dht.rc.createDHTRecord(
        bestCryptoKind,
        DHTSchema.smpl(oCnt: rendezvousOwnerSubkeys, members: [member]),
      ),
      what: 'create rendezvous',
    );
    final owner = d.ownerKeyPair!.toString();
    _open[d.key.toString()] = owner;
    return (
      d.key.toString(),
      Uint8List.fromList(utf8.encode(owner)),
      Uint8List.fromList(utf8.encode(slot.toString())),
    );
  }

  /// Closes every record this object opened.
  Future<void> close() async {
    final keys = _open.keys.toList();
    _open.clear();
    for (final k in keys) {
      await Dht.close(RecordKey.fromString(k));
    }
  }

  static void _log(String msg) => debugPrint('[v2 dht] $msg');
}
