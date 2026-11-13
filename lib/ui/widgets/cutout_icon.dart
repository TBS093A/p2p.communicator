import 'package:flutter/material.dart';

/// A filled circle with [icon] cut out of it: the icon is a hole through
/// which whatever is behind the button (the chat background) shows.
class CutoutIcon extends StatelessWidget {
  const CutoutIcon({
    super.key,
    required this.icon,
    required this.color,
    this.diameter = 44,
    this.iconSize = 24,
  });

  final IconData icon;
  final Color color;
  final double diameter;
  final double iconSize;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(diameter),
    painter: _CutoutPainter(icon: icon, color: color, iconSize: iconSize),
  );
}

class _CutoutPainter extends CustomPainter {
  _CutoutPainter({
    required this.icon,
    required this.color,
    required this.iconSize,
  });

  final IconData icon;
  final Color color;
  final double iconSize;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // A layer of its own, so the hole only removes the circle beneath it.
    canvas.saveLayer(rect, Paint());
    canvas.drawCircle(
      rect.center,
      size.shortestSide / 2,
      Paint()..color = color,
    );
    final glyph = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: iconSize,
          height: 1,
          foreground: Paint()..blendMode = BlendMode.dstOut,
        ),
      ),
    )..layout();
    glyph.paint(
      canvas,
      rect.center - Offset(glyph.width / 2, glyph.height / 2),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CutoutPainter old) =>
      old.icon != icon || old.color != color || old.iconSize != iconSize;
}
