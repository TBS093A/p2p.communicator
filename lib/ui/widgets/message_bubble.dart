import 'dart:async';
import 'dart:io';

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
  MsgType.dmInvite => '',
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

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.session,
    this.showName = true,
    this.onReply,
    this.onQuoteTap,
    this.highlighted = false,
  });

  final ChatMessage message;
  final RoomSession session;

  /// The author's name above the bubble: only on the first message of a
  /// group from one person.
  final bool showName;

  /// Swipe right or long-press: reply to this message.
  final ValueChanged<ChatMessage>? onReply;

  /// Tap on the quote of a reply: go to the original.
  final ValueChanged<ReplyRef>? onQuoteTap;

  /// Briefly marked after jumping here from a quote.
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final mine = message.author == session.myOutbox;
    final scheme = Theme.of(context).colorScheme;
    final profile = session.profileOf(message.author);
    final time = DateTime.fromMillisecondsSinceEpoch(message.ts);
    final hhmm =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    // The room sets both bubble colors (like a chat theme): one for your own
    // messages, one for everyone else's; defaults are blue and grey.
    final dark = Theme.of(context).brightness == Brightness.dark;
    final roomBubble = mine ? session.meta.bubble : session.meta.otherBubble;
    final custom = roomBubble != null ? Color(roomBubble) : null;
    final jumbo =
        message.type == MsgType.text &&
        EmojiCode.isJumbo(
          EmojiCode.split(message.text ?? '', session.meta.emoji.keys.toSet()),
        );
    final fill =
        custom ??
        Color(
          mine
              ? defaultMyBubble
              : (dark ? defaultOtherBubbleDark : defaultOtherBubbleLight),
        );
    final bg = jumbo ? Colors.transparent : fill;
    final fg = jumbo ? scheme.onSurface : onColor(fill);

    final reply = message.replyTo;
    final bubble = AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.72,
      ),
      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: highlighted ? scheme.tertiary : Colors.transparent,
          width: 2,
        ),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: fg),
        child: IconTheme.merge(
          data: IconThemeData(color: fg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!mine && showName)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    profile.name,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: custom != null ? fg : scheme.primary,
                      fontSize: 13,
                    ),
                  ),
                ),
              if (reply != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: ReplyQuote(
                    key: ValueKey('quote-${message.id}'),
                    reply: reply,
                    session: session,
                    color: jumbo ? scheme.primary : fg,
                    onTap: onQuoteTap == null ? null : () => onQuoteTap!(reply),
                  ),
                ),
              _content(context, fg),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    hhmm,
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: fg),
                  ),
                  if (mine) ...[
                    const SizedBox(width: 4),
                    Icon(switch (message.status) {
                      MsgStatus.sending => Icons.schedule,
                      MsgStatus.sent => Icons.done,
                      MsgStatus.failed => Icons.error_outline,
                    }, size: 14),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );

    // No avatar here: the chat list draws one per message group, sticking to
    // the bottom of the group while scrolling (see GroupAvatar).
    final row = Padding(
      padding: EdgeInsets.only(left: mine ? 0 : 8, right: mine ? 4 : 0),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: onReply == null
            ? bubble
            : GestureDetector(onLongPress: () => _menu(context), child: bubble),
      ),
    );
    if (onReply == null || message.status == MsgStatus.sending) return row;
    return SwipeToReply(onReply: () => onReply!(message), child: row);
  }

  /// Long-press menu (like most messengers): reply, and copy for text.
  Future<void> _menu(BuildContext context) async {
    unawaited(HapticFeedback.mediumImpact());
    final text = message.text;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
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
              borderRadius: BorderRadius.circular(10),
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
        borderRadius: BorderRadius.circular(10),
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
          borderRadius: BorderRadius.circular(10),
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
