import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state/app_session.dart';
import '../room/invite.dart';
import '../room/room_protocol.dart';
import '../room/room_session.dart';
import '../vault/pin_vault.dart';
import '../vault/room_secrets.dart';
import 'chat_screen.dart';
import 'scan_screen.dart';

/// Create a group, a DM (shared by QR/text) or a private room, or join one
/// from an invite.
///
/// * Group / DM: public, listed on the home screen, shown with your global
///   profile.
/// * Private: opens only with its own password from private mode, never
///   listed, with a separate per-room name.
class NewRoomScreen extends StatefulWidget {
  const NewRoomScreen({
    super.key,
    required this.app,
    this.initialKind = RoomKind.group,
  });

  final AppSession app;
  final RoomKind initialKind;

  @override
  State<NewRoomScreen> createState() => _NewRoomScreenState();
}

enum _Mode { group, dm, private, join }

class _NewRoomScreenState extends State<NewRoomScreen> {
  final _form = GlobalKey<FormState>();
  final _roomName = TextEditingController();
  final _myName = TextEditingController();
  final _invite = TextEditingController();
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  late _Mode _mode = switch (widget.initialKind) {
    RoomKind.dm => _Mode.dm,
    RoomKind.group => _Mode.group,
    RoomKind.private => _Mode.private,
  };
  bool _busy = false;
  String? _status;

  AppSession get app => widget.app;

  /// Joining a private room needs a password and a per-room name too.
  bool get _needsPrivateFields =>
      _mode == _Mode.private ||
      (_mode == _Mode.join &&
          Invite.tryParse(_invite.text)?.kind == RoomKind.private);

