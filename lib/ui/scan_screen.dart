import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../room/invite.dart';

/// Scans a QR code and returns its text: a room invite by default, or
/// whatever [accept] recognizes (e.g. the code of a phone you move to).
class ScanScreen extends StatefulWidget {
  const ScanScreen({
    super.key,
    this.title = 'Zeskanuj zaproszenie',
    this.accept = _isInvite,
  });

  final String title;
  final bool Function(String raw) accept;

  static bool _isInvite(String raw) => Invite.tryParse(raw) != null;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: MobileScanner(
        onDetect: (capture) {
          if (_done) return;
          for (final b in capture.barcodes) {
            final raw = b.rawValue;
            if (raw != null && widget.accept(raw)) {
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
