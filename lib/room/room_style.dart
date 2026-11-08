import 'package:flutter/painting.dart';

import 'message.dart';

/// Shared look of a room, stored in roster subkey 0 next to the name. Any
/// member can change it (rooms have no roles: everyone holding the invite is
/// equal), and every member renders the same thing.
class RoomMeta {
  RoomMeta({
    required this.name,
    this.avatar,
    this.accent,
    Map<String, MediaRef>? emoji,
  }) : emoji = emoji ?? {};

  final String name;
  final MediaRef? avatar;

  /// ARGB seed of the room's color scheme; null = app default.
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
    int? accent,
    Map<String, MediaRef>? emoji,
  }) => RoomMeta(
    name: name ?? this.name,
    avatar: clearAvatar ? null : (avatar ?? this.avatar),
    accent: accent ?? this.accent,
    emoji: emoji ?? this.emoji,
  );

  Map<String, dynamic> toJson() => {
    'v': 1,
    'name': name,
    if (avatar != null) 'avatar': avatar!.toJson(),
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

  /// ARGB color of this member's message bubbles; null = theme default.
  final int? color;

  MemberProfile copyWith({
    String? name,
    MediaRef? avatar,
    bool clearAvatar = false,
    int? color,
  }) => MemberProfile(
    name: name ?? this.name,
    avatar: clearAvatar ? null : (avatar ?? this.avatar),
    color: color ?? this.color,
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

/// Colors offered for room accents and bubbles: readable in light and dark
/// themes, distinct from each other.
const stylePalette = <int>[
  0xFF3F51B5, // indigo
  0xFF1E88E5, // blue
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
