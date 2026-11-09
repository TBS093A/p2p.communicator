import 'dart:io';

import 'package:flutter/material.dart';

import '../../room/message.dart';
import '../../room/room_session.dart';

/// An image stored as room media (downloaded once, cached encrypted).
/// GIF and animated WebP play; [placeholder] shows until it is ready.
class MediaImage extends StatelessWidget {
  const MediaImage({
    super.key,
    required this.session,
    required this.ref,
    this.fit = BoxFit.cover,
    this.placeholder = const SizedBox.shrink(),
  });

  final RoomSession session;
  final MediaRef ref;
  final BoxFit fit;
  final Widget placeholder;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File>(
      // mediaFile de-duplicates by content hash, so rebuilding is cheap.
      future: session.mediaFile('image', ref),
      builder: (context, snap) => snap.hasData
          ? Image.file(
              snap.data!,
              fit: fit,
              width: double.infinity,
              height: double.infinity,
              gaplessPlayback: true,
            )
          : placeholder,
    );
  }
}
