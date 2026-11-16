import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_communicator/v2/v2_groups.dart';

import 'support/memory_dht.dart';

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

  test('two phones: create, invite, join, talk, restart', () async {
    final dht = MemoryDht();
    var aliceSaves = 0;
    final alice = V2Groups(dht, save: () async => aliceSaves++);
    final bob = V2Groups(dht, save: () async {});

    final ga = await alice.create('Wycieczka');
    expect(alice.isAdmin(ga), isTrue);
    final code = await alice.createInvite(ga);
    expect(ga.openInvites, hasLength(1));

    final invite = V2Invite.tryParse(code)!;
    expect(invite.adminCik, alice.myCik(ga));
    final gb = await bob.join(invite, 'Od Alicji');
    expect(gb.joining, isTrue);

    // Bob's request is in; Alice's sync lets him in; Bob's completes it.
    await bob.sync(gb);
    expect(gb.joining, isTrue);
    await alice.sync(ga);
    expect(ga.openInvites, isEmpty);
    for (var i = 0; i < 3 && gb.joining; i++) {
      await bob.sync(gb);
    }
    expect(gb.joining, isFalse);
    await alice.sync(ga);
    expect(alice.info(ga)['members'], hasLength(2));

    await alice.send(ga, 'cześć Bob');
    await bob.send(gb, 'cześć Alicjo');
    for (var i = 0; i < 3; i++) {
      await alice.sync(ga);
      await bob.sync(gb);
    }
    // Bob's own message is listed when sent, Alice's when it arrives.
    expect(gb.messages.map((m) => m.text), ['cześć Alicjo', 'cześć Bob']);
    expect(gb.messages.first.mine, isTrue);
    expect(gb.messages.last.mine, isFalse);
    expect(ga.messages.map((m) => m.text), contains('cześć Alicjo'));
    expect(ga.messages.where((m) => m.text == 'cześć Bob').single.mine, isTrue);
    expect(aliceSaves, greaterThan(0));

    // What the app stores brings the group back as it was.
    final saved = bob.toJson();
    await bob.close();
    final bob2 = V2Groups(dht, save: () async {});
    bob2.load(saved);
    final gb2 = bob2.groups.single;
    expect(gb2.name, 'Od Alicji');
    expect(gb2.messages, hasLength(2));
    await alice.send(ga, 'po restarcie');
    for (var i = 0; i < 3; i++) {
      await alice.sync(ga);
      await bob2.sync(gb2);
    }
    expect(gb2.messages.last.text, 'po restarcie');
    expect(
      gb2.messages.where((m) => m.text == 'cześć Bob'),
      hasLength(1),
      reason: 'nothing delivered twice after a restart',
    );

    // An invite nobody used stays open; a spent one is dropped.
    await alice.createInvite(ga);
    await alice.sync(ga);
    expect(ga.openInvites, hasLength(1));
    await alice.close();
    await bob2.close();
  });
}
