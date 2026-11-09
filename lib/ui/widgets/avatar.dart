import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_state/global_profile.dart';
import '../../core/media_cache.dart';
import '../../room/message.dart';
import '../../room/room_session.dart';
import '../../room/room_style.dart';

/// Round avatar: the picture if there is one (GIFs play; downloaded from the
/// DHT on first use, then cached encrypted), else initials on [color].
/// With [presence], a status dot sits in the corner.
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.session,
    required this.name,
    this.image,
    this.color,
    this.radius = 20,
    this.presence,
  });

  final MediaSource session;
  final String name;
  final MediaRef? image;
  final int? color;
  final double radius;
  final Presence? presence;

  factory Avatar.member(
    RoomSession session,
    String outbox, {
    double radius = 20,
    Key? key,
  }) {
    final p = session.profileOf(outbox);
    final profileKey = session.profileKeyOf(outbox);
    return Avatar(
      key: key,
      session: session,
      name: p.name,
      image: p.avatar,
      color: p.color,
      radius: radius,
      presence: profileKey == null
          ? null
          : session.app?.directory[profileKey]?.presence,
    );
  }

  factory Avatar.room(RoomSession session, {double radius = 18}) => Avatar(
    session: session,
    name: session.meta.name,
    image: session.meta.avatar,
    color: session.meta.background ?? session.meta.accent,
    radius: radius,
  );

  factory Avatar.global(
    MediaSource media,
    GlobalProfile p, {
    double radius = 20,
    bool showPresence = true,
  }) => Avatar(
    session: media,
    name: p.name,
    image: p.avatar,
    color: p.color,
    radius: radius,
    presence: showPresence ? p.presence : null,
  );

  static Color presenceColor(Presence p) => switch (p) {
    Presence.online => const Color(0xFF31A24C),
    Presence.away => const Color(0xFFF5A623),
    Presence.dnd => const Color(0xFFE53935),
    Presence.offline => const Color(0xFF9E9E9E),
  };

  @override
  Widget build(BuildContext context) {
    final bg = color != null
        ? Color(color!)
        : Theme.of(context).colorScheme.primaryContainer;
    final initials = Container(
      width: radius * 2,
      height: radius * 2,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Text(
        _initials(name),
        style: TextStyle(
          color: onColor(bg),
          fontWeight: FontWeight.w600,
          fontSize: radius * 0.8,
        ),
      ),
    );
    final ref = image;
    final face = ref == null
        ? initials
        : _AvatarPicture(
            session: session,
            image: ref,
            size: radius * 2,
            fallback: initials,
          );
    final p = presence;
    if (p == null) return face;
    final dot = (radius * 0.55).clamp(8.0, 16.0);
    return SizedBox(
      width: radius * 2,
      height: radius * 2,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          face,
          Positioned(
            right: -1,
            bottom: -1,
            child: Tooltip(
              message: p.label,
              child: Container(
                width: dot,
                height: dot,
                decoration: BoxDecoration(
                  color: presenceColor(p),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.surface,
                    width: 2,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _initials(String name) {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    if (words.isEmpty) return '?';
    final chars = words.take(2).map((w) => w.characters.first.toUpperCase());
    return chars.join();
  }
}

/// The picture inside an [Avatar]. Keeps one load per picture across
/// rebuilds: a fresh future on every rebuild (rooms and the profile
/// directory notify often) kept resetting to the initials, so a busy screen
/// could show them indefinitely. The previous picture stays up while a new
/// one loads.
class _AvatarPicture extends StatefulWidget {
  const _AvatarPicture({
    required this.session,
    required this.image,
    required this.size,
    required this.fallback,
  });

  final MediaSource session;
  final MediaRef image;
  final double size;
  final Widget fallback;

  @override
  State<_AvatarPicture> createState() => _AvatarPictureState();
}

class _AvatarPictureState extends State<_AvatarPicture> {
  File? _file;
  String? _loading;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_AvatarPicture old) {
    super.didUpdateWidget(old);
    if (old.image.hash != widget.image.hash || old.session != widget.session) {
      _load();
    }
  }

  Future<void> _load() async {
    final hash = widget.image.hash;
    _loading = hash;
    try {
      // mediaFile de-duplicates by content hash: the file is fetched once.
      final f = await widget.session.mediaFile('avatar', widget.image);
      if (mounted && _loading == hash) setState(() => _file = f);
    } on Object catch (e) {
      debugPrint('avatar not available yet: $e');
      if (mounted && _loading == hash) setState(() => _file = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = _file;
    if (f == null) return widget.fallback;
    return ClipOval(
      child: Image.file(
        f,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      ),
    );
  }
}
