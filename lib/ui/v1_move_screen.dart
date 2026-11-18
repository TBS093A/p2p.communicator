// PROTOCOL §B11.2: an old (v1) private room is opened with its password
// only, so it moves to v2 right then: it joins the move a member already
// announced in it, or moves it itself. Then the password opens the v2
// conversation in the same slot (§B11.1).
import 'dart:async';

import 'package:flutter/material.dart';

import '../room/room_session.dart';
import '../v2/private_v2.dart';
import '../v2/v1_mover.dart';
import '../vault/pin_vault.dart';
import 'chat_screen.dart';

class PrivateMoveScreen extends StatefulWidget {
  const PrivateMoveScreen({super.key, required this.slot});

  final PrivateSlot slot;

  @override
  State<PrivateMoveScreen> createState() => _PrivateMoveScreenState();
}

class _PrivateMoveScreenState extends State<PrivateMoveScreen> {
  RoomSession? _v1;
  PrivateV2? _pv;
  bool _handedOff = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    unawaited(_v1?.close());
    if (!_handedOff) unawaited(_pv?.close());
    super.dispose();
  }

  Future<void> _run() async {
    setState(() => _error = null);
    final slot = widget.slot;
    try {
      final v1 = _v1 ??= RoomSession(
        UnlockedRoom(slot.slotId, slot.key, slot.v1!),
      );
      if (_pv == null) {
        await v1.open();
        _pv = await PrivateV2.inSlot(slot);
      }
      final pv = _pv!;
      // It must have read the room once to know of a move already there.
      for (var i = 0; !v1.syncedOnce; i++) {
        if (i > 240 || !mounted) {
          throw StateError('Brak połączenia z siecią');
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      final g = await V1Mover(pv.groups, leaderFirst: false).step(v1);
      if (g == null) throw StateError('Nie udało się przenieść');
      await PinVault.instance.markMovedToV2(slot);
      if (!mounted) return;
      _handedOff = true;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => ChatScreen.v2(
            session: pv.groups.roomOf(g),
            v2: pv.groups,
            privateSlot: slot,
            onClose: pv.close,
          ),
        ),
      );
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = '$e'.replaceFirst('Bad state: ', ''));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Rozmowa prywatna')),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error == null) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              const Text(
                'Przenoszę tę rozmowę do nowej wersji (szyfrowanie MLS). '
                'Historia przejdzie razem z nią.',
                textAlign: TextAlign.center,
              ),
            ] else ...[
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey('private-move-retry'),
                onPressed: _run,
                child: const Text('Spróbuj ponownie'),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
