import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

enum ImageUse { avatar, background }

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

/// Turns a picked file into what gets uploaded.
///
/// * GIF and animated WebP are kept byte for byte, so they stay animated
///   (re-encoding would keep only the first frame); they are size-limited.
/// * Static images get their EXIF rotation applied and are scaled down:
///   avatars to a 256×256 square crop, backgrounds to 1440 px on the long
///   side, both as JPEG. A 12 MP photo becomes a few tens of KB.
///
/// Runs in a background isolate so decoding big photos does not stutter
/// the UI.
class ImagePrep {
  ImagePrep._();

  static const maxAnimatedAvatar = 1024 * 1024;
  static const maxAnimatedBackground = 4 * 1024 * 1024;
  static const maxSource = 25 * 1024 * 1024;
  static const avatarSize = 256;
  static const backgroundLongSide = 1440;

  static Future<PreparedImage> prepare(Uint8List bytes, ImageUse use) =>
      compute(_prepare, (bytes, use));

  static PreparedImage _prepare((Uint8List, ImageUse) args) {
    final (bytes, use) = args;
    if (bytes.length > maxSource) {
      throw ImagePrepException('Plik jest za duży (max 25 MB)');
    }

    final animatedMime = _animatedMime(bytes);
    if (animatedMime != null) {
      final limit = use == ImageUse.avatar
          ? maxAnimatedAvatar
          : maxAnimatedBackground;
      if (bytes.length > limit) {
        throw ImagePrepException(
          'GIF jest za duży (max ${limit ~/ (1024 * 1024)} MB)',
        );
      }
      return PreparedImage(bytes, animatedMime, animated: true);
    }

    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw ImagePrepException(
        'Nieobsługiwany format obrazka (użyj JPG, PNG, WebP lub GIF)',
      );
    }
    final upright = img.bakeOrientation(decoded);
    final out = switch (use) {
      ImageUse.avatar => img.copyResizeCropSquare(
        upright,
        size: avatarSize,
        interpolation: img.Interpolation.average,
      ),
      ImageUse.background => _fitLongSide(upright, backgroundLongSide),
    };
    return PreparedImage(
      img.encodeJpg(out, quality: use == ImageUse.avatar ? 85 : 82),
      'image/jpeg',
      animated: false,
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
