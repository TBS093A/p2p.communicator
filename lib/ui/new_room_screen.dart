import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../room/invite.dart';
import '../room/room_protocol.dart';
import '../vault/pin_vault.dart';
import '../vault/room_secrets.dart';
import 'chat_screen.dart';
import 'scan_screen.dart';

/// Create a room or join one from an invite, and pick the PIN that will open
/// it from the PIN pad.
class NewRoomScreen extends StatefulWidget {
  const NewRoomScreen({super.key});

  @override
  State<NewRoomScreen> createState() => _NewRoomScreenState();
}

class _NewRoomScreenState extends State<NewRoomScreen> {
  final _form = GlobalKey<FormState>();
  final _roomName = TextEditingController();
  final _myName = TextEditingController();
  final _invite = TextEditingController();
  final _pin = TextEditingController();
  final _pin2 = TextEditingController();
  bool _join = false;
  bool _busy = false;
  String? _status;

  @override
  void dispose() {
    for (final c in [_roomName, _myName, _invite, _pin, _pin2]) {
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

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    final pin = _pin.text;
    setState(() {
      _busy = true;
      _status = 'Sprawdzam PIN…';
    });
    try {
      if (!await PinVault.instance.isPinFree(pin)) {
        _fail('Ten PIN jest już zajęty przez inny pokój. Wybierz inny.');
        return;
      }
      RoomSecrets secrets;
      if (_join) {
        setState(() => _status = 'Szukam pokoju w sieci…');
        secrets = await RoomProtocol.join(
          invite: Invite.tryParse(_invite.text)!,
          myName: _myName.text.trim(),
        );
      } else {
        setState(() => _status = 'Tworzę pokój…');
        secrets = await RoomProtocol.create(
          roomName: _roomName.text.trim(),
          myName: _myName.text.trim(),
        );
      }
      final room = await PinVault.instance.store(pin, secrets);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => ChatScreen(room: room)),
      );
    } on RoomNotFoundException {
      _fail('Nie znaleziono pokoju. Sprawdź zaproszenie i połączenie.');
    } on RoomFullException {
      _fail('Pokój jest pełny (63 osoby).');
    } on Object catch (e) {
      _fail('Nie udało się: $e');
    }
  }

  void _fail(String msg) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String? _pinValidator(String? v) {
    if (v == null || !RegExp(r'^\d{4,8}$').hasMatch(v)) {
      return 'PIN: 4–8 cyfr';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nowy pokój')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    label: Text('Utwórz'),
                    icon: Icon(Icons.add_home),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text('Dołącz'),
                    icon: Icon(Icons.qr_code_scanner),
                  ),
                ],
                selected: {_join},
                onSelectionChanged: (s) => setState(() => _join = s.first),
              ),
              const SizedBox(height: 16),
              if (!_join)
                TextFormField(
                  controller: _roomName,
                  decoration: const InputDecoration(labelText: 'Nazwa pokoju'),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Podaj nazwę' : null,
                )
              else
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
              const SizedBox(height: 12),
              TextFormField(
                controller: _myName,
                decoration: const InputDecoration(
                  labelText: 'Twoja nazwa w tym pokoju',
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Podaj nazwę' : null,
              ),
              const SizedBox(height: 24),
              TextFormField(
                controller: _pin,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'PIN do tego pokoju',
                ),
                validator: _pinValidator,
              ),
              TextFormField(
                controller: _pin2,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Powtórz PIN'),
                validator: (v) => v != _pin.text ? 'PIN-y się różnią' : null,
              ),
              const SizedBox(height: 8),
              Text(
                'Ten PIN otworzy ten pokój z ekranu PIN-u. Każdy pokój ma '
                'własny PIN. Nie da się go odzyskać: zapomniany PIN oznacza '
                'utratę dostępu do pokoju na tym telefonie.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: Text(_join ? 'Dołącz' : 'Utwórz'),
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
    );
  }
}
