// The host loop (docs/V2_PLAN.md, option C): drives a CoreSession over an
// asynchronous DHT. The core never does networking; this does, in rounds.
import 'dart:convert';
import 'dart:typed_data';

import 'session.dart';

/// The DHT as the core needs it, implemented over Veilid by the app (and in
/// memory by the tests). Record ids and writer secrets are opaque strings
/// and bytes to the core.
abstract interface class CoreDht {
  /// Protocol time in ticks (the app: hours since the epoch).
  int get now;

  /// The subkey's value, or null when it is empty (or not propagated).
  Future<Uint8List?> get(String record, int subkey);

  Future<void> set(
    String record,
    int subkey,
    Uint8List value,
    Uint8List writer,
  );

  /// A new empty record with a fresh owner key: (record, owner secret).
  Future<(String, Uint8List)> createRecord();

  /// A new empty one-time rendezvous record: (record, owner, slot writer).
  Future<(String, Uint8List, Uint8List)> createRendezvous();
}

class CoreError implements Exception {
  CoreError(this.message);
  final String message;
  @override
  String toString() => 'core: $message';
}

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

class CoreHost {
  CoreHost(this.dht, {this.recordPool = 3, this.rendezvousPool = 1});

  final CoreDht dht;
  final int recordPool;
  final int rendezvousPool;

  // Empty records created ahead of time and not used yet (kept across
  // runs: creating one is a network round trip).
  final _records = <(String, Uint8List)>[];
  final _rendezvous = <(String, Uint8List, Uint8List)>[];

  Future<void> _fill() async {
    while (_records.length < recordPool) {
      _records.add(await dht.createRecord());
    }
    while (_rendezvous.length < rendezvousPool) {
      _rendezvous.add(await dht.createRendezvous());
    }
  }

  /// Runs [op] (`{"op": "sync"}`, `{"op": "send_text", "text": ...}`, …)
  /// on [session]: dry rounds until its reads settle, then one committed
  /// round. [persist] gets the new state before any write is performed.
  /// Returns the operation's result; throws [CoreError] if it failed (its
  /// writes, if any, have still been performed: they are safe to resume
  /// from).
  Future<Object?> run(
    CoreSession session,
    Map<String, dynamic> op, {
    required Future<void> Function(Uint8List state) persist,
  }) async {
    await _fill();
    final known = <(String, int)>{};
    final values = <(String, int), Uint8List?>{};

    Map<String, dynamic> request(bool commit) => {
      ...op,
      'now': dht.now,
      'commit': commit,
      'values': [
        for (final k in known)
          {
            'record': k.$1,
            'subkey': k.$2,
            'value': values[k] == null ? null : _hex(values[k]!),
          },
      ],
      'record_pool': [
        for (final (r, o) in _records) {'record': r, 'owner': _hex(o)},
      ],
      'rendezvous_pool': [
        for (final (r, o, s) in _rendezvous)
          {'record': r, 'owner': _hex(o), 'slot': _hex(s)},
      ],
    };

    for (var i = 0; i < 32; i++) {
      final dry = session.round(request(false));
      if (dry['ok'] != true) throw CoreError('${dry['error']}');
      final needs = [
        for (final n in dry['needs'] as List)
          ((n as List)[0] as String, n[1] as int),
      ].where((k) => !known.contains(k)).toList();
      if (needs.isEmpty) break;
      // Read what it asked for (in parallel; Veilid batches poorly).
      final got = await Future.wait([
        for (final k in needs) dht.get(k.$1, k.$2),
      ]);
      for (var j = 0; j < needs.length; j++) {
        known.add(needs[j]);
        values[needs[j]] = got[j];
      }
    }

    final out = session.round(request(true));
    _records.removeRange(0, out['used_records'] as int? ?? 0);
    _rendezvous.removeRange(0, out['used_rendezvous'] as int? ?? 0);
    await persist(session.save());
    for (final w in (out['writes'] as List).cast<Map<String, dynamic>>()) {
      await dht.set(
        w['record'] as String,
        w['subkey'] as int,
        _unhex(w['value'] as String),
        _unhex(w['writer'] as String),
      );
    }
    if (out['ok'] != true) throw CoreError('${out['error']}');
    return out['result'];
  }
}

/// Decodes a `p2pc2.` invite's public part (the rendezvous record the admin
/// watches for a join request).
String inviteRendezvous(String invite) {
  final body = invite.substring('p2pc2.'.length);
  return (jsonDecode(body) as Map<String, dynamic>)['rendezvous'] as String;
}
