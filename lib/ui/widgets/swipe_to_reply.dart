import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Drag a message sideways to reply (like most messengers): someone else's
/// message to the right, your own to the left (towards the middle). A reply
/// icon fades in behind it, and past [threshold] letting go replies. The
/// message springs back either way.
class SwipeToReply extends StatefulWidget {
  const SwipeToReply({
    super.key,
    required this.onReply,
    required this.child,
    this.toLeft = false,
    this.threshold = 64,
  });

  final VoidCallback onReply;
  final Widget child;

  /// Swipe left instead of right (your own messages).
  final bool toLeft;
  final double threshold;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply>
    with SingleTickerProviderStateMixin {
  late final AnimationController _back = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..addListener(() => setState(() => _dx = _from * (1 - _back.value)));

  /// Distance dragged in the reply direction, always >= 0.
  double _dx = 0;
  double _from = 0;
  bool _armed = false;

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails d) {
    _back.stop();
    final max = widget.threshold * 1.4;
    final delta = widget.toLeft ? -d.delta.dx : d.delta.dx;
    setState(() => _dx = (_dx + delta).clamp(0, max));
    final armed = _dx >= widget.threshold;
    if (armed && !_armed) HapticFeedback.selectionClick();
    _armed = armed;
  }

  void _end([DragEndDetails? _]) {
    if (_armed) widget.onReply();
    _armed = false;
    _from = _dx;
    _back.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_dx / widget.threshold).clamp(0.0, 1.0);
    final icon = Opacity(
      opacity: progress,
      child: Transform.scale(
        scale: 0.6 + 0.4 * progress,
        child: const Icon(Icons.reply),
      ),
    );
    return GestureDetector(
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      onHorizontalDragCancel: _end,
      child: Stack(
        alignment: widget.toLeft ? Alignment.centerRight : Alignment.centerLeft,
        children: [
          Positioned(
            left: widget.toLeft ? null : 12,
            right: widget.toLeft ? 12 : null,
            child: icon,
          ),
          Transform.translate(
            offset: Offset(widget.toLeft ? -_dx : _dx, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}
