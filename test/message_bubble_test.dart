import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_communicator/room/message.dart';
import 'package:p2p_communicator/room/room_session.dart';
import 'package:p2p_communicator/ui/widgets/message_bubble.dart';
import 'package:p2p_communicator/ui/widgets/message_list.dart';
import 'package:p2p_communicator/vault/pin_vault.dart';
import 'package:p2p_communicator/vault/room_secrets.dart';
import 'package:veilid/veilid.dart';

const me = 'VLD0:me';
const ola = 'VLD0:ola';

RoomSession _session() {
  final s = RoomSession(
    UnlockedRoom(
      'slot',
      SharedSecret(
        kind: cryptoKindVLD0,
        value: BareSharedSecret.fromBytes(Uint8List(32)),
      ),
      RoomSecrets(
        roomName: 'Test',
        rosterKey: 'VLD0:roster',
        rosterWriter: 'VLD0:w',
        myName: 'Ja',
        outboxKey: me,
        outboxWriter: 'VLD0:ow',
        rosterSlot: 1,
        kind: RoomKind.group,
      ),
    ),
  );
  return s;
}

ChatMessage _msg(String id, String author, String text, {ReplyRef? re}) =>
    ChatMessage(
      id: id,
      author: author,
      ts: DateTime(2026, 11, 10, 14, 46).millisecondsSinceEpoch,
      type: MsgType.text,
      text: text,
      replyTo: re,
    );

void main() {
  late RoomSession session;
  final replies = <ChatMessage>[];
  final quoteTaps = <ReplyRef>[];
  String? highlight;

  Widget app() => MaterialApp(
    home: Scaffold(
      body: StatefulBuilder(
        builder: (context, setState) => MessageList(
          session: session,
          onReply: replies.add,
          onQuoteTap: (r) {
            quoteTaps.add(r);
            setState(() => highlight = r.id);
          },
          highlight: highlight,
        ),
      ),
    ),
  );

  setUp(() {
    session = _session();
    replies.clear();
    quoteTaps.clear();
    highlight = null;
    final original = _msg('o1', ola, 'Kto bierze termos?');
    session.messages.addAll([
      original,
      _msg('r1', me, 'Ja, z herbatą', re: ReplyRef.of(original)),
    ]);
  });

  testWidgets('tapping the tucked quote goes to the original', (t) async {
    await t.pumpWidget(app());
    final quote = find.descendant(
      of: find.byType(MessageBubble),
      matching: find.byType(QuotedBubble),
    );
    expect(quote, findsOneWidget);
    expect(
      find.descendant(of: quote, matching: find.text('Kto bierze termos?')),
      findsOneWidget,
    );
    // Drawn 1:1 like the original: the same fill and shape, no inner box
    // or side bar.
    BoxDecoration deco(Finder of) => t
        .widgetList<Container>(
          find.descendant(of: of, matching: find.byType(Container)),
        )
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .first;
    final quoted = deco(quote);
    final original = deco(find.byKey(const ValueKey('bubble-o1')));
    expect(quoted.color, original.color);
    expect(quoted.borderRadius, original.borderRadius);
    expect(quoted.border, isNull);
    expect(
      t
          .widgetList<Container>(
            find.descendant(of: quote, matching: find.byType(Container)),
          )
          .where((c) => c.decoration != null)
          .length,
      1,
      reason: 'no bubble inside the bubble',
    );
    await t.tap(quote, warnIfMissed: true);
    await t.pump();
    expect(quoteTaps.map((r) => r.id), ['o1']);
    expect(
      t
          .widgetList<MessageBubble>(find.byType(MessageBubble))
          .where((b) => b.highlighted)
          .map((b) => b.message.id),
      ['o1'],
    );
    await t.pumpAndSettle();
  });

  testWidgets('a long-press survives the wobble ending underneath it', (
    t,
  ) async {
    await t.pumpWidget(app());
    // Jump to the original: it starts wobbling (700 ms).
    await t.tap(
      find.descendant(
        of: find.byType(MessageBubble),
        matching: find.byType(QuotedBubble),
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    // Hold the original while the wobble ends (at 700 ms) and past the
    // long-press timeout.
    final gesture = await t.startGesture(
      t.getCenter(find.byKey(const ValueKey('bubble-o1'))),
    );
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await gesture.up();
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('msg-reply')), findsOneWidget);
  });

  testWidgets('time is hidden until the bubble is tapped', (t) async {
    await t.pumpWidget(app());
    final time = find.byKey(const ValueKey('time-o1'));
    double shown() => t
        .getSize(find.ancestor(of: time, matching: find.byType(ClipRect)).first)
        .height;
    expect(shown(), 0);
    await t.tap(find.byKey(const ValueKey('bubble-o1')));
    await t.pumpAndSettle();
    expect(shown(), greaterThan(0));
  });

  testWidgets('name above the group, not inside the bubble', (t) async {
    await t.pumpWidget(app());
    expect(find.text('?'), findsWidgets); // Ola's name is unknown here
    final bubble = find.byKey(const ValueKey('bubble-o1'));
    expect(find.descendant(of: bubble, matching: find.text('?')), findsNothing);
  });

  testWidgets('own messages reply by swiping left, others by right', (t) async {
    await t.pumpWidget(app());
    final mine = find.byKey(const ValueKey('bubble-r1'));
    final theirs = find.byKey(const ValueKey('bubble-o1'));
    await t.drag(mine, const Offset(-120, 0));
    await t.pumpAndSettle();
    expect(replies.map((m) => m.id), ['r1']);
    await t.drag(theirs, const Offset(120, 0));
    await t.pumpAndSettle();
    expect(replies.map((m) => m.id), ['r1', 'o1']);
    // The wrong direction does nothing.
    await t.drag(mine, const Offset(120, 0));
    await t.pumpAndSettle();
    expect(replies.length, 2);
  });
}
