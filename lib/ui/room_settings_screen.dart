import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

import '../app.dart';
import '../core/ui_prefs.dart';
import '../room/room_session.dart';
import '../room/room_style.dart';
import 'widgets/avatar.dart';
import 'widgets/emoji_text.dart';
import 'widgets/media_image.dart';
import 'widgets/rgb_color_dialog.dart';

/// Shared room look (every member sees the same): picture, name, chat
/// background and the custom emoji pack. Plus the app-wide light/dark choice.
class RoomSettingsScreen extends StatefulWidget {
  const RoomSettingsScreen({super.key, required this.session});

  final RoomSession session;

  @override
  State<RoomSettingsScreen> createState() => _RoomSettingsScreenState();
}

class _RoomSettingsScreenState extends State<RoomSettingsScreen> {
  late final _name = TextEditingController(text: widget.session.meta.name);
  bool _busy = false;

  /// Dim value while the slider is being dragged (saved on release).
  int? _dim;

  RoomSession get s => widget.session;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// No resize options on the picker: re-encoding there would flatten a GIF.
  /// The session scales static pictures itself and keeps GIFs animated.
  Future<File?> _pickOriginal() async {
    final picked = await AutoLock.suppress(
      () => ImagePicker().pickImage(source: ImageSource.gallery),
    );
    return picked == null ? null : File(picked.path);
  }

  Future<void> _uploadAvatar() async {
    final file = await _pickOriginal();
    if (file == null) return;
    await _run(() => s.updateRoom(avatar: file));
  }

  Future<void> _uploadBackgroundImage() async {
    final file = await _pickOriginal();
    if (file == null) return;
    await _run(() => s.updateRoom(backgroundImage: file));
  }

  Future<void> _editBackground() async {
    final fallback = Theme.of(context).colorScheme.surface.toARGB32();
    final choice = await showRgbColorDialog(
      context,
      title: 'Tło czatu',
      initial: s.meta.background,
      fallback: fallback,
      preview: backgroundPreview,
    );
    if (choice == null) return;
    await _run(
      () => choice.color == null
          ? s.updateRoom(clearBackground: true)
          : s.updateRoom(background: choice.color),
    );
  }

