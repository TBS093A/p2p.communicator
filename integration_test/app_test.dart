// Dynamic test of the real app on an Android device/emulator: the embedded
// Veilid node starts, rooms are created, and the PIN vault behaves as
// promised (a wrong PIN opens nothing, each PIN opens only its own room).
// Also produces the README screenshots.
//
//   flutter drive --driver=test_driver/integration_test.dart \
//                 --target=integration_test/app_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:integration_test/integration_test.dart';
import 'package:p2p_communicator/main.dart' as app;
import 'package:p2p_communicator/ui/chat_screen.dart';
import 'package:p2p_communicator/ui/invite_screen.dart';
import 'package:p2p_communicator/ui/members_screen.dart';
import 'package:p2p_communicator/ui/new_room_screen.dart';
import 'package:p2p_communicator/ui/pin_screen.dart';
import 'package:p2p_communicator/ui/profile_screen.dart';
import 'package:p2p_communicator/ui/room_settings_screen.dart';
import 'package:p2p_communicator/ui/widgets/avatar.dart';

import 'test_images.dart';

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
    // Say what the user would have seen (SnackBar errors included) and keep
    // a picture of it in the screenshots artifact.
    final onScreen = find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .whereType<String>()
        .where((s) => s.trim().isNotEmpty)
        .toSet()
        .join(' | ');
    try {
      await binding.takeScreenshot('zz_failure');
    } on Object {
      // Best effort only.
    }
    throw TestFailure(
      'Timed out after $timeout waiting for $finder\n'
      'On screen: $onScreen',
    );
  }

  Future<void> idle(WidgetTester t, Duration d) async {
    final end = DateTime.now().add(d);
    while (DateTime.now().isBefore(end)) {
      await t.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Lets route and menu transitions finish. Screens below the top route
  /// stay in the tree, so "finder found" alone does not mean "on top".
  Future<void> settle(WidgetTester t) =>
      idle(t, const Duration(milliseconds: 1200));

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

  Future<void> reveal(WidgetTester t, Finder finder) async {
    await t.ensureVisible(finder);
    await t.pump();
  }

  Future<void> fill(WidgetTester t, String label, String value) async {
    final field = find.widgetWithText(TextFormField, label);
    await reveal(t, field);
    await t.enterText(field, value);
    await t.pump();
  }

  /// The real soft keyboard slides over the bottom of the screen; wait until
  /// it is gone so taps land and screenshots are clean.
  Future<void> hideKeyboard(WidgetTester t) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (t.view.viewInsets.bottom > 0 && DateTime.now().isBefore(end)) {
      await idle(t, const Duration(milliseconds: 200));
    }
    await idle(t, const Duration(milliseconds: 600));
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
    await settle(t);
    await fill(t, 'Nazwa pokoju', room);
    await fill(t, 'Twoja nazwa w tym pokoju', me);
    await fill(t, 'PIN do tego pokoju', pin);
    await fill(t, 'Powtórz PIN', pin);
    await hideKeyboard(t);
    if (screenshot) await shot(t, '02_new_room');
    final submit = find.widgetWithText(FilledButton, 'Utwórz');
    await reveal(t, submit);
    await t.tap(submit);
    await pumpUntil(t, find.byType(ChatScreen));
    await pumpUntil(t, find.text(room));
    await settle(t);
  }

  Future<void> openMenu(WidgetTester t, String item) async {
    await t.tap(find.byType(PopupMenuButton<String>));
    await pumpUntil(t, find.text(item));
    await settle(t); // the menu animates in; taps before that hit its barrier
    await t.tap(find.text(item));
  }

  Future<void> tapKey(WidgetTester t, String key) async {
    final f = find.byKey(ValueKey(key));
    await pumpUntil(t, f, timeout: const Duration(seconds: 20));
    await t.ensureVisible(f);
    await t.pump();
    await t.tap(f);
    await t.pump();
  }

  /// Waits until a settings screen's save (upload + DHT write) is done,
  /// i.e. its progress bar is gone again, and no error was shown.
  Future<void> waitSaved(WidgetTester t) async {
    await idle(t, const Duration(milliseconds: 400));
    final end = DateTime.now().add(const Duration(minutes: 3));
    while (find.byType(LinearProgressIndicator).evaluate().isNotEmpty &&
        DateTime.now().isBefore(end)) {
      await idle(t, const Duration(milliseconds: 250));
    }
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(SnackBar), findsNothing, reason: 'save failed');
  }

  /// Opens an RGB picker via [editKey], types [hex] and saves.
  Future<void> pickColor(WidgetTester t, String editKey, String hex) async {
    await tapKey(t, editKey);
    await pumpUntil(t, find.byKey(const ValueKey('rgb-hex')));
    await settle(t);
    await t.enterText(find.byKey(const ValueKey('rgb-hex')), hex);
    await t.pump();
    await hideKeyboard(t);
    await tapKey(t, 'rgb-save');
    await settle(t);
    await waitSaved(t);
  }

  /// An uploaded picture (not initials) is showing inside an avatar.
  Finder avatarImage() =>
      find.descendant(of: find.byType(Avatar), matching: find.byType(Image));

  Future<void> lock(WidgetTester t) async {
    await settle(t);
    await t.tap(find.byTooltip('Zablokuj'));
    await pumpUntil(t, find.byType(PinScreen));
    await settle(t);
  }

  testWidgets('rooms, PIN isolation and screenshots', (t) async {
    // A tap that misses its widget should fail here, not minutes later.
    WidgetController.hitTestWarningShouldBeFatal = true;
    // "Gallery" picks return generated images through the app's normal
    // ImagePicker calls.
    final gallery = FakeImagePicker();
    ImagePickerPlatform.instance = gallery;
    final roomPicture = await mountainAvatar();
    final myPicture = await portraitAvatar();
    final partyEmoji = await partyGif();

    app.main();
    await pumpUntil(t, find.byType(PinScreen));
    if (Platform.isAndroid) {
      await binding.convertFlutterSurfaceToImage();
    }
    await shot(t, '01_pin');

    // Room A: send a message, show the invite.
    await createRoom(
      t,
      room: 'Wyprawa w Tatry',
      me: 'Marta',
      pin: '1234',
      screenshot: true,
    );
    const hello = 'Jutro o 6:00 pod schroniskiem. Kto jedzie? 🏔️';
    await t.enterText(find.byType(TextField).last, hello);
    await t.pump();
    await t.tap(find.byTooltip('Wyślij'));
    await pumpUntil(t, find.text(hello));
    await pumpUntil(
      t,
      find.byIcon(Icons.done),
      timeout: const Duration(minutes: 3),
    );
    await hideKeyboard(t);
    await shot(t, '03_chat');

    await openMenu(t, 'Zaproś');
    await pumpUntil(t, find.byType(InviteScreen));
    await shot(t, '04_invite');
    await t.pageBack();
    await settle(t);

    // Customization. Room picture, background and emoji are shared through
    // the roster; my picture and bubble color through my outbox head; the
    // images themselves are uploaded to the DHT like any media.
    await openMenu(t, 'Ustawienia pokoju');
    await pumpUntil(t, find.byType(RoomSettingsScreen));
    await settle(t);

    gallery.queue.add(roomPicture);
    await tapKey(t, 'room-avatar-upload');
    await waitSaved(t);
    await pumpUntil(t, avatarImage(), timeout: const Duration(seconds: 30));

    await pickColor(t, 'room-bg-edit', '1B2A41');
    await pumpUntil(t, find.textContaining('#1B2A41'));

    gallery.queue.add(partyEmoji); // party.gif -> suggested code :party:
    await tapKey(t, 'emoji-add');
    await pumpUntil(t, find.byKey(const ValueKey('emoji-confirm')));
    await settle(t);
    await tapKey(t, 'emoji-confirm');
    await settle(t);
    await waitSaved(t);
    await pumpUntil(t, find.text(':party:'));
    // Back to the top so the screenshot shows the picture and the background.
    await t.drag(find.byType(ListView).first, const Offset(0, 1500));
    await settle(t);
    await shot(t, '05_room_settings');
    await t.pageBack();
    await settle(t);

    await openMenu(t, 'Mój profil');
    await pumpUntil(t, find.byType(ProfileScreen));
    await settle(t);
    gallery.queue.add(myPicture);
    await tapKey(t, 'profile-avatar-upload');
    await waitSaved(t);
    await pumpUntil(t, avatarImage(), timeout: const Duration(seconds: 30));
    await pickColor(t, 'bubble-color-edit', 'FF6F00');
    await pumpUntil(t, find.textContaining('#FF6F00'));
    await t.pageBack();
    await settle(t);

    // The custom GIF emoji inline and on its own (shown large).
    for (final text in [':party: Jedziemy!', ':party:']) {
      await t.enterText(find.byType(TextField).last, text);
      await t.pump();
      await t.tap(find.byTooltip('Wyślij'));
      await settle(t);
    }
    // Rich text with an inline image: match the plain part only.
    await pumpUntil(t, find.textContaining('Jedziemy!', findRichText: true));
    await hideKeyboard(t);
    await shot(t, '06_chat_styled');

    await openMenu(t, 'Osoby');
    await pumpUntil(t, find.byType(MembersScreen));
    await shot(t, '07_members');
    await t.pageBack();
    await settle(t);

    // Room B under another PIN.
    await lock(t);
    await createRoom(t, room: 'Projekt Apollo', me: 'Marta', pin: '5678');
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
    expect(find.text('Projekt Apollo'), findsNothing);
    await lock(t);

    await enterPin(t, '5678');
    await pumpUntil(t, find.text('Projekt Apollo'));
    expect(find.text(hello), findsNothing);
    expect(find.text('Wyprawa w Tatry'), findsNothing);
    await lock(t);
  });
}
