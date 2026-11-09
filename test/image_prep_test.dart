import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:p2p_communicator/core/image_prep.dart';

Uint8List _png(int w, int h) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(30, 120, 200));
  return Uint8List.fromList(img.encodePng(im));
}

Uint8List _gif(int frames) {
  img.Image? anim;
  for (var i = 0; i < frames; i++) {
    final f = img.Image(width: 32, height: 32);
    img.fill(f, color: img.ColorRgb8(i * 40, 0, 0));
    f.frameDuration = 100;
    if (anim == null) {
      anim = f;
    } else {
      anim.addFrame(f);
    }
  }
  return Uint8List.fromList(img.encodeGif(anim!));
}

void main() {
  test('static avatar becomes a 256×256 JPEG', () async {
    final p = await ImagePrep.prepare(_png(1200, 800), ImageUse.avatar);
    expect(p.mime, 'image/jpeg');
    expect(p.animated, isFalse);
    final out = img.decodeJpg(p.bytes)!;
    expect(out.width, 256);
    expect(out.height, 256);
  });

  test('static background keeps aspect, long side at most 1440', () async {
    final p = await ImagePrep.prepare(_png(3000, 1000), ImageUse.background);
    final out = img.decodeJpg(p.bytes)!;
    expect(out.width, 1440);
    expect(out.height, 480);
  });

  test('small background is not upscaled', () async {
    final p = await ImagePrep.prepare(_png(400, 300), ImageUse.background);
    final out = img.decodeJpg(p.bytes)!;
    expect((out.width, out.height), (400, 300));
  });

  test('GIF is kept byte for byte so it stays animated', () async {
    final gif = _gif(6);
    for (final use in ImageUse.values) {
      final p = await ImagePrep.prepare(gif, use);
      expect(p.mime, 'image/gif');
      expect(p.animated, isTrue);
      expect(p.bytes, gif);
      expect(img.decodeGif(p.bytes)!.numFrames, 6);
    }
  });

  test(
    'a corrupt GIF over the limit is refused with a readable error',
    () async {
      // GIF header followed by padding: too big to keep, not decodable.
      final big = Uint8List(ImagePrep.maxAnimatedAvatar + 1)
        ..setAll(0, 'GIF89a'.codeUnits);
      await expectLater(
        ImagePrep.prepare(big, ImageUse.avatar),
        throwsA(isA<ImagePrepException>()),
      );
    },
  );

  test('static emoji becomes a ≤128 px PNG with transparency', () async {
    final im = img.Image(width: 900, height: 450, numChannels: 4);
    img.fill(im, color: img.ColorRgba8(0, 0, 0, 0));
    img.fillCircle(
      im,
      x: 450,
      y: 225,
      radius: 200,
      color: img.ColorRgba8(255, 0, 0, 255),
    );
    final p = await ImagePrep.prepare(
      Uint8List.fromList(img.encodePng(im)),
      ImageUse.emoji,
    );
    expect(p.mime, 'image/png');
    final out = img.decodePng(p.bytes)!;
    expect((out.width, out.height), (128, 64));
    expect(out.getPixel(0, 0).a, 0, reason: 'corner stays transparent');
    expect(p.bytes.length, lessThan(ImagePrep.maxEmoji));
  });

  test(
    'an oversized animated GIF emoji is shrunk to fit, still animated',
    () async {
      // Noise frames: big on purpose (GIF compresses noise badly).
      img.Image? anim;
      final rnd = Random(1);
      for (var f = 0; f < 20; f++) {
        final fr = img.Image(width: 320, height: 320);
        for (var y = 0; y < 320; y++) {
          for (var x = 0; x < 320; x++) {
            fr.setPixelRgb(x, y, rnd.nextInt(256), rnd.nextInt(256), f * 12);
          }
        }
        fr.frameDuration = 50;
        if (anim == null) {
          anim = fr;
        } else {
          anim.addFrame(fr);
        }
      }
      final big = Uint8List.fromList(img.encodeGif(anim!));
      expect(big.length, greaterThan(ImagePrep.maxEmoji), reason: 'test input');

      final p = await ImagePrep.prepare(big, ImageUse.emoji);
      expect(p.mime, 'image/gif');
      expect(p.animated, isTrue);
      expect(p.bytes.length, lessThanOrEqualTo(ImagePrep.maxEmoji));
      final out = img.decodeGif(p.bytes)!;
      expect(out.numFrames, greaterThan(1), reason: 'still animated');
      expect(out.width, lessThanOrEqualTo(128));
      // Total duration kept within one frame even if frames were merged.
      final total = out.frames.fold<int>(0, (s, f) => s + f.frameDuration);
      expect(total, closeTo(20 * 50, 160));
    },
  );

  test('a GIF within the emoji limit is kept byte for byte', () async {
    final gif = _gif(4);
    final p = await ImagePrep.prepare(gif, ImageUse.emoji);
    expect(p.bytes, gif);
  });

  test('not an image is refused with a readable error', () async {
    await expectLater(
      ImagePrep.prepare(
        Uint8List.fromList(List.filled(64, 7)),
        ImageUse.avatar,
      ),
      throwsA(isA<ImagePrepException>()),
    );
  });
}
