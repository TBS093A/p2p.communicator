import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app.dart';
import '../room/room_session.dart';
import '../room/room_style.dart';
import 'widgets/avatar.dart';
import 'widgets/rgb_color_dialog.dart';

/// How I appear in this room: picture, name, bubble color (text, photos and
/// voice notes alike). Each room has its own profile, so rooms stay
/// unlinkable.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.session});

  final RoomSession session;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final _name = TextEditingController(text: widget.session.myProfile.name);
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
        ).showSnackBar(SnackBar(content: Text('Nie udało się: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uploadAvatar() async {
    // No resize options: re-encoding in the picker would flatten a GIF. The
    // session scales static photos itself and keeps GIFs animated.
    final picked = await AutoLock.suppress(
      () => ImagePicker().pickImage(source: ImageSource.gallery),
    );
    if (picked == null) return;
    await _run(() => s.updateMyProfile(avatar: File(picked.path)));
  }

  Future<void> _editColor() async {
    final choice = await showRgbColorDialog(
      context,
      title: 'Kolor moich dymków',
      initial: s.myProfile.color,
      fallback: defaultMyBubble,
      preview: bubblePreview,
    );
    if (choice == null) return;
    await _run(
      () => choice.color == null
          ? s.updateMyProfile(clearColor: true)
          : s.updateMyProfile(color: choice.color),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final color = s.myProfile.color ?? defaultMyBubble;
        return Scaffold(
          appBar: AppBar(title: const Text('Mój profil w pokoju')),
          body: AbsorbPointer(
            absorbing: _busy,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_busy) const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Center(child: Avatar.member(s, s.myOutbox, radius: 56)),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('profile-avatar-upload'),
                      onPressed: _uploadAvatar,
                      icon: const Icon(Icons.add_a_photo_outlined),
                      label: Text(
                        s.myProfile.avatar == null
                            ? 'Wgraj zdjęcie'
                            : 'Zmień zdjęcie',
                      ),
                    ),
                    if (s.myProfile.avatar != null) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Usuń zdjęcie',
                        onPressed: () =>
                            _run(() => s.updateMyProfile(clearAvatar: true)),
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
                    labelText: 'Nazwa w tym pokoju',
                    suffixIcon: IconButton(
                      tooltip: 'Zapisz nazwę',
                      icon: const Icon(Icons.check),
                      onPressed: () =>
                          _run(() => s.updateMyProfile(name: _name.text)),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  key: const ValueKey('bubble-color-edit'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Kolor moich dymków'),
                  subtitle: Text(
                    s.myProfile.color == null
                        ? 'domyślny'
                        : '#${(color & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
                  ),
                  trailing: const Icon(Icons.tune),
                  onTap: _editColor,
                ),
                bubblePreview(Color(color)),
                const SizedBox(height: 24),
                Text(
                  'Kolor dotyczy wszystkich twoich dymków: tekstu, zdjęć, '
                  'wideo i głosówek. Tak widzą cię inni w tym pokoju; w innych '
                  'pokojach masz osobny profil.',
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
