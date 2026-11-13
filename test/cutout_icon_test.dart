import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_communicator/ui/widgets/cutout_icon.dart';

void main() {
  testWidgets('the icon is a hole: the background shows through it', (t) async {
    // Tests draw no icon glyphs unless the icon font is loaded.
    final font = File(
      '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/'
      'material_fonts/MaterialIcons-Regular.otf',
    );
    await t.runAsync(() async {
      final bytes = await font.readAsBytes();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    });
    const background = Color(0xFFFF0000);
    const circle = Color(0xFF0000FF);
    final key = GlobalKey();
    await t.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(
            key: key,
            child: const ColoredBox(
              color: background,
              child: Padding(
                padding: EdgeInsets.all(8),
                child: CutoutIcon(
                  icon: Icons.stop, // a solid square glyph
                  color: circle,
                  diameter: 44,
                  iconSize: 24,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final bytes = (await t.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return (data!, image.width);
    }))!;
    Color at(int x, int y) {
      final i = (y * bytes.$2 + x) * 4;
      final d = bytes.$1;
      return Color.fromARGB(
        d.getUint8(i + 3),
        d.getUint8(i),
        d.getUint8(i + 1),
        d.getUint8(i + 2),
      );
    }

    // 8 px padding + 22 px radius: the circle's center is at (30, 30).
    expect(at(30, 30), background, reason: 'icon must be cut out');
    expect(at(30, 12), circle, reason: 'ring of the circle stays filled');
    expect(at(2, 2), background, reason: 'outside the circle');
  });
}
