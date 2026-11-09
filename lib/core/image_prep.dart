import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

enum ImageUse {
  avatar(maxAnimated: 1024 * 1024, sizes: [256, 192, 128]),
  background(maxAnimated: 4 * 1024 * 1024, sizes: [720, 540, 360]),
  emoji(maxAnimated: 512 * 1024, sizes: [128, 96, 64]);

  const ImageUse({required this.maxAnimated, required this.sizes});

  /// Animated files up to this size are kept byte for byte.
  final int maxAnimated;

  /// Longest-side sizes tried, in order, when an animation must shrink.
  final List<int> sizes;
}

class PreparedImage {
  const PreparedImage(this.bytes, this.mime, {required this.animated});
  final Uint8List bytes;
  final String mime;
  final bool animated;
}

class ImagePrepException implements Exception {
  ImagePrepException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Turns a picked file into what gets uploaded, automatically: nobody has
/// to resize anything by hand.
///
/// * GIF and animated WebP within the use's limit are kept byte for byte.
///   Bigger ones are re-encoded as a smaller GIF: frames scaled down (e.g.
///   emoji to 128, then 96, 64 px) and, if needed, every 2nd/3rd/4th frame
///   kept with its timing merged so the speed stays the same, until it fits.
/// * Static images get their EXIF rotation applied and are scaled down:
///   avatars to a 256×256 square crop (JPEG), backgrounds to 1440 px on the
///   long side (JPEG), emoji to 128 px keeping transparency (PNG).
///
/// Runs in a background isolate so decoding big files does not stutter
/// the UI.
class ImagePrep {
  ImagePrep._();

  static final maxAnimatedAvatar = ImageUse.avatar.maxAnimated;
  static final maxAnimatedBackground = ImageUse.background.maxAnimated;
  static final maxEmoji = ImageUse.emoji.maxAnimated;
  static const maxSource = 25 * 1024 * 1024;
  static const avatarSize = 256;
  static const backgroundLongSide = 1440;
  static const emojiSize = 128;

  static Future<PreparedImage> prepare(Uint8List bytes, ImageUse use) =>
      compute(_prepare, (bytes, use));

  static PreparedImage _prepare((Uint8List, ImageUse) args) {
    final (bytes, use) = args;
    if (bytes.length > maxSource) {
      throw ImagePrepException('Plik jest za duży (max 25 MB)');
    }

    final animatedMime = _animatedMime(bytes);
    if (animatedMime != null) {
      if (bytes.length <= use.maxAnimated) {
        return PreparedImage(bytes, animatedMime, animated: true);
      }
      return _shrinkAnimation(bytes, use);
    }

    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw ImagePrepException(
        'Nieobsługiwany format obrazka (użyj JPG, PNG, WebP lub GIF)',
      );
    }
    final upright = img.bakeOrientation(decoded);
    switch (use) {
      case ImageUse.avatar:
        final out = img.copyResizeCropSquare(
          upright,
          size: avatarSize,
          interpolation: img.Interpolation.average,
        );
        return PreparedImage(
          img.encodeJpg(out, quality: 85),
          'image/jpeg',
          animated: false,
        );
      case ImageUse.background:
        return PreparedImage(
          img.encodeJpg(_fitLongSide(upright, backgroundLongSide), quality: 82),
          'image/jpeg',
          animated: false,
        );
      case ImageUse.emoji:
        // PNG keeps transparency; a 128 px emoji is a few KB.
        final png = img.encodePng(_fitLongSide(upright, emojiSize));
        if (png.length <= use.maxAnimated) {
          return PreparedImage(png, 'image/png', animated: false);
        }
        return PreparedImage(
          img.encodeJpg(_fitLongSide(upright, emojiSize), quality: 85),
          'image/jpeg',
          animated: false,
        );
    }
  }

  /// Re-encodes an animation that is over the use's limit: smaller frames
  /// first, then fewer frames (timing merged so the speed is unchanged),
  /// until it fits.
  static PreparedImage _shrinkAnimation(Uint8List bytes, ImageUse use) {
    final anim = img.decodeImage(bytes);
    if (anim == null) {
      throw ImagePrepException('Nie udało się odczytać animacji');
    }
    final frames = anim.frames;
    for (final step in const [1, 2, 3, 4]) {
      for (final size in use.sizes) {
        img.Image? out;
        for (var i = 0; i < frames.length; i += step) {
          var duration = 0;
          for (var j = i; j < i + step && j < frames.length; j++) {
            duration += frames[j].frameDuration;
          }
          // Frame 0 is the animation itself (it holds the frame list), and
          // copyResize walks all frames: copy one bare frame first.
          final single = img.Image.from(frames[i], noAnimation: true);
          final f = _fitLongSide(single, size)
            ..frameDuration = duration == 0 ? 100 * step : duration;
          if (out == null) {
            out = f;
          } else {
            out.addFrame(f);
          }
        }
        final gif = img.encodeGif(out!);
        if (gif.length <= use.maxAnimated) {
          return PreparedImage(gif, 'image/gif', animated: true);
        }
      }
    }
    throw ImagePrepException(
      'Animacja jest zbyt duża nawet po zmniejszeniu '
      '(limit ${use.maxAnimated ~/ 1024} KB)',
    );
  }

  static img.Image _fitLongSide(img.Image src, int max) {
    if (src.width <= max && src.height <= max) return src;
    return src.width >= src.height
        ? img.copyResize(
            src,
            width: max,
            interpolation: img.Interpolation.average,
          )
        : img.copyResize(
            src,
            height: max,
            interpolation: img.Interpolation.average,
          );
  }

  /// GIF (any) or animated WebP; null for everything else.
  static String? _animatedMime(Uint8List b) {
    if (b.length >= 6 &&
        b[0] == 0x47 && // G
        b[1] == 0x49 && // I
        b[2] == 0x46 && // F
        b[3] == 0x38) {
      return 'image/gif';
    }
    final isWebp =
        b.length >= 16 &&
        String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(b.sublist(8, 12)) == 'WEBP';
    if (isWebp &&
        String.fromCharCodes(b.sublist(12, 16)) == 'VP8X' &&
        b.length > 20 &&
        (b[20] & 0x02) != 0) {
      return 'image/webp'; // VP8X header with the animation flag
    }
    return null;
  }
}
