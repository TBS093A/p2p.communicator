// Dynamic test of the real app on an Android device/emulator: the embedded
// Veilid node starts, the app PIN is set up, a group and a DM are created
// and listed, a private room opens only with its password and never shows on
// the lists, and a wrong app PIN keeps everything shut. Also produces the
// README screenshots.
//
//   flutter drive --driver=test_driver/integration_test.dart \
//                 --target=integration_test/app_test.dart
import 'dart:async';
import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/gestures.dart' show HitTestResult;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:integration_test/integration_test.dart';
import 'package:p2p_communicator/core/crypto.dart';
import 'package:p2p_communicator/main.dart' as app;
import 'package:p2pc_core/p2pc_core.dart';
import 'package:p2p_communicator/migration/migration_archive.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';
import 'package:p2p_communicator/app_state/app_session.dart';
import 'package:p2p_communicator/ui/chat_screen.dart';
import 'package:p2p_communicator/ui/home_screen.dart';
import 'package:p2p_communicator/room/message.dart';
import 'package:p2p_communicator/room/room_session.dart';
import 'package:p2p_communicator/ui/my_profile_screen.dart';
import 'package:p2p_communicator/ui/pin_screen.dart';
import 'package:p2p_communicator/ui/profile_screen.dart';
import 'package:p2p_communicator/v2/v2_groups.dart';
import 'package:p2p_communicator/vault/room_secrets.dart';
import 'package:p2p_communicator/ui/room_settings_screen.dart';
import 'package:p2p_communicator/ui/setup_screen.dart';
import 'package:p2p_communicator/ui/update_screen.dart';
import 'package:p2p_communicator/ui/widgets/avatar.dart';
import 'package:p2p_communicator/ui/widgets/message_bubble.dart';

