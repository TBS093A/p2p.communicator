import 'package:flutter/material.dart';

import '../app_state/app_session.dart';

/// First run: your name (one profile for all DMs and groups) and the app PIN.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.onReady});

  final ValueChanged<AppSession> onReady;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _pin = TextEditingController();
  final _pin2 = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_name, _pin, _pin2]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final app = await AppSession.setUp(
        pin: _pin.text,
        name: _name.text.trim(),
      );
      widget.onReady(app);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Nie udało się: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return Scaffold(
      body: SafeArea(
        child: AbsorbPointer(
          absorbing: _busy,
          child: Form(
            key: _form,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 24),
                  Icon(
                    Icons.forum_outlined,
                    size: 48,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Witaj!',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Ustaw swoją nazwę i PIN aplikacji. Nazwę, zdjęcie i '
                    'status widzą osoby z twoich rozmów i grup.',
                    textAlign: TextAlign.center,
                    style: small,
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _name,
                    maxLength: 40,
                    decoration: const InputDecoration(labelText: 'Twoja nazwa'),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Podaj nazwę' : null,
                  ),
                  TextFormField(
                    controller: _pin,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'PIN aplikacji',
                    ),
                    validator: (v) =>
                        (v == null || !RegExp(r'^\d{4,8}$').hasMatch(v))
                        ? 'PIN: 4–8 cyfr'
                        : null,
                  ),
                  TextFormField(
                    controller: _pin2,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Powtórz PIN'),
                    validator: (v) =>
                        v != _pin.text ? 'PIN-y się różnią' : null,
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: const Text('Zaczynamy'),
                  ),
                  if (_busy) ...[
                    const SizedBox(height: 16),
                    const Center(child: CircularProgressIndicator()),
                  ],
                  const SizedBox(height: 24),
                  Text(
                    'Masz już pokoje z wersji z PIN-ami? Nic nie znika: to '
                    'teraz pokoje prywatne. Otworzysz je w trybie prywatnym '
                    '(ikona incognito), wpisując dawny PIN jako hasło.',
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
