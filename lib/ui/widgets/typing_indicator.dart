import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../room/room_session.dart';
import '../../room/typing.dart';
import '../../vault/room_secrets.dart';

/// Three bouncing dots, plus who is typing in groups ("Ola pisze…"). In a
/// DM only the dots: there is just one other person.
class TypingIndicator extends StatelessWidget {
  const TypingIndicator({super.key, required this.session});

  final RoomSession session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final names = session.typingNames;
        final dm = session.kind == RoomKind.dm;
        return AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.bottomLeft,
          child: names.isEmpty
              ? const SizedBox(width: double.infinity)
              : Padding(
                  key: const ValueKey('typing-indicator'),
                  padding: const EdgeInsets.fromLTRB(14, 2, 14, 2),
                  child: Row(
                    children: [
                      const TypingDots(),
                      if (!dm) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            Typing.label(names),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
        );
      },
    );
  }
}

class TypingDots extends StatefulWidget {
  const TypingDots({super.key});

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 4),
              Transform.translate(
                // Each dot rises and falls a third of a cycle after the last.
                offset: Offset(
                  0,
                  -3 * math.max(0, math.sin((_c.value - i / 3) * 2 * math.pi)),
                ),
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
