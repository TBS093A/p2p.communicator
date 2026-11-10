import 'package:flutter/material.dart';
import 'package:flutter_sticky_header/flutter_sticky_header.dart';

import '../../room/message.dart';
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
  const MessageList({
    super.key,
    required this.session,
    this.controller,
    this.entrances,
    this.itemKeys,
    this.onReply,
    this.onQuoteTap,
    this.highlight,
    this.onAvatarTap,
  });

  /// Tap on a group's avatar: show that member's profile.
  final ValueChanged<String>? onAvatarTap;

  final RoomSession session;
  final ScrollController? controller;

  /// Decides which bubbles animate in (only messages that arrive while the
  /// chat is open, not the history shown on opening).
  final BubbleEntrances? entrances;

  /// Filled with one key per built message, so the chat can scroll to a
  /// quoted original.
  final Map<String, GlobalKey>? itemKeys;
  final ValueChanged<ChatMessage>? onReply;
  final ValueChanged<ReplyRef>? onQuoteTap;

  /// Id of the message briefly marked after jumping to it.
  final String? highlight;

  static const avatarRadius = 16.0;

  @override
  Widget build(BuildContext context) {
    final groups = groupMessages(session.messages);
    final avatars = session.kind != RoomKind.dm;
    entrances?.update(session.messages);
    // The "sent" tick goes under your newest message only.
    final lastMine = session.messages.reversed
        .where((m) => m.author == session.myOutbox)
        .firstOrNull
        ?.id;
    return SoftEdges(
      child: StickyGroupList(
        controller: controller,
        groupCount: groups.length,
        itemCount: (g) => groups[g].messages.length,
        hasAvatar: (g) => avatars && groups[g].author != session.myOutbox,
        groupKey: (g) => groups[g].messages.first.id,
        avatar: (g) {
          final author = groups[g].author;
          final avatar = Avatar.member(
            session,
            author,
            radius: avatarRadius,
            key: const ValueKey('group-avatar'),
          );
          final tap = onAvatarTap;
          if (tap == null) return avatar;
          return GestureDetector(
            key: ValueKey('avatar-$author'),
            onTap: () => tap(author),
            child: avatar,
          );
        },
        item: (g, i) =>
            _item(groups[g].messages[i], i == 0 && avatars, lastMine),
      ),
    );
  }

  Widget _item(ChatMessage m, bool firstOfGroup, String? lastMine) {
    final bubble = MessageBubble(
      key: ValueKey(m.id),
      message: m,
      session: session,
      showName: firstOfGroup,
      showStatus: m.id == lastMine,
      onReply: onReply,
      onQuoteTap: onQuoteTap,
      highlighted: m.id == highlight,
    );
    final animated = BubbleEntrance(
      animate: entrances?.take(m.id) ?? false,
      fromRight: m.author == session.myOutbox,
      child: bubble,
    );
    final keys = itemKeys;
    if (keys == null) return animated;
    // A GlobalKey keeps the entrance animation's state when the message
    // moves to another index (a newer one arrives right after it).
    return KeyedSubtree(
      key: keys.putIfAbsent(m.id, GlobalKey.new),
      child: animated,
    );
  }
}

/// Messages fade out over a narrow band at the top and bottom of the list
/// instead of being cut off by a hard edge while scrolling.
class SoftEdges extends StatelessWidget {
  const SoftEdges({super.key, required this.child, this.band = 18});

  final Widget child;

  /// Height of the fading band at each edge.
  final double band;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final h = box.maxHeight;
        final stop = h <= 0 || !h.isFinite ? 0.0 : (band / h).clamp(0.0, 0.5);
        // A gradient mask only: a live blur (BackdropFilter) over a
        // scrolling list costs whole seconds per frame on weak or
        // software-rendered GPUs. The list repaints in its own layer.
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: const [
              Color(0x00000000),
              Color(0x99000000),
              Color(0xFF000000),
              Color(0xFF000000),
              Color(0x99000000),
              Color(0x00000000),
            ],
            stops: [0, stop * 0.5, stop, 1 - stop, 1 - stop * 0.5, 1],
          ).createShader(rect),
          child: RepaintBoundary(child: child),
        );
      },
    );
  }
}

/// Remembers which messages the chat has already shown. The history present
/// when the chat opens never animates; a message added later animates once,
/// the first time its bubble is built.
class BubbleEntrances {
  final _known = <String>{};
  final _fresh = <String>{};
  bool _primed = false;

  void update(List<ChatMessage> messages) {
    if (!_primed) {
      _primed = messages.isNotEmpty;
      _known.addAll(messages.map((m) => m.id));
      return;
    }
    for (final m in messages) {
      if (_known.add(m.id)) _fresh.add(m.id);
    }
  }

  /// True once for a message that arrived while the chat was open.
  bool take(String id) => _fresh.remove(id);
}

/// A new bubble grows into place (the list above slides up smoothly instead
/// of jumping), fades in and slides a little from its side.
class BubbleEntrance extends StatefulWidget {
  const BubbleEntrance({
    super.key,
    required this.animate,
    required this.fromRight,
    required this.child,
  });

  /// Only read when first built: later rebuilds never restart it.
  final bool animate;
  final bool fromRight;
  final Widget child;

  static const duration = Duration(milliseconds: 280);

  @override
  State<BubbleEntrance> createState() => _BubbleEntranceState();
}

class _BubbleEntranceState extends State<BubbleEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: BubbleEntrance.duration,
    value: widget.animate ? 0 : 1,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  // The same widget tree before, during and after the animation, so the
  // bubble's own state (players, downloads) is never rebuilt from scratch.
  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: _curve,
      alignment: Alignment.bottomCenter,
      child: FadeTransition(
        opacity: _curve,
        child: SlideTransition(
          position: Tween(
            begin: Offset(widget.fromRight ? 0.08 : -0.08, 0.35),
            end: Offset.zero,
          ).animate(_curve),
          child: widget.child,
        ),
      ),
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
