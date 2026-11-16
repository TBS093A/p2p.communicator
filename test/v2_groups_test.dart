import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_communicator/room/message.dart';
import 'package:p2p_communicator/v2/v2_groups.dart';
import 'package:p2p_communicator/v2/v2_room_session.dart';
import 'package:p2p_communicator/vault/pin_vault.dart';
import 'package:veilid/veilid.dart';

import 'support/memory_dht.dart';

/// A v2 room without the vault and media cache (unit tests have neither).
class TestRoom extends V2RoomSession {
  TestRoom(super.groups, super.group, super.room);

  Uint8List? cache;

  @override
  Future<void> writeCache(Uint8List data) async => cache = data;

  @override
  Future<Uint8List?> readCache() async => cache;

  @override
  Future<void> close() async {}
}

V2Groups phone(MemoryDht dht) => V2Groups(
  dht,
  save: () async {},
  openRoom: (groups, group, secrets) async => TestRoom(
    groups,
    group,
    UnlockedRoom(
      'slot-${group.id}',
      SharedSecret(
        kind: cryptoKindVLD0,
        value: BareSharedSecret.fromBytes(Uint8List(32)),
      ),
      secrets,
    ),
  ),
);

/// Lets queued sends (greetings, room look) go out between syncs.
Future<void> rounds(List<(V2Groups, V2Group)> who, {int times = 3}) async {
  for (var i = 0; i < times; i++) {
    for (final (p, g) in who) {
      await Future<void>.delayed(Duration.zero);
      await p.sync(g);
    }
  }
}

List<String> texts(V2RoomSession r) => [
  for (final m in r.messages) m.text ?? '',
];

void main() {
  test('invite parsing and the fingerprint', () {
    expect(V2Invite.tryParse('p2pc1.abc'), isNull);
    expect(
      V2Invite.tryParse('p2pc2.{"rendezvous":"r","admin_cik":"x"}'),
      isNull,
    );
    final cik = 'ab' * 32;
    final inv = V2Invite.tryParse(
      ' p2pc2.{"rendezvous":"r1","slot":"00","admin_cik":"$cik"} ',
    );
    expect(inv!.rendezvous, 'r1');
    expect(inv.adminCik, cik);
    expect(v2Fingerprint(cik).split(' '), hasLength(16));
    expect(v2Fingerprint(cik), startsWith('ABAB ABAB'));
  });

  test('core inbox entries become chat messages', () {
    final wire = ChatMessage(
      id: 'm1',
      author: 'ignored',
      ts: 5,
      type: MsgType.text,
      text: 'hej',
    ).toWire();
    final m = V2RoomSession.parse(
      'alice',
      '{"id":"m1","ts":5,"t":"text",'
          '"text":"hej"}',
      0,
    )!;
    expect(wire['text'], 'hej');
    // The author is who MLS says sent it, never a field of the message.
    expect(m.author, 'alice');
    expect(m.ts, 5);
    // Plain text from the first v2 screens still shows.
    expect(V2RoomSession.parse('bob', 'zwykły tekst', 3)!.text, 'zwykły tekst');
    // A type from a newer version, or a malformed message, is skipped.
    expect(
      V2RoomSession.parse('bob', '{"id":"x","ts":1,"t":"poll"}', 4),
      isNull,
    );
    expect(V2RoomSession.parse('bob', '{"id":1}', 5), isNull);
  });

  test('two phones: join, names, room look, replies, restart', () async {
    final dht = MemoryDht();
    final alice = phone(dht);
    final bob = phone(dht);

    final ga = await alice.create('Wycieczka', 'Ala');
    expect(alice.isAdmin(ga), isTrue);
    final code = await alice.createInvite(ga);
    final invite = V2Invite.tryParse(code)!;
    expect(invite.adminCik, alice.myCik(ga));
    final gb = await bob.join(invite, 'Od Alicji', 'Bob');
    expect(gb.joining, isTrue);
    expect(bob.roomOf(gb).roomName, 'Od Alicji');

    // Sending before being let in fails instead of getting lost.
    await bob.roomOf(gb).sendText('za wcześnie');
    expect(bob.roomOf(gb).messages.single.status, MsgStatus.failed);

    await rounds([(bob, gb), (alice, ga)], times: 4);
    expect(gb.joining, isFalse);
    expect(ga.openInvites, isEmpty);

    final ra = alice.roomOf(ga);
    final rb = bob.roomOf(gb);
    expect(ra.memberOutboxes, hasLength(2));
    // Both told each other their names; the admin also the room look.
    expect(ra.nameOf(bob.myCik(gb)), 'Bob');
    expect(rb.nameOf(alice.myCik(ga)), 'Ala');
    expect(rb.roomName, 'Wycieczka');

    await ra.sendText('cześć Bob');
    await rounds([(bob, gb), (alice, ga)]);
    final hello = rb.messages.where((m) => m.text == 'cześć Bob').single;
    expect(hello.author, alice.myCik(ga));

    await rb.sendText('cześć Ala', replyTo: hello);
    await rounds([(alice, ga), (bob, gb)]);
    final reply = ra.messages.where((m) => m.text == 'cześć Ala').single;
    expect(reply.replyTo?.id, hello.id);
    expect(reply.author, bob.myCik(gb));
    // Listed by the sender's time: the reply comes after the original.
    expect(
      texts(ra).indexOf('cześć Ala'),
      greaterThan(texts(ra).indexOf('cześć Bob')),
    );

    // Renaming the room reaches the other member.
    await ra.updateRoom(name: 'Tatry 2026');
    await rounds([(bob, gb)]);
    expect(rb.roomName, 'Tatry 2026');

    // After a restart nothing already read is delivered again.
    final saved = bob.toJson();
    await bob.close();
    final bob2 = phone(dht);
    await bob2.load(saved);
    final gb2 = bob2.groups.single;
    expect(gb2.me, 'Bob');
    await ra.sendText('po restarcie');
    await rounds([(alice, ga), (bob2, gb2)]);
    expect(texts(bob2.roomOf(gb2)), ['po restarcie']);

    // An invite nobody used stays open.
    await alice.createInvite(ga);
    await alice.sync(ga);
    expect(ga.openInvites, hasLength(1));
    await alice.close();
    await bob2.close();
  });
}
