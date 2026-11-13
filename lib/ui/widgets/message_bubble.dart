import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../room/message.dart';
import '../../room/room_session.dart';
import '../../room/room_style.dart';
import 'emoji_text.dart';
import 'swipe_to_reply.dart';

/// How a quoted message reads in one line: its text, or its media type.
String replyPreviewText(ReplyRef r) => switch (r.type) {
  MsgType.text => r.preview,
  MsgType.image => r.preview.isEmpty ? '📷 Zdjęcie' : '📷 ${r.preview}',
  MsgType.video => r.preview.isEmpty ? '🎬 Film' : '🎬 ${r.preview}',
  MsgType.voice => '🎤 Wiadomość głosowa',
  MsgType.dmInvite || MsgType.reaction => '',
};

/// A quote: a bar, the original's author and one line of its content. Used
/// inside a reply bubble and above the composer while replying.
class ReplyQuote extends StatelessWidget {
  const ReplyQuote({
    super.key,
    required this.reply,
    required this.session,
    required this.color,
    this.onTap,
  });

  final ReplyRef reply;
  final RoomSession session;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final name = reply.author == session.myOutbox
        ? 'Ty'
        : session.nameOf(reply.author);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        decoration: BoxDecoration(
          color: color.withAlpha(30),
          borderRadius: BorderRadius.circular(8),
          border: Border(left: BorderSide(color: color, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
            Text(
              replyPreviewText(reply),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color.withAlpha(220), fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.session,
    this.showName = true,
    this.onReply,
    this.onQuoteTap,
    this.highlighted = false,
    this.showStatus = false,
  });

  final ChatMessage message;
  final RoomSession session;

  /// The author's name above the bubble (outside it): only on the first
  /// message of a group from someone else.
  final bool showName;

  /// Swipe (right for others, left for your own) or long-press: reply.
  final ValueChanged<ChatMessage>? onReply;

  /// Tap on the quote of a reply: go to the original.
  final ValueChanged<ReplyRef>? onQuoteTap;

  /// Briefly wobbles after jumping here from a quote.
  final bool highlighted;

  /// Show the "sent" tick under it (your newest message only).
  final bool showStatus;

  static const _radius = 18.0;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble>
    with SingleTickerProviderStateMixin {
  ChatMessage get message => widget.message;
  RoomSession get session => widget.session;
  ValueChanged<ChatMessage>? get onReply => widget.onReply;

  /// The time slides out from under the bubble on tap.
  bool _showTime = false;

  late final AnimationController _wobble = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void initState() {
    super.initState();
    if (widget.highlighted) _wobble.forward();
  }

  @override
  void didUpdateWidget(MessageBubble old) {
    super.didUpdateWidget(old);
    if (widget.highlighted && !old.highlighted) _wobble.forward(from: 0);
  }

  @override
  void dispose() {
    _wobble.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mine = message.author == session.myOutbox;
    final scheme = Theme.of(context).colorScheme;
    final time = DateTime.fromMillisecondsSinceEpoch(message.ts);
    final hhmm =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final fill = bubbleFill(context, session, mine: mine);
    final text = message.text ?? '';
    final jumbo =
        message.type == MsgType.text &&
        (EmojiCode.isJumbo(
              EmojiCode.split(text, session.meta.emoji.keys.toSet()),
            ) ||
            EmojiCode.isUnicodeJumbo(text));
    // Photos and videos stand on their own, without a bubble around them;
    // their time is always shown (a tap opens or plays them).
    final bare =
        jumbo || message.type == MsgType.image || message.type == MsgType.video;
    final fg = bare ? scheme.onSurface : onColor(fill);
    final maxWidth = MediaQuery.sizeOf(context).width * 0.72;

    final content = DefaultTextStyle.merge(
      style: TextStyle(color: fg),
      child: IconTheme.merge(
        data: IconThemeData(color: fg),
        child: _content(context, fg),
      ),
    );
    final body = Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: bare ? EdgeInsets.zero : const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: bare
          ? null
          : BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(MessageBubble._radius),
            ),
      child: content,
    );
    final tappable = GestureDetector(
      key: ValueKey('bubble-${message.id}'),
      onTap: bare ? null : () => setState(() => _showTime = !_showTime),
      onLongPress: onReply == null ? null : () => _menu(context),
      child: body,
    );
    // A short wobble after a jump from a quote.
    final wobbling = AnimatedBuilder(
      animation: _wobble,
      // Always the same two transforms (identity when still): a wrapper
      // that appears or disappears would rebuild the gesture detector
      // inside and drop a long-press in progress.
      builder: (context, child) {
        final v = _wobble.value;
        final fade = v == 0 ? 0.0 : 1 - v;
        return Transform.rotate(
          angle: math.sin(v * math.pi * 6) * 0.045 * fade,
          child: Transform.scale(
            scale: 1 + 0.05 * math.sin(v * math.pi) * fade,
            child: child,
          ),
        );
      },
      child: tappable,
    );

    final small = Theme.of(context).textTheme.labelSmall;
    final status = mine
        ? switch (message.status) {
            MsgStatus.sending => const Icon(Icons.schedule, size: 14),
            MsgStatus.failed => Icon(
              Icons.error_outline,
              size: 16,
              color: scheme.error,
            ),
            MsgStatus.sent => null,
          }
        : null;
    final timeLabel = _Pill(
      child: Text(hhmm, style: small, key: ValueKey('time-${message.id}')),
    );
    final reply = message.replyTo;

    final column = Column(
      crossAxisAlignment: mine
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!mine && widget.showName)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
            child: _Pill(
              child: Text(
                session.profileOf(message.author).name,
                style: small?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ),
        // Who is being answered, then the quoted message itself peeking out
        // from under the reply, see-through.
        if (reply != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
            child: _Pill(
              child: Text(
                '↩ ${reply.author == session.myOutbox ? 'Ty' : session.nameOf(reply.author)}',
                style: small,
              ),
            ),
          ),
        if (reply != null)
          Transform.translate(
            offset: const Offset(0, QuotedBubble.tuck),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: QuotedBubble(
                key: ValueKey('quote-${message.id}'),
                reply: reply,
                session: session,
                maxWidth: maxWidth * 0.85,
                onTap: widget.onQuoteTap == null
                    ? null
                    : () => widget.onQuoteTap!(reply),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (status != null) ...[status, const SizedBox(width: 4)],
              Flexible(child: wobbling),
            ],
          ),
        ),
        // Reactions overlap the bubble's bottom edge a little.
        if (session.reactionsOf(message.id).isNotEmpty)
          Transform.translate(
            offset: const Offset(0, -8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: _ReactionChips(session: session, message: message),
            ),
          ),
        // Time: always for photos and videos, otherwise on tap, sliding
        // down from under the bubble.
        ClipRect(
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: mine ? Alignment.bottomRight : Alignment.bottomLeft,
            heightFactor: bare || _showTime ? 1 : 0,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 2),
              child: timeLabel,
            ),
          ),
        ),
        if (widget.showStatus && mine && message.status == MsgStatus.sent)
          Padding(
            padding: const EdgeInsets.only(right: 10, bottom: 2),
            child: Icon(Icons.done, size: 14, color: scheme.onSurfaceVariant),
          ),
      ],
    );

    // No avatar here: the chat list draws one per message group, sticking to
    // the bottom of the group while scrolling (see GroupAvatar).
    final row = Padding(
      padding: EdgeInsets.only(left: mine ? 0 : 8, right: mine ? 4 : 0),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: column,
      ),
    );
    if (onReply == null || message.status == MsgStatus.sending) return row;
    return SwipeToReply(
      toLeft: mine,
      onReply: () => onReply!(message),
      child: row,
    );
  }

  /// Long-press menu (like most messengers): reply, and copy for text.
  Future<void> _menu(BuildContext context) async {
    unawaited(HapticFeedback.mediumImpact());
    final text = message.text;
    final codes = session.meta.emoji.keys.toList()..sort();
    final mineNow = session.myReaction(message.id);
    final canReact = message.status != MsgStatus.sending;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            // React with one of the room's own emoji (tap yours again to
            // take it back).
            if (canReact && codes.isNotEmpty)
              SizedBox(
                key: const ValueKey('msg-reactions'),
                height: 64,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    for (final c in codes)
                      Padding(
                        padding: const EdgeInsets.all(4),
                        child: InkWell(
                          key: ValueKey('react-$c'),
                          borderRadius: BorderRadius.circular(28),
                          onTap: () => Navigator.pop(context, 'react:$c'),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: c == mineNow
                                  ? Theme.of(
                                      context,
                                    ).colorScheme.primaryContainer
                                  : null,
                            ),
                            child: EmojiImage(
                              session: session,
                              code: c,
                              size: 36,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (canReact && codes.isEmpty)
              const ListTile(
                leading: Icon(Icons.add_reaction_outlined),
                title: Text('Reakcje'),
                subtitle: Text(
                  'Ten pokój nie ma jeszcze własnych emoji. Dodasz je w '
                  'ustawieniach pokoju.',
                ),
              ),
            if (message.status != MsgStatus.sending)
              ListTile(
                key: const ValueKey('msg-reply'),
                leading: const Icon(Icons.reply),
                title: const Text('Odpowiedz'),
                onTap: () => Navigator.pop(context, 'reply'),
              ),
            if (text != null && text.isNotEmpty)
              ListTile(
                key: const ValueKey('msg-copy'),
                leading: const Icon(Icons.copy),
                title: const Text('Kopiuj'),
                onTap: () => Navigator.pop(context, 'copy'),
              ),
          ],
        ),
      ),
    );
    if (action != null && action.startsWith('react:')) {
      session.react(message, action.substring('react:'.length));
      return;
    }
    switch (action) {
      case 'reply':
        onReply?.call(message);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: text ?? ''));
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Skopiowano')));
        }
    }
  }

  Widget _content(BuildContext context, Color fg) {
    final media = message.media;
    switch (message.type) {
      case MsgType.dmInvite:
      case MsgType.reaction:
        return const SizedBox.shrink(); // never listed; see RoomSession
      case MsgType.text:
        return EmojiText(
          text: message.text ?? '',
          session: session,
          style: TextStyle(color: fg),
          // Long-press opens the message menu (with Copy) instead.
          selectable: onReply == null,
        );
      case MsgType.image:
        return _MediaLoader(
          session: session,
          message: message,
          auto: true,
          builder: (file) => GestureDetector(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => _ImageViewer(file: file)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.file(file, fit: BoxFit.cover),
            ),
          ),
          placeholderAspect: (media?.width != null && media?.height != null)
              ? media!.width! / media.height!
              : 4 / 3,
        );
      case MsgType.video:
        return _MediaLoader(
          session: session,
          message: message,
          auto: false,
          label: 'Wideo · ${_mb(media?.size ?? 0)}',
          builder: (file) => _VideoTile(file: file),
          placeholderAspect: 16 / 9,
        );
      case MsgType.voice:
        return _MediaLoader(
          session: session,
          message: message,
          auto: true,
          builder: (file) =>
              _VoicePlayer(file: file, durationMs: media?.durationMs),
          placeholderAspect: null,
        );
    }
  }

  static String _mb(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// The room's bubble color for your own messages or everyone else's (like a
/// chat theme); defaults are blue and grey.
Color bubbleFill(
  BuildContext context,
  RoomSession session, {
  required bool mine,
}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final room = mine ? session.meta.bubble : session.meta.otherBubble;
  if (room != null) return Color(room);
  return Color(
    mine
        ? defaultMyBubble
        : (dark ? defaultOtherBubbleDark : defaultOtherBubbleLight),
  );
}

/// The reactions under a message: each emoji with how many chose it. Yours
/// is outlined; tapping an emoji reacts with it (or takes yours back).
class _ReactionChips extends StatelessWidget {
  const _ReactionChips({required this.session, required this.message});

  final RoomSession session;
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final list = session.reactionsOf(message.id);
    return Wrap(
      key: ValueKey('reactions-${message.id}'),
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final (code, authors) in list)
          GestureDetector(
            key: ValueKey('reaction-${message.id}-$code'),
            onTap: () => session.react(message, code),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.surface.withAlpha(230),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: authors.contains(session.myOutbox)
                      ? scheme.primary
                      : scheme.outlineVariant,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  EmojiImage(session: session, code: code, size: 20),
                  if (authors.length > 1) ...[
                    const SizedBox(width: 4),
                    Text(
                      '${authors.length}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Small text on the chat background (names, times): a soft pill keeps it
/// readable over any background color or picture.
class _Pill extends StatelessWidget {
  const _Pill({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.surface.withAlpha(150),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: scheme.onSurface),
        child: child,
      ),
    );
  }
}

/// The message a reply answers, tucked from above under the reply and
/// see-through, drawn the way the original looks (like Messenger): the same
/// bubble with its text, or a quoted photo on its own without any frame.
class QuotedBubble extends StatefulWidget {
  const QuotedBubble({
    super.key,
    required this.reply,
    required this.session,
    required this.maxWidth,
    this.onTap,
  });

  final ReplyRef reply;
  final RoomSession session;
  final double maxWidth;
  final VoidCallback? onTap;

  /// The part hidden under the reply bubble.
  static const tuck = 14.0;

  @override
  State<QuotedBubble> createState() => _QuotedBubbleState();
}

class _QuotedBubbleState extends State<QuotedBubble> {
  Future<File>? _photo;

  @override
  void initState() {
    super.initState();
    // A quoted photo shows the picture itself, if the original is still
    // here (its file is cached locally or downloads like any other).
    final original = widget.session.messageById(widget.reply.id);
    final media = original?.media;
    if (widget.reply.type == MsgType.image && media != null) {
      _photo = widget.session.mediaFile(original!.id, media);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reply = widget.reply;
    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: 0.6,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: widget.maxWidth),
          child: _photo == null
              ? _bubble(context, reply)
              : FutureBuilder<File>(
                  future: _photo,
                  builder: (context, snap) => snap.hasData
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 160),
                            child: Image.file(snap.data!, fit: BoxFit.cover),
                          ),
                        )
                      : _bubble(context, reply),
                ),
        ),
      ),
    );
  }

  /// The original's own bubble: its author's color and shape, its text.
  Widget _bubble(BuildContext context, ReplyRef reply) {
    final fill = bubbleFill(
      context,
      widget.session,
      mine: reply.author == widget.session.myOutbox,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8 + QuotedBubble.tuck),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(MessageBubble._radius),
      ),
      child: Text(
        replyPreviewText(reply),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: onColor(fill)),
      ),
    );
  }
}

