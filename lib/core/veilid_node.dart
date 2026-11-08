import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:veilid/veilid.dart';

/// The Veilid node embedded in this app. Every phone running the app is a full
/// network node: it routes traffic for others and stores DHT records, so there
/// is no server of ours anywhere.
class VeilidNode {
  VeilidNode._();
  static final VeilidNode instance = VeilidNode._();

  static const _programName = 'p2pcommunicator';

  final _updates = StreamController<VeilidUpdate>.broadcast();

  /// Every update the node emits (value changes, attachment, app messages).
  Stream<VeilidUpdate> get updates => _updates.stream;

  /// Current network attachment, for the status dot in the UI.
  final ValueNotifier<AttachmentState> attachment = ValueNotifier(
    AttachmentState.detached,
  );

  late final VeilidCryptoSystem crypto;
  late final VeilidRoutingContext routing;
  StreamSubscription<VeilidUpdate>? _sub;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;

    try {
      Veilid.instance.initializeVeilidCore(
        VeilidFFIConfig(
          logging: VeilidFFIConfigLogging(
            terminal: VeilidFFIConfigLoggingTerminal(
              enabled: kDebugMode,
              level: VeilidConfigLogLevel.info,
            ),
          ),
        ).toJson(),
      );
    } on VeilidAPIExceptionAlreadyInitialized {
      // Hot restart: the native side survives, that is fine.
    }

    final config = await getDefaultVeilidConfig(
      isWeb: false,
      programName: _programName,
    );

    Stream<VeilidUpdate> stream;
    try {
      stream = await Veilid.instance.startupVeilidCore(config);
    } on VeilidAPIExceptionAlreadyInitialized {
      await Veilid.instance.shutdownVeilidCore();
      stream = await Veilid.instance.startupVeilidCore(config);
    }
    _sub = stream.listen((update) {
      if (update is VeilidUpdateAttachment) {
        attachment.value = update.state;
      }
      _updates.add(update);
    });

    crypto = await Veilid.instance.getCryptoSystem(bestCryptoKind);
    await Veilid.instance.attach();

    // The default context already uses safety routing (hides which node is
    // reading or writing a record). Stability.reliable is avoided on purpose:
    // a fresh node may not know enough long-uptime peers to build routes.
    routing = await Veilid.instance.routingContext();
    _started = true;
  }

  Future<void> stop() async {
    if (!_started) return;
    routing.close();
    await _sub?.cancel();
    await Veilid.instance.shutdownVeilidCore();
    _started = false;
  }

  /// Resolves once the node can do network operations.
  Future<void> waitUntilOnline({Duration? timeout}) =>
      Veilid.instance.waitForAttachmentCondition(timeout: timeout);
}

extension AttachmentStateLabel on AttachmentState {
  bool get isOnline =>
      this != AttachmentState.detached &&
      this != AttachmentState.detaching &&
      this != AttachmentState.attaching;
}
