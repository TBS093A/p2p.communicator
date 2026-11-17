import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_communicator/room/message.dart';
import 'package:p2p_communicator/v2/private_v2.dart';
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

/// Test time for every phone (ms), moved forward by the tests.
var testClock = DateTime(2026, 11, 16).millisecondsSinceEpoch;

/// Whether the phones' app is in the foreground (presence).
var testActive = true;

V2Groups phone(MemoryDht dht) => V2Groups(
  dht,
  save: () async {},
  clock: () => testClock,
  appActive: () => testActive,
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
/// With [approve], an admin lets in every join request it sees (the
/// approval itself is tested on its own).
Future<void> rounds(
  List<(V2Groups, V2Group)> who, {
  int times = 3,
  bool approve = true,
}) async {
  for (var i = 0; i < times; i++) {
    for (final (p, g) in who) {
      await Future<void>.delayed(Duration.zero);
      await p.sync(g);
      if (!approve) continue;
      for (final r in p.joinRequests(g)) {
        await p.approveJoin(g, r);
      }
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

    // PROTOCOL §B4 step 4: the request waits for the admin, who sees the
    // name and key; nothing happens without approval.
    await rounds([(bob, gb), (alice, ga)], times: 3, approve: false);
    expect(gb.joining, isTrue);
    final req = alice.joinRequests(ga).single;
    expect(req.name, 'Bob');
    expect(req.cik, bob.myCik(gb));
    expect(ga.openInvites, hasLength(1));

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

  test('membership: key updates, successor, removal, takeover', () async {
    final dht = MemoryDht();
    final alice = phone(dht);
    final bob = phone(dht);
    final carol = phone(dht);

    Future<V2Group> joinAs(V2Groups p, V2Group admin, String me) async {
      final code = await alice.createInvite(admin);
      final g = await p.join(V2Invite.tryParse(code)!, 'Grupa', me);
      await rounds([(p, g), (alice, admin)], times: 4);
      expect(g.joining, isFalse);
      return g;
    }

    final ga = await alice.create('Rada', 'Ala');
    final gb = await joinAs(bob, ga, 'Bob');
    final gc = await joinAs(carol, ga, 'Karola');
    final all = [(alice, ga), (bob, gb), (carol, gc)];
    await rounds(all, times: 3);
    expect(alice.roomOf(ga).memberOutboxes, hasLength(3));

    // A week later every member's keys are due: the members propose
    // Updates, the admin commits them (and its own with an empty commit).
    final epoch = alice.info(ga)['epoch'] as int;
    testClock += const Duration(days: 8).inMilliseconds;
    await rounds(all, times: 3);
    expect(alice.info(ga)['epoch'] as int, greaterThan(epoch));
    expect(alice.info(ga)['pending_proposals'], 0);
    expect(bob.info(gb)['epoch'], alice.info(ga)['epoch']);
    expect(carol.info(gc)['epoch'], alice.info(ga)['epoch']);
    expect(gb.keysAt, testClock, reason: 'Bob refreshed his keys this week');

    // Bob becomes the successor; everyone learns it.
    final bobCik = bob.myCik(gb);
    await alice.setSuccessor(ga, bobCik);
    await rounds(all, times: 2);
    expect(carol.successors(gc), [bobCik]);
    expect(bob.successors(gb), [bobCik]);

    // Karola is removed: she is told, cannot read on, the rest moves on.
    await alice.removeMember(ga, carol.myCik(gc));
    await rounds(all, times: 4);
    expect(carol.info(gc)['removed'], isTrue);
    expect(alice.roomOf(ga).memberOutboxes, hasLength(2));
    await alice.roomOf(ga).sendText('już bez Karoli');
    await rounds(all, times: 2);
    expect(texts(bob.roomOf(gb)), contains('już bez Karoli'));
    expect(texts(carol.roomOf(gc)), isNot(contains('już bez Karoli')));

    // Alice's phone is gone: after 14 days of silence Bob takes over.
    await alice.close();
    dht.now += 15 * 24;
    await rounds([(bob, gb)], times: 2);
    expect(bob.isAdmin(gb), isTrue);
    await bob.close();
    await carol.close();
  });

  test(
    'handover: the new admin moves the group on and lets people in',
    () async {
      final dht = MemoryDht();
      final alice = phone(dht);
      final bob = phone(dht);
      final carol = phone(dht);
      final dave = phone(dht);

      Future<V2Group> joinAs(
        V2Groups admin,
        V2Group ga,
        V2Groups p,
        String me,
      ) async {
        final code = await admin.createInvite(ga);
        final g = await p.join(V2Invite.tryParse(code)!, 'Grupa', me);
        await rounds([(p, g), (admin, ga)], times: 4);
        expect(g.joining, isFalse);
        return g;
      }

      final ga = await alice.create('Rada', 'Ala');
      final gb = await joinAs(alice, ga, bob, 'Bob');
      final gc = await joinAs(alice, ga, carol, 'Karola');
      final all = [(alice, ga), (bob, gb), (carol, gc)];
      await rounds(all, times: 3);
      final gen = alice.info(ga)['gen'] as int;
      final epoch = alice.info(ga)['epoch'] as int;

      final bobCik = bob.myCik(gb);
      await alice.handOver(ga, bobCik);
      expect(alice.isAdmin(ga), isFalse);
      await rounds(all, times: 4);
      expect(bob.isAdmin(gb), isTrue);
      for (final (p, g) in all) {
        expect(p.info(g)['admin'], bobCik);
        expect(p.info(g)['gen'], gen + 1);
        expect(p.info(g)['move_stable'], isTrue);
      }
      // Bob's first commit as admin reached everyone.
      expect(bob.info(gb)['commit_due'], isFalse);
      expect(carol.info(gc)['epoch'] as int, greaterThan(epoch));
      expect(carol.info(gc)['epoch'], bob.info(gb)['epoch']);

      // The conversation goes on, and Bob lets Dawid in.
      await carol.roomOf(gc).sendText('po zmianie admina');
      await rounds(all, times: 2);
      expect(texts(alice.roomOf(ga)), contains('po zmianie admina'));
      final gd = await joinAs(bob, gb, dave, 'Dawid');
      await rounds([...all, (dave, gd)], times: 3);
      expect(alice.roomOf(ga).memberOutboxes, hasLength(4));
      for (final p in [alice, bob, carol, dave]) {
        await p.close();
      }
    },
  );

  test('DM from a shared group: only the invited member gets it', () async {
    final dht = MemoryDht();
    final alice = phone(dht);
    final bob = phone(dht);
    final carol = phone(dht);

    Future<V2Group> joinAs(V2Groups p, V2Group admin, String me) async {
      final code = await alice.createInvite(admin);
      final g = await p.join(V2Invite.tryParse(code)!, 'Grupa', me);
      await rounds([(p, g), (alice, admin)], times: 4);
      return g;
    }

    final ga = await alice.create('Rada', 'Ala');
    final gb = await joinAs(bob, ga, 'Bob');
    final gc = await joinAs(carol, ga, 'Karola');
    final all = [(alice, ga), (bob, gb), (carol, gc)];
    await rounds(all, times: 3);

    final bobCik = bob.myCik(gb);
    final dmA = await alice.startDm(ga, bobCik, 'Bob');
    expect(alice.myCik(dmA), isNot(alice.myCik(ga)), reason: 'new identity');
    await rounds(all, times: 2);
    expect(carol.dmOffers, isEmpty, reason: 'meant for Bob only');
    expect(alice.dmOffers, isEmpty);
    expect(bob.dmOffers, hasLength(1));
    final (via, offer) = bob.dmOffers.single;
    expect(via, gb);
    expect(offer.from, alice.myCik(ga));
    // Kept across a restart of the app data.
    expect(V2Group.fromJson(gb.toJson()).dmOffers.single.code, offer.code);

    final dmB = await bob.acceptDm(gb, offer);
    expect(bob.dmOffers, isEmpty);
    expect(bob.myCik(dmB), isNot(bobCik), reason: 'new identity');
    final dm = [(alice, dmA), (bob, dmB)];
    await rounds(dm, times: 4);
    expect(dmB.joining, isFalse);
    expect(alice.roomOf(dmA).memberOutboxes, hasLength(2));
    // Each side names the DM after the other person.
    expect(alice.roomOf(dmA).roomName, 'Bob');
    expect(bob.roomOf(dmB).roomName, 'Ala');
    await bob.roomOf(dmB).sendText('tylko dla Ali');
    await rounds(dm, times: 2);
    expect(texts(alice.roomOf(dmA)), contains('tylko dla Ali'));
    expect(texts(carol.roomOf(gc)), isNot(contains('tylko dla Ali')));
    for (final p in [alice, bob, carol]) {
      await p.close();
    }
  });

  test('a move to v2 announced in a v1 room (§B11)', () {
    final code =
        'p2pc2.{"rendezvous":"VLD0:r","slot":"00",'
        '"admin_cik":"${'ab' * 32}"}';
    ChatMessage text(String id, String author, Map<String, dynamic>? x) =>
        ChatMessage(
          id: id,
          author: author,
          ts: 1,
          type: MsgType.text,
          text: 'przenoszę',
          extra: x,
        );
    final announce = text(
      'm1',
      'VLD0:ala',
      V1Move.extra('Rada', {'VLD0:bob': code, 'VLD0:kasia': 'zepsute'}),
    );
    final mine = V1Move.find([announce], 'VLD0:bob')!;
    expect(mine.code, code);
    expect(mine.name, 'Rada');
    expect(mine.from, 'VLD0:ala');
    // Not for me, malformed, or my own announcement: nothing.
    expect(V1Move.find([announce], 'VLD0:ewa'), isNull);
    expect(V1Move.find([announce], 'VLD0:kasia'), isNull);
    expect(V1Move.find([announce], 'VLD0:ala'), isNull);
    expect(
      V1Move.find([
        text('m2', 'VLD0:ala', {'v2move': 'x'}),
      ], 'VLD0:bob'),
      isNull,
    );
    // The wire keeps it (old apps just show the text).
    final back = ChatMessage.fromWire('VLD0:ala', announce.toWire());
    expect(V1Move.find([back], 'VLD0:bob')!.code, code);
  });

  test('a refused join request never gets in', () async {
    final dht = MemoryDht();
    final alice = phone(dht);
    final eve = phone(dht);
    final ga = await alice.create('Rada', 'Ala');
    final code = await alice.createInvite(ga);
    final ge = await eve.join(V2Invite.tryParse(code)!, 'Grupa', 'Ewa');
    await rounds([(eve, ge), (alice, ga)], times: 3, approve: false);
    final req = alice.joinRequests(ga).single;
    await alice.rejectJoin(ga, req);
    expect(ga.openInvites, isEmpty);
    expect(alice.joinRequests(ga), isEmpty);
    await rounds([(eve, ge), (alice, ga)], times: 3);
    expect(ge.joining, isTrue, reason: 'still waiting, never let in');
    expect(alice.roomOf(ga).memberOutboxes, hasLength(1));
    await alice.close();
    await eve.close();
  });

  test('presence: off by default, opt-in here, at most every 15 min', () async {
    final dht = MemoryDht();
    final alice = phone(dht);
    final bob = phone(dht);
    final ga = await alice.create('Rada', 'Ala');
    final code = await alice.createInvite(ga);
    final gb = await bob.join(V2Invite.tryParse(code)!, 'Grupa', 'Bob');
    final both = [(alice, ga), (bob, gb)];
    await rounds(both, times: 4);
    final aliceCik = alice.myCik(ga);
    final bobCik = bob.myCik(gb);
    String? seenByBob() => bob.roomOf(gb).presenceOf(aliceCik);

    // Off by default: nothing is sent, nothing is shown.
    expect(ga.presence, isFalse);
    expect(ga.presenceSent, isNull);
    expect(seenByBob(), isNull);

    testActive = true;
    await alice.setPresence(ga, true);
    await rounds(both, times: 2);
    expect(seenByBob(), 'active');
    final sentAt = ga.presenceAt;

    // The app goes to the background: within 15 minutes nothing new goes
    // out (the coarse limit), after that "away".
    testActive = false;
    testClock += const Duration(minutes: 5).inMilliseconds;
    await rounds(both, times: 2);
    expect(ga.presenceAt, sentAt, reason: 'at most once every 15 minutes');
    expect(seenByBob(), 'active');
    testClock += const Duration(minutes: 11).inMilliseconds;
    await rounds(both, times: 2);
    expect(seenByBob(), 'away');
    // "Away" is said once, not repeated.
    final awayAt = ga.presenceAt;
    testClock += const Duration(minutes: 16).inMilliseconds;
    await rounds(both, times: 2);
    expect(ga.presenceAt, awayAt);
    // ...and fades out like anything not refreshed.
    testClock += const Duration(minutes: 5).inMilliseconds;
    expect(seenByBob(), isNull);

    // Turned off: back in the foreground, nothing more is sent.
    await alice.setPresence(ga, false);
    testActive = true;
    testClock += const Duration(minutes: 16).inMilliseconds;
    await rounds(both, times: 2);
    expect(ga.presenceAt, awayAt);
    expect(seenByBob(), isNull);
    // Bob never turned it on: Alice sees nothing of him.
    expect(alice.roomOf(ga).presenceOf(bobCik), isNull);
    // The choice is kept per conversation in the app data.
    expect(V2Group.fromJson(ga.toJson()).presence, isFalse);
    expect(V2Group.fromJson(gb.toJson()).presence, isFalse);
    await alice.close();
    await bob.close();
  });

  test(
    'a private conversation (§B11.1): its own state, only while open',
    () async {
      final dht = MemoryDht();
      Uint8List? slotData; // what the password slot's data area holds

      Future<PrivateV2> openPrivate() => PrivateV2.open(
        dht: dht,
        read: () async => slotData,
        write: (d) async => slotData = d,
        clock: () => testClock,
        appActive: () => testActive,
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

      // A fresh slot (its data file holds random bytes): nothing there yet.
      slotData = Uint8List.fromList([1, 2, 3]);
      var pv = await openPrivate();
      expect(pv.group, isNull);
      expect(pv.groups.private, isTrue);
      final g = await pv.groups.create('Sekret', 'Ala');
      final cik = pv.groups.myCik(g);
      final code = await pv.groups.createInvite(g);
      await pv.close();
      expect(slotData, isNotNull);

      // Bob joins with an ordinary invite: on the wire it is a v2 group.
      final bob = phone(dht);
      final gb = await bob.join(V2Invite.tryParse(code)!, 'Sekret', 'Bob');
      // While the private conversation is closed, nobody lets him in.
      await rounds([(bob, gb)], times: 3);
      expect(gb.joining, isTrue);

      // Opened again from the slot alone: same identity, and while it is
      // open the request is handled.
      pv = await openPrivate();
      final again = pv.group!;
      expect(pv.groups.myCik(again), cik);
      await rounds([(bob, gb), (pv.groups, again)], times: 4);
      expect(gb.joining, isFalse);
      await bob.roomOf(gb).sendText('cicho');
      await rounds([(pv.groups, again), (bob, gb)], times: 2);
      expect(texts(pv.groups.roomOf(again)), contains('cicho'));

      // No DMs from or into it: they would live outside the slot.
      pv.groups.offerDm(again, bob.myCik(gb), code, 'x');
      expect(pv.groups.dmOffers, isEmpty);
      await pv.close();
      await bob.close();
    },
  );
}
