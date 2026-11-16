// v2 on the real network (docs/V2_PLAN.md phase 2): two members, each its
// own CoreSession, talk through the device's Veilid node: the admin creates
// a group and an invite, the other joins with the admin's fingerprint
// checked, and they exchange messages both ways. Runs inside the DAST app
// test once the node is up.
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:p2p_communicator/core/crypto.dart';
import 'package:p2p_communicator/room/blob_store.dart';
import 'package:p2p_communicator/room/dht.dart';
import 'package:p2p_communicator/room/message.dart';
import 'package:p2p_communicator/v2/veilid_core_dht.dart';
import 'package:p2pc_core/p2pc_core.dart';
import 'package:veilid/veilid.dart';

/// PROTOCOL §B9 on the real network: a file is sealed chunk by chunk before
/// upload, the records hold no plaintext, and only the right key (with
/// every chunk at its place) gives the file back. Returns a short report.
Future<List<String>> encryptedMediaOverVeilid() async {
  final rnd = Random(9);
  final file = Uint8List.fromList(
    List.generate(70000, (_) => rnd.nextInt(256)), // 3 chunks, 1 record
  );
  final ref = await BlobStore.upload(
    file,
    mime: 'application/octet-stream',
    encrypt: true,
  );
  final steps = ['uploaded ${ref.chunkCount} sealed chunks'];
  if (ref.key == null) throw StateError('no media key');

  // What a storage node (or anyone with the record key) sees.
  final record = RecordKey.fromString(ref.records.single);
  await Dht.retry(() => Dht.rc.openDHTRecord(record));
  final Uint8List? raw;
  try {
    raw = await Dht.get(record, 0);
  } finally {
    await Dht.close(record);
  }
  if (raw == null) throw StateError('chunk 0 not readable');
  final plain0 = Uint8List.sublistView(file, 0, BlobStore.chunkSize);
  if (raw.length != plain0.length + 40 || listEquals(raw, plain0)) {
    throw StateError('chunk 0 is not sealed (${raw.length} bytes)');
  }
  final leak = Uint8List.sublistView(file, 1000, 1032);
  for (var i = 0; i + leak.length <= raw.length; i++) {
    if (listEquals(Uint8List.sublistView(raw, i, i + leak.length), leak)) {
      throw StateError('plaintext found in a sealed chunk');
    }
  }

  final back = await BlobStore.download(ref);
  if (!listEquals(back, file)) throw StateError('file changed in transit');
  steps.add('downloaded and checked');

  // A wrong key, or none, must not give anything back.
  final wrong = Crypto.secretFromBytes(await Crypto.randomBytes(32));
  for (final key in [wrong.toString(), null]) {
    final bad = MediaRef.fromJson({...ref.toJson()..remove('k'), 'k': ?key});
    try {
      await BlobStore.download(bad);
      throw StateError('opened with ${key == null ? 'no' : 'a wrong'} key');
    } on MediaCorruptException {
      // expected
    }
  }
  steps.add('wrong or missing key refused');
  return steps;
}

List<String> _texts(CoreSession s) => [
  for (final m in (s.info()['inbox'] as List).cast<Map<String, dynamic>>())
    m['text'] as String,
];

/// Returns a short report (steps with timings); throws on failure.
Future<List<String>> v2OverVeilid() async {
  final dht = VeilidCoreDht();
  final host = CoreHost(dht);
  final steps = <String>[];
  final sw = Stopwatch()..start();
  Future<void> keep(Uint8List _) async {}

  Future<Object?> run(CoreSession s, Map<String, dynamic> op) async {
    final t0 = sw.elapsedMilliseconds;
    final r = await host.run(s, op, persist: keep);
    final step = '${op['op']} ${sw.elapsedMilliseconds - t0} ms';
    steps.add(step);
    debugPrint('[v2] $step');
    return r;
  }

  final alice = CoreSession.create('alice');
  final bob = CoreSession.create('bob');
  try {
    await run(alice, {'op': 'create_group'});
    final invite = await run(alice, {'op': 'create_invite'}) as String;
    // The QR code stays small: the invite carries a Veilid key pair string
    // as hex, not a JSON array of numbers.
    steps.add('invite ${invite.length} chars');
    if (invite.length > 1200) {
      throw StateError('invite too long: ${invite.length}');
    }

    // In the app the joiner compares this fingerprint with the admin's
    // screen; here it is passed on directly.
    final admin = alice.info()['cik'] as String;
    await run(bob, {
      'op': 'request_join',
      'invite': invite,
      'verified_admin': admin,
    });
    await run(alice, {
      'op': 'stage_add',
      'rendezvous': inviteRendezvous(invite),
    });
    await run(alice, {'op': 'publish_pending'});
    final joined = await run(bob, {'op': 'complete_join', 'invite': invite});
    if (joined != true) throw StateError('join did not complete: $joined');

    Future<void> syncUntil(bool Function() done, String what) async {
      for (var i = 0; i < 8; i++) {
        if (done()) return;
        await run(alice, {'op': 'sync'});
        await run(bob, {'op': 'sync'});
      }
      if (!done()) throw StateError('timed out waiting for: $what');
    }

    await syncUntil(
      () => (alice.info()['members'] as List).length == 2,
      'two members',
    );

    await run(alice, {'op': 'send_text', 'text': 'cześć przez Veilid'});
    await run(bob, {'op': 'send_text', 'text': 'odpowiedź przez Veilid'});
    await syncUntil(
      () =>
          _texts(bob).contains('cześć przez Veilid') &&
          _texts(alice).contains('odpowiedź przez Veilid'),
      'messages both ways',
    );
    // Delivered exactly once.
    final dupes = _texts(bob).where((t) => t == 'cześć przez Veilid').length;
    if (dupes != 1) throw StateError('message delivered $dupes times');
    steps.add('total ${sw.elapsedMilliseconds} ms');
    return steps;
  } finally {
    alice.close();
    bob.close();
    await dht.close();
  }
}