  Future<void> _addEmoji() async {
    // No resize/quality options on purpose: re-encoding would flatten an
    // animated GIF/WebP to its first frame. Size is limited instead.
    final picked = await AutoLock.suppress(
      () => ImagePicker().pickImage(source: ImageSource.gallery),
    );
    if (picked == null || !mounted) return;
    final suggested = p
        .basenameWithoutExtension(picked.path)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final code = await showDialog<String>(
      context: context,
      builder: (context) => _EmojiCodeDialog(
        image: File(picked.path),
        suggested: suggested.length > 32
            ? suggested.substring(0, 32)
            : suggested,
        taken: s.meta.emoji.keys.toSet(),
      ),
    );
    if (code == null) return;
    await _run(() => s.addEmoji(code, File(picked.path)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final emoji = s.meta.emoji.keys.toList()..sort();
        final bg = s.meta.background;
        return Scaffold(
          appBar: AppBar(title: const Text('Ustawienia pokoju')),
          body: AbsorbPointer(
            absorbing: _busy,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_busy) const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Center(child: Avatar.room(s, radius: 56)),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('room-avatar-upload'),
                      onPressed: _uploadAvatar,
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                      label: Text(
                        s.meta.avatar == null
                            ? 'Wgraj obrazek pokoju'
                            : 'Zmień obrazek',
                      ),
                    ),
                    if (s.meta.avatar != null) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Usuń obrazek pokoju',
                        onPressed: () =>
                            _run(() => s.updateRoom(clearAvatar: true)),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _name,
                  maxLength: 40,
                  decoration: InputDecoration(
                    labelText: 'Nazwa pokoju',
                    suffixIcon: IconButton(
                      tooltip: 'Zapisz nazwę',
                      icon: const Icon(Icons.check),
                      onPressed: () =>
                          _run(() => s.updateRoom(name: _name.text)),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  key: const ValueKey('room-bg-edit'),
                  contentPadding: EdgeInsets.zero,
                  leading: _Swatch(
                    color: bg == null
                        ? Theme.of(context).colorScheme.surface
                        : Color(bg),
                  ),
                  title: const Text('Tło czatu'),
                  subtitle: Text(
                    bg == null ? 'domyślne' : '#${_hex(bg)} · RGB ${_rgb(bg)}',
                  ),
                  trailing: const Icon(Icons.tune),
                  onTap: _editBackground,
                ),
                const SizedBox(height: 8),
                _Section('Obraz tła (może być GIF)'),
                Row(
                  children: [
                    if (s.meta.backgroundImage != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: SizedBox(
                          width: 56,
                          height: 96,
                          child: MediaImage(
                            session: s,
                            ref: s.meta.backgroundImage!,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    if (s.meta.backgroundImage != null)
                      const SizedBox(width: 12),
                    Expanded(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          FilledButton.tonalIcon(
                            key: const ValueKey('room-bgimg-upload'),
                            onPressed: _uploadBackgroundImage,
                            icon: const Icon(Icons.wallpaper),
                            label: Text(
                              s.meta.backgroundImage == null
                                  ? 'Wgraj obraz tła'
                                  : 'Zmień obraz',
                            ),
                          ),
                          if (s.meta.backgroundImage != null)
                            IconButton(
                              tooltip: 'Usuń obraz tła',
                              onPressed: () => _run(
                                () => s.updateRoom(clearBackgroundImage: true),
                              ),
                              icon: const Icon(Icons.delete_outline),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (s.meta.backgroundImage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Przyciemnienie: ${_dim ?? s.meta.effectiveDim}%',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  Slider(
                    key: const ValueKey('room-bgimg-dim'),
                    value: (_dim ?? s.meta.effectiveDim).toDouble(),
                    max: RoomMeta.maxDim.toDouble(),
                    divisions: RoomMeta.maxDim ~/ 5,
                    label: '${_dim ?? s.meta.effectiveDim}%',
                    onChanged: (v) => setState(() => _dim = v.round()),
                    // One network write when the finger lifts, not per tick.
                    onChangeEnd: (v) async {
                      await _run(() => s.updateRoom(dim: v.round()));
                      if (mounted) setState(() => _dim = null);
                    },
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _Section(
                        'Własne emoji (${emoji.length}/${RoomMeta.maxEmoji})',
                      ),
                    ),
                    FilledButton.tonalIcon(
                      key: const ValueKey('emoji-add'),
                      onPressed: _addEmoji,
                      icon: const Icon(Icons.add_reaction_outlined),
                      label: const Text('Dodaj'),
                    ),
                  ],
                ),
                Text(
                  'Obrazek lub GIF do 512 KB. W wiadomości wpisz :kod: albo '
                  'wybierz z przycisku emoji. GIF-y są animowane.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                if (emoji.isEmpty)
                  const Text('Brak własnych emoji.')
                else
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final code in emoji)
                        InputChip(
                          avatar: EmojiImage(session: s, code: code, size: 24),
                          label: Text(':$code:'),
                          onDeleted: () => _run(() => s.removeEmoji(code)),
                          deleteButtonTooltipMessage: 'Usuń :$code:',
                        ),
                    ],
                  ),
                const SizedBox(height: 24),
                _Section('Motyw aplikacji (ten telefon)'),
                ValueListenableBuilder<ThemeMode>(
                  valueListenable: UiPrefs.instance.themeMode,
                  builder: (context, mode, _) => SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text('Auto'),
                        tooltip: 'Jak w systemie',
                        icon: Icon(Icons.brightness_auto),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        label: Text('Jasny'),
                        icon: Icon(Icons.light_mode),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        label: Text('Ciemny'),
                        icon: Icon(Icons.dark_mode),
                      ),
                    ],
                    selected: {mode},
                    onSelectionChanged: (v) =>
                        UiPrefs.instance.setThemeMode(v.first),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Obrazek, nazwę, tło i emoji pokoju widzą i mogą zmieniać '
                  'wszyscy członkowie. Motyw dotyczy tylko tego telefonu.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

String _hex(int argb) =>
    (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

String _rgb(int argb) =>
    '${(argb >> 16) & 0xFF}, ${(argb >> 8) & 0xFF}, ${argb & 0xFF}';

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 40,
    height: 40,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(title, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _EmojiCodeDialog extends StatefulWidget {
  const _EmojiCodeDialog({
    required this.image,
    required this.suggested,
    required this.taken,
  });

  final File image;
  final String suggested;
  final Set<String> taken;

  @override
  State<_EmojiCodeDialog> createState() => _EmojiCodeDialogState();
}

class _EmojiCodeDialogState extends State<_EmojiCodeDialog> {
  late final _code = TextEditingController(text: widget.suggested);

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  String? get _error {
    final c = _code.text;
    if (!EmojiCode.isValid(c)) return '2–32 znaki: a–z, 0–9, _';
    if (widget.taken.contains(c)) return 'Ten kod zostanie podmieniony';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final valid = EmojiCode.isValid(_code.text);
    return AlertDialog(
      title: const Text('Nowe emoji'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.file(widget.image, width: 96, height: 96, fit: BoxFit.contain),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('emoji-code'),
            controller: _code,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Kod',
              prefixText: ':',
              suffixText: ':',
              helperText: _error == null ? 'np. party_parrot' : null,
              errorText: _error,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Anuluj'),
        ),
        FilledButton(
          key: const ValueKey('emoji-confirm'),
          onPressed: valid ? () => Navigator.pop(context, _code.text) : null,
          child: const Text('Dodaj'),
        ),
      ],
    );
  }
}
