import 'package:flutter/painting.dart';

import 'message.dart';

/// Default bubble colors when a member has not picked their own: a clear
/// messenger blue for your own messages, neutral grey for everyone else's.
const defaultMyBubble = 0xFF0084FF;
const defaultOtherBubbleLight = 0xFFE9E9EB;
const defaultOtherBubbleDark = 0xFF303134;

/// Shared look of a room, stored in roster subkey 0 next to the name. Any
/// member can change it (rooms have no roles: everyone holding the invite is
/// equal), and every member renders the same thing.
class RoomMeta {
  RoomMeta({
    required this.name,
    this.avatar,
    this.background,
    this.backgroundImage,
    this.dim,
    this.bubble,
    this.otherBubble,
    this.barTransparency,
    this.accent,
    Map<String, MediaRef>? emoji,
  }) : emoji = emoji ?? {};

  final String name;

  /// Uploaded room picture.
  final MediaRef? avatar;

  /// ARGB chat background; null = theme surface. Shown under
  /// [backgroundImage] and wherever the image does not cover.
  final int? background;

  /// Picture or (animated) GIF behind the conversation.
  final MediaRef? backgroundImage;

  /// Darkening over [backgroundImage], 0–80 %, so bubbles stay readable;
  /// null = [defaultDim].
  final int? dim;

  static const defaultDim = 30;
  static const maxDim = 80;

  int get effectiveDim => (dim ?? defaultDim).clamp(0, maxDim);

  /// ARGB of your own bubbles in this room (like a chat theme: each member
  /// sees their own messages in it). null = [defaultMyBubble].
  final int? bubble;

  /// ARGB of everyone else's bubbles in this room. null = the theme's grey
  /// ([defaultOtherBubbleLight] / [defaultOtherBubbleDark]).
  final int? otherBubble;

  /// How see-through the top bar and the message bar are over the
  /// background picture, 0–90 %; null = [defaultBarTransparency].
  final int? barTransparency;

  static const defaultBarTransparency = 25;
  static const maxBarTransparency = 90;

  int get effectiveBarTransparency =>
      (barTransparency ?? defaultBarTransparency).clamp(0, maxBarTransparency);

  /// Alpha (0–255) of the bars for [effectiveBarTransparency].
  int get barAlpha => (255 * (100 - effectiveBarTransparency) / 100).round();

  /// Legacy (v0.1.3) theme seed. Still read so old rooms keep their tint;
  /// no longer set by the UI, which uses [background] instead.
  final int? accent;

  /// Custom emoji: `:code:` in message text renders as this image. GIF and
  /// animated WebP play as animations.
  final Map<String, MediaRef> emoji;

  /// Roster subkeys hold at most 32 KiB; leave room for the other fields.
  static const maxEncodedBytes = 30000;
  static const maxEmoji = 80;

  RoomMeta copyWith({
    String? name,
    MediaRef? avatar,
    bool clearAvatar = false,
    int? background,
    bool clearBackground = false,
    MediaRef? backgroundImage,
    bool clearBackgroundImage = false,
    int? dim,
    int? bubble,
    bool clearBubble = false,
    int? otherBubble,
    bool clearOtherBubble = false,
    int? barTransparency,
    Map<String, MediaRef>? emoji,
  }) => RoomMeta(
    name: name ?? this.name,
    avatar: clearAvatar ? null : (avatar ?? this.avatar),
    background: clearBackground ? null : (background ?? this.background),
    backgroundImage: clearBackgroundImage
        ? null
        : (backgroundImage ?? this.backgroundImage),
    dim: dim ?? this.dim,
    bubble: clearBubble ? null : (bubble ?? this.bubble),
    otherBubble: clearOtherBubble ? null : (otherBubble ?? this.otherBubble),
    barTransparency: barTransparency ?? this.barTransparency,
    // A background choice (or reset) replaces the legacy tint.
    accent: (background != null || clearBackground) ? null : accent,
    emoji: emoji ?? this.emoji,
  );

  Map<String, dynamic> toJson() => {
    'v': 1,
    'name': name,
    if (avatar != null) 'avatar': avatar!.toJson(),
    if (background != null) 'bg': background,
    if (backgroundImage != null) 'bgImg': backgroundImage!.toJson(),
    if (dim != null) 'dim': dim,
    if (bubble != null) 'bubble': bubble,
    if (otherBubble != null) 'otherBubble': otherBubble,
    if (barTransparency != null) 'bars': barTransparency,
    if (accent != null) 'accent': accent,
    if (emoji.isNotEmpty)
      'emoji': {for (final e in emoji.entries) e.key: e.value.toJson()},
  };

