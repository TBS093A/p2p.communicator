// Screens of the experimental v2 groups (MLS): the list, a new group, the
// invite as a QR code with the admin's fingerprint, and joining with that
// fingerprint checked. The conversation itself is the regular ChatScreen.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../room/message.dart';
import '../v2/v2_groups.dart';
import 'chat_screen.dart';
import 'scan_screen.dart';
import 'widgets/avatar.dart';

void _toast(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

String _plain(Object e) =>
    '$e'.replaceFirst('Bad state: ', '').replaceFirst('core: ', '');

Future<void> openV2Chat(BuildContext context, V2Groups groups, V2Group g) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen.v2(session: groups.roomOf(g), v2: groups),
      ),
    );

class V2HomeScreen extends StatelessWidget {
  const V2HomeScreen({super.key, required this.groups, required this.myName});

  final V2Groups groups;

  /// Suggested name in a new group (it can be changed; v2 groups do not
  /// show the global profile).
  final String myName;

  Future<void> _create(BuildContext context) async {
    final names = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _NewGroupDialog(myName: myName),
    );
    if (names == null || !context.mounted) return;
    try {
      final g = await groups.create(names.$1, names.$2);
      if (context.mounted) await openV2Chat(context, groups, g);
    } on Object catch (e) {
      if (context.mounted) _toast(context, 'Nie udało się: ${_plain(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: groups,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Grupy v2 (eksperymentalne)')),
        floatingActionButton: FloatingActionButton.extended(
          key: const ValueKey('v2-new'),
          onPressed: () => _create(context),
          icon: const Icon(Icons.group_add_outlined),
          label: const Text('Nowa grupa'),
        ),
        body: ListView(
          padding: const EdgeInsets.only(bottom: 88),
          children: [
            ListTile(
              key: const ValueKey('v2-join'),
              leading: const Icon(Icons.qr_code_scanner),
              title: const Text('Dołącz z zaproszenia'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => V2JoinScreen(groups: groups, myName: myName),
                ),
              ),
            ),
            const Divider(),
            if (groups.groups.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Brak grup v2. Utwórz grupę albo dołącz z zaproszenia. '
                  'Grupy v2 są szyfrowane protokołem MLS i nie łączą się '
                  'z twoim profilem globalnym.',
                  textAlign: TextAlign.center,
                ),
              ),
            for (final g in groups.groups) _GroupTile(groups: groups, group: g),
          ],
        ),
      ),
    );
  }
}

class _GroupTile extends StatelessWidget {
  const _GroupTile({required this.groups, required this.group});

  final V2Groups groups;
  final V2Group group;

  @override
  Widget build(BuildContext context) {
    final room = groups.roomOf(group);
    final last = room.messages.isEmpty ? null : room.messages.last;
    final String subtitle;
    if (group.joining) {
      subtitle = 'Czeka, aż admin cię wpuści';
    } else if (last == null) {
      subtitle = 'Brak wiadomości';
    } else {
      final what = switch (last.type) {
        MsgType.text => last.text ?? '',
        MsgType.image => '📷 Zdjęcie',
        MsgType.video => '🎥 Wideo',
        MsgType.voice => '🎤 Głosówka',
        _ => '',
      };
      final who = last.author == room.myOutbox
          ? 'Ty'
          : room.nameOf(last.author);
      subtitle = '$who: $what';
    }
    return ListTile(
      key: ValueKey('v2-group-${room.roomName}'),
      leading: Avatar.room(room, radius: 24),
      title: Text(room.roomName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => openV2Chat(context, groups, group),
    );
  }
}

/// Group name and our name in it.
class _NewGroupDialog extends StatefulWidget {
  const _NewGroupDialog({required this.myName});

  final String myName;

  @override
  State<_NewGroupDialog> createState() => _NewGroupDialogState();
}

class _NewGroupDialogState extends State<_NewGroupDialog> {
  final _name = TextEditingController();
  late final _me = TextEditingController(text: widget.myName);

  @override
  void dispose() {
    _name.dispose();
    _me.dispose();
    super.dispose();
  }

  void _done() {
    if (_name.text.trim().isEmpty || _me.text.trim().isEmpty) return;
    Navigator.pop(context, (_name.text, _me.text));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Nowa grupa v2'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const ValueKey('v2-name'),
          controller: _name,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(labelText: 'Nazwa grupy'),
        ),
        TextField(
          key: const ValueKey('v2-my-name'),
          controller: _me,
          maxLength: 40,
          decoration: const InputDecoration(
            labelText: 'Twoja nazwa w tej grupie',
            helperText: 'Grupa nie widzi twojego profilu globalnego',
          ),
          onSubmitted: (_) => _done(),
        ),
      ],
    ),
    actions: [
      FilledButton(
        key: const ValueKey('v2-create'),
        onPressed: _done,
        child: const Text('Utwórz'),
      ),
    ],
  );
}

