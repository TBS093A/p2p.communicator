import 'package:flutter/material.dart';

import '../../room/room_style.dart';

/// A row of color swatches from [stylePalette]; null selection = default.
class ColorPicker extends StatelessWidget {
  const ColorPicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final int? selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final c in stylePalette)
          Semantics(
            button: true,
            selected: c == selected,
            label: '#${c.toRadixString(16).substring(2).toUpperCase()}',
            child: InkWell(
              key: ValueKey('swatch-${c.toRadixString(16)}'),
              customBorder: const CircleBorder(),
              onTap: () => onChanged(c),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Color(c),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: c == selected
                        ? Theme.of(context).colorScheme.onSurface
                        : Colors.transparent,
                    width: 3,
                  ),
                ),
                child: c == selected
                    ? Icon(Icons.check, color: onColor(Color(c)))
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}
