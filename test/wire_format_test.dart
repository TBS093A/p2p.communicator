import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_communicator/room/invite.dart';
import 'package:p2p_communicator/room/message.dart';

void main() {
  test('invite survives encode/parse', () {
    final inv = Invite(
      roomName: 'Rodzina 🏠',
      rosterKey: 'VLD0:abc:def',
      rosterWriter: 'VLD0:pub:sec',
    );
    final back = Invite.tryParse(inv.encode())!;
    expect(back.roomName, inv.roomName);
    expect(back.rosterKey, inv.rosterKey);
    expect(back.rosterWriter, inv.rosterWriter);
  });

  test('garbage is not an invite', () {
    expect(Invite.tryParse('hello'), isNull);
    expect(Invite.tryParse('p2pc1.!!!'), isNull);
  });

  test('media message round-trips through wire and cache form', () {
    final m = ChatMessage(
      id: 'x',
      author: 'VLD0:outbox',
      ts: 1,
      type: MsgType.voice,
      seq: 7,
      media: MediaRef(
        mime: 'audio/mp4',
        size: 64001,
        hash: 'h',
        records: ['VLD0:r1'],
        chunkSize: 32000,
        chunksPerRecord: 30,
        durationMs: 4200,
      ),
    );
    final wire = ChatMessage.fromWire('VLD0:outbox', m.toWire());
    expect(wire.seq, 7);
    expect(wire.media!.chunkCount, 3);
    expect(wire.media!.durationMs, 4200);

    m.status = MsgStatus.sending;
    final cached = ChatMessage.fromCache(m.toCache());
    // A send interrupted by closing the app must not stay "sending" forever.
    expect(cached.status, MsgStatus.failed);
  });
}
