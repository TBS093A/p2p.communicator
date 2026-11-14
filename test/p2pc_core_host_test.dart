import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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

List<String> texts(CoreSession s) => [
  for (final m in (s.info()['inbox'] as List).cast<Map<String, dynamic>>())
    m['text'] as String,
];

void main() {
  test('a v2 conversation driven from Dart through the core', () async {
    final dht = MemoryDht();
    final host = CoreHost(dht);
    final saved = <String, Uint8List>{};
    Future<void> Function(Uint8List) keep(String who) =>
        (state) async => saved[who] = state;

    final alice = CoreSession.create('alice');
    var bob = CoreSession.create('bob');
    await host.run(alice, {'op': 'create_group'}, persist: keep('alice'));
    expect(alice.info()['is_admin'], isTrue);

    final invite =
        await host.run(alice, {'op': 'create_invite'}, persist: keep('alice'))
            as String;
    expect(invite, startsWith('p2pc2.'));
    final admin = alice.info()['cik'] as String;
    await host.run(bob, {
      'op': 'request_join',
      'invite': invite,
      'verified_admin': admin,
    }, persist: keep('bob'));
    await host.run(alice, {
      'op': 'stage_add',
      'rendezvous': inviteRendezvous(invite),
    }, persist: keep('alice'));
    await host.run(alice, {'op': 'publish_pending'}, persist: keep('alice'));
    final joined = await host.run(bob, {
      'op': 'complete_join',
      'invite': invite,
    }, persist: keep('bob'));
    expect(joined, isTrue);

    Future<void> syncBoth() async {
      for (var i = 0; i < 3; i++) {
        await host.run(alice, {'op': 'sync'}, persist: keep('alice'));
        await host.run(bob, {'op': 'sync'}, persist: keep('bob'));
      }
    }

    await syncBoth();
    expect(alice.info()['members'], hasLength(2));

    await host.run(alice, {
      'op': 'send_text',
      'text': 'cześć z Darta',
    }, persist: keep('alice'));
    await host.run(bob, {
      'op': 'send_text',
      'text': 'odpowiedź',
    }, persist: keep('bob'));
    await syncBoth();
    expect(texts(bob).where((t) => t == 'cześć z Darta'), hasLength(1));
    expect(texts(alice), contains('odpowiedź'));

    // Restart from what the host persisted.
    bob.close();
    bob = CoreSession.restore(saved['bob']!)!;
    expect(texts(bob), contains('cześć z Darta'));

    // A failing operation is an error, not a crash.
    await expectLater(
      host.run(bob, {
        'op': 'request_join',
        'invite': 'garbage',
        'verified_admin': '00',
      }, persist: keep('bob')),
      throwsA(isA<CoreError>()),
    );
    expect(CoreSession.restore(Uint8List.fromList([1, 2, 3])), isNull);
    alice.close();
    bob.close();
  });
}
