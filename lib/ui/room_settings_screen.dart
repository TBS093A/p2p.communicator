import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

import '../app.dart';
import '../core/ui_prefs.dart';
import '../room/room_session.dart';
import '../room/room_style.dart';
import 'widgets/avatar.dart';
import 'widgets/color_picker.dart';
import 'widgets/emoji_text.dart';

/// Shared room look (every member sees the same): avatar, name, accent color
/// and the custom emoji pack. Plus the app-wide light/dark choice.
class RoomSettingsScreen extends StatefulWidget {
  const RoomSettingsScreen({super.key, required this.session});

  final RoomSession session;

  @override
  State<RoomSettingsScreen> createState() => _RoomSettingsScreenState();
}

class _RoomSettingsScreenState extends State<RoomSettingsScreen> {
  late final _name = TextEditingController(text: widget.session.meta.name);
  bool _busy = false;

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

  Future<void> _pickAvatar() async {
    final picked = await AutoLock.suppress(
      () => ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 256,
        maxHeight: 256,
        imageQuality: 85,
      ),
    );
    if (picked == null) return;
    await _run(() => s.updateRoom(avatar: File(picked.path)));
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
        return Scaffold(
          appBar: AppBar(title: const Text('Ustawienia pokoju')),
          body: AbsorbPointer(
            absorbing: _busy,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_busy) const LinearProgressIndicator(),
                Center(
                  child: Stack(
                    children: [
                      Avatar.room(s, radius: 48),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: IconButton.filledTonal(
                          tooltip: 'Zmień awatar pokoju',
                          icon: const Icon(Icons.photo_camera),
                          onPressed: _pickAvatar,
                        ),
                      ),
                    ],
                  ),
                ),
                if (s.meta.avatar != null)
                  Center(
                    child: TextButton(
                      onPressed: () =>
                          _run(() => s.updateRoom(clearAvatar: true)),
                      child: const Text('Usuń awatar pokoju'),
                    ),
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
                const SizedBox(height: 16),
                _Section('Kolor pokoju'),
                ColorPicker(
                  selected: s.meta.accent,
                  onChanged: (c) => _run(() => s.updateRoom(accent: c)),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: _Section(
                        'Własne emoji (${emoji.length}/${RoomMeta.maxEmoji})',
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _addEmoji,
                      icon: const Icon(Icons.add_reaction_outlined),
                      label: const Text('Dodaj'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
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
                        label: Text('Systemowy'),
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
                  'Awatar, nazwę, kolor i emoji pokoju widzą i mogą zmieniać '
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

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
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
            controller: _code,
            autofocus: true,
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
          onPressed: valid ? () => Navigator.pop(context, _code.text) : null,
          child: const Text('Dodaj'),
        ),
      ],
    );
  }
}