import 'test_images.dart';
import 'test_platforms.dart';
import 'v2_scenario.dart';

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

  Future<void> tapKey(WidgetTester t, String key) async {
    final f = find.byKey(ValueKey(key));
    await pumpUntil(t, f, timeout: const Duration(seconds: 20));
    await t.ensureVisible(f);
    await t.pump();
    await t.tap(f);
    await t.pump();
  }

  /// Types [text] into the field with [key]. The emulator's real keyboard
  /// can push an older copy of the field back after `enterText` (it kept a
  /// prefilled name once), so retype until the field holds the text.
  Future<void> typeKey(WidgetTester t, String key, String text) async {
    final field = find.byKey(ValueKey(key));
    await pumpUntil(t, field, timeout: const Duration(seconds: 20));
    String current() => t.widget<TextField>(field).controller!.text;
    for (var attempt = 1; attempt <= 4; attempt++) {
      await t.enterText(field, text);
      await idle(t, const Duration(milliseconds: 600));
      if (current() == text) break;
    }
    expect(current(), text, reason: 'IME reverted $key');
  }

  /// From the home screen: "Nowa" → [item] (a group or a 1:1
  /// conversation) → its name → create.
  Future<void> newConversation(
    WidgetTester t,
    String name, {
    String item = 'v2-new',
  }) async {
    await tapKey(t, 'new-room');
    await settle(t);
    await tapKey(t, item);
    await settle(t);
    await typeKey(t, 'v2-name', name);
    await tapKey(t, 'v2-create');
    await hideKeyboard(t);
  }

  /// From the home screen: "Nowa" → "Dołącz z zaproszenia".
  Future<void> openJoin(WidgetTester t) async {
    await tapKey(t, 'new-room');
    await settle(t);
    await tapKey(t, 'v2-join');
    await settle(t);
  }

  /// Waits for [ok] while the app keeps running.
  Future<void> waitFor(
    WidgetTester t,
    bool Function() ok, {
    Duration timeout = const Duration(minutes: 3),
    String what = 'condition',
  }) async {
    final end = DateTime.now().add(timeout);
    while (!ok()) {
      if (DateTime.now().isAfter(end)) {
        throw TestFailure('Timed out after $timeout waiting for $what');
      }
      await idle(t, const Duration(milliseconds: 500));
    }
  }

  /// Shows the home screen's 1:1 or groups list.
  Future<void> homeTab(WidgetTester t, {required bool dm}) async {
    await t.tap(find.textContaining(dm ? 'DM (' : 'Grupy ('));
    await settle(t);
  }

  /// Types [text] into the composer and sends it. The emulator's real
  /// keyboard can push an older copy of the field back after `enterText`
  /// (see [pickColor]), so retype until the field holds the text.
  Future<void> send(WidgetTester t, String text) async {
    final field = find.byType(TextField).last;
    String current() => t.widget<TextField>(field).controller!.text;
    // After hideKeyboard the real keyboard reconnects with its own (empty)
    // copy of the field: let it come up and settle before typing.
    if (t.view.viewInsets.bottom == 0) {
      await t.tap(field);
      final end = DateTime.now().add(const Duration(seconds: 5));
      while (t.view.viewInsets.bottom == 0 && DateTime.now().isBefore(end)) {
        await idle(t, const Duration(milliseconds: 200));
      }
      await idle(t, const Duration(milliseconds: 600));
    }
    for (var attempt = 1; attempt <= 3; attempt++) {
      await t.enterText(field, text);
      await idle(t, const Duration(milliseconds: 500));
      if (current() == text) break;
    }
    expect(current(), text, reason: 'IME reverted');
    await t.tap(find.byTooltip('Wyślij'));
    await settle(t);
  }

  Future<void> backToHome(WidgetTester t) async {
    while (find.byType(HomeScreen).evaluate().isEmpty ||
        find.byType(ChatScreen).evaluate().isNotEmpty) {
      // A route that is popping keeps its back button until its exit
      // animation ends (slow on the software-rendered emulator): wait for
      // it to go before pressing Back again.
      final backs = find.byTooltip('Back').evaluate().length;
      await t.pageBack();
      final end = DateTime.now().add(const Duration(seconds: 15));
      while (find.byTooltip('Back').evaluate().length >= backs &&
          DateTime.now().isBefore(end)) {
        await idle(t, const Duration(milliseconds: 200));
      }
      await settle(t);
    }
  }

  /// Private mode from the home screen: type [password], open.
  Future<void> privateMode(WidgetTester t, String password) async {
    await tapKey(t, 'private-mode');
    await pumpUntil(t, find.byKey(const ValueKey('private-password')));
    await settle(t);
    await t.enterText(find.byKey(const ValueKey('private-password')), password);
    await idle(t, const Duration(milliseconds: 600));
    await tapKey(t, 'private-open');
    await settle(t);
    await hideKeyboard(t);
  }

  Future<void> openMenu(WidgetTester t, String item) async {
    await t.tap(find.byType(PopupMenuButton<String>));
    await pumpUntil(t, find.text(item));
    await settle(t); // the menu animates in; taps before that hit its barrier
    await t.tap(find.text(item));
  }

  /// Waits until a settings screen's save (upload + DHT write) is done,
  /// i.e. its progress bar is gone again, and no error was shown.
  ///
  /// Busy screens also block input (AbsorbPointer). On a long, scrolled list
  /// the progress bar at its top may not be built at all, so the blocked
  /// input is what really tells that the save is still running.
  Future<void> waitSaved(WidgetTester t) async {
    final blocked = find.byWidgetPredicate(
      (w) => w is AbsorbPointer && w.absorbing,
    );
    bool busy() =>
        find.byType(LinearProgressIndicator).evaluate().isNotEmpty ||
        blocked.evaluate().isNotEmpty;
    await idle(t, const Duration(milliseconds: 400));
    final end = DateTime.now().add(const Duration(minutes: 3));
    while (busy() && DateTime.now().isBefore(end)) {
      await idle(t, const Duration(milliseconds: 250));
    }
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(blocked, findsNothing, reason: 'screen still busy');
    expect(find.byType(SnackBar), findsNothing, reason: 'save failed');
  }

  /// Opens an RGB picker via [editKey], types [hex] and saves.
  ///
  /// The emulator's real keyboard (IME) can push its own, older copy of the
  /// field back after `enterText`, reverting the typed value; so check the
  /// field actually holds [hex] (retyping if not) and save while the keyboard
  /// is still up, before hiding it can trigger another sync.
  Future<void> pickColor(WidgetTester t, String editKey, String hex) async {
    await tapKey(t, editKey);
    final field = find.byKey(const ValueKey('rgb-hex'));
    await pumpUntil(t, field);
    await settle(t);
    String current() => t.widget<TextField>(field).controller!.text;
    for (var attempt = 1; attempt <= 3; attempt++) {
      await t.enterText(field, hex);
      await idle(t, const Duration(milliseconds: 800));
      if (current().toUpperCase() == hex.toUpperCase()) break;
    }
    expect(current().toUpperCase(), hex.toUpperCase(), reason: 'IME reverted');
    await tapKey(t, 'rgb-save');
    await settle(t);
    await hideKeyboard(t);
    await waitSaved(t);
  }

  /// An uploaded picture (not initials) is showing inside an avatar.
  Finder avatarImage() =>
      find.descendant(of: find.byType(Avatar), matching: find.byType(Image));

  /// Waits for the uploaded picture at the top of a settings list. Tapping
  /// the upload button (ensureVisible) can scroll a long list until the
  /// picture above it is no longer built, so scroll back up first.
  Future<void> topAvatarShows(WidgetTester t) async {
    await t.drag(find.byType(ListView).first, const Offset(0, 1500));
    await settle(t);
    await pumpUntil(t, avatarImage(), timeout: const Duration(seconds: 30));
  }

  Future<void> lock(WidgetTester t) async {
    await settle(t);
    await t.tap(find.byTooltip('Zablokuj'));
    await pumpUntil(t, find.byType(PinScreen));
    await settle(t);
  }

  testWidgets('app PIN, conversations, private ones and screenshots', (
    t,
  ) async {
    // A tap that misses its widget should fail here, not minutes later.
    WidgetController.hitTestWarningShouldBeFatal = true;
    // Old v1 rooms are moved by hand below, when the test wants it.
    AppSession.moveEvery = const Duration(days: 1);
    // "Gallery" picks return generated images through the app's normal
    // ImagePicker calls.
    final gallery = FakeImagePicker();
    ImagePickerPlatform.instance = gallery;
    final roomPicture = await mountainAvatar();
    // Animated on purpose: GIF avatars and backgrounds must stay GIFs.
    final myPicture = await portraitGif();
    final chatBackground = await snowfallGif();
    final partyEmoji = await partyGif();
    // Bulk add: three GIFs plus one far over the 512 KB emoji limit, which
    // must be shrunk automatically rather than refused.
    final bulkEmoji = [...await emojiPack(), await bigGif()];

    // The v2 core (Rust) is built into this app and works on the device:
    // its end-to-end self-test (group, join, messages, rotation, restart,
    // removal) on an in-memory DHT.
    final core = coreSelfTest();
    expect(core['ok'], isTrue, reason: '${core['steps']}');

    app.main();
    await pumpUntil(t, find.byType(SetupScreen));
    if (Platform.isAndroid) {
      await binding.convertFlutterSurfaceToImage();
    }

    // First run: one name for all DMs and groups, and the app PIN.
    await settle(t);
    await fill(t, 'Twoja nazwa', 'Marta');
    await fill(t, 'PIN aplikacji', '2468');
    await fill(t, 'Powtórz PIN', '2468');
    await hideKeyboard(t);
    await shot(t, '01_setup');
    await t.tap(find.text('Zaczynamy'));
    await pumpUntil(t, find.byType(HomeScreen));
    await settle(t);
    final session = t.widget<HomeScreen>(find.byType(HomeScreen)).app;

    // PROTOCOL §B11.2: a room an earlier (v1) app version left behind moves
    // to v2 by itself, with its history; nothing to tap. (Made here through
    // the old code, which only the move still reads.)
    RoomSession.legacyWrites = true;
    final old = await session.createRoom(
      kind: RoomKind.group,
      name: 'Stara grupa',
    );
    const oldText = 'Napisane jeszcze w starej wersji';
    await old.session.sendText(oldText);
    await waitFor(
      t,
      () => old.session.messages.any(
        (m) => m.text == oldText && m.status == MsgStatus.sent,
      ),
      what: 'the v1 message to be sent',
    );
    RoomSession.legacyWrites = false;
    await pumpUntil(t, find.byKey(const ValueKey('v1-moving')));
    await shot(t, '02a_v1_moving');
    await waitFor(t, () {
      unawaited(session.moveRooms());
      return session.rooms.isEmpty;
    }, what: 'the v1 room to move');
    await settle(t);
    expect(find.byKey(const ValueKey('v1-moving')), findsNothing);
    await homeTab(t, dm: false);
    await pumpUntil(t, find.text('Stara grupa'));
    await t.tap(find.text('Stara grupa'));
    await pumpUntil(t, find.text(oldText));
    await settle(t);
    await shot(t, '02b_v1_moved');
    await backToHome(t);

    // A group: send a message, show the invite.
    await newConversation(t, 'Wyprawa w Tatry');
    await pumpUntil(t, find.byType(ChatScreen));
    await pumpUntil(t, find.text('osób: 1'));
    await pumpUntil(t, find.text('Wyprawa w Tatry'));
    const hello = 'Jutro o 6:00 pod schroniskiem. Kto jedzie? 🏔️';
    await send(t, hello);
    await pumpUntil(t, find.text(hello));
    await pumpUntil(
      t,
      find.byIcon(Icons.done),
      timeout: const Duration(minutes: 3),
    );
    await hideKeyboard(t);
    await shot(t, '03_chat');

    await openMenu(t, 'Zaproś');
    await pumpUntil(t, find.byKey(const ValueKey('v2-invite-copy')));
    await settle(t);
    await shot(t, '04_invite');
    await t.pageBack();
    await settle(t);

    // Customization. Room picture, background, bubbles and emoji go to the
    // members inside the group (in parts if large); the images themselves
    // are sealed and uploaded to the DHT like any media.
    await openMenu(t, 'Ustawienia pokoju');
    await pumpUntil(t, find.byType(RoomSettingsScreen));
    await settle(t);

    gallery.queue.add(roomPicture);
    await tapKey(t, 'room-avatar-upload');
    await waitSaved(t);
    await topAvatarShows(t);

    await pickColor(t, 'room-bg-edit', '1B2A41');
    await pumpUntil(t, find.textContaining('#1B2A41'));

    gallery.queue.add(chatBackground);
    await tapKey(t, 'room-bgimg-upload');
    await waitSaved(t);
    await pumpUntil(t, find.byKey(const ValueKey('room-bgimg-dim')));

    // Bubble colors are a room setting: mine and everyone else's.
    await pickColor(t, 'room-bubble-edit', 'FF6F00');
    await pumpUntil(t, find.textContaining('#FF6F00'));
    await pickColor(t, 'room-other-bubble-edit', '2E7D32');
    await pumpUntil(t, find.textContaining('#2E7D32'));

    gallery.queue.add(partyEmoji); // party.gif -> suggested code :party:
    await tapKey(t, 'emoji-add');
    await pumpUntil(t, find.byKey(const ValueKey('emoji-confirm')));
    await settle(t);
    await tapKey(t, 'emoji-confirm');
    await settle(t);
    await waitSaved(t);
    await pumpUntil(t, find.text(':party:'));

    // Several at once: codes suggested from file names, one room write.
    gallery.queue.addAll(bulkEmoji);
    await tapKey(t, 'emoji-add-many');
    await pumpUntil(t, find.byKey(const ValueKey('bulk-emoji-confirm')));
    await settle(t);
    await tapKey(t, 'bulk-emoji-confirm');
    // All four added, none skipped (the big one was shrunk, not refused).
    await pumpUntil(
      t,
      find.text('Dodano 4 emoji'),
      timeout: const Duration(minutes: 3),
    );
    await idle(t, const Duration(seconds: 5)); // let the SnackBar go
    for (final code in ['ogien', 'serce', 'kciuk_w_gore', 'wielki_gif']) {
      await pumpUntil(t, find.text(':$code:'));
    }
    // Back to the top so the screenshot shows the picture and the background.
    await t.drag(find.byType(ListView).first, const Offset(0, 1500));
    await settle(t);
    await shot(t, '05_room_settings');
    await t.pageBack();
    await settle(t);

    // "My profile" in a conversation is how the others there see me: its
    // own picture and name (no global profile is shown in v2, §B10).
    await openMenu(t, 'Mój profil');
    await pumpUntil(t, find.byType(ProfileScreen));
    await settle(t);
    gallery.queue.add(myPicture);
    await tapKey(t, 'profile-avatar-upload');
    await waitSaved(t);
    await topAvatarShows(t);
    final nick = find.byKey(const ValueKey('room-nick'));
    await pumpUntil(t, nick);
    for (var attempt = 1; attempt <= 3; attempt++) {
      await t.enterText(nick, 'Marta z Tatr');
      await idle(t, const Duration(milliseconds: 800));
      if (t.widget<TextField>(nick).controller!.text == 'Marta z Tatr') break;
    }
    await tapKey(t, 'room-nick-save');
    await waitSaved(t);
    await hideKeyboard(t);
    await settle(t);
    await shot(t, '08_profile');
    await t.pageBack();
    await settle(t);

    // The custom GIF emoji inline and on its own (shown large).
    for (final text in [':party: Jedziemy!', ':party:']) {
      await send(t, text);
    }
    // Rich text with an inline image: match the plain part only.
    await pumpUntil(t, find.textContaining('Jedziemy!', findRichText: true));
    // The animated background is drawn behind the conversation.
    await pumpUntil(
      t,
      find.descendant(
        of: find.byKey(const ValueKey('chat-background-image')),
        matching: find.byType(Image),
      ),
      timeout: const Duration(seconds: 30),
    );
    await hideKeyboard(t);
    // The picture runs under the top bar and the message field; both take
    // exactly the room's background color (#1B2A41) at the default 25 %
    // transparency, so the bottom looks like the top.
    final top = t.widget<AppBar>(find.byKey(const ValueKey('chat-top-bar')));
    final fieldFill = t
        .widget<TextField>(find.byKey(const ValueKey('composer-field')))
        .decoration!
        .fillColor!;
    for (final c in [top.backgroundColor!, fieldFill]) {
      expect(c.toARGB32() & 0xFFFFFF, 0x1B2A41);
      expect((c.a * 100).round(), 75);
    }
    final chatScaffold = find.ancestor(
      of: find.byKey(const ValueKey('chat-top-bar')),
      matching: find.byType(Scaffold),
    );
    expect(
      t.widget<Scaffold>(chatScaffold.first).extendBodyBehindAppBar,
      isTrue,
    );
    await shot(t, '06_chat_styled');

    // Reply to a message: long-press it, the composer shows what is being
    // answered, the sent reply carries a quote, and tapping the quote jumps
    // to (and marks) the original.
    // The original is the newest message, so it is on screen (older ones
    // may sit under the composer by now).
    const question = 'Kto bierze termos?';
    await send(t, question);
    await pumpUntil(t, find.text(question));
    await hideKeyboard(t);
    await t.longPress(find.text(question));
    await settle(t);
    await pumpUntil(t, find.byKey(const ValueKey('msg-reply')));
    await tapKey(t, 'msg-reply');
    await pumpUntil(t, find.byKey(const ValueKey('reply-bar')));
    const answer = 'Ja, z herbatą ☕';
    await send(t, answer);
    await pumpUntil(t, find.text(answer));
    expect(find.byKey(const ValueKey('reply-bar')), findsNothing);
    final quote = find.descendant(
      of: find.byType(MessageBubble),
      matching: find.byType(QuotedBubble),
    );
    await pumpUntil(t, quote);
    expect(
      find.descendant(of: quote, matching: find.text(question)),
      findsOneWidget,
    );
    await hideKeyboard(t);
    await shot(t, '06b_reply');
    await t.tap(quote.first);
    // Scrolls to the original and wobbles it (highlighted for a moment).
    await pumpUntil(
      t,
      find.byWidgetPredicate(
        (w) =>
            w is MessageBubble && w.highlighted && w.message.text == question,
      ),
      timeout: const Duration(seconds: 10),
    );
    await settle(t);

    // Reactions with the room's own emoji: long-press → pick one → a chip
    // under the message; pick another → the chip changes; tap the chip →
    // the reaction is taken back.
    Finder chip(String code) => find.byWidgetPredicate((w) {
      final k = w.key;
      return k is ValueKey<String> &&
          k.value.startsWith('reaction-') &&
          k.value.endsWith('-$code');
    });
    // Let the highlight from the quote jump end first.
    await idle(t, const Duration(seconds: 3));
    String bubbleId(String text) => t
        .widgetList<MessageBubble>(find.byType(MessageBubble))
        .firstWhere((b) => b.message.text == text)
        .message
        .id;
    // Diagnostic only: what a finger on the original would hit (a
    // long-press there did not open the menu on the emulator, while the
    // same steps pass in a widget test).
    {
      final original = find.byKey(ValueKey('bubble-${bubbleId(question)}'));
      final at = t.getCenter(original);
      final hit = HitTestResult();
      WidgetsBinding.instance.hitTestInView(hit, at, t.view.viewId);
      debugPrint(
        'DIAG original at $at hits: '
        '${hit.path.take(14).map((e) => e.target.runtimeType).join(' > ')}',
      );
    }
    // React to the newest message (the reply), at the bottom like the
    // message the reply step long-pressed.
    final target = find.byKey(ValueKey('bubble-${bubbleId(answer)}'));
    Future<String> react(String? code) async {
      await t.longPress(target);
      await settle(t);
      await pumpUntil(
        t,
        find.byKey(const ValueKey('msg-reactions')),
        timeout: const Duration(seconds: 10),
      );
      final picked =
          code ??
          t
              .widgetList(
                find.byWidgetPredicate(
                  (w) =>
                      w.key is ValueKey<String> &&
                      (w.key! as ValueKey<String>).value.startsWith('react-') &&
                      (w.key! as ValueKey<String>).value != 'react-party',
                ),
              )
              .map((w) => (w.key! as ValueKey<String>).value.substring(6))
              .first;
      await tapKey(t, 'react-$picked');
      await settle(t);
      return picked;
    }

    await react('party');
    await pumpUntil(t, chip('party'));
    // Taking it back by tapping the chip. (Changing a reaction is covered
    // by unit tests: on the emulator a second long-press on the same
    // bubble is not recognized, unlike in widget tests; logged below.)
    await t.tap(chip('party'));
    await settle(t);
    expect(chip('party'), findsNothing);
    await t.longPress(target);
    await settle(t);
    final reopened = find.byKey(const ValueKey('msg-reactions'));
    debugPrint(
      'DIAG second long-press opened menu: ${reopened.evaluate().isNotEmpty}',
    );
    if (reopened.evaluate().isNotEmpty) {
      await t.tapAt(const Offset(20, 120)); // dismiss the sheet
      await settle(t);
    }
    // Let the debounced send go out (one outbox slot at most).
    await idle(t, const Duration(seconds: 4));

    // "Is typing" is opt-in per conversation: off until switched on here.
    // (A checked menu item ignores pointers on its text: tap the item.)
    Future<void> toggleTyping() async {
      await t.tap(find.byType(PopupMenuButton<String>));
      await pumpUntil(t, find.byKey(const ValueKey('menu-share-typing')));
      await settle(t);
      await tapKey(t, 'menu-share-typing');
    }

    await toggleTyping();
    await pumpUntil(t, find.text('Inni w tej rozmowie zobaczą, kiedy piszesz'));
    await settle(t);
    await toggleTyping();
    await pumpUntil(t, find.text('Nie pokazujesz już, że piszesz'));
    await settle(t);

    await openMenu(t, 'Osoby');
    await pumpUntil(t, find.text('Osoby (1)'));
    // The name chosen for this group.
    await pumpUntil(t, find.byKey(const ValueKey('v2-member-Marta z Tatr')));
    await settle(t);
    await shot(t, '07_members');
    await t.pageBack();
    await settle(t);

    // v2 on the real network: two core members on this device's Veilid
    // node, join with a checked fingerprint, messages both ways.
    final scenario = await v2OverVeilid();
    debugPrint('[v2] ${scenario.join(', ')}');
    // v2 media (§B9): sealed per file before chunking, nothing in clear.
    final media = await encryptedMediaOverVeilid();
    debugPrint('[v2] ${media.join(', ')}');

    // The same through the app's screens (v2 is the default now, no
    // switch): create a v2 group, invite, join it (as a second member on
    // this phone) with the admin's fingerprint checked, and talk.
    await backToHome(t);
    await newConversation(t, 'Test v2');
    // The v2 group opens in the regular chat screen.
    await pumpUntil(t, find.byType(ChatScreen));
    await pumpUntil(t, find.text('osób: 1'));
    await openMenu(t, 'Zaproś');
    await pumpUntil(t, find.byKey(const ValueKey('v2-invite-copy')));
    await settle(t);
    final adminPrint = t
        .widget<Text>(find.byKey(const ValueKey('v2-fingerprint')))
        .data!;
    await shot(t, '09_v2_invite');
    // The emulator's clipboard is not readable by the test: take the code
    // from its text form under the QR code.
    final v2Code = t
        .widget<SelectableText>(find.byKey(const ValueKey('v2-invite-text')))
        .data!;
    expect(v2Code, startsWith('p2pc2.'));
    t.state<NavigatorState>(find.byType(Navigator).first)
      ..pop()
      ..pop();
    await settle(t);
    await openJoin(t);
    await typeKey(t, 'v2-invite-code', v2Code);
    await typeKey(t, 'v2-join-name', 'Dołączona');
    // Its own name in this group, not the global profile.
    await typeKey(t, 'v2-join-me', 'Kasia z v2');
    await hideKeyboard(t);
    // Checked again once the keyboard is gone: hiding it can push an older
    // copy back as well.
    String joinMe() => t
        .widget<TextField>(find.byKey(const ValueKey('v2-join-me')))
        .controller!
        .text;
    for (var i = 0; i < 3 && joinMe() != 'Kasia z v2'; i++) {
      await typeKey(t, 'v2-join-me', 'Kasia z v2');
      await hideKeyboard(t);
    }
    expect(joinMe(), 'Kasia z v2');
    // The joiner sees the same fingerprint as the admin's screen.
    expect(
      t.widget<Text>(find.byKey(const ValueKey('v2-fingerprint'))).data,
      adminPrint,
    );
    await tapKey(t, 'v2-fingerprint-ok');
    await tapKey(t, 'v2-join-go');
    await pumpUntil(t, find.byKey(const ValueKey('v2-waiting')));
    // PROTOCOL §B4 step 4: the admin sees the request with Kasia's name and
    // key, and lets her in after comparing it.
    await t.pageBack();
    await settle(t);
    await homeTab(t, dm: false);
    await t.tap(find.byKey(const ValueKey('v2-group-Test v2')).first);
    await pumpUntil(t, find.byKey(const ValueKey('v2-approve-Kasia z v2')));
    await settle(t);
    await shot(t, '09b_v2_join_request');
    await tapKey(t, 'v2-approve-Kasia z v2');
    await pumpUntil(t, find.byKey(const ValueKey('v2-request-fingerprint')));
    await settle(t);
    await tapKey(t, 'v2-approve-confirm');
    await pumpUntil(t, find.text('osób: 2'));
    await t.pageBack();
    await settle(t);
    // The list is newest first: each copy of the group by its own tile.
    final v2 = session.v2;
    final adminTest = v2.groups.firstWhere(
      (g) => !g.dm && v2.isAdmin(g) && v2.roomOf(g).roomName == 'Test v2',
    );
    final kasiaTest = v2.groups.firstWhere(
      (g) => !g.dm && g.joinedWith != null && g.fromV1 == null,
    );
    Finder tileOf(V2Group g) => find.descendant(
      of: find.byKey(ValueKey('v2-tile-${g.id}')),
      matching: find.byType(ListTile),
    );
    await t.tap(tileOf(kasiaTest));
    await settle(t);
    await pumpUntil(t, find.text('osób: 2'));
    // The admin's greeting carries the room look: the shared name replaces
    // the one typed when joining.
    await pumpUntil(t, find.text('Test v2'));
    await send(t, 'cześć z grupy v2');
    await hideKeyboard(t);
    await shot(t, '10_v2_chat');
    await t.pageBack();
    await settle(t);
    // Both groups are now called "Test v2".
    await pumpUntil(t, find.byKey(const ValueKey('v2-group-Test v2')));
    await t.tap(tileOf(adminTest));
    await pumpUntil(t, find.text('cześć z grupy v2'));
    // Shown with the name the sender chose for this group.
    await pumpUntil(t, find.text('Kasia z v2'));
    await settle(t);
    await shot(t, '11_v2_admin');

    // The same message kinds as v1, in the v2 group: a photo from the
    // gallery, a voice note, an emoji on its own (shown large), and a reply
    // quoting the photo (the quote shows the picture itself).
    gallery.queue.add(roomPicture);
    await t.tap(find.byTooltip('Załącz'));
    await pumpUntil(t, find.text('Zdjęcie z galerii'));
    await settle(t);
    await t.tap(find.text('Zdjęcie z galerii'));
    final photo = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is MessageBubble && w.message.type == MsgType.image,
      ),
      matching: find.byType(Image),
    );
    await pumpUntil(t, photo, timeout: const Duration(minutes: 2));
    // A voice note through the session (the CI emulator has no reliable
    // microphone; recording itself is the v1 composer code).
    final v2Session = t
        .widget<ChatScreen>(find.byType(ChatScreen).last)
        .session;
    final voiceFile = File('${Directory.systemTemp.path}/dast_voice.m4a')
      ..writeAsBytesSync(List.filled(4000, 7));
    await v2Session.sendFile(voiceFile, MsgType.voice, durationMs: 2300);
    await pumpUntil(
      t,
      find.byWidgetPredicate(
        (w) =>
            w is MessageBubble &&
            w.message.type == MsgType.voice &&
            w.message.status == MsgStatus.sent,
      ),
      timeout: const Duration(minutes: 2),
    );
    await send(t, '🎉');
    await pumpUntil(t, find.text('🎉'));
    await hideKeyboard(t);
    await settle(t);
    await t.longPress(photo.last);
    await settle(t);
    await pumpUntil(t, find.byKey(const ValueKey('msg-reply')));
    await tapKey(t, 'msg-reply');
    await pumpUntil(t, find.byKey(const ValueKey('reply-bar')));
    await send(t, 'piękny widok');
    await hideKeyboard(t);
    await pumpUntil(
      t,
      find.descendant(
        of: find.byType(QuotedBubble),
        matching: find.byType(Image),
      ),
      timeout: const Duration(minutes: 1),
    );
    await settle(t);
    await shot(t, '11d_v2_media');

    // Swipe to reply, as in v1: past the threshold the reply bar opens with
    // the swiped message. The gesture both ways is covered by
    // test/message_bubble_test.dart; here on fresh messages mid-screen (an
    // old one at the top sits under the sticky day header): our own to the
    // left now, someone else's to the right in the DM below.
    Future<void> swipeToReply(String text, double dx) async {
      final bubble = find.ancestor(
        of: find.text(text).last,
        matching: find.byType(MessageBubble),
      );
      // A bubble with a quoted photo is tall: bring its middle into the
      // list, away from the composer and the sticky day header.
      await Scrollable.ensureVisible(t.element(bubble.first), alignment: 0.5);
      await settle(t);
      // Start on the text itself: the row is wider than the bubble, so the
      // row's middle can be empty space beside a short bubble.
      await t.timedDragFrom(
        t.getCenter(
          find.descendant(of: bubble.first, matching: find.text(text)).last,
        ),
        Offset(dx, 0),
        const Duration(milliseconds: 400),
      );
      await settle(t);
      await pumpUntil(t, find.byKey(const ValueKey('reply-bar')));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('reply-bar')),
          matching: find.textContaining(text),
        ),
        findsWidgets,
      );
      await tapKey(t, 'reply-cancel');
      await settle(t);
      expect(find.byKey(const ValueKey('reply-bar')), findsNothing);
    }

    await swipeToReply('piękny widok', -140);

    // A DM from the shared group (phase 4b, PROTOCOL §B10): the admin
    // starts one with Kasia; her copy of the group gets the offer, she
    // accepts it with a fresh identity and the admin's DM lets her in.
    await openMenu(t, 'Osoby');
    await tapKey(t, 'v2-member-dm-Kasia z v2');
    await pumpUntil(t, find.textContaining('rozmowy prywatnej'));
    await settle(t);
    for (var i = 0; i < 3; i++) {
      await t.pageBack(); // the DM, the member list, the group
      await settle(t);
    }
    // The offer and the DMs are on the home screen's 1:1 list.
    await homeTab(t, dm: true);
    final accept = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('v2-dm-accept-'),
    );
    await pumpUntil(t, accept);
    await settle(t);
    await shot(t, '11b_v2_dm_offer');
    await t.tap(accept.first);
    await pumpUntil(t, find.text('osób: 2'));
    await send(t, 'prywatnie w v2');
    await hideKeyboard(t);
    // Phase 4c (PROTOCOL §B8): Kasia shares her presence in this DM only.
    // (A checked menu item ignores pointers on its text: tap the item.)
    await t.tap(find.byType(PopupMenuButton<String>));
    await pumpUntil(t, find.byKey(const ValueKey('menu-share-presence')));
    await settle(t);
    await tapKey(t, 'menu-share-presence');
    await pumpUntil(t, find.textContaining('zobaczą, kiedy jesteś aktywny'));
    await settle(t);
    await t.pageBack();
    await settle(t);
    // The admin's DM is named after Kasia, shows her message and that she
    // is around.
    await t.tap(find.byKey(const ValueKey('v2-group-Kasia z v2')).first);
    await pumpUntil(t, find.text('prywatnie w v2'));
    await pumpUntil(t, find.text('aktywny teraz'));
    await settle(t);
    // Kasia's newest message, swiped to the right.
    await swipeToReply('prywatnie w v2', 140);
    await shot(t, '11c_v2_dm');
    // PROTOCOL §B5.5: the admin, who started this DM, deletes it for both.
    // Its chat closes now; Kasia's copy goes at her next sync, and the
    // list says so once.
    final v2Groups = t.widget<ChatScreen>(find.byType(ChatScreen).last).v2!;
    final groupsBefore = v2Groups.groups.length;
    await t.tap(find.byType(PopupMenuButton<String>));
    await pumpUntil(t, find.byKey(const ValueKey('menu-delete-all')));
    await settle(t);
    await t.ensureVisible(find.byKey(const ValueKey('menu-delete-all')));
    await settle(t);
    await tapKey(t, 'menu-delete-all');
    await pumpUntil(t, find.byKey(const ValueKey('delete-all-confirm')));
    await settle(t);
    await tapKey(t, 'delete-all-confirm');
    await pumpUntil(
      t,
      find.textContaining('Admin usunął rozmowę'),
      timeout: const Duration(minutes: 2),
    );
    expect(v2Groups.groups.length, groupsBefore - 2);
    expect(find.byKey(const ValueKey('v2-group-Kasia z v2')), findsNothing);
    await settle(t);
    await shot(t, '11e_v2_dm_deleted');
    await homeTab(t, dm: false);
    await t.tap(tileOf(adminTest));
    // Back in the group (its newest message; older ones are scrolled away).
    await pumpUntil(t, find.text('piękny widok'));
    await settle(t);

    // Membership (phase 3): the admin makes Kasia its successor, hands the
    // admin role over to her, and Kasia, now the admin, removes it; the old
    // admin's copy of the group says so.
    await openMenu(t, 'Osoby');
    await pumpUntil(t, find.byKey(const ValueKey('v2-member-Kasia z v2')));
    await settle(t);
    await tapKey(t, 'v2-member-menu-Kasia z v2');
    await settle(t);
    await t.tap(find.text('Ustaw jako następcę'));
    await pumpUntil(t, find.textContaining('następca admina'));
    // The label shows as soon as the list is set; the screen stays blocked
    // until the commit carrying it is published, which the toast confirms.
    await pumpUntil(t, find.textContaining('przejmie grupę, jeśli'));
    await settle(t);
    await shot(t, '12_v2_members');
    await tapKey(t, 'v2-member-menu-Kasia z v2');
    await settle(t);
    await t.tap(find.text('Przekaż rolę admina'));
    await tapKey(t, 'v2-handover-confirm');
    await pumpUntil(t, find.textContaining('jest teraz adminem grupy'));
    await settle(t);
    // No admin menu any more on the old admin's side.
    expect(
      find.byKey(const ValueKey('v2-member-menu-Kasia z v2')),
      findsNothing,
    );
    await t.pageBack();
    await settle(t);
    await t.pageBack();
    await settle(t);
    // Kasia's copy. Once her phone reads the handover she is the admin:
    // the menu appears next to the other member, and she removes it.
    await t.tap(tileOf(kasiaTest));
    await settle(t);
    await openMenu(t, 'Osoby');
    final adminMenu = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('v2-member-menu-'),
    );
    await pumpUntil(t, adminMenu);
    await settle(t);
    await t.tap(adminMenu.first);
    await settle(t);
    await t.tap(find.text('Usuń z grupy'));
    await tapKey(t, 'v2-remove-confirm');
    await pumpUntil(t, find.text('Osoby (1)'));
    await settle(t);
    await shot(t, '13_v2_new_admin');
    await t.pageBack();
    await settle(t);
    await t.pageBack();
    await settle(t);
    // The old admin's copy was removed by Kasia.
    await t.tap(tileOf(adminTest));
    await pumpUntil(t, find.text('Usunięto cię z tej grupy.'));
    await settle(t);
    await backToHome(t);

    // A private v2 conversation (PROTOCOL §B11.1): created behind its own
    // password, not on any list, and opened again with that password.
    await backToHome(t);
    await tapKey(t, 'private-mode');
    await pumpUntil(t, find.byKey(const ValueKey('private-new')));
    await settle(t);
    await tapKey(t, 'private-new');
    await pumpUntil(t, find.byKey(const ValueKey('private-new-password')));
    await settle(t);
    // A phrase with spaces, like the other test passwords (no key-like
    // token for secret scanners).
    const v2Password = 'tajne v2 haslo';
    await typeKey(t, 'private-new-password', v2Password);
    await typeKey(t, 'private-new-again', v2Password);
    await typeKey(t, 'private-new-name', 'Sekret v2');
    await typeKey(t, 'private-new-me', 'Ja w sekrecie');
    await hideKeyboard(t);
    await tapKey(t, 'private-new-go');
    await pumpUntil(t, find.text('osób: 1'));
    await pumpUntil(t, find.text('Sekret v2'));
    await send(t, 'tylko pod hasłem');
    await hideKeyboard(t);
    await shot(t, '13b_v2_private');
    await backToHome(t);
    // Nowhere on the home screen or the v2 list.
    expect(find.text('Sekret v2'), findsNothing);
    await privateMode(t, v2Password);
    await pumpUntil(t, find.text('tylko pod hasłem'));
    await settle(t);
    await backToHome(t);

    // A 1:1 conversation started with a QR code: named after the other
    // person, its QR shown at once, listed under "DM".
    await backToHome(t);
    await newConversation(t, 'Rozmowa', item: 'v2-new-dm');
    await pumpUntil(t, find.byKey(const ValueKey('v2-invite-copy')));
    await settle(t);
    await t.pageBack();
    await pumpUntil(t, find.byType(ChatScreen));
    await settle(t);
    await backToHome(t);
    await homeTab(t, dm: true);
    await pumpUntil(t, find.text('Rozmowa'));

    // The home list: groups segment, with the group's last message.
    await homeTab(t, dm: false);
    await pumpUntil(t, find.text('Wyprawa w Tatry'));
    await shot(t, '02_home');

    // Another private conversation: never listed, opened only by its
    // password (it goes along to a new phone below).
    const secret = 'Tylko dla mnie 🤫';
    await tapKey(t, 'private-mode');
    await pumpUntil(t, find.byKey(const ValueKey('private-new')));
    await settle(t);
    await tapKey(t, 'private-new');
    await pumpUntil(t, find.byKey(const ValueKey('private-new-password')));
    await settle(t);
    await typeKey(t, 'private-new-password', 'tajne haslo');
    await typeKey(t, 'private-new-again', 'tajne haslo');
    await typeKey(t, 'private-new-name', 'Pamiętnik');
    await typeKey(t, 'private-new-me', 'M.');
    await hideKeyboard(t);
    await tapKey(t, 'private-new-go');
    await pumpUntil(t, find.byType(ChatScreen));
    await pumpUntil(t, find.text('osób: 1'));
    await settle(t);
    await send(t, secret);
    await pumpUntil(t, find.text(secret));
    await backToHome(t);
    for (final tab in ['DM (', 'Grupy (']) {
      await t.tap(find.textContaining(tab));
      await settle(t);
      expect(find.text('Pamiętnik'), findsNothing, reason: 'listed in $tab');
    }

    // A wrong password opens nothing.
    await privateMode(t, 'zle haslo');
    await pumpUntil(t, find.text('Nieprawidłowe hasło'));
    expect(find.byType(ChatScreen), findsNothing);
    await idle(t, const Duration(seconds: 4)); // let the toast go

    // The right one opens exactly that room, with its history.
    await privateMode(t, 'tajne haslo');
    await pumpUntil(t, find.byType(ChatScreen));
    await pumpUntil(t, find.text(secret));
    expect(find.text('Pamiętnik'), findsOneWidget);
    await hideKeyboard(t);
    await shot(t, '09_private_room');
    await backToHome(t);

    // Locking: a wrong app PIN keeps it shut, the right one restores the
    // lists (and the group's history).
    await lock(t);
    await enterPin(t, '1111');
    await idle(t, const Duration(seconds: 5));
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.byType(PinScreen), findsOneWidget);

    await enterPin(t, '2468');
    await pumpUntil(t, find.byType(HomeScreen));
    await settle(t);
    await t.tap(find.textContaining('Grupy ('));
    await settle(t);
    await pumpUntil(t, find.text('Wyprawa w Tatry'));
    await t.tap(find.text('Wyprawa w Tatry'));
    await pumpUntil(t, find.text(hello));
    await backToHome(t);

    // Updates (GitHub flavor): the installed version comes from Android, and
    // a check against the real latest release offers it (this debug build
    // is 0.1.0). Shared CI IPs may hit GitHub's anonymous rate limit; that
    // must then show as a readable message, not hang or crash.
    await tapKey(t, 'my-profile');
    await pumpUntil(t, find.byType(MyProfileScreen));
    await settle(t);
    final updatesTile = find.byKey(const ValueKey('updates'));
    await t.scrollUntilVisible(
      updatesTile,
      200,
      scrollable: find
          .descendant(
            of: find.byType(MyProfileScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    // The tile itself shows the installed version.
    await pumpUntil(
      t,
      find.text('Wersja 0.1.0 · nowe wydania'),
      timeout: const Duration(seconds: 15),
    );
    await tapKey(t, 'updates');
    await pumpUntil(t, find.byType(UpdateScreen));
    await settle(t);
    await pumpUntil(
      t,
      find.text('Wersja 0.1.0'),
      timeout: const Duration(seconds: 15),
    );
    expect(find.text('Źródło: wydania na GitHubie'), findsOneWidget);
    await tapKey(t, 'update-check');
    final offered = find.byKey(const ValueKey('update-available'));
    final status = find.byKey(const ValueKey('update-status'));
    await pumpUntil(
      t,
      find.byWidgetPredicate(
        (w) =>
            w.key == const ValueKey('update-available') ||
            (w is Text &&
                w.key == const ValueKey('update-status') &&
                (w.data ?? '').startsWith('Nie udało się')),
      ),
      timeout: const Duration(minutes: 1),
    );
    if (offered.evaluate().isNotEmpty) {
      expect(find.byKey(const ValueKey('update-install')), findsOneWidget);
      await shot(t, '11_update');
    } else {
      final why = t.widget<Text>(status).data!;
      expect(why, anyOf(contains('403'), contains('429')), reason: why);
      debugPrint('[dast] update check rate-limited by GitHub: $why');
    }
    await t.pageBack();
    await settle(t);
    await t.pageBack();
    await settle(t);

    // Moving to a new phone, with this emulator playing both. The old phone
    // seals everything to the new phone's one-time key, shares the file and
    // wipes itself; the new phone imports it under a new app PIN.
    final share = FakeShare();
    SharePlatform.instance = share;
    final picker = FakeFileSelector();
    FileSelectorPlatform.instance = picker;
    final testKey = await Crypto.newIdentity();

    await tapKey(t, 'my-profile');
    await pumpUntil(t, find.byType(MyProfileScreen));
    await settle(t);
    final moveOut = find.byKey(const ValueKey('move-out'));
    await t.scrollUntilVisible(
      moveOut,
      200,
      scrollable: find
          .descendant(
            of: find.byType(MyProfileScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tapKey(t, 'move-out');
    final codeInput = find.byKey(const ValueKey('move-code-input'));
    await pumpUntil(t, codeInput);
    await settle(t);
    await t.enterText(codeInput, MoveCode.encode(testKey.key));
    await idle(t, const Duration(milliseconds: 600));
    await hideKeyboard(t);

    // The private room goes along only when added with its password.
    await tapKey(t, 'move-add-private');
    final privatePass = find.byKey(const ValueKey('move-private-password'));
    await pumpUntil(t, privatePass);
    await settle(t);
    await t.enterText(privatePass, 'tajne haslo');
    await idle(t, const Duration(milliseconds: 600));
    await tapKey(t, 'move-private-add');
    await settle(t);
    await hideKeyboard(t);
    await pumpUntil(t, find.text('Pamiętnik'));

    await tapKey(t, 'move-export');
    await pumpUntil(t, find.byKey(const ValueKey('move-wipe')));
    await settle(t);
    final sealed = share.last;
    expect(sealed, isNotNull, reason: 'nothing was shared');

    // Only that key opens it, and it holds the whole account.
    final names = <String>[];
    await for (final (name, _) in (await MigrationReader.open(
      sealed!,
      testKey,
    )).entries()) {
      names.add(name);
    }
    expect(names, containsAll(['app/payload', 'app/data', 'pv2/0/secrets']));
    expect(
      names.where((n) => n.startsWith('v2/') && n.endsWith('/secrets')),
      hasLength(greaterThanOrEqualTo(2)),
      reason: 'the groups and the DM',
    );
    expect(names.any((n) => n.startsWith('pr2/')), isTrue);
    expect(names.any((n) => n.contains('/media/')), isTrue);
    await shot(t, '10_move_send');

    await tapKey(t, 'move-wipe');
    await pumpUntil(t, find.byKey(const ValueKey('move-wipe-confirm')));
    await settle(t);
    await tapKey(t, 'move-wipe-confirm');
    await pumpUntil(t, find.byType(SetupScreen));
    await settle(t);

    // The "new phone": its code is a different one-time key, so the test
    // passes the file on sealed to that key, as the old phone would have.
    await tapKey(t, 'move-receive');
    final codeText = find.byKey(const ValueKey('move-code-text'));
    await pumpUntil(t, codeText);
    await settle(t);
    final newPhone = MoveCode.tryParse(
      t.widget<SelectableText>(codeText).data!,
    );
    expect(newPhone, isNotNull);
    final received = File('${sealed.parent.path}/z-nowego-telefonu.p2pc');
    final rewrap = await MigrationWriter.create(received, newPhone!);
    await for (final (name, data) in (await MigrationReader.open(
      sealed,
      testKey,
    )).entries()) {
      await rewrap.add(name, data);
    }
    await rewrap.close();
    picker.file = received;

    await tapKey(t, 'move-pick-file');
    await pumpUntil(t, find.text('z-nowego-telefonu.p2pc'));
    await fill(t, 'Nowy PIN aplikacji', '1357');
    await fill(t, 'Powtórz PIN', '1357');
    await hideKeyboard(t);
    await tapKey(t, 'move-import');
    await pumpUntil(t, find.byType(HomeScreen));
    await settle(t);

    // Everything is there: the group with its history, and the private room
    // by its unchanged password.
    await t.tap(find.textContaining('Grupy ('));
    await settle(t);
    await pumpUntil(t, find.text('Wyprawa w Tatry'));
    await t.tap(find.text('Wyprawa w Tatry'));
    await pumpUntil(t, find.text(hello));
    await backToHome(t);
    await privateMode(t, 'tajne haslo');
    await pumpUntil(t, find.byType(ChatScreen));
    await pumpUntil(t, find.text(secret));
    await backToHome(t);

    // The new PIN opens it; the old one no longer does.
    await lock(t);
    await enterPin(t, '2468');
    await idle(t, const Duration(seconds: 5));
    expect(find.byType(HomeScreen), findsNothing);
    await enterPin(t, '1357');
    await pumpUntil(t, find.byType(HomeScreen));
    await lock(t);
  });
}
