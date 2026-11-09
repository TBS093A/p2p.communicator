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

  test('GIF over the avatar limit is refused, fine as a background', () async {
    // Valid GIF header followed by padding: only the size matters here.
    final big = Uint8List(ImagePrep.maxAnimatedAvatar + 1)
      ..setAll(0, 'GIF89a'.codeUnits);
    await expectLater(
      ImagePrep.prepare(big, ImageUse.avatar),
      throwsA(isA<ImagePrepException>()),
    );
    final bg = await ImagePrep.prepare(big, ImageUse.background);
    expect(bg.animated, isTrue);
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
