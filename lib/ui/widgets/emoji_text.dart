import 'dart:io';

import 'package:flutter/material.dart';

import '../../room/room_session.dart';
import '../../room/room_style.dart';

/// Message text with the room's custom `:code:` emoji drawn as images.
/// Animated GIF/WebP emoji play inline. A message made only of 1–3 emoji is
/// shown large.
class EmojiText extends StatelessWidget {
  const EmojiText({
    super.key,
    required this.text,
    required this.session,
    this.style,
    this.selectable = true,
  });

  final String text;
  final RoomSession session;
  final TextStyle? style;

  /// A message of 1–3 custom emoji and nothing else (was 64).
  static const customJumboSize = 128.0;

  /// A message of 1–3 ordinary emoji and nothing else.
  static const unicodeJumboSize = 56.0;

  /// Plain text can be selected by long-pressing. Off in chat bubbles,
  /// where long-press opens the message menu (reply, copy) instead.
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final emoji = session.meta.emoji;
    final parts = EmojiCode.split(text, emoji.keys.toSet());
    if (parts.every((p) => p.code == null)) {
      // Only ordinary emoji: large, like a lone custom emoji.
      final big = EmojiCode.isUnicodeJumbo(text)
          ? (style ?? const TextStyle()).copyWith(
              fontSize: unicodeJumboSize,
              height: 1.1,
            )
          : style;
      return selectable
          ? SelectableText(text, style: big)
          : Text(text, style: big);
    }
    final jumbo = EmojiCode.isJumbo(parts);
    final base = style ?? DefaultTextStyle.of(context).style;
    final size = jumbo ? customJumboSize : (base.fontSize ?? 14) * 1.6;

    return Text.rich(
      TextSpan(
        style: base,
        children: [
          for (final p in parts)
            if (p.code == null)
              TextSpan(text: p.text)
            else
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: EmojiImage(session: session, code: p.code!, size: size),
              ),
        ],
      ),
    );
  }
}

class EmojiImage extends StatelessWidget {
  const EmojiImage({
    super.key,
    required this.session,
    required this.code,
    required this.size,
  });

  final RoomSession session;
  final String code;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ref = session.meta.emoji[code];
    final placeholder = SizedBox(
      width: size,
      height: size,
      child: Center(
        child: Text(
          ':$code:',
          style: TextStyle(fontSize: size / 4),
          overflow: TextOverflow.fade,
          softWrap: false,
        ),
      ),
    );
    if (ref == null) return placeholder;
    return Tooltip(
      message: ':$code:',
      child: FutureBuilder<File>(
        future: session.mediaFile('emoji', ref),
        builder: (context, snap) => snap.hasData
            ? Image.file(
                snap.data!,
                width: size,
                height: size,
                fit: BoxFit.contain,
                gaplessPlayback: true,
              )
            : placeholder,
      ),
    );
  }
}
