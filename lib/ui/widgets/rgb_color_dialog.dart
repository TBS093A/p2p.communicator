import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../room/room_style.dart';

/// Result of [showRgbColorDialog]: a chosen color, or `color == null` when
/// the user asked for the default back. The dialog returns null on cancel.
typedef RgbChoice = ({int? color});

/// Full-RGB color picker: live preview, R/G/B sliders, HEX input and a few
/// presets. [preview] draws the sample (a bubble, a chat background, …).
Future<RgbChoice?> showRgbColorDialog(
  BuildContext context, {
  required String title,
  required int? initial,
  required int fallback,
  required Widget Function(Color color) preview,
}) => showDialog<RgbChoice>(
  context: context,
  builder: (_) => _RgbColorDialog(
    title: title,
    initial: initial ?? fallback,
    preview: preview,
  ),
);

class _RgbColorDialog extends StatefulWidget {
  const _RgbColorDialog({
    required this.title,
    required this.initial,
    required this.preview,
  });

  final String title;
  final int initial;
  final Widget Function(Color color) preview;

  @override
  State<_RgbColorDialog> createState() => _RgbColorDialogState();
}

class _RgbColorDialogState extends State<_RgbColorDialog> {
  late int _r = (widget.initial >> 16) & 0xFF;
  late int _g = (widget.initial >> 8) & 0xFF;
  late int _b = widget.initial & 0xFF;
  late final _hex = TextEditingController(text: _hexOf(widget.initial));

  int get _argb => 0xFF000000 | (_r << 16) | (_g << 8) | _b;

  static String _hexOf(int argb) =>
      (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

  void _set(int argb, {bool fromHex = false}) {
    setState(() {
      _r = (argb >> 16) & 0xFF;
      _g = (argb >> 8) & 0xFF;
      _b = argb & 0xFF;
    });
    if (!fromHex) _hex.text = _hexOf(argb);
  }

  void _onHex(String text) {
    final clean = text.replaceAll('#', '').trim();
    if (clean.length != 6) return;
    final v = int.tryParse(clean, radix: 16);
    if (v != null) _set(0xFF000000 | v, fromHex: true);
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  Widget _slider(String label, int value, Color track, ValueChanged<int> on) {
    return Row(
      children: [
        SizedBox(
          width: 18,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(
              context,
            ).copyWith(activeTrackColor: track, thumbColor: track),
            child: Slider(
              key: ValueKey('rgb-slider-$label'),
              value: value.toDouble(),
              max: 255,
              divisions: 255,
              label: '$value',
              onChanged: (v) => on(v.round()),
            ),
          ),
        ),
        SizedBox(width: 34, child: Text('$value', textAlign: TextAlign.end)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = Color(_argb);
    return AlertDialog(
      title: Text(widget.title),
      scrollable: true,
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            widget.preview(color),
            const SizedBox(height: 16),
            _slider('R', _r, const Color(0xFFE53935), (v) {
              _set((_argb & 0xFF00FFFF) | (v << 16));
            }),
            _slider('G', _g, const Color(0xFF43A047), (v) {
              _set((_argb & 0xFFFF00FF) | (v << 8));
            }),
            _slider('B', _b, const Color(0xFF1E88E5), (v) {
              _set((_argb & 0xFFFFFF00) | v);
            }),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('rgb-hex'),
              controller: _hex,
              maxLength: 7,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp('[#0-9a-fA-F]')),
              ],
              decoration: const InputDecoration(
                labelText: 'HEX',
                prefixText: '#',
                counterText: '',
              ),
              onChanged: _onHex,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in stylePalette)
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _set(c),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: c == _argb
                              ? Theme.of(context).colorScheme.onSurface
                              : Colors.black12,
                          width: c == _argb ? 3 : 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, (color: null)),
          child: const Text('Domyślny'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Anuluj'),
        ),
        FilledButton(
          key: const ValueKey('rgb-save'),
          onPressed: () => Navigator.pop(context, (color: _argb)),
          child: const Text('Zapisz'),
        ),
      ],
    );
  }
}

/// Sample message bubble used as the preview for bubble colors.
Widget bubblePreview(Color color) => Align(
  alignment: Alignment.centerRight,
  child: Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Text(
      'Tak będą wyglądać twoje wiadomości',
      style: TextStyle(color: onColor(color)),
    ),
  ),
);

/// Small chat mock used as the preview for room backgrounds.
Widget backgroundPreview(Color color) => Container(
  height: 110,
  padding: const EdgeInsets.all(12),
  decoration: BoxDecoration(
    color: color,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: Colors.black12),
  ),
  child: Column(
    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
    children: [
      Align(
        alignment: Alignment.centerLeft,
        child: _mockBubble(defaultOtherBubbleLight, 'Hej, gdzie jesteście?'),
      ),
      Align(
        alignment: Alignment.centerRight,
        child: _mockBubble(defaultMyBubble, 'Już na szlaku!'),
      ),
    ],
  ),
);

Widget _mockBubble(int argb, String text) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
  decoration: BoxDecoration(
    color: Color(argb),
    borderRadius: BorderRadius.circular(12),
  ),
  child: Text(
    text,
    style: TextStyle(color: onColor(Color(argb)), fontSize: 12),
  ),
);