  @override
  void initState() {
    super.initState();
    _myName.text = app.myGlobal.name;
    _invite.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    for (final c in [_roomName, _myName, _invite, _pass, _pass2]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _scan() async {
    final code = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (code != null) setState(() => _invite.text = code);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) setState(() => _invite.text = data!.text!.trim());
  }

  void _step(String what) {
    if (mounted) setState(() => _status = what);
    debugPrint('[new-room] $what');
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final Widget chat;
      if (_needsPrivateFields) {
        chat = await _private();
      } else if (_mode == _Mode.join) {
        _step('Szukam rozmowy w sieci…');
        final room = await app.joinRoom(Invite.tryParse(_invite.text)!);
        chat = ChatScreen(session: room.session, app: app);
      } else {
        _step('Tworzę rozmowę…');
        final dm = _mode == _Mode.dm;
        final room = await app.createRoom(
          kind: dm ? RoomKind.dm : RoomKind.group,
          name: dm ? 'Rozmowa' : _roomName.text.trim(),
        );
        chat = ChatScreen(session: room.session, app: app);
      }
      if (!mounted) return;
      await Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute<void>(builder: (_) => chat));
    } on RoomNotFoundException {
      _fail('Nie znaleziono rozmowy. Sprawdź zaproszenie i połączenie.');
    } on RoomFullException {
      _fail('Rozmowa jest pełna (63 osoby).');
    } on Object catch (e) {
      _fail('Nie udało się: $e');
    }
  }

  Future<Widget> _private() async {
    final password = _pass.text;
    _step('Sprawdzam hasło…');
    if (!await PinVault.instance.isPinFree(password)) {
      throw StateError('To hasło jest już zajęte przez inny pokój prywatny');
    }
    final RoomSecrets secrets;
    if (_mode == _Mode.join) {
      _step('Szukam pokoju w sieci…');
      secrets = await RoomProtocol.join(
        invite: Invite.tryParse(_invite.text)!,
        myName: _myName.text.trim(),
        asPrivate: true,
      );
    } else {
      _step('Tworzę pokój prywatny…');
      secrets = await RoomProtocol.create(
        roomName: _roomName.text.trim(),
        myName: _myName.text.trim(),
      );
    }
    final room = await PinVault.instance.store(password, secrets);
    _step('Zapisano');
    return ChatScreen.private(session: RoomSession(room));
  }

  void _fail(String msg) {
    debugPrint('[new-room] failed: $msg');
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg.replaceFirst('Bad state: ', ''))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return Scaffold(
      appBar: AppBar(title: const Text('Nowa rozmowa')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: Form(
          key: _form,
          // Not a ListView: a lazy list does not build off-screen fields, and
          // Form.validate() silently skips fields that are not built.
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<_Mode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: _Mode.group,
                      label: Text('Grupa'),
                      icon: Icon(Icons.groups_outlined),
                    ),
                    ButtonSegment(
                      value: _Mode.dm,
                      label: Text('DM'),
                      icon: Icon(Icons.person_outline),
                    ),
                    ButtonSegment(
                      value: _Mode.private,
                      label: Text('Prywatny'),
                      icon: Icon(Icons.vpn_key_outlined),
                    ),
                    ButtonSegment(
                      value: _Mode.join,
                      label: Text('Dołącz'),
                      icon: Icon(Icons.qr_code_scanner),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) => setState(() => _mode = s.first),
                ),
                const SizedBox(height: 16),
                Text(switch (_mode) {
                  _Mode.group =>
                    'Grupa pojawi się na liście. Zaprosisz osoby kodem QR '
                        'z menu rozmowy.',
                  _Mode.dm =>
                    'Rozmowa 1:1. Po utworzeniu pokaż kod QR z menu. '
                        'Osoby, z którymi masz wspólną grupę, zaprosisz '
                        'też stuknięciem w ich avatar na liście.',
                  _Mode.private =>
                    'Pokój prywatny nie pojawi się na żadnej liście. '
                        'Otworzysz go tylko hasłem w trybie prywatnym. '
                        'Masz w nim osobną nazwę, niepowiązaną z profilem.',
                  _Mode.join =>
                    'Wklej albo zeskanuj zaproszenie. Do pokoju prywatnego '
                        'ustawisz też hasło.',
                }, style: small),
                const SizedBox(height: 12),
                if (_mode == _Mode.group || _mode == _Mode.private)
                  TextFormField(
                    controller: _roomName,
                    decoration: InputDecoration(
                      labelText: _mode == _Mode.group
                          ? 'Nazwa grupy'
                          : 'Nazwa pokoju',
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Podaj nazwę' : null,
                  ),
                if (_mode == _Mode.join)
                  TextFormField(
                    controller: _invite,
                    minLines: 2,
                    maxLines: 4,
                    decoration: InputDecoration(
                      labelText: 'Zaproszenie',
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.content_paste),
                            onPressed: _paste,
                          ),
                          IconButton(
                            icon: const Icon(Icons.qr_code_scanner),
                            onPressed: _scan,
                          ),
                        ],
                      ),
                    ),
                    validator: (v) => Invite.tryParse(v ?? '') == null
                        ? 'To nie jest poprawne zaproszenie'
                        : null,
                  ),
                if (_needsPrivateFields) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _myName,
                    decoration: const InputDecoration(
                      labelText: 'Twoja nazwa w tym pokoju',
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Podaj nazwę' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _pass,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Hasło do tego pokoju',
                    ),
                    validator: (v) => (v == null || v.length < 4)
                        ? 'Hasło: co najmniej 4 znaki'
                        : null,
                  ),
                  TextFormField(
                    controller: _pass2,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Powtórz hasło',
                    ),
                    validator: (v) =>
                        v != _pass.text ? 'Hasła się różnią' : null,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Hasła nie da się odzyskać: zapomniane hasło oznacza '
                    'utratę dostępu do pokoju na tym telefonie.',
                    style: small,
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  key: const ValueKey('new-room-submit'),
                  onPressed: _busy ? null : _submit,
                  child: Text(_mode == _Mode.join ? 'Dołącz' : 'Utwórz'),
                ),
                if (_status != null) ...[
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      Text(_status!),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
