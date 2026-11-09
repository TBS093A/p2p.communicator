// The DAST run uploads these generated images as avatars and as an animated
// emoji; make sure they are what the screenshots promise.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:p2p_communicator/core/image_prep.dart';

import '../integration_test/test_images.dart';

void main() {
  test('avatars are 256×256 PNGs within the avatar size limit', () async {
    for (final path in [await mountainAvatar(), await portraitAvatar()]) {
      final bytes = await File(path).readAsBytes();
      final png = img.decodePng(bytes)!;
      expect(png.width, 256);
      expect(png.height, 256);
      expect(bytes.length, lessThan(200 * 1024));
      // ignore: avoid_print
      print('DAST image: $path');
    }
  });

  test('party emoji is an animated GIF within the emoji size limit', () async {
    final path = await partyGif();
    final bytes = await File(path).readAsBytes();
    final gif = img.decodeGif(bytes)!;
    expect(gif.numFrames, 12);
    // Transparent corners (it sits on any bubble color), opaque star.
    final first = gif.frames.first;
    expect(first.getPixel(0, 0).a, 0);
    expect(first.getPixel(48, 48).a, isNot(0));
    expect(bytes.length, lessThan(512 * 1024));
    expect(path, endsWith('party.gif')); // the app suggests :party: from it
    // ignore: avoid_print
    print('DAST image: $path');
  });

  test('GIF avatar and GIF background pass ImagePrep as animations', () async {
    for (final (path, use, frames) in [
      (await portraitGif(), ImageUse.avatar, 2),
      (await snowfallGif(), ImageUse.background, 10),
    ]) {
      final bytes = await File(path).readAsBytes();
      expect(img.decodeGif(bytes)!.numFrames, frames);
      final prepared = await ImagePrep.prepare(bytes, use);
      expect(prepared.animated, isTrue, reason: path);
      expect(prepared.bytes, bytes, reason: 'kept byte for byte');
      // ignore: avoid_print
      print('DAST image: $path (${bytes.length} B)');
    }
  });

  test('fake picker hands out queued files in order, then nothing', () async {
    final picker = FakeImagePicker()..queue.addAll(['/a.png', '/b.gif']);
    expect(
      (await picker.getImageFromSource(source: ImageSource.gallery))!.path,
      '/a.png',
    );
    expect(
      (await picker.getImageFromSource(source: ImageSource.gallery))!.path,
      '/b.gif',
    );
    expect(
      await picker.getImageFromSource(source: ImageSource.gallery),
      isNull,
    );
  });
}
