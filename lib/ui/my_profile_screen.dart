import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app.dart';
import '../app_state/app_session.dart';
import '../app_state/global_profile.dart';
import '../room/room_session.dart';
import '../update/update_service.dart';
import '../vault/room_secrets.dart';
import 'migration_screens.dart';
import 'update_screen.dart';
import 'widgets/avatar.dart';

/// The one profile everyone in your DMs and groups sees: picture (GIF ok),
/// global nickname and status. Opened from a DM or group ([room]), it also
/// offers a nickname for just that conversation. Private rooms have their
/// own profile instead.
class MyProfileScreen extends StatefulWidget {
  const MyProfileScreen({super.key, required this.app, this.room});

  final AppSession app;
  final RoomSession? room;

  @override
  State<MyProfileScreen> createState() => _MyProfileScreenState();
}

class _MyProfileScreenState extends State<MyProfileScreen> {
  late final _name = TextEditingController(text: widget.app.myGlobal.name);
  late final _nick = TextEditingController(text: widget.room?.myNick ?? '');
  bool _busy = false;

  AppSession get app => widget.app;

  @override
  void initState() {
    super.initState();
    // The installed version for the updates tile (null until read, and in
    // debug builds without the platform channel).
    UpdateService.instance.prepare();
  }

  @override
  void dispose() {
    _name.dispose();
    _nick.dispose();
    super.dispose();
  }

  Widget _roomNick(BuildContext context, RoomSession room) {
    final where = room.kind == RoomKind.dm ? 'tej rozmowie' : 'tej grupie';
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Zdjęcie w $where (opcjonalnie)',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Avatar.member(
                  room,
                  room.myOutbox,
                  radius: 28,
                  key: const ValueKey('room-avatar-preview'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Wrap(
                    spacing: 4,
                    children: [
                      TextButton.icon(
                        key: const ValueKey('room-avatar-pick'),
                        onPressed: _busy ? null : () => _pickRoomAvatar(room),
                        icon: const Icon(Icons.photo),
                        label: const Text('Wybierz'),
                      ),
                      if (room.myRoomAvatar != null)
                        TextButton(
                          key: const ValueKey('room-avatar-clear'),
                          onPressed: _busy
                              ? null
                              : () => _run(() => room.setRoomAvatar(null)),
                          child: const Text('Użyj zdjęcia globalnego'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            Text(
              room.myRoomAvatar == null
                  ? 'Teraz: zdjęcie globalne'
                  : 'Teraz: osobne zdjęcie w $where',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Text(
              'Pseudonim w $where (opcjonalnie)',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            TextField(
              key: const ValueKey('room-nick'),
              controller: _nick,
              maxLength: RoomSession.maxNickLength,
              decoration: InputDecoration(
                hintText: app.myGlobal.name,
                helperText: room.myNick == null
                    ? 'Teraz: pseudonim globalny'
                    : 'Teraz: „${room.myNick}”',
                suffixIcon: IconButton(
                  key: const ValueKey('room-nick-save'),
                  tooltip: 'Zapisz pseudonim',
                  icon: const Icon(Icons.check),
                  onPressed: () => _run(() => room.setNick(_nick.text)),
                ),
              ),
            ),
            if (room.myNick != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('room-nick-clear'),
                  onPressed: () => _run(() async {
                    _nick.clear();
                    await room.setNick(null);
                  }),
                  child: const Text('Użyj pseudonimu globalnego'),
                ),
              ),
          ],
        ),
      ),
    );
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

  /// A picture for this DM/group only (the global one stays everywhere
  /// else).
  Future<void> _pickRoomAvatar(RoomSession room) async {
    final picked = await AutoLock.suppress(
      () => ImagePicker().pickImage(source: ImageSource.gallery),
    );
    if (picked == null) return;
    await _run(() => room.setRoomAvatar(File(picked.path)));
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
    final room = widget.room;
    return ListenableBuilder(
      listenable: Listenable.merge([app, ?room]),
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
                if (room != null && room.isPublic) _roomNick(context, room),
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
                    labelText: 'Pseudonim globalny',
                    helperText:
                        'We wszystkich DM i grupach, gdzie nie ustawisz '
                        'innego',
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
                // iOS has no self-update: a new build is installed the way
                // the app was (docs/IOS.md); the tile only says so.
                if (Platform.isIOS)
                  const ListTile(
                    key: ValueKey('updates-ios'),
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.system_update_alt),
                    title: Text('Aktualizacje'),
                    subtitle: Text(
                      'Na iOS aktualizujesz, instalując nowy plik IPA tak '
                      'samo jak pierwszy raz (Sideloadly lub AltStore). Dane '
                      'w aplikacji zostają.',
                    ),
                  ),
                if (!Platform.isIOS)
                  ListTile(
                    key: const ValueKey('updates'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.system_update_alt),
                    title: const Text('Aktualizacje'),
                    subtitle: ListenableBuilder(
                      listenable: UpdateService.instance,
                      builder: (context, _) {
                        final v = UpdateService.instance.current;
                        return Text(
                          v == null
                              ? 'Wersja aplikacji, nowe wydania'
                              : 'Wersja $v · nowe wydania',
                          key: const ValueKey('app-version'),
                        );
                      },
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const UpdateScreen(),
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
