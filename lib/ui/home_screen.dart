import 'package:flutter/material.dart';

import '../app.dart';
import '../app_state/app_session.dart';
import '../app_state/global_profile.dart';
import '../room/message.dart';
import '../room/room_session.dart';
import '../v2/private_v2.dart';
import '../vault/pin_vault.dart';
import '../vault/room_secrets.dart';
import 'chat_screen.dart';
import 'my_profile_screen.dart';
import '../update/update_service.dart';
import 'new_room_screen.dart';
import 'update_screen.dart';
import 'v2_screens.dart';
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

  @override
  void initState() {
    super.initState();
    // Release builds only; GitHub at most about once a day, if allowed.
    UpdateService.instance.autoCheck();
  }

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

  Future<void> _openV2() =>
      _push(V2HomeScreen(groups: app.v2, myName: app.myGlobal.name));

  // --------------------------------------------------------- private mode

  Future<void> _privateMode() async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _PrivateModeDialog(),
    );
    if (password == null || !mounted) return;
    if (password == '\u0000new' || password == '\u0000join') {
      if (RoomSession.legacyWrites && password == '\u0000new') {
        // Tests of the old paths: a v1 private room.
        await _push(NewRoomScreen(app: app, initialKind: RoomKind.private));
        return;
      }
      await _newPrivate(join: password == '\u0000join');
      return;
    }
    if (password.isEmpty) return;
    try {
      final slot = await PinVault.instance.openPrivate(password);
      if (!mounted) return;
      if (slot == null) {
        _toast('Nieprawidłowe hasło');
        return;
      }
      if (slot.hasV2) {
        await _openPrivateV2(slot);
        return;
      }
      final v1 = slot.v1;
      if (v1 == null) return;
      await _push(
        ChatScreen.private(
          session: RoomSession(UnlockedRoom(slot.slotId, slot.key, v1)),
          privateSlot: slot,
        ),
      );
    } on VaultLockedOut catch (e) {
      _toast('Za dużo prób. Spróbuj za ${e.remaining.inSeconds + 1} s');
    }
  }

  /// PROTOCOL §B11.1: a private v2 conversation, running only while open.
  Future<void> _openPrivateV2(PrivateSlot slot) async {
    final pv = await PrivateV2.inSlot(slot);
    final g = pv.group;
    if (g == null || !mounted) {
      await pv.close();
      if (mounted) _toast('Ta rozmowa nie jest jeszcze gotowa');
      return;
    }
    await _push(
      ChatScreen.v2(
        session: pv.groups.roomOf(g),
        v2: pv.groups,
        privateSlot: slot,
        onClose: pv.close,
      ),
    );
  }

  /// A new private v2 conversation, created or joined, in a new password
  /// slot (§B11.1).
  Future<void> _newPrivate({required bool join}) async {
    final r = await showDialog<_NewPrivate>(
      context: context,
      builder: (_) => _NewPrivateDialog(join: join, myName: app.myGlobal.name),
    );
    if (r == null || !mounted) return;
    final PrivateSlot slot;
    try {
      if (!await PinVault.instance.isPinFree(r.password)) {
        _toast('To hasło jest już zajęte');
        return;
      }
      slot = await PinVault.instance.storePrivateV2(r.password);
    } on Object catch (e) {
      _toast('Nie udało się: $e');
      return;
    }
    final pv = await PrivateV2.inSlot(slot);
    if (!mounted) {
      await pv.close();
      return;
    }
    if (join) {
      await _push(
        V2JoinScreen(groups: pv.groups, myName: r.me, onClose: pv.close),
      );
      return;
    }
    try {
      final g = await pv.groups.create(r.name, r.me);
      if (!mounted) {
        await pv.close();
        return;
      }
      await _push(
        ChatScreen.v2(
          session: pv.groups.roomOf(g),
          v2: pv.groups,
          privateSlot: slot,
          onClose: pv.close,
        ),
      );
    } on Object catch (e) {
      await pv.close();
      if (mounted) _toast('Nie udało się: $e');
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
                  // PROTOCOL §B10, §B11: new DMs start in a shared v2 group.
                  if (!RoomSession.legacyWrites && app.dmWith(key) == null)
                    const Text(
                      'Nowe rozmowy prywatne zaczniesz z grupy v2 '
                      '(Osoby → Napisz prywatnie).',
                      textAlign: TextAlign.center,
                    )
                  else
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
                key: const ValueKey('v2-home'),
                tooltip: 'Grupy v2',
                icon: const Icon(Icons.forum_outlined),
                onPressed: _openV2,
              ),
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
          // PROTOCOL §B11: new conversations are v2 groups; v1 rooms only
          // read (tests of the old paths turn writes back on).
          floatingActionButton: FloatingActionButton.extended(
            key: const ValueKey('new-room'),
            // Decided at the tap: tests switch legacyWrites while this
            // screen stays built underneath.
            onPressed: () => RoomSession.legacyWrites
                ? _push(NewRoomScreen(app: app, initialKind: _tab))
                : _openV2(),
            icon: const Icon(Icons.add_comment_outlined),
            label: const Text('Nowa'),
          ),
          body: Column(
            children: [
              UpdateBanner(onOpen: () => _push(const UpdateScreen())),
              if (!RoomSession.legacyWrites)
                ListTile(
                  key: const ValueKey('home-v2-groups'),
                  leading: const Icon(Icons.forum_outlined),
                  title: Text('Grupy v2 (${app.v2.groups.length})'),
                  subtitle: const Text(
                    'Szyfrowanie MLS. Rozmowy poniżej to stary protokół, '
                    'tylko do odczytu.',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _openV2,
                ),
              if (RoomSession.legacyWrites)
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

/// Password prompt for private mode. Returns the password, or `\0new` for
/// "create a private room". It owns its text controller, which therefore
/// lives until the dialog's closing animation has finished (disposing it
/// right after `showDialog` returned crashed the still-animating field).
class _PrivateModeDialog extends StatefulWidget {
  const _PrivateModeDialog();

  @override
  State<_PrivateModeDialog> createState() => _PrivateModeDialogState();
}

class _PrivateModeDialogState extends State<_PrivateModeDialog> {
  final _pass = TextEditingController();

  @override
  void dispose() {
    _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
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
            controller: _pass,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Hasło'),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('private-join'),
          onPressed: () => Navigator.pop(context, '\u0000join'),
          child: const Text('Dołącz'),
        ),
        TextButton(
          key: const ValueKey('private-new'),
          onPressed: () => Navigator.pop(context, '\u0000new'),
          child: const Text('Nowa'),
        ),
        FilledButton(
          key: const ValueKey('private-open'),
          onPressed: () => Navigator.pop(context, _pass.text),
          child: const Text('Otwórz'),
        ),
      ],
    );
  }
}

class _NewPrivate {
  const _NewPrivate(this.password, this.name, this.me);
  final String password;
  final String name;
  final String me;
}

/// A new private conversation (or one to join): its password, and for a
/// new one its name and ours. Owns its controllers (see above).
class _NewPrivateDialog extends StatefulWidget {
  const _NewPrivateDialog({required this.join, required this.myName});

  final bool join;
  final String myName;

  @override
  State<_NewPrivateDialog> createState() => _NewPrivateDialogState();
}

class _NewPrivateDialogState extends State<_NewPrivateDialog> {
  final _pass = TextEditingController();
  final _again = TextEditingController();
  final _name = TextEditingController();
  late final _me = TextEditingController(text: widget.myName);
  String? _error;

  @override
  void dispose() {
    for (final c in [_pass, _again, _name, _me]) {
      c.dispose();
    }
    super.dispose();
  }

  void _done() {
    final p = _pass.text;
    if (p.length < 6) {
      setState(() => _error = 'Hasło: co najmniej 6 znaków');
    } else if (p != _again.text) {
      setState(() => _error = 'Hasła się różnią');
    } else if (!widget.join && _name.text.trim().isEmpty) {
      setState(() => _error = 'Podaj nazwę rozmowy');
    } else {
      Navigator.pop(context, _NewPrivate(p, _name.text.trim(), _me.text));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.join ? 'Dołącz do rozmowy prywatnej' : 'Nowa rozmowa prywatna',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Otworzysz ją tylko tym hasłem; nie ma jej na żadnej liście. '
              'Działa tylko wtedy, gdy jest otwarta.',
            ),
            TextField(
              key: const ValueKey('private-new-password'),
              controller: _pass,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Hasło'),
            ),
            TextField(
              key: const ValueKey('private-new-again'),
              controller: _again,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Powtórz hasło'),
            ),
            if (!widget.join)
              TextField(
                key: const ValueKey('private-new-name'),
                controller: _name,
                decoration: const InputDecoration(labelText: 'Nazwa rozmowy'),
              ),
            if (!widget.join)
              TextField(
                key: const ValueKey('private-new-me'),
                controller: _me,
                decoration: const InputDecoration(
                  labelText: 'Twoje imię tutaj',
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Anuluj'),
        ),
        FilledButton(
          key: const ValueKey('private-new-go'),
          onPressed: _done,
          child: Text(widget.join ? 'Dalej' : 'Utwórz'),
        ),
      ],
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
      // Hidden types never reach the message list (reactions are shown
      // under their message), so never the preview either.
      MsgType.dmInvite ||
      MsgType.reaction ||
      MsgType.profile ||
      MsgType.meta => '',
      MsgType.presence => '',
      MsgType.typing => '',
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
