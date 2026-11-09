import 'package:flutter/material.dart';

import 'app_state/app_session.dart';
import 'core/ui_prefs.dart';
import 'core/veilid_node.dart';
import 'ui/home_screen.dart';
import 'ui/migration_screens.dart';
import 'ui/pin_screen.dart';
import 'ui/setup_screen.dart';
import 'vault/pin_vault.dart';

final navigatorKey = GlobalKey<NavigatorState>();

/// Locks the app (back to the app PIN pad, every room closed) when it leaves
/// the screen, except while we ourselves opened the camera, gallery or
/// recorder.
class AutoLock {
  AutoLock._();
  static int _suppressed = 0;

  /// Set by [AppGate]: closes the unlocked app.
  static VoidCallback? _onLock;

  static Future<T> suppress<T>(Future<T> Function() action) async {
    _suppressed++;
    try {
      return await action();
    } finally {
      // The resume event arrives just after the picker returns.
      Future<void>.delayed(const Duration(seconds: 1), () => _suppressed--);
    }
  }

  static void lockNow() {
    navigatorKey.currentState?.popUntil((route) => route.isFirst);
    _onLock?.call();
  }

  /// Set by [AppGate]: back to first-run setup (after this phone was wiped).
  static VoidCallback? _onRestart;

  static void restart() {
    navigatorKey.currentState?.popUntil((route) => route.isFirst);
    _onRestart?.call();
  }

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
    // One line in logcat either way (also in release builds), which the
    // CI release smoke test waits for.
    try {
      await UiPrefs.instance.load();
      await VeilidNode.instance.start();
      await PinVault.instance.init();
      debugPrint('[startup] ready');
    } on Object catch (e) {
      debugPrint('[startup] failed: $e');
      rethrow;
    }
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
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: UiPrefs.instance.themeMode,
      builder: (context, mode, home) => MaterialApp(
        title: 'P2P Communicator',
        navigatorKey: navigatorKey,
        debugShowCheckedModeBanner: false,
        themeMode: mode,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF3F51B5),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFF3F51B5),
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: home,
      ),
      child: FutureBuilder<void>(
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
          return const AppGate();
        },
      ),
    );
  }
}

/// First run → [SetupScreen]; locked → app PIN pad; unlocked → home.
class AppGate extends StatefulWidget {
  const AppGate({super.key});

  @override
  State<AppGate> createState() => _AppGateState();
}

class _AppGateState extends State<AppGate> {
  Future<bool> _isSet = PinVault.instance.isAppSet();
  bool _setUpNow = false;

  /// Receiving everything from the old phone. Shown in place (not pushed),
  /// so leaving the app to accept the file does not close it.
  bool _moving = false;
  AppSession? _app;

  @override
  void initState() {
    super.initState();
    AutoLock._onLock = _lock;
    AutoLock._onRestart = _restart;
  }

  @override
  void dispose() {
    if (AutoLock._onLock == _lock) AutoLock._onLock = null;
    if (AutoLock._onRestart == _restart) AutoLock._onRestart = null;
    super.dispose();
  }

  void _restart() => setState(() {
    _app = null;
    _setUpNow = false;
    _moving = false;
    _isSet = PinVault.instance.isAppSet();
  });

  void _ready(AppSession a) => setState(() {
    _setUpNow = true;
    _moving = false;
    _app = a;
  });

  void _lock() {
    final app = _app;
    if (app == null) return;
    setState(() => _app = null);
    // Close after the PIN pad is up: no room is visible while it shuts down.
    WidgetsBinding.instance.addPostFrameCallback((_) => app.close());
  }

  Future<bool> _unlock(String pin) async {
    final app = await AppSession.unlock(pin);
    if (app == null) return false;
    if (mounted) setState(() => _app = app);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final app = _app;
    if (app != null) return HomeScreen(app: app);
    return FutureBuilder<bool>(
      future: _isSet,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (!snap.data! && !_setUpNow) {
          if (_moving) {
            return MigrationReceiveScreen(
              onReady: _ready,
              onCancel: () => setState(() => _moving = false),
            );
          }
          return SetupScreen(
            onReady: _ready,
            onMoveHere: () => setState(() => _moving = true),
          );
        }
        return PinScreen(onSubmit: _unlock);
      },
    );
  }
}
