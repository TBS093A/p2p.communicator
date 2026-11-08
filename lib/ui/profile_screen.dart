import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app.dart';
import '../room/room_session.dart';
import 'widgets/avatar.dart';
import 'widgets/color_picker.dart';

/// How I appear in this room: name, avatar, bubble color. Each room has its
/// own profile, so rooms stay unlinkable.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.session});

  final RoomSession session;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final _name = TextEditingController(text: widget.session.myProfile.name);
  bool _busy = false;

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
    await _run(() => widget.session.updateMyProfile(avatar: File(picked.path)));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Mój profil w pokoju')),
        body: AbsorbPointer(
          absorbing: _busy,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_busy) const LinearProgressIndicator(),
              Center(
                child: Stack(
                  children: [
                    Avatar.member(s, s.myOutbox, radius: 48),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: IconButton.filledTonal(
                        tooltip: 'Zmień awatar',
                        icon: const Icon(Icons.photo_camera),
                        onPressed: _pickAvatar,
                      ),
                    ),
                  ],
                ),
              ),
              if (s.myProfile.avatar != null)
                Center(
                  child: TextButton(
                    onPressed: () =>
                        _run(() => s.updateMyProfile(clearAvatar: true)),
                    child: const Text('Usuń awatar'),
                  ),
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
              const SizedBox(height: 16),
              Text(
                'Kolor moich dymków',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 12),
              ColorPicker(
                selected: s.myProfile.color,
                onChanged: (c) => _run(() => s.updateMyProfile(color: c)),
              ),
              const SizedBox(height: 16),
              Text(
                'Tak widzą cię inni w tym pokoju. W innych pokojach masz '
                'osobny profil.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
