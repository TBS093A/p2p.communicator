import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_communicator/room/message.dart';
import 'package:p2p_communicator/ui/widgets/message_list.dart';

ChatMessage _m(String id) =>
    ChatMessage(id: id, author: 'VLD0:a', ts: 1, type: MsgType.text, text: id);

void main() {
  test('history on opening never animates; later messages animate once', () {
    final e = BubbleEntrances();
    e.update([_m('1'), _m('2')]);
    expect(e.take('1'), isFalse);
    expect(e.take('2'), isFalse);
    e.update([_m('1'), _m('2'), _m('3')]);
    expect(e.take('3'), isTrue);
    expect(e.take('3'), isFalse, reason: 'only the first build animates');
    e.update([_m('1'), _m('2'), _m('3')]);
    expect(e.take('3'), isFalse);
  });

  test('an empty chat is primed by its first messages', () {
    final e = BubbleEntrances();
    e.update([]);
    e.update([_m('1')]);
    // Still loading when opened: the first batch is history, not news.
    expect(e.take('1'), isFalse);
    e.update([_m('1'), _m('2')]);
    expect(e.take('2'), isTrue);
  });

  testWidgets('a new bubble grows in and ends at full size', (t) async {
    const key = ValueKey('bubble');
    Widget host(bool animate) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: BubbleEntrance(
            animate: animate,
            fromRight: true,
            child: const SizedBox(key: key, width: 100, height: 40),
          ),
        ),
      ),
    );
    await t.pumpWidget(host(true));
    final start = t.getSize(find.byType(BubbleEntrance)).height;
    expect(start, lessThan(40));
    await t.pump(BubbleEntrance.duration ~/ 2);
    final mid = t.getSize(find.byType(BubbleEntrance)).height;
    expect(mid, greaterThan(start));
    expect(mid, lessThan(40));
    await t.pumpAndSettle();
    expect(t.getSize(find.byType(BubbleEntrance)).height, 40);
    // A rebuild with animate: false does not restart it.
    await t.pumpWidget(host(false));
    expect(t.getSize(find.byType(BubbleEntrance)).height, 40);
  });

  testWidgets('history bubbles appear at full size at once', (t) async {
    await t.pumpWidget(
      const MaterialApp(
        home: BubbleEntrance(
          animate: false,
          fromRight: false,
          child: SizedBox(width: 100, height: 40),
        ),
      ),
    );
    expect(t.getSize(find.byType(SizedBox).first).height, 40);
    expect(t.hasRunningAnimations, isFalse);
  });
}
