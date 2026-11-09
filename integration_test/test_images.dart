// Images for the DAST run, generated in the test so no binary fixtures live
// in the repo, plus a fake gallery that hands them to the app through the
// normal ImagePicker API.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

/// Replaces the system photo picker: each pick returns the next queued file.
class FakeImagePicker extends ImagePickerPlatform {
  final List<String> queue = [];

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async => queue.isEmpty ? null : XFile(queue.removeAt(0));
}

Future<String> _write(String name, Uint8List bytes) async {
  final dir = await Directory.systemTemp.createTemp('dast_images');
  final f = File('${dir.path}/$name');
  await f.writeAsBytes(bytes);
  return f.path;
}

img.ColorRgb8 _rgb(int r, int g, int b) => img.ColorRgb8(r, g, b);

/// 256×256 PNG: dusk sky, sun, Tatra-like peaks with snow caps.
Future<String> mountainAvatar() async {
  const s = 256;
  final im = img.Image(width: s, height: s);
  for (var y = 0; y < s; y++) {
    final t = y / s;
    final c = _rgb(
      (255 * (0.98 - 0.45 * t)).round(),
      (255 * (0.62 - 0.25 * t)).round(),
      (255 * (0.38 + 0.35 * t)).round(),
    );
    img.drawLine(im, x1: 0, y1: y, x2: s - 1, y2: y, color: c);
  }
  img.fillCircle(im, x: 180, y: 92, radius: 30, color: _rgb(255, 236, 170));

  void peak(int left, int top, int right, img.Color c, img.Color snow) {
    final cx = (left + right) ~/ 2;
    img.fillPolygon(
      im,
      vertices: [img.Point(left, s), img.Point(cx, top), img.Point(right, s)],
      color: c,
    );
    final cap = (s - top) ~/ 5;
    img.fillPolygon(
      im,
      vertices: [
        img.Point(cx - cap ~/ 2, top + cap),
        img.Point(cx, top),
        img.Point(cx + cap ~/ 2, top + cap),
      ],
      color: snow,
    );
  }

  final snow = _rgb(245, 248, 255);
  peak(-40, 110, 170, _rgb(58, 74, 110), snow);
  peak(90, 70, 330, _rgb(38, 52, 84), snow);
  peak(-10, 160, 140, _rgb(28, 40, 64), snow);
  return _write('tatry.png', Uint8List.fromList(img.encodePng(im)));
}

img.Image _portrait({required bool eyesOpen}) {
  const s = 256;
  final im = img.Image(width: s, height: s);
  img.fill(im, color: _rgb(255, 183, 77));
  final hair = _rgb(93, 64, 55);
  final eye = _rgb(60, 40, 30);
  img.fillCircle(im, x: 128, y: 300, radius: 120, color: _rgb(0, 121, 107));
  img.fillCircle(im, x: 128, y: 104, radius: 66, color: hair);
  img.fillCircle(im, x: 128, y: 126, radius: 54, color: _rgb(255, 224, 189));
  for (final x in [108, 148]) {
    if (eyesOpen) {
      img.fillCircle(im, x: x, y: 126, radius: 6, color: eye);
    } else {
      img.fillRect(im, x1: x - 7, y1: 125, x2: x + 7, y2: 128, color: eye);
    }
  }
  img.fillRect(
    im,
    x1: 112,
    y1: 150,
    x2: 144,
    y2: 154,
    color: _rgb(214, 96, 96),
  );
  return im;
}

/// 256×256 PNG portrait on a warm background.
Future<String> portraitAvatar() async => _write(
  'marta.png',
  Uint8List.fromList(img.encodePng(_portrait(eyesOpen: true))),
);

/// The same portrait as an animated GIF that blinks: a GIF avatar.
Future<String> portraitGif() async {
  final anim = _portrait(eyesOpen: true)..frameDuration = 1800;
  anim.addFrame(_portrait(eyesOpen: false)..frameDuration = 160);
  return _write('marta_blink.gif', Uint8List.fromList(img.encodeGif(anim)));
}

