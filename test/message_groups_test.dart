import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_communicator/room/message.dart';
import 'package:p2p_communicator/room/message_groups.dart';

ChatMessage _m(String id, String author, int minute) => ChatMessage(
  id: id,
  author: author,
  ts: Duration(minutes: minute).inMilliseconds,
  type: MsgType.text,
  text: id,
);

List<List<String>> _ids(List<MessageGroup> g) => [
  for (final x in g) [for (final m in x.messages) m.id],
];

void main() {
  test('consecutive messages from one author form one group', () {
    final g = groupMessages([
      _m('a1', 'ala', 0),
      _m('a2', 'ala', 1),
      _m('b1', 'bob', 2),
      _m('b2', 'bob', 3),
      _m('a3', 'ala', 4),
    ]);
    expect(_ids(g), [
      ['a1', 'a2'],
      ['b1', 'b2'],
      ['a3'],
    ]);
    expect(g.map((x) => x.author), ['ala', 'bob', 'ala']);
  });

  test('a long pause starts a new group even for the same author', () {
    final g = groupMessages([
      _m('a1', 'ala', 0),
      _m('a2', 'ala', 10), // exactly the gap: still together
      _m('a3', 'ala', 21), // 11 min later: new group
    ]);
    expect(_ids(g), [
      ['a1', 'a2'],
      ['a3'],
    ]);
  });

  test('empty in, empty out; order is kept', () {
    expect(groupMessages(const []), isEmpty);
    final g = groupMessages([for (var i = 0; i < 5; i++) _m('$i', 'x', i)]);
    expect(_ids(g), [
      ['0', '1', '2', '3', '4'],
    ]);
  });
}
