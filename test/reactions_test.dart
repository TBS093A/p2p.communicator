import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_communicator/room/message.dart';
import 'package:p2p_communicator/room/reactions.dart';

ChatMessage r(String author, int seq, Object? to, Object? e, {int ts = 0}) =>
    ChatMessage(
      id: '$author-$seq',
      author: author,
      ts: ts,
      type: MsgType.reaction,
      seq: seq,
      extra: {'to': to, 'e': e},
    );

/// "code:author,author" per emoji (records with lists inside do not compare
/// deeply).
List<String> s(List<(String, List<String>)> l) => [
  for (final (c, a) in l) '$c:${a.join(',')}',
];

void main() {
  test('one reaction per member per message; the highest seq wins', () {
    final x = Reactions();
    expect(x.apply(r('ola', 5, 'm1', 'party')), isTrue);
    expect(x.apply(r('ola', 7, 'm1', 'love')), isTrue);
    // An older one arriving late (out of order, or a lagging replica) and
    // with a later clock still loses: order is the author's seq.
    expect(x.apply(r('ola', 6, 'm1', 'party', ts: 999999)), isFalse);
    expect(x.mine('m1', 'ola'), 'love');
    expect(s(x.of('m1')), ['love:ola']);
  });

  test('the same result in any delivery order', () {
    final msgs = [
      r('ola', 1, 'm1', 'a1'),
      r('jan', 1, 'm1', 'a1'),
      r('ola', 2, 'm1', 'b2'),
      r('ewa', 3, 'm1', 'a1'),
      r('jan', 4, 'm1', null),
    ];
    final forward = Reactions();
    final backward = Reactions();
    msgs.forEach(forward.apply);
    msgs.reversed.forEach(backward.apply);
    expect(forward.toJson(), backward.toJson());
    expect(s(forward.of('m1')), ['a1:ewa', 'b2:ola']);
  });

  test('e: null takes the reaction back', () {
    final x = Reactions();
    x.apply(r('ola', 1, 'm1', 'party'));
    expect(x.apply(r('ola', 2, 'm1', null)), isTrue);
    expect(x.mine('m1', 'ola'), isNull);
    expect(x.of('m1'), isEmpty);
  });

  test('malformed reactions are ignored', () {
    final x = Reactions();
    for (final m in [
      r('ola', 1, null, 'party'),
      r('ola', 1, '', 'party'),
      r('ola', 1, 42, 'party'),
      r('ola', 1, 'm1', 7),
      r('ola', 1, 'm1', 'Not A Code!'),
      r('ola', 1, 'm1', ':party:'),
      ChatMessage(
        id: 'x',
        author: 'ola',
        ts: 0,
        type: MsgType.reaction,
        extra: {'to': 'm1', 'e': 'party'},
      ), // no seq
      ChatMessage(
        id: 'y',
        author: 'ola',
        ts: 0,
        type: MsgType.text,
        seq: 1,
        extra: {'to': 'm1', 'e': 'party'},
      ), // not a reaction
    ]) {
      expect(x.apply(m), isFalse, reason: '${m.extra}');
    }
    expect(x.targetCount, 0);
  });

  test('emoji the room no longer has are hidden, the data kept', () {
    final x = Reactions();
    x.apply(r('ola', 1, 'm1', 'gone'));
    x.apply(r('jan', 1, 'm1', 'party'));
    expect(s(x.of('m1', show: (c) => c != 'gone')), ['party:jan']);
    expect(x.mine('m1', 'ola'), 'gone');
  });

  test('cache round trip, and pruning only past the limit', () {
    final x = Reactions();
    x.apply(r('ola', 3, 'm1', 'party'));
    x.apply(r('jan', 4, 'm2', null));
    final back = Reactions()..loadJson(x.toJson());
    expect(back.toJson(), x.toJson());
    // An older one still loses after a reload.
    expect(back.apply(r('ola', 2, 'm1', 'love')), isFalse);

    back.prune({'m1'}, max: 5);
    expect(back.targetCount, 2, reason: 'under the limit: kept');
    back.prune({'m1'}, max: 1);
    expect(back.targetCount, 1);
    expect(back.mine('m1', 'ola'), 'party');
  });

  test('garbage in the cache is skipped', () {
    final x = Reactions()
      ..loadJson({
        'm1': {
          'ola': {'e': 'party', 'seq': 1},
          'jan': {'e': 'bad code', 'seq': 1},
          'ewa': {'e': 'party'},
          'ida': 'nope',
        },
        'm2': 'nope',
      });
    expect(s(x.of('m1')), ['party:ola']);
  });
}