/// The admin's fingerprint in a monospace block, to compare by eye.
class V2FingerprintBox extends StatelessWidget {
  const V2FingerprintBox({super.key, required this.cik});

  final String cik;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        v2Fingerprint(cik),
        key: const ValueKey('v2-fingerprint'),
        textAlign: TextAlign.center,
        style: theme.textTheme.titleMedium?.copyWith(
          fontFamily: 'monospace',
          letterSpacing: 1,
          height: 1.5,
        ),
      ),
    );
  }
}

class V2InviteScreen extends StatelessWidget {
  const V2InviteScreen({super.key, required this.code, required this.adminCik});

  final String code;
  final String adminCik;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Zaproszenie v2')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.all(12),
            child: QrImageView(data: code, size: 260),
          ),
        ),
        const SizedBox(height: 8),
        // The same code as text, for sending it some other way.
        SelectableText(
          code,
          key: const ValueKey('v2-invite-text'),
          maxLines: 2,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
        ),
        const SizedBox(height: 16),
        const Text(
          'Twój odcisk (osoba dołączająca porównuje go ze swoim ekranem):',
        ),
        const SizedBox(height: 8),
        V2FingerprintBox(cik: adminCik),
        const SizedBox(height: 16),
        Card(
          color: Theme.of(context).colorScheme.errorContainer,
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Zaproszenie jest jednorazowe. Kto użyje go pierwszy, zostanie '
              'wpuszczony przy następnej synchronizacji. Najlepiej pokaż kod '
              'osobiście.',
            ),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const ValueKey('v2-invite-copy'),
          icon: const Icon(Icons.copy),
          label: const Text('Kopiuj jako tekst'),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: code));
            if (context.mounted) _toast(context, 'Skopiowano');
          },
        ),
      ],
    ),
  );
}

class V2JoinScreen extends StatefulWidget {
  const V2JoinScreen({super.key, required this.groups, required this.myName});

  final V2Groups groups;
  final String myName;

  @override
  State<V2JoinScreen> createState() => _V2JoinScreenState();
}

class _V2JoinScreenState extends State<V2JoinScreen> {
  final _code = TextEditingController();
  final _name = TextEditingController(text: 'Grupa v2');
  late final _me = TextEditingController(text: widget.myName);
  bool _checked = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _code.addListener(() => setState(() => _checked = false));
  }

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _me.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ScanScreen(
          title: 'Zeskanuj zaproszenie v2',
          accept: (s) => V2Invite.tryParse(s) != null,
        ),
      ),
    );
    if (raw != null) _code.text = raw;
  }

  Future<void> _join(V2Invite invite) async {
    setState(() => _busy = true);
    try {
      final groups = widget.groups;
      final g = await groups.join(invite, _name.text, _me.text);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => ChatScreen.v2(session: groups.roomOf(g), v2: groups),
        ),
      );
    } on Object catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        _toast(context, 'Nie udało się: ${_plain(e)}');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final invite = V2Invite.tryParse(_code.text);
    return Scaffold(
      appBar: AppBar(title: const Text('Dołącz do grupy v2')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_busy) const LinearProgressIndicator(),
            TextField(
              key: const ValueKey('v2-invite-code'),
              controller: _code,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Zaproszenie (p2pc2.…)',
                errorText: _code.text.isNotEmpty && invite == null
                    ? 'To nie jest zaproszenie v2'
                    : null,
                suffixIcon: IconButton(
                  tooltip: 'Skanuj kod QR',
                  icon: const Icon(Icons.qr_code_scanner),
                  onPressed: _scan,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('v2-join-name'),
              controller: _name,
              maxLength: 40,
              decoration: const InputDecoration(
                labelText: 'Nazwa grupy',
                helperText: 'Do czasu, aż admin pokaże jej nazwę',
              ),
            ),
            TextField(
              key: const ValueKey('v2-join-me'),
              controller: _me,
              maxLength: 40,
              decoration: const InputDecoration(
                labelText: 'Twoja nazwa w tej grupie',
                helperText: 'Grupa nie widzi twojego profilu globalnego',
              ),
            ),
            if (invite != null) ...[
              const SizedBox(height: 12),
              const Text(
                'Odcisk admina z zaproszenia. Porównaj go z tym, co admin '
                'widzi u siebie na ekranie zaproszenia:',
              ),
              const SizedBox(height: 8),
              V2FingerprintBox(cik: invite.adminCik),
              CheckboxListTile(
                key: const ValueKey('v2-fingerprint-ok'),
                contentPadding: EdgeInsets.zero,
                value: _checked,
                onChanged: (v) => setState(() => _checked = v ?? false),
                title: const Text('Odcisk się zgadza'),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('v2-join-go'),
              onPressed:
                  invite != null &&
                      _checked &&
                      !_busy &&
                      _me.text.trim().isNotEmpty
                  ? () => _join(invite)
                  : null,
              child: const Text('Poproś o dołączenie'),
            ),
          ],
        ),
      ),
    );
  }
}
