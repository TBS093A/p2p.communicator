import 'dart:io';

import 'package:flutter/material.dart';

import '../../room/message.dart';
import '../../room/room_session.dart';
import '../../room/room_style.dart';

/// Round avatar: the image if there is one (downloaded from the room's DHT
/// records on first use, then cached encrypted), else initials on [color].
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.session,
    required this.name,
    this.image,
    this.color,
    this.radius = 20,
  });

  final RoomSession session;
  final String name;
  final MediaRef? image;
  final int? color;
  final double radius;

  factory Avatar.member(
    RoomSession session,
    String outbox, {
    double radius = 20,
  }) {
    final p = session.profileOf(outbox);
    return Avatar(
      session: session,
      name: p.name,
      image: p.avatar,
      color: p.color,
      radius: radius,
    );
  }

  factory Avatar.room(RoomSession session, {double radius = 18}) => Avatar(
    session: session,
    name: session.meta.name,
    image: session.meta.avatar,
    color: session.meta.accent,
    radius: radius,
  );

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
    if (ref == null) return initials;
    return FutureBuilder<File>(
      // mediaFile de-duplicates by content hash, so rebuilding is cheap.
      future: session.mediaFile('avatar', ref),
      builder: (context, snap) => snap.hasData
          ? ClipOval(
              child: Image.file(
                snap.data!,
                width: radius * 2,
                height: radius * 2,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            )
          : initials,
    );
  }

  static String _initials(String name) {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    if (words.isEmpty) return '?';
    final chars = words.take(2).map((w) => w.characters.first.toUpperCase());
    return chars.join();
  }
}
