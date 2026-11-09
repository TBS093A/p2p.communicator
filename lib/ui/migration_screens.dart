import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:veilid/veilid.dart';

import '../app.dart';
import '../app_state/app_session.dart';
import '../core/crypto.dart';
import '../migration/migration_archive.dart';
import '../migration/migration_service.dart';
import '../vault/pin_vault.dart';
import 'scan_screen.dart';

// ------------------------------------------------------------- old phone

/// Old phone: scan the new phone's code, pick private rooms to take along,
/// send the sealed file, then wipe this phone.
class MigrationSendScreen extends StatefulWidget {
  const MigrationSendScreen({super.key, required this.app});

  final AppSession app;

  @override
  State<MigrationSendScreen> createState() => _MigrationSendScreenState();
}

class _MigrationSendScreenState extends State<MigrationSendScreen> {
  final _code = TextEditingController();
  final _private = <PrivateRoomToMove>[];
  bool _busy = false;
  String? _step;
  File? _file;

  PublicKey? get _to => MoveCode.tryParse(_code.text);

  @override
  void initState() {
    super.initState();
    _code.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ScanScreen(
          title: 'Kod z nowego telefonu',
          accept: (r) => MoveCode.tryParse(r) != null,
        ),
      ),
    );
    if (raw != null) _code.text = raw.trim();
  }

  Future<void> _addPrivate() async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _PasswordDialog(),
    );
    if (password == null || password.isEmpty || !mounted) return;
    try {
      final room = await PinVault.instance.unlock(password);
      if (!mounted) return;
      if (room == null) {
        _toast('Nieprawidłowe hasło');
      } else if (_private.any((r) => r.room.slotId == room.slotId)) {
        _toast('Ten pokój jest już na liście');
      } else {
        setState(() => _private.add(PrivateRoomToMove(password, room)));
      }
    } on VaultLockedOut catch (e) {
      _toast('Za dużo prób. Spróbuj za ${e.remaining.inSeconds + 1} s');
    }
  }

  Future<void> _export() async {
    final to = _to;
    if (to == null) return;
    setState(() {
      _busy = true;
      _step = 'Przygotowuję';
    });
    try {
      final now = DateTime.now();
      final name =
          'p2p-communicator-${now.year}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}.p2pc';
      final out = File(p.join((await getTemporaryDirectory()).path, name));
      await _file?.delete().catchError((Object _) => _file!);
      await MigrationService.export(
        app: widget.app,
        to: to,
        privateRooms: _private,
        out: out,
        onProgress: (s) {
          if (mounted) setState(() => _step = s);
        },
      );
      if (!mounted) return;
      setState(() => _file = out);
      await _share();
    } on Object catch (e) {
      if (mounted) _toast('Nie udało się: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _step = null;
        });
      }
    }
  }

  Future<void> _share() async {
    final f = _file;
    if (f == null) return;
    await AutoLock.suppress(
      () => SharePlus.instance.share(
        ShareParams(
          title: 'Plik przeniesienia',
          files: [XFile(f.path, mimeType: 'application/octet-stream')],
        ),
      ),
    );
  }

  Future<void> _wipe() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Wyczyścić ten telefon?'),
        content: const Text(
          'Zrób to dopiero, gdy nowy telefon pokazuje twoje rozmowy. '
          'Konto, rozmowy, media i przeniesione pokoje prywatne znikną z '
          'tego telefonu na zawsze.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            key: const ValueKey('move-wipe-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Wyczyść'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() {
      _busy = true;
      _step = 'Czyszczę telefon';
    });
    try {
      await widget.app.close();
      await _file?.delete().catchError((Object _) => _file!);
      await PinVault.instance.wipe();
      AutoLock.restart();
    } on Object catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        _toast('Nie udało się wyczyścić: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final file = _file;
    return Scaffold(
      appBar: AppBar(title: const Text('Przenieś na nowy telefon')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_busy) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text(_step ?? '', key: const ValueKey('move-step')),
                const SizedBox(height: 8),
              ],
              Text(
                '1. Kod z nowego telefonu',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                'Na nowym telefonie zainstaluj aplikację i wybierz „Przenieś '
                'z innego telefonu”. Zeskanuj pokazany tam kod.',
                style: small,
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: _scan,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Zeskanuj kod'),
              ),
              TextField(
                key: const ValueKey('move-code-input'),
                controller: _code,
                decoration: InputDecoration(
                  labelText: 'albo wklej kod',
                  errorText: _code.text.isNotEmpty && _to == null
                      ? 'To nie jest kod przeniesienia'
                      : null,
                  suffixIcon: _to == null
                      ? null
                      : const Icon(Icons.check_circle, color: Colors.green),
                ),
              ),
              const SizedBox(height: 24),
              Text('2. Pokoje prywatne', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                'Nie ma ich na żadnej liście, więc aplikacja ich nie zna. '
                'Dodaj hasłem te, które chcesz zabrać; pozostałe zostaną '
                'tutaj (i znikną przy czyszczeniu).',
                style: small,
              ),
              for (final r in _private)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.vpn_key_outlined),
                  title: Text(r.room.secrets.roomName),
                  trailing: IconButton(
                    tooltip: 'Nie zabieraj',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _private.remove(r)),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('move-add-private'),
                  onPressed: _addPrivate,
                  icon: const Icon(Icons.add),
                  label: const Text('Dodaj pokój prywatny'),
                ),
              ),
              const SizedBox(height: 24),
              Text('3. Wyślij', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                'Plik jest zaszyfrowany tak, że otworzy go tylko ten nowy '
                'telefon. Wyślij go Quick Share, Bluetooth albo kablem.',
                style: small,
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                key: const ValueKey('move-export'),
                onPressed: _to == null ? null : _export,
                icon: const Icon(Icons.send_to_mobile_outlined),
                label: Text(
                  file == null ? 'Utwórz plik i wyślij' : 'Utwórz ponownie',
                ),
              ),
              if (file != null) ...[
                TextButton.icon(
                  key: const ValueKey('move-share-again'),
                  onPressed: _share,
                  icon: const Icon(Icons.share_outlined),
                  label: const Text('Wyślij ten sam plik ponownie'),
                ),
                const SizedBox(height: 24),
                Card(
                  color: theme.colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Gdy nowy telefon pokazuje twoje rozmowy, wyczyść '
                          'ten. Oba telefony z tym samym kontem pisałyby do '
                          'tych samych rozmów i psuły sobie nawzajem historię.',
                          style: TextStyle(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          key: const ValueKey('move-wipe'),
                          style: FilledButton.styleFrom(
                            backgroundColor: theme.colorScheme.error,
                            foregroundColor: theme.colorScheme.onError,
                          ),
                          onPressed: _wipe,
                          icon: const Icon(Icons.delete_forever_outlined),
                          label: const Text('Wyczyść ten telefon'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Owns its controller so it outlives the dialog's closing animation.
class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog();

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _pass = TextEditingController();

  @override
  void dispose() {
    _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pokój prywatny'),
      content: TextField(
        key: const ValueKey('move-private-password'),
        controller: _pass,
        obscureText: true,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Hasło pokoju'),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Anuluj'),
        ),
        FilledButton(
          key: const ValueKey('move-private-add'),
          onPressed: () => Navigator.pop(context, _pass.text),
          child: const Text('Dodaj'),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------- new phone

/// New phone, instead of first-run setup: shows a one-time key as a QR,
/// takes the file the old phone sealed to it, and sets a new app PIN.
///
/// Shown in place of [SetupScreen] rather than pushed, so leaving the app to
/// accept the file (Quick Share etc.) does not close it.
class MigrationReceiveScreen extends StatefulWidget {
  const MigrationReceiveScreen({
    super.key,
    required this.onReady,
    required this.onCancel,
  });

  final ValueChanged<AppSession> onReady;
  final VoidCallback onCancel;

  @override
  State<MigrationReceiveScreen> createState() => _MigrationReceiveScreenState();
}

class _MigrationReceiveScreenState extends State<MigrationReceiveScreen> {
  /// Lives only in memory: once this screen is gone, a file sealed to it
  /// can no longer be opened by anyone.
  late final Future<KeyPair> _key = Crypto.newIdentity();
  final _form = GlobalKey<FormState>();
  final _pin = TextEditingController();
  final _pin2 = TextEditingController();
  File? _file;
  bool _busy = false;
  String? _step;

  @override
  void dispose() {
    _pin.dispose();
    _pin2.dispose();
    super.dispose();
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _pick() async {
    final picked = await AutoLock.suppress(() => openFile());
    if (picked != null && mounted) setState(() => _file = File(picked.path));
  }

  Future<void> _import() async {
    final file = _file;
    if (file == null) {
      _toast('Najpierw wybierz plik przeniesienia');
      return;
    }
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _step = 'Otwieram plik';
    });
    final vault = PinVault.instance;
    try {
      await MigrationService.import(
        file: file,
        me: await _key,
        pin: _pin.text,
        onProgress: (s) {
          if (mounted) setState(() => _step = s);
        },
      );
      if (mounted) setState(() => _step = 'Łączę z siecią');
      final app = await AppSession.unlock(_pin.text);
      if (app == null) throw MigrationException('Nie udało się otworzyć konta');
      widget.onReady(app);
    } on Object catch (e) {
      // A half-written import must not block the next try.
      if (await vault.isAppSet()) await vault.wipe();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _step = null;
      });
      _toast(e is MigrationException ? e.message : 'Nie udało się: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) widget.onCancel();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: _busy ? null : widget.onCancel),
          title: const Text('Przenieś z innego telefonu'),
        ),
        body: AbsorbPointer(
          absorbing: _busy,
          child: Form(
            key: _form,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_busy) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Text(_step ?? ''),
                    const SizedBox(height: 8),
                  ],
                  Text(
                    'Na starym telefonie: Mój profil → Przenieś na nowy '
                    'telefon, i zeskanuj ten kod.',
                    style: small,
                  ),
                  const SizedBox(height: 12),
                  FutureBuilder<KeyPair>(
                    future: _key,
                    builder: (context, snap) {
                      final kp = snap.data;
                      if (kp == null) {
                        return const SizedBox(
                          height: 240,
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      final code = MoveCode.encode(kp.key);
                      return Column(
                        children: [
                          Center(
                            child: Container(
                              color: Colors.white,
                              padding: const EdgeInsets.all(12),
                              child: QrImageView(data: code, size: 240),
                            ),
                          ),
                          const SizedBox(height: 8),
                          SelectableText(
                            code,
                            key: const ValueKey('move-code-text'),
                            textAlign: TextAlign.center,
                            style: small,
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Stary telefon wyśle plik (Quick Share, Bluetooth…). '
                    'Przyjmij go, wróć tutaj i wybierz go:',
                    style: small,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('move-pick-file'),
                    onPressed: _pick,
                    icon: const Icon(Icons.file_open_outlined),
                    label: Text(
                      _file == null
                          ? 'Wybierz plik przeniesienia'
                          : p.basename(_file!.path),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const ValueKey('move-pin'),
                    controller: _pin,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Nowy PIN aplikacji',
                    ),
                    validator: (v) =>
                        (v == null || !RegExp(r'^\d{4,8}$').hasMatch(v))
                        ? 'PIN: 4–8 cyfr'
                        : null,
                  ),
                  TextFormField(
                    key: const ValueKey('move-pin2'),
                    controller: _pin2,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Powtórz PIN'),
                    validator: (v) =>
                        v != _pin.text ? 'PIN-y się różnią' : null,
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    key: const ValueKey('move-import'),
                    onPressed: _busy ? null : _import,
                    child: const Text('Przenieś'),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Wszystko zostanie zaszyfrowane na tym telefonie nowym '
                    'PIN-em. Hasła pokoi prywatnych się nie zmieniają.',
                    style: small,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