/// Fetches the plain media file (local copy or DHT download) and shows
/// progress until it is ready.
class _MediaLoader extends StatefulWidget {
  const _MediaLoader({
    required this.session,
    required this.message,
    required this.auto,
    required this.builder,
    required this.placeholderAspect,
    this.label,
  });

  final RoomSession session;
  final ChatMessage message;
  final bool auto;
  final Widget Function(File file) builder;
  final double? placeholderAspect;
  final String? label;

  @override
  State<_MediaLoader> createState() => _MediaLoaderState();
}

class _MediaLoaderState extends State<_MediaLoader> {
  Future<File>? _file;

  @override
  void initState() {
    super.initState();
    if (widget.auto) _load();
  }

  void _load() {
    final media = widget.message.media;
    if (media == null) return;
    setState(() {
      _file = widget.session.mediaFile(widget.message.id, media);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_file == null) {
      return _placeholder(
        child: TextButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.download),
          label: Text(widget.label ?? 'Pobierz'),
        ),
      );
    }
    return FutureBuilder<File>(
      future: _file,
      builder: (context, snap) {
        if (snap.hasData) return widget.builder(snap.data!);
        if (snap.hasError) {
          return _placeholder(
            child: TextButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Nie udało się pobrać. Ponów'),
            ),
          );
        }
        return _placeholder(
          child: ListenableBuilder(
            listenable: widget.session,
            builder: (context, _) {
              final v = widget.session.progress[widget.message.id];
              return SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(value: v),
              );
            },
          ),
        );
      },
    );
  }

  Widget _placeholder({required Widget child}) {
    final box = Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.black12,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(8),
      child: child,
    );
    final aspect = widget.placeholderAspect;
    return aspect == null
        ? SizedBox(width: 220, height: 48, child: box)
        : AspectRatio(aspectRatio: aspect, child: box);
  }
}

