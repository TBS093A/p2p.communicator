import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../vault/pin_vault.dart';
import 'chat_screen.dart';
import 'new_room_screen.dart';
import 'widgets/network_dot.dart';

/// The only entry point. Looks like any PIN pad and reveals nothing: no list
/// of rooms, no "wrong PIN" message, the same shake for every miss.
class PinScreen extends StatefulWidget {
  const PinScreen({super.key});

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen>
    with SingleTickerProviderStateMixin {
  static const _maxLen = 8;

  String _pin = '';
  bool _busy = false;
  Duration? _lockout;
  Timer? _lockTimer;
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );

  @override
  void initState() {
    super.initState();
    unawaited(_refreshLockout());
  }

  @override
  void dispose() {
    _shake.dispose();
    _lockTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshLockout() async {
    final left = await PinVault.instance.lockoutRemaining();
    if (!mounted) return;
    setState(() => _lockout = left);
    _lockTimer?.cancel();
    if (left != null) {
      _lockTimer = Timer(const Duration(seconds: 1), _refreshLockout);
    }
  }

  void _tap(String d) {
    if (_busy || _lockout != null || _pin.length >= _maxLen) return;
    HapticFeedback.selectionClick();
    setState(() => _pin += d);
  }

  void _backspace() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    if (_pin.length < 4 || _busy) return;
    setState(() => _busy = true);
    final pin = _pin;
    try {
      final room = await PinVault.instance.unlock(pin);
      if (!mounted) return;
      setState(() {
        _pin = '';
        _busy = false;
      });
      if (room == null) {
        unawaited(_shake.forward(from: 0));
        unawaited(HapticFeedback.heavyImpact());
        await _refreshLockout();
        return;
      }
      await Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => ChatScreen(room: room)));
    } on VaultLockedOut {
      setState(() {
        _pin = '';
        _busy = false;
      });
      await _refreshLockout();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: IconButton(
                tooltip: 'Nowy pokój',
                icon: const Icon(Icons.add),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const NewRoomScreen(),
                  ),
                ),
              ),
            ),
            const Spacer(),
            Icon(Icons.lock_outline, size: 40, color: scheme.primary),
            const SizedBox(height: 24),
            AnimatedBuilder(
              animation: _shake,
              builder: (context, child) => Transform.translate(
                offset: Offset(sin(_shake.value * pi * 6) * 12, 0),
                child: child,
              ),
              child: SizedBox(
                height: 24,
                child: _busy
                    ? const SizedBox(
                        width: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < max(4, _pin.length); i++)
                            Container(
                              margin: const EdgeInsets.symmetric(horizontal: 6),
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: i < _pin.length
                                    ? scheme.primary
                                    : scheme.outlineVariant,
                              ),
                            ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 20,
              child: _lockout == null
                  ? null
                  : Text(
                      'Spróbuj ponownie za ${_lockout!.inSeconds + 1} s',
                      style: TextStyle(color: scheme.error),
                    ),
            ),
            const Spacer(),
            _Keypad(onDigit: _tap, onBack: _backspace, onOk: _submit),
            const SizedBox(height: 16),
            const NetworkDot(),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _Keypad extends StatelessWidget {
  const _Keypad({
    required this.onDigit,
    required this.onBack,
    required this.onOk,
  });

  final void Function(String) onDigit;
  final VoidCallback onBack;
  final VoidCallback onOk;

  @override
  Widget build(BuildContext context) {
    Widget key(Widget child, VoidCallback onTap) => Padding(
      padding: const EdgeInsets.all(8),
      child: SizedBox(
        width: 76,
        height: 76,
        child: TextButton(
          style: TextButton.styleFrom(shape: const CircleBorder()),
          onPressed: onTap,
          child: child,
        ),
      ),
    );
    Widget digit(String d) =>
        key(Text(d, style: const TextStyle(fontSize: 28)), () => onDigit(d));

    return Column(
      children: [
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [for (final d in row) digit(d)],
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            key(const Icon(Icons.backspace_outlined), onBack),
            digit('0'),
            key(const Icon(Icons.arrow_forward, size: 30), onOk),
          ],
        ),
      ],
    );
  }
}
