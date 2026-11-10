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

  group('replies', () {
    ChatMessage textMsg(String id, String text) => ChatMessage(
      id: id,
      author: 'VLD0:alice',
      ts: 1,
      type: MsgType.text,
      text: text,
      seq: 0,
    );

    Map<String, dynamic> base() => {
      'id': 'r1',
      'seq': 1,
      'ts': 2,
      't': 'text',
      'text': 'odpowiedź',
    };

    test('a reply round-trips through wire and cache form', () {
      final original = textMsg('o1', 'Jutro o 6:00?');
      final reply = ChatMessage(
        id: 'r1',
        author: 'VLD0:bob',
        ts: 2,
        type: MsgType.text,
        text: 'Jadę',
        seq: 1,
        replyTo: ReplyRef.of(original),
      );
      final wire = reply.toWire();
      expect(wire['re'], {
        'id': 'o1',
        'a': 'VLD0:alice',
        't': 'text',
        'p': 'Jutro o 6:00?',
      });
      final back = ChatMessage.fromWire('VLD0:bob', wire);
      expect(back.replyTo!.id, 'o1');
      expect(back.replyTo!.author, 'VLD0:alice');
      expect(back.replyTo!.preview, 'Jutro o 6:00?');
      final cached = ChatMessage.fromCache(reply.toCache());
      expect(cached.replyTo!.id, 'o1');
      // The cache's own top-level keys are untouched by `re`.
      expect(reply.toCache()['a'], 'VLD0:bob');
    });

    test('no `re`: a normal message', () {
      expect(ChatMessage.fromWire('VLD0:bob', base()).replyTo, isNull);
    });

    test('malformed `re` never drops the message', () {
      for (final bad in <Object?>[
        'o1',
        42,
        ['o1'],
        <String, dynamic>{},
        {'id': 'o1'},
        {'id': 'o1', 'a': 'VLD0:alice'},
        {'id': 'o1', 'a': 'VLD0:alice', 't': 'sticker'},
        {'id': 5, 'a': 'VLD0:alice', 't': 'text'},
        {'id': '', 'a': 'VLD0:alice', 't': 'text'},
        // Replies to hidden types (DM invites) are not allowed.
        {'id': 'o1', 'a': 'VLD0:alice', 't': 'dmInvite'},
      ]) {
        final m = ChatMessage.fromWire('VLD0:bob', {...base(), 're': bad});
        expect(m.text, 'odpowiedź', reason: '$bad');
        expect(m.replyTo, isNull, reason: '$bad');
      }
      // A preview of the wrong type is dropped, the reference kept.
      final m = ChatMessage.fromWire('VLD0:bob', {
        ...base(),
        're': {'id': 'o1', 'a': 'VLD0:alice', 't': 'image', 'p': 7},
      });
      expect(m.replyTo!.type, MsgType.image);
      expect(m.replyTo!.preview, '');
    });

    test('preview is cut by grapheme, never inside an emoji', () {
      final family = '👨‍👩‍👧‍👦';
      final long = 'a' * (ReplyRef.maxPreview - 1) + family * 3;
      final r = ReplyRef.of(textMsg('o1', long))!;
      expect(r.preview, '${'a' * (ReplyRef.maxPreview - 1)}$family…');
      // Whitespace collapses to single spaces.
      expect(ReplyRef.clip('  a \n\n b  '), 'a b');
    });

    test('media is quoted by type only, without a MediaRef', () {
      final voice = ChatMessage(
        id: 'v1',
        author: 'VLD0:alice',
        ts: 1,
        type: MsgType.voice,
        media: MediaRef(
          mime: 'audio/mp4',
          size: 1,
          hash: 'h',
          records: ['VLD0:secret-record'],
          chunkSize: 1,
          chunksPerRecord: 1,
        ),
      );
      final json = ReplyRef.of(voice)!.toJson();
      expect(json, {'id': 'v1', 'a': 'VLD0:alice', 't': 'voice'});
    });

    test('hidden messages cannot be replied to', () {
      final invite = ChatMessage(
        id: 'd1',
        author: 'VLD0:alice',
        ts: 1,
        type: MsgType.dmInvite,
      );
      expect(ReplyRef.of(invite), isNull);
    });
  });
}
