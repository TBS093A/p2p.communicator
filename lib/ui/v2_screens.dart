// Screens of the experimental v2 groups (MLS): list, join with the admin's
// fingerprint checked, invite as a QR code, and a plain text chat.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../v2/v2_groups.dart';
import 'scan_screen.dart';

String _time(int ts) {
  final t = DateTime.fromMillisecondsSinceEpoch(ts);
  return '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
}

void _toast(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

String _plain(Object e) =>
    '$e'.replaceFirst('Bad state: ', '').replaceFirst('core: ', '');

class V2HomeScreen extends StatelessWidget {
  const V2HomeScreen({super.key, required this.groups});

  final V2Groups groups;

  Future<void> _create(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NameDialog(),
    );
    if (name == null || name.trim().isEmpty || !context.mounted) return;
    try {
      final g = await groups.create(name);
      if (context.mounted) await _open(context, g);
    } on Object catch (e) {
      if (context.mounted) _toast(context, 'Nie udało się: ${_plain(e)}');
    }
  }

  Future<void> _open(BuildContext context, V2Group g) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => V2ChatScreen(groups: groups, group: g),
        ),
      );

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
                  builder: (_) => V2JoinScreen(groups: groups),
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
            for (final g in groups.groups)
              ListTile(
                key: ValueKey('v2-group-${g.name}'),
                leading: const CircleAvatar(child: Icon(Icons.lock_outline)),
                title: Text(g.name),
                subtitle: Text(
                  g.joining
                      ? 'Czeka, aż admin cię wpuści'
                      : g.messages.isEmpty
                      ? 'Brak wiadomości'
                      : '${groups.senderLabel(g, g.messages.last)}: '
                            '${g.messages.last.text}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => _open(context, g),
              ),
          ],
        ),
      ),
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog();

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Nowa grupa v2'),
    content: TextField(
      key: const ValueKey('v2-name'),
      controller: _name,
      autofocus: true,
      maxLength: 40,
      decoration: const InputDecoration(
        labelText: 'Nazwa grupy',
        helperText: 'Widzisz ją tylko ty',
      ),
      onSubmitted: (v) => Navigator.pop(context, v),
    ),
    actions: [
      FilledButton(
        key: const ValueKey('v2-create'),
        onPressed: () => Navigator.pop(context, _name.text),
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
  const V2JoinScreen({super.key, required this.groups});

  final V2Groups groups;

  @override
  State<V2JoinScreen> createState() => _V2JoinScreenState();
}

class _V2JoinScreenState extends State<V2JoinScreen> {
  final _code = TextEditingController();
  final _name = TextEditingController(text: 'Grupa v2');
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
      final g = await widget.groups.join(invite, _name.text);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => V2ChatScreen(groups: widget.groups, group: g),
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
                helperText: 'Widzisz ją tylko ty',
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
              onPressed: invite != null && _checked && !_busy
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

class V2ChatScreen extends StatefulWidget {
  const V2ChatScreen({super.key, required this.groups, required this.group});

  final V2Groups groups;
  final V2Group group;

  @override
  State<V2ChatScreen> createState() => _V2ChatScreenState();
}

class _V2ChatScreenState extends State<V2ChatScreen> {
  final _text = TextEditingController();
  Timer? _timer;
  bool _sending = false;

  V2Groups get groups => widget.groups;
  V2Group get g => widget.group;

  @override
  void initState() {
    super.initState();
    // Faster while the conversation is open.
    unawaited(groups.sync(g));
    _timer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => unawaited(groups.sync(g)),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await groups.send(g, text);
      _text.clear();
    } on Object catch (e) {
      if (mounted) _toast(context, 'Nie wysłano: ${_plain(e)}');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _invite() async {
    try {
      final code = await groups.createInvite(g);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => V2InviteScreen(code: code, adminCik: groups.myCik(g)),
        ),
      );
    } on Object catch (e) {
      if (mounted) _toast(context, 'Nie udało się: ${_plain(e)}');
    }
  }

  Future<void> _leave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Usunąć grupę z tego telefonu?'),
        content: const Text(
          'Tracisz jej klucze i historię na tym telefonie. Pozostali '
          'członkowie nadal widzą cię w grupie.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Usuń'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await groups.leave(g);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: groups,
      builder: (context, _) {
        final info = groups.info(g);
        final admin = info['is_admin'] == true;
        final members = (info['members'] as List?)?.length ?? 0;
        final theme = Theme.of(context);
        final warnings = [
          if (info['fork_suspected'] == true)
            'Uwaga: log grupy rozgałęził się. Możliwa próba ataku.',
          if (info['history_diverged'] == true)
            'Twoja historia różni się od historii grupy.',
          if ((info['lost_messages'] as int? ?? 0) > 0)
            'Część wiadomości nie dotarła (${info['lost_messages']}).',
          if (info['removed'] == true) 'Usunięto cię z tej grupy.',
        ];
        final msgs = g.messages.reversed.toList();
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(g.name),
                Text(
                  g.joining
                      ? 'oczekuje na wpuszczenie'
                      : '$members ${members == 1 ? 'członek' : 'członków'}'
                            '${admin ? ' · jesteś adminem' : ''}',
                  key: const ValueKey('v2-members'),
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
            actions: [
              if (admin)
                IconButton(
                  key: const ValueKey('v2-invite'),
                  tooltip: 'Zaproś',
                  icon: const Icon(Icons.person_add_alt),
                  onPressed: _invite,
                ),
              PopupMenuButton<String>(
                onSelected: (_) => _leave(),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'leave', child: Text('Usuń z telefonu')),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              if (g.joining)
                const MaterialBanner(
                  key: ValueKey('v2-waiting'),
                  content: Text(
                    'Prośba wysłana. Admin wpuści cię przy najbliższej '
                    'synchronizacji (musi mieć włączoną aplikację).',
                  ),
                  actions: [SizedBox.shrink()],
                ),
              for (final w in warnings)
                MaterialBanner(
                  backgroundColor: theme.colorScheme.errorContainer,
                  content: Text(w),
                  actions: const [SizedBox.shrink()],
                ),
              Expanded(
                child: ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.all(12),
                  itemCount: msgs.length,
                  itemBuilder: (context, i) => _Bubble(
                    message: msgs[i],
                    label: groups.senderLabel(g, msgs[i]),
                  ),
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('v2-composer'),
                          controller: _text,
                          enabled: !g.joining,
                          minLines: 1,
                          maxLines: 5,
                          maxLength: 2000,
                          decoration: const InputDecoration(
                            hintText: 'Wiadomość',
                            counterText: '',
                          ),
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('v2-send'),
                        tooltip: 'Wyślij',
                        onPressed: g.joining || _sending ? null : _send,
                        icon: _sending
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.send),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.label});

  final V2Message message;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mine = message.mine;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: mine
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!mine)
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              Text(message.text),
              Text(_time(message.ts), style: theme.textTheme.labelSmall),
            ],
          ),
        ),
      ),
    );
  }
}