  factory RoomMeta.fromJson(
    Map<String, dynamic> j, {
    String fallbackName = '',
  }) {
    final emoji = <String, MediaRef>{};
    final raw = j['emoji'];
    if (raw is Map) {
      for (final e in raw.entries) {
        final code = e.key as String;
        if (!EmojiCode.isValid(code) || e.value is! Map) continue;
        emoji[code] = MediaRef.fromJson(
          (e.value as Map).cast<String, dynamic>(),
        );
      }
    }
    return RoomMeta(
      name: (j['name'] as String?)?.trim().isNotEmpty == true
          ? j['name'] as String
          : fallbackName,
      avatar: j['avatar'] is Map
          ? MediaRef.fromJson((j['avatar'] as Map).cast<String, dynamic>())
          : null,
      background: j['bg'] as int?,
      backgroundImage: j['bgImg'] is Map
          ? MediaRef.fromJson((j['bgImg'] as Map).cast<String, dynamic>())
          : null,
      dim: j['dim'] as int?,
      bubble: j['bubble'] as int?,
      otherBubble: j['otherBubble'] as int?,
      barTransparency: j['bars'] as int?,
      accent: j['accent'] as int?,
      emoji: emoji,
    );
  }
}

/// How one member presents themselves in a room. Lives in the head of their
/// own outbox, so only they can change it.
class MemberProfile {
  const MemberProfile({required this.name, this.avatar, this.color});

  final String name;
  final MediaRef? avatar;

  /// ARGB color of this member's bubbles (text, photos, voice notes);
  /// null = the defaults above.
  final int? color;

  MemberProfile copyWith({
    String? name,
    MediaRef? avatar,
    bool clearAvatar = false,
    int? color,
    bool clearColor = false,
  }) => MemberProfile(
    name: name ?? this.name,
    avatar: clearAvatar ? null : (avatar ?? this.avatar),
    color: clearColor ? null : (color ?? this.color),
  );

  /// Fields merged into the outbox head (`count` is added by the session).
  Map<String, dynamic> toJson() => {
    'name': name,
    if (avatar != null) 'avatar': avatar!.toJson(),
    if (color != null) 'color': color,
  };

  factory MemberProfile.fromJson(Map<String, dynamic> j) => MemberProfile(
    name: j['name'] as String? ?? '?',
    avatar: j['avatar'] is Map
        ? MediaRef.fromJson((j['avatar'] as Map).cast<String, dynamic>())
        : null,
    color: j['color'] as int?,
  );
}

/// Quick presets in the RGB picker (any RGB value is allowed).
const stylePalette = <int>[
  0xFF0084FF, // messenger blue
  0xFF3F51B5, // indigo
  0xFF00897B, // teal
  0xFF43A047, // green
  0xFFC0CA33, // lime
  0xFFFFB300, // amber
  0xFFF4511E, // deep orange
  0xFFE53935, // red
  0xFFD81B60, // pink
  0xFF8E24AA, // purple
  0xFF6D4C41, // brown
  0xFF546E7A, // blue grey
  0xFF1B1B1F, // near black
  0xFFF5F5F5, // near white
];

/// Text color with enough contrast on [background].
Color onColor(Color background) => background.computeLuminance() > 0.45
    ? const Color(0xFF1B1B1F)
    : const Color(0xFFFFFFFF);

/// `:code:` handling for custom emoji.
class EmojiCode {
  EmojiCode._();

  static final _code = RegExp(r'^[a-z0-9_]{2,32}$');
  static final _token = RegExp(r':([a-z0-9_]{2,32}):');

  static bool isValid(String code) => _code.hasMatch(code);

  /// Splits [text] into plain strings and emoji codes, keeping only codes
  /// the room actually has (unknown `:foo:` stays as text).
  static List<EmojiPart> split(String text, Set<String> known) {
    final parts = <EmojiPart>[];
    var last = 0;
    for (final m in _token.allMatches(text)) {
      final code = m.group(1)!;
      if (!known.contains(code)) continue;
      if (m.start > last) {
        parts.add(EmojiPart.text(text.substring(last, m.start)));
      }
      parts.add(EmojiPart.emoji(code));
      last = m.end;
    }
    if (last < text.length) parts.add(EmojiPart.text(text.substring(last)));
    return parts;
  }

  /// True when the message is only custom emoji (and spaces), at most
  /// [max] of them: shown large, like most messengers do.
  static bool isJumbo(List<EmojiPart> parts, {int max = 3}) {
    var count = 0;
    for (final p in parts) {
      if (p.code != null) {
        count++;
      } else if (p.text!.trim().isNotEmpty) {
        return false;
      }
    }
    return count > 0 && count <= max;
  }
}

class EmojiPart {
  const EmojiPart.text(String this.text) : code = null;
  const EmojiPart.emoji(String this.code) : text = null;

  final String? text;
  final String? code;
}