/// 360×640 animated GIF chat background: night sky over the Tatras with
/// falling snow, 10 frames.
Future<String> snowfallGif() async {
  const w = 360;
  const h = 640;
  const frames = 10;
  final rnd = Random(7);
  final flakes = [
    for (var i = 0; i < 90; i++)
      (rnd.nextInt(w), rnd.nextInt(h), 1 + rnd.nextInt(3)),
  ];
  img.Image? anim;
  for (var f = 0; f < frames; f++) {
    final im = img.Image(width: w, height: h);
    for (var y = 0; y < h; y++) {
      final t = y / h;
      img.drawLine(
        im,
        x1: 0,
        y1: y,
        x2: w - 1,
        y2: y,
        color: _rgb(
          (14 + 40 * t).round(),
          (24 + 50 * t).round(),
          (52 + 70 * t).round(),
        ),
      );
    }
    img.fillPolygon(
      im,
      vertices: [img.Point(-60, h), img.Point(120, 420), img.Point(300, h)],
      color: _rgb(30, 42, 66),
    );
    img.fillPolygon(
      im,
      vertices: [img.Point(120, h), img.Point(280, 380), img.Point(460, h)],
      color: _rgb(22, 32, 52),
    );
    for (final (x, y, r) in flakes) {
      final fy = (y + f * h ~/ frames * r ~/ 2) % h;
      img.fillCircle(im, x: x, y: fy, radius: r, color: _rgb(235, 242, 255));
    }
    im.frameDuration = 120;
    if (anim == null) {
      anim = im;
    } else {
      anim.addFrame(im);
    }
  }
  return _write('snieg.gif', Uint8List.fromList(img.encodeGif(anim!)));
}

/// 96×96 animated GIF, 12 frames: a spinning, color-cycling party star on a
/// transparent background. Frames are palette images (index 0 transparent),
/// because the GIF encoder only keeps transparency from an alpha palette.
Future<String> partyGif() async {
  const s = 96;
  const frames = 12;
  img.Image? anim;
  for (var f = 0; f < frames; f++) {
    final hue = f / frames;
    final star = _hsv(hue);
    final dot = _hsv((hue + 0.5) % 1);
    final palette = img.PaletteUint8(3, 4)
      ..setRgba(0, 0, 0, 0, 0)
      ..setRgba(1, star.r, star.g, star.b, 255)
      ..setRgba(2, dot.r, dot.g, dot.b, 255);
    final frame = img.Image(width: s, height: s, palette: palette);
    // On a palette image a pixel's value is its palette index.
    final starIndex = img.ColorUint8.rgb(1, 0, 0);
    final dotIndex = img.ColorUint8.rgb(2, 0, 0);
    final angle = 2 * pi * f / frames;
    final pts = <img.Point>[];
    for (var i = 0; i < 10; i++) {
      final r = i.isEven ? 44.0 : 18.0;
      final a = angle + i * pi / 5;
      pts.add(img.Point(48 + r * sin(a), 48 - r * cos(a)));
    }
    img.fillPolygon(frame, vertices: pts, color: starIndex);
    img.fillCircle(frame, x: 48, y: 48, radius: 8, color: dotIndex);
    frame.frameDuration = 80;
    if (anim == null) {
      anim = frame;
    } else {
      anim.addFrame(frame);
    }
  }
  return _write('party.gif', Uint8List.fromList(img.encodeGif(anim!)));
}

img.ColorRgba8 _hsv(double h) {
  final i = (h * 6).floor();
  final f = h * 6 - i;
  final q = 1 - f;
  final (r, g, b) = switch (i % 6) {
    0 => (1.0, f, 0.0),
    1 => (q, 1.0, 0.0),
    2 => (0.0, 1.0, f),
    3 => (0.0, q, 1.0),
    4 => (f, 0.0, 1.0),
    _ => (1.0, 0.0, q),
  };
  return img.ColorRgba8(
    (r * 255).round(),
    (g * 255).round(),
    (b * 255).round(),
    255,
  );
}
