import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../room/invite.dart';

class InviteScreen extends StatelessWidget {
  const InviteScreen({super.key, required this.invite});

  final Invite invite;

  @override
  Widget build(BuildContext context) {
    final code = invite.encode();
    return Scaffold(
      appBar: AppBar(title: const Text('Zaproszenie')),
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
          const SizedBox(height: 24),
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Zaproszenie to klucz do pokoju: kto je ma, może czytać '
                'wszystko i dołączyć. Najlepiej pokaż kod QR osobiście. Nie '
                'wysyłaj go przez Messengera ani maila.',
              ),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('Kopiuj jako tekst'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Skopiowano')));
              }
            },
          ),
        ],
      ),
    );
  }
}
