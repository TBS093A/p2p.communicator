import 'package:flutter/material.dart';

import '../app.dart';
import '../app_state/app_session.dart';
import '../v2/private_v2.dart';
import '../vault/pin_vault.dart';
import 'chat_screen.dart';
import 'my_profile_screen.dart';
import '../update/update_service.dart';
import 'update_screen.dart';
import 'v1_move_screen.dart';
import 'v2_screens.dart';
import 'widgets/avatar.dart';
import 'widgets/network_dot.dart';

/// After the app PIN: people from our groups, then 1:1 conversations and
/// groups (all MLS, PROTOCOL part B). Private conversations never appear
/// here; they open from private mode with their password. Old v1 rooms are
/// not listed: each moves to v2 by itself (§B11.2).
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.app});

  final AppSession app;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _dm = true;

  AppSession get app => widget.app;

  @override
  void initState() {
    super.initState();
    // Release builds only; GitHub at most about once a day, if allowed.
    UpdateService.instance.autoCheck();
  }

  Future<void> _push(Widget screen) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => screen));

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  // --------------------------------------------------------- private mode

  Future<void> _privateMode() async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _PrivateModeDialog(),
    );
    if (password == null || !mounted) return;
    if (password == '\u0000new' || password == '\u0000join') {
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
      // An old private room: it moves to v2 now, in its own slot (§B11.2).
      if (slot.v1 != null) await _push(PrivateMoveScreen(slot: slot));
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

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final groups = app.v2;
    return ListenableBuilder(
      listenable: Listenable.merge([app, groups]),
      builder: (context, _) {
        showDeletedByAdmin(context, groups);
        final me = app.myGlobal;
        final people = v2People(groups);
        final dms = V2ConversationList.of(groups, dm: true).length;
        final rooms = V2ConversationList.of(groups, dm: false).length;
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
            onPressed: () => newV2Conversation(context, groups, me.name),
            icon: const Icon(Icons.add_comment_outlined),
            label: const Text('Nowa'),
          ),
          body: Column(
            children: [
              UpdateBanner(onOpen: () => _push(const UpdateScreen())),
              // PROTOCOL §B11.2: old rooms move by themselves.
              if (app.moving)
                ListTile(
                  key: const ValueKey('v1-moving'),
                  dense: true,
                  leading: const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  title: Text(
                    'Przenoszę rozmowy ze starej wersji '
                    '(${app.rooms.length})…',
                  ),
                  subtitle: const Text(
                    'Pojawią się poniżej z całą historią, gdy pozostali '
                    'też zaktualizują aplikację.',
                  ),
                ),
              if (people.isNotEmpty)
                SizedBox(
                  height: 100,
                  child: ListView.separated(
                    key: const ValueKey('user-bar'),
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    itemCount: people.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, i) =>
                        V2PersonChip(groups: groups, person: people[i]),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(
                      value: true,
                      icon: const Icon(Icons.person_outline),
                      label: Text('DM ($dms)'),
                    ),
                    ButtonSegment(
                      value: false,
                      icon: const Icon(Icons.groups_outlined),
                      label: Text('Grupy ($rooms)'),
                    ),
                  ],
                  selected: {_dm},
                  onSelectionChanged: (s) => setState(() => _dm = s.first),
                ),
              ),
              Expanded(
                child: V2ConversationList(groups: groups, dm: _dm),
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
