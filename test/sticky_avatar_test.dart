// The Telegram-style avatar: it sits at the bottom of its message group and,
// while the group is taller than what is visible, sticks to the bottom of
// the screen instead of scrolling away with the group's newest message.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_communicator/ui/widgets/message_list.dart';

const _viewport = 600.0;
const _bubble = 80.0;

Widget _app(ScrollController c, {required int groups, required int items}) =>
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: _viewport,
          child: StickyGroupList(
            controller: c,
            groupCount: groups,
            itemCount: (_) => items,
            hasAvatar: (g) => g.isEven, // even groups: someone else
            groupKey: (g) => 'g$g',
            avatar: (g) =>
                SizedBox(key: ValueKey('avatar-$g'), width: 32, height: 32),
            item: (g, i) => SizedBox(
              key: ValueKey('bubble-$g-$i'),
              height: _bubble,
              child: Text('g$g #$i'),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('avatar sits beside the newest bubble at rest', (t) async {
    final c = ScrollController();
    await t.pumpWidget(_app(c, groups: 1, items: 3));
    final avatar = t.getRect(find.byKey(const ValueKey('avatar-0')));
    final newest = t.getRect(find.byKey(const ValueKey('bubble-0-2')));
    expect(avatar.left, lessThan(newest.left), reason: 'avatar in the gutter');
    expect(avatar.bottom, closeTo(newest.bottom, 8));
  });

  testWidgets('scrolling up a tall group keeps its avatar pinned to the '
      'bottom of the screen', (t) async {
    final c = ScrollController();
    // One tall group from someone else: 20 bubbles = 1600 px > viewport.
    await t.pumpWidget(_app(c, groups: 1, items: 20));
    final screenBottom = t.getRect(find.byType(StickyGroupList)).bottom;

    c.jumpTo(400); // newest bubbles are now below the screen
    await t.pump();
    expect(
      find.byKey(const ValueKey('bubble-0-19')).hitTestable(),
      findsNothing,
      reason: 'the newest bubble scrolled off screen',
    );
    final avatar = t.getRect(find.byKey(const ValueKey('avatar-0')));
    expect(avatar.bottom, closeTo(screenBottom, 8), reason: 'pinned');
  });

  testWidgets('the next group pushes the avatar away once its group ends', (
    t,
  ) async {
    final c = ScrollController();
    // Group 0 (someone else, avatar) older, group 1 (mine, no avatar) newer.
    await t.pumpWidget(_app(c, groups: 2, items: 4));
    final screenBottom = t.getRect(find.byType(StickyGroupList)).bottom;

    // At rest group 1 is at the bottom; group 0's avatar is above it, beside
    // group 0's newest bubble, not pinned to the screen bottom.
    final atRest = t.getRect(find.byKey(const ValueKey('avatar-0')));
    final newest0 = t.getRect(find.byKey(const ValueKey('bubble-0-3')));
    expect(atRest.bottom, closeTo(newest0.bottom, 8));
    expect(atRest.bottom, lessThan(screenBottom - 100));

    // Scroll so group 0 fills the bottom: now its avatar pins there.
    c.jumpTo(4 * _bubble + 6 + 2 * _bubble);
    await t.pump();
    final pinned = t.getRect(find.byKey(const ValueKey('avatar-0')));
    expect(pinned.bottom, closeTo(screenBottom, 8));

    // Scroll further until only group 0's oldest bubble is left: the avatar
    // rides up with the group's top instead of overlapping older content.
    c.jumpTo(8 * _bubble + 6 + 8 + 6 - _bubble / 2);
    await t.pump();
    final oldest = t.getRect(find.byKey(const ValueKey('bubble-0-0')));
    final pushed = t.getRect(find.byKey(const ValueKey('avatar-0')));
    expect(pushed.bottom, lessThanOrEqualTo(oldest.bottom + 8));
  });

  testWidgets('groups without an avatar get no gutter', (t) async {
    final c = ScrollController();
    await t.pumpWidget(_app(c, groups: 2, items: 1));
    final other = t.getRect(find.byKey(const ValueKey('bubble-0-0')));
    final mine = t.getRect(find.byKey(const ValueKey('bubble-1-0')));
    expect(other.left, greaterThan(mine.left + 20));
    expect(find.byKey(const ValueKey('avatar-1')), findsNothing);
  });
}
