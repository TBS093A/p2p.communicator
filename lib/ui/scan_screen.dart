import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../room/invite.dart';

/// Scans an invite QR code and returns its text.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Zeskanuj zaproszenie')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_done) return;
          for (final b in capture.barcodes) {
            final raw = b.rawValue;
            if (raw != null && Invite.tryParse(raw) != null) {
              _done = true;
              Navigator.of(context).pop(raw);
              return;
            }
          }
        },
      ),
    );
  }
}