class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.file});

  final File file;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: InteractiveViewer(maxScale: 5, child: Image.file(file)),
      ),
    );
  }
}

class _VideoTile extends StatefulWidget {
  const _VideoTile({required this.file});

  final File file;

  @override
  State<_VideoTile> createState() => _VideoTileState();
}

class _VideoTileState extends State<_VideoTile> {
  late final VideoPlayerController _c = VideoPlayerController.file(widget.file);
  late final Future<void> _init = _c.initialize();

  @override
  void dispose() {
    unawaited(_c.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _init,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const AspectRatio(
            aspectRatio: 16 / 9,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: AspectRatio(
            aspectRatio: _c.value.aspectRatio,
            child: Stack(
              alignment: Alignment.center,
              children: [
                VideoPlayer(_c),
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: _c,
                  builder: (context, v, _) => IconButton.filled(
                    iconSize: 36,
                    icon: Icon(v.isPlaying ? Icons.pause : Icons.play_arrow),
                    onPressed: () => v.isPlaying ? _c.pause() : _c.play(),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: VideoProgressIndicator(_c, allowScrubbing: true),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _VoicePlayer extends StatefulWidget {
  const _VoicePlayer({required this.file, this.durationMs});

  final File file;
  final int? durationMs;

  @override
  State<_VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<_VoicePlayer> {
  final _player = AudioPlayer();
  final _subs = <StreamSubscription<Object?>>[];
  PlayerState _state = PlayerState.stopped;
  Duration _pos = Duration.zero;
  Duration? _dur;

  @override
  void initState() {
    super.initState();
    _dur = widget.durationMs == null
        ? null
        : Duration(milliseconds: widget.durationMs!);
    _subs
      ..add(
        _player.onPlayerStateChanged.listen((s) => setState(() => _state = s)),
      )
      ..add(_player.onPositionChanged.listen((p) => setState(() => _pos = p)))
      ..add(_player.onDurationChanged.listen((d) => setState(() => _dur = d)))
      ..add(
        _player.onPlayerComplete.listen(
          (_) => setState(() => _pos = Duration.zero),
        ),
      );
  }

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_state == PlayerState.playing) {
      await _player.pause();
    } else {
      await _player.play(DeviceFileSource(widget.file.path));
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _dur?.inMilliseconds ?? 0;
    final progress = total == 0 ? 0.0 : _pos.inMilliseconds / total;
    final shown = _state == PlayerState.playing
        ? _pos
        : (_dur ?? Duration.zero);
    return SizedBox(
      width: 220,
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              _state == PlayerState.playing ? Icons.pause : Icons.play_arrow,
            ),
            onPressed: _toggle,
          ),
          Expanded(
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              // Follow the bubble's text color so it shows on any bubble.
              color: DefaultTextStyle.of(context).style.color,
              backgroundColor: DefaultTextStyle.of(
                context,
              ).style.color?.withAlpha(60),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${shown.inMinutes}:${(shown.inSeconds % 60).toString().padLeft(2, '0')}',
          ),
        ],
      ),
    );
  }
}
