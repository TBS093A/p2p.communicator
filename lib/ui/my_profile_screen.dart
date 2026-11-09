import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app.dart';
import '../app_state/app_session.dart';
import '../app_state/global_profile.dart';
import 'migration_screens.dart';
import 'widgets/avatar.dart';

/// The one profile everyone in your DMs and groups sees: picture (GIF ok),
/// name, bubble color and status. Private rooms have their own instead.
class MyProfileScreen extends StatefulWidget {
  const MyProfileScreen({super.key, required this.app});

  final AppSession app;

  @override
  State<MyProfileScreen> createState() => _MyProfileScreenState();
}

class _MyProfileScreenState extends State<MyProfileScreen> {
  late final _name = TextEditingController(text: widget.app.myGlobal.name);
  bool _busy = false;

  AppSession get app => widget.app;

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
    // No resize options: re-encoding in the picker would flatten a GIF.
    final picked = await AutoLock.suppress(
      () => ImagePicker().pickImage(source: ImageSource.gallery),
    );
    if (picked == null) return;
    await _run(() => app.updateGlobalProfile(avatar: File(picked.path)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final me = app.myGlobal;
        return Scaffold(
          appBar: AppBar(title: const Text('Mój profil')),
          body: AbsorbPointer(
            absorbing: _busy,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_busy) const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Center(child: Avatar.global(app, me, radius: 56)),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('profile-avatar-upload'),
                      onPressed: _uploadAvatar,
                      icon: const Icon(Icons.add_a_photo_outlined),
                      label: Text(
                        me.avatar == null ? 'Wgraj zdjęcie' : 'Zmień zdjęcie',
                      ),
                    ),
                    if (me.avatar != null) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Usuń zdjęcie',
                        onPressed: () => _run(
                          () => app.updateGlobalProfile(clearAvatar: true),
                        ),
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
                    labelText: 'Twoja nazwa',
                    suffixIcon: IconButton(
                      tooltip: 'Zapisz nazwę',
                      icon: const Icon(Icons.check),
                      onPressed: () =>
                          _run(() => app.updateGlobalProfile(name: _name.text)),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text('Status', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                RadioGroup<UserStatus>(
                  groupValue: me.status,
                  onChanged: (v) {
                    if (v != null) _run(() => app.setStatus(v));
                  },
                  child: Column(
                    children: [
                      for (final s in UserStatus.values)
                        RadioListTile<UserStatus>(
                          key: ValueKey('status-${s.name}'),
                          contentPadding: EdgeInsets.zero,
                          value: s,
                          secondary: Icon(
                            Icons.circle,
                            size: 14,
                            color: Avatar.presenceColor(switch (s) {
                              UserStatus.available => Presence.online,
                              UserStatus.away => Presence.away,
                              UserStatus.dnd => Presence.dnd,
                              UserStatus.invisible => Presence.offline,
                            }),
                          ),
                          title: Text(s.label),
                          subtitle: s == UserStatus.invisible
                              ? const Text('Inni widzą cię jako offline')
                              : null,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  key: const ValueKey('move-out'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.phonelink_setup),
                  title: const Text('Przenieś na nowy telefon'),
                  subtitle: const Text(
                    'Rozmowy, grupy, media i wybrane pokoje prywatne',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => MigrationSendScreen(app: app),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Ten profil widzą osoby z twoich rozmów i grup. Pokoje '
                  'prywatne mają osobną tożsamość, niepowiązaną z tą.',
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
