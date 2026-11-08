import 'package:flutter/material.dart';

import 'core/veilid_node.dart';
import 'ui/pin_screen.dart';
import 'vault/pin_vault.dart';

final navigatorKey = GlobalKey<NavigatorState>();

/// Locks every open room (back to the PIN pad) when the app leaves the
/// screen, except while we ourselves opened the camera, gallery or recorder.
class AutoLock {
  AutoLock._();
  static int _suppressed = 0;

  static Future<T> suppress<T>(Future<T> Function() action) async {
    _suppressed++;
    try {
      return await action();
    } finally {
      // The resume event arrives just after the picker returns.
      Future<void>.delayed(const Duration(seconds: 1), () => _suppressed--);
    }
  }

  static void lockNow() =>
      navigatorKey.currentState?.popUntil((route) => route.isFirst);

  static void onBackground() {
    if (_suppressed == 0) lockNow();
  }
}

class P2PApp extends StatefulWidget {
  const P2PApp({super.key});

  @override
  State<P2PApp> createState() => _P2PAppState();
}

class _P2PAppState extends State<P2PApp> with WidgetsBindingObserver {
  late final Future<void> _init = _start();

  Future<void> _start() async {
    await VeilidNode.instance.start();
    await PinVault.instance.init();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      AutoLock.onBackground();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'P2P Communicator',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF3F51B5),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF3F51B5),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: FutureBuilder<void>(
        future: _init,
        builder: (context, snap) {
          if (snap.hasError) {
            return Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Nie udało się uruchomić węzła:\n${snap.error}'),
                ),
              ),
            );
          }
          if (snap.connectionState != ConnectionState.done) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return const PinScreen();
        },
      ),
    );
  }
}
