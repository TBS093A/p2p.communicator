import 'package:flutter/material.dart';
import 'package:flutter_sticky_header/flutter_sticky_header.dart';

import '../../room/message_groups.dart';
import '../../room/room_session.dart';
import '../../vault/room_secrets.dart';
import 'avatar.dart';
import 'message_bubble.dart';

/// The conversation, newest at the bottom, grouped by author (Telegram
/// style): someone else's run of messages gets one avatar beside it, and
/// that avatar sticks to the bottom of the screen while the group scrolls,
/// until the group's top edge pushes it away. Your own messages and DMs have
/// no avatars (you know who is talking), like in most messengers.
class MessageList extends StatelessWidget {
  const MessageList({super.key, required this.session});

  final RoomSession session;

  static const avatarRadius = 16.0;

  @override
  Widget build(BuildContext context) {
    final groups = groupMessages(session.messages);
    final avatars = session.kind != RoomKind.dm;
    return StickyGroupList(
      groupCount: groups.length,
      itemCount: (g) => groups[g].messages.length,
      hasAvatar: (g) => avatars && groups[g].author != session.myOutbox,
      groupKey: (g) => groups[g].messages.first.id,
      avatar: (g) => Avatar.member(
        session,
        groups[g].author,
        radius: avatarRadius,
        key: const ValueKey('group-avatar'),
      ),
      item: (g, i) {
        final m = groups[g].messages[i];
        return MessageBubble(
          key: ValueKey(m.id),
          message: m,
          session: session,
          showName: i == 0,
        );
      },
    );
  }
}

/// Reversed list of groups (index 0 = oldest group; inside a group, item 0
/// = oldest) where a group can carry a side widget that pins to the bottom
/// of the viewport while the group is on screen.
///
/// How: the scroll view is reversed, so each group is a
/// [SliverStickyHeader] whose header pins to the leading edge, which in a
/// reversed list is the bottom. `overlapsContent` lays the header over the
/// group's left gutter instead of above it, and the header only takes taps
/// on the avatar itself, so the bubbles stay tappable.
class StickyGroupList extends StatelessWidget {
  const StickyGroupList({
    super.key,
    required this.groupCount,
    required this.itemCount,
    required this.item,
    required this.hasAvatar,
    required this.avatar,
    required this.groupKey,
    this.gutter = 8 + MessageList.avatarRadius * 2 + 4,
    this.controller,
  });

  final int groupCount;
  final int Function(int group) itemCount;
  final Widget Function(int group, int index) item;
  final bool Function(int group) hasAvatar;
  final Widget Function(int group) avatar;
  final String Function(int group) groupKey;
  final double gutter;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      controller: controller,
      reverse: true,
      slivers: [
        const SliverPadding(padding: EdgeInsets.only(top: 8)),
        for (var g = groupCount - 1; g >= 0; g--) _group(g),
        const SliverPadding(padding: EdgeInsets.only(top: 8)),
      ],
    );
  }

  Widget _group(int g) {
    final count = itemCount(g);
    final side = hasAvatar(g);
    // Reversed list: child 0 is the group's newest item, at the bottom.
    final list = SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, i) => item(g, count - 1 - i),
        childCount: count,
      ),
    );
    final spaced = SliverPadding(
      padding: EdgeInsets.only(top: 6, left: side ? gutter - 8 : 0),
      sliver: list,
    );
    if (!side) return spaced;
    return SliverStickyHeader(
      key: ValueKey('group-${groupKey(g)}'),
      overlapsContent: true,
      header: Align(
        alignment: Alignment.bottomLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 6),
          child: avatar(g),
        ),
      ),
      sliver: spaced,
    );
  }
}
