// Dynamic test of the real app on an Android device/emulator: the embedded
// Veilid node starts, rooms are created, and the PIN vault behaves as
// promised (a wrong PIN opens nothing, each PIN opens only its own room).
// Also produces the README screenshots.
//
//   flutter drive --driver=test_driver/integration_test.dart \
//                 --target=integration_test/app_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:p2p_communicator/main.dart' as app;
import 'package:p2p_communicator/ui/chat_screen.dart';
import 'package:p2p_communicator/ui/invite_screen.dart';
import 'package:p2p_communicator/ui/new_room_screen.dart';
import 'package:p2p_communicator/ui/pin_screen.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpUntil(
    WidgetTester t,
    Finder finder, {
    Duration timeout = const Duration(minutes: 4),
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      await t.pump();
      if (finder.evaluate().isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw TestFailure('Timed out after $timeout waiting for $finder');
  }

  Future<void> idle(WidgetTester t, Duration d) async {
    final end = DateTime.now().add(d);
    while (DateTime.now().isBefore(end)) {
      await t.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> shot(WidgetTester t, String name) async {
    await idle(t, const Duration(milliseconds: 800));
    await binding.takeScreenshot(name);
  }

  Future<void> enterPin(WidgetTester t, String pin) async {
    for (final d in pin.split('')) {
      await t.tap(find.text(d));
      await t.pump();
    }
    await t.tap(find.byIcon(Icons.arrow_forward));
    await t.pump();
  }

  Future<void> fill(WidgetTester t, String label, String value) async {
    final field = find.widgetWithText(TextFormField, label);
    await t.ensureVisible(field);
    await t.enterText(field, value);
    await t.pump();
  }

  Future<void> createRoom(
    WidgetTester t, {
    required String room,
    required String me,
    required String pin,
    bool screenshot = false,
  }) async {
    await t.tap(find.byTooltip('Nowy pokój'));
    await pumpUntil(t, find.byType(NewRoomScreen));
    await fill(t, 'Nazwa pokoju', room);
    await fill(t, 'Twoja nazwa w tym pokoju', me);
    await fill(t, 'PIN do tego pokoju', pin);
    await fill(t, 'Powtórz PIN', pin);
    FocusManager.instance.primaryFocus?.unfocus();
    if (screenshot) await shot(t, '02_new_room');
    final submit = find.widgetWithText(FilledButton, 'Utwórz');
    await t.ensureVisible(submit);
    await t.tap(submit);
    await pumpUntil(t, find.byType(ChatScreen));
    await pumpUntil(t, find.text(room));
  }

  Future<void> lock(WidgetTester t) async {
    await t.tap(find.byTooltip('Zablokuj'));
    await pumpUntil(t, find.byType(PinScreen));
    await idle(t, const Duration(milliseconds: 500));
  }

  testWidgets('rooms, PIN isolation and screenshots', (t) async {
    app.main();
    await pumpUntil(t, find.byType(PinScreen));
    if (Platform.isAndroid) {
      await binding.convertFlutterSurfaceToImage();
    }
    await shot(t, '01_pin');

    // Room A: send a message, show the invite.
    await createRoom(
      t,
      room: 'Rodzina',
      me: 'Ala',
      pin: '1234',
      screenshot: true,
    );
    const hello = 'Cześć! To jest wiadomość testowa 👋';
    await t.enterText(find.byType(TextField).last, hello);
    await t.pump();
    await t.tap(find.byTooltip('Wyślij'));
    await pumpUntil(t, find.text(hello));
    await pumpUntil(
      t,
      find.byIcon(Icons.done),
      timeout: const Duration(minutes: 2),
    );
    await shot(t, '03_chat');

    await t.tap(find.byType(PopupMenuButton<String>));
    await pumpUntil(t, find.text('Zaproś'));
    await t.tap(find.text('Zaproś'));
    await pumpUntil(t, find.byType(InviteScreen));
    await shot(t, '04_invite');
    await t.pageBack();
    await pumpUntil(t, find.byType(ChatScreen));

    // Room B under another PIN.
    await lock(t);
    await createRoom(t, room: 'Praca', me: 'Ala', pin: '5678');
    await lock(t);

    // A wrong PIN opens nothing and says nothing.
    await enterPin(t, '9999');
    await idle(t, const Duration(seconds: 5));
    expect(find.byType(ChatScreen), findsNothing);
    expect(find.byType(PinScreen), findsOneWidget);

    // Each PIN opens only its own room, with its history decrypted.
    await enterPin(t, '1234');
    await pumpUntil(t, find.byType(ChatScreen));
    await pumpUntil(t, find.text(hello));
    expect(find.text('Praca'), findsNothing);
    await lock(t);

    await enterPin(t, '5678');
    await pumpUntil(t, find.text('Praca'));
    expect(find.text(hello), findsNothing);
    expect(find.text('Rodzina'), findsNothing);
    await lock(t);
  });
}
