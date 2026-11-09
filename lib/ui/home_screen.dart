import 'package:flutter/material.dart';

import '../app.dart';
import '../app_state/app_session.dart';
import '../app_state/global_profile.dart';
import '../room/message.dart';
import '../room/room_session.dart';
import '../vault/pin_vault.dart';
import '../vault/room_secrets.dart';
import 'chat_screen.dart';
import 'my_profile_screen.dart';
import 'new_room_screen.dart';
import 'widgets/avatar.dart';
import 'widgets/network_dot.dart';

/// After the app PIN: people with their status, then DMs and groups.
/// Private rooms never appear here; they open from private mode with their
/// password.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.app});

  final AppSession app;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  RoomKind _tab = RoomKind.dm;

  AppSession get app => widget.app;

  Future<void> _openChat(RoomSession session) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ChatScreen(session: session, app: app),
    ),
  );

  Future<void> _push(Widget screen) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => screen));

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  // --------------------------------------------------------- private mode

  Future<void> _privateMode() async {
    final pass = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tryb prywatny'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Wpisz hasło pokoju prywatnego. Każde hasło otwiera tylko '
              'swój pokój; takich pokoi nie ma na żadnej liście.',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('private-password'),
              controller: pass,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Hasło'),
              onSubmitted: (v) => Navigator.pop(context, v),
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('private-new'),
            onPressed: () => Navigator.pop(context, '\u0000new'),
            child: const Text('Nowy pokój prywatny'),
          ),
          FilledButton(
            key: const ValueKey('private-open'),
            onPressed: () => Navigator.pop(context, pass.text),
            child: const Text('Otwórz'),
          ),
        ],
      ),
    );
    pass.dispose();
    if (password == null || !mounted) return;
    if (password == '\u0000new') {
      await _push(NewRoomScreen(app: app, initialKind: RoomKind.private));
      return;
    }
    if (password.isEmpty) return;
    try {
      final room = await PinVault.instance.unlock(password);
      if (!mounted) return;
      if (room == null) {
        _toast('Nieprawidłowe hasło');
        return;
      }
      await _push(ChatScreen.private(session: RoomSession(room)));
    } on VaultLockedOut catch (e) {
      _toast('Za dużo prób. Spróbuj za ${e.remaining.inSeconds + 1} s');
    }
  }

  // ---------------------------------------------------------------- users

  Future<void> _userSheet(String key) async {
    final dm = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => ListenableBuilder(
        listenable: app.directory,
        builder: (context, _) {
          final p = app.directory[key];
          if (p == null) return const SizedBox(height: 120);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Avatar.global(app, p, radius: 44),
                  const SizedBox(height: 12),
                  Text(p.name, style: Theme.of(context).textTheme.titleLarge),
                  Text(p.presence.label),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    key: const ValueKey('user-dm'),
                    onPressed: () => Navigator.pop(context, true),
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: Text(
                      app.dmWith(key) == null
                          ? 'Zaproś do rozmowy'
                          : 'Otwórz rozmowę',
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (dm != true || !mounted) return;
    try {
      final room = await app.startDm(key);
      if (mounted) await _openChat(room.session);
    } on Object catch (e) {
      _toast('$e'.replaceFirst('Bad state: ', ''));
    }
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([app, app.directory]),
      builder: (context, _) {
        final me = app.myGlobal;
        final others = app.directory.others;
        final rooms = app.roomsOf(_tab);
        return Scaffold(
          appBar: AppBar(
            leading: Padding(
              padding: const EdgeInsets.all(8),
              child: InkWell(
                key: const ValueKey('my-profile'),
                customBorder: const CircleBorder(),
                onTap: () => _push(MyProfileScreen(app: app)),
                child: Avatar.global(app, me, radius: 18),
              ),
            ),
            title: const Text('Rozmowy'),
            actions: [
              IconButton(
                key: const ValueKey('private-mode'),
                tooltip: 'Tryb prywatny',
                icon: const Icon(Icons.vpn_key_outlined),
                onPressed: _privateMode,
              ),
              IconButton(
                tooltip: 'Zablokuj',
                icon: const Icon(Icons.lock),
                onPressed: AutoLock.lockNow,
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            key: const ValueKey('new-room'),
            onPressed: () => _push(NewRoomScreen(app: app, initialKind: _tab)),
            icon: const Icon(Icons.add_comment_outlined),
            label: const Text('Nowa'),
          ),
          body: Column(
            children: [
              for (final inv in app.pendingInvites)
                _InviteBanner(app: app, invite: inv, onOpen: _openChat),
              if (others.isNotEmpty)
                SizedBox(
                  height: 100,
                  child: ListView.separated(
                    key: const ValueKey('user-bar'),
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    itemCount: others.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, i) {
                      final e = others[i];
                      return _UserChip(
                        app: app,
                        profile: e.value,
                        onTap: () => _userSheet(e.key),
                      );
                    },
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: SegmentedButton<RoomKind>(
                  segments: [
                    ButtonSegment(
                      value: RoomKind.dm,
                      icon: const Icon(Icons.person_outline),
                      label: Text('DM (${app.roomsOf(RoomKind.dm).length})'),
                    ),
                    ButtonSegment(
                      value: RoomKind.group,
                      icon: const Icon(Icons.groups_outlined),
                      label: Text(
                        'Grupy (${app.roomsOf(RoomKind.group).length})',
                      ),
                    ),
                  ],
                  selected: {_tab},
                  onSelectionChanged: (s) => setState(() => _tab = s.first),
                ),
              ),
              Expanded(
                child: rooms.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            _tab == RoomKind.dm
                                ? 'Brak rozmów. Stuknij osobę u góry albo '
                                      '„Nowa”, by zaprosić kogoś kodem QR.'
                                : 'Brak grup. Utwórz grupę albo dołącz z '
                                      'zaproszenia przyciskiem „Nowa”.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 88),
                        itemCount: rooms.length,
                        itemBuilder: (context, i) => _RoomTile(
                          app: app,
                          room: rooms[i],
                          onTap: () => _openChat(rooms[i].session),
                        ),
                      ),
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: NetworkDot(),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _UserChip extends StatelessWidget {
  const _UserChip({
    required this.app,
    required this.profile,
    required this.onTap,
  });

  final AppSession app;
  final GlobalProfile profile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: SizedBox(
        width: 64,
        child: Column(
          children: [
            Avatar.global(app, profile, radius: 26),
            const SizedBox(height: 6),
            Text(
              profile.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _RoomTile extends StatelessWidget {
  const _RoomTile({required this.app, required this.room, required this.onTap});

  final AppSession app;
  final PublicRoom room;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = room.session;
    final peer = app.peerOf(s);
    final last = s.messages.isEmpty ? null : s.messages.last;
    final title = peer?.name ?? s.roomName;
    return ListTile(
      key: ValueKey('room-${s.room.secrets.rosterKey}'),
      leading: peer != null
          ? Avatar.global(app, peer, radius: 24)
          : Avatar.room(s, radius: 24),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: last == null
          ? const Text('Brak wiadomości')
          : Text(
              _preview(s, last),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: last == null ? null : Text(_time(last.ts)),
      onTap: onTap,
    );
  }

  String _preview(RoomSession s, ChatMessage m) {
    final what = switch (m.type) {
      MsgType.text => m.text ?? '',
      MsgType.image => '📷 Zdjęcie',
      MsgType.video => '🎥 Wideo',
      MsgType.voice => '🎤 Głosówka',
      MsgType.dmInvite => '',
    };
    final who = m.author == s.myOutbox
        ? 'Ty'
        : (room.kind == RoomKind.group ? s.nameOf(m.author) : null);
    return who == null ? what : '$who: $what';
  }

  static String _time(int ts) {
    final t = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}';
    }
    return '${t.day}.${t.month.toString().padLeft(2, '0')}';
  }
}

class _InviteBanner extends StatelessWidget {
  const _InviteBanner({
    required this.app,
    required this.invite,
    required this.onOpen,
  });

  final AppSession app;
  final PendingInvite invite;
  final Future<void> Function(RoomSession) onOpen;

  @override
  Widget build(BuildContext context) {
    final from = app.directory[invite.fromKey];
    return Card(
      key: ValueKey('invite-${invite.id}'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            if (from != null) Avatar.global(app, from, radius: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '${from?.name ?? 'Ktoś'} zaprasza cię do rozmowy',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
            TextButton(
              key: const ValueKey('invite-decline'),
              onPressed: () => app.declineInvite(invite),
              child: const Text('Odrzuć'),
            ),
            FilledButton(
              key: const ValueKey('invite-accept'),
              onPressed: () async {
                try {
                  final room = await app.acceptInvite(invite);
                  await onOpen(room.session);
                } on Object catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Nie udało się dołączyć: $e')),
                    );
                  }
                }
              },
              child: const Text('Akceptuj'),
            ),
          ],
        ),
      ),
    );
  }
}
