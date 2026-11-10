// Dynamic test of the real app on an Android device/emulator: the embedded
// Veilid node starts, the app PIN is set up, a group and a DM are created
// and listed, a private room opens only with its password and never shows on
// the lists, and a wrong app PIN keeps everything shut. Also produces the
// README screenshots.
//
//   flutter drive --driver=test_driver/integration_test.dart \
//                 --target=integration_test/app_test.dart
import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:integration_test/integration_test.dart';
import 'package:p2p_communicator/core/crypto.dart';
import 'package:p2p_communicator/main.dart' as app;
import 'package:p2p_communicator/migration/migration_archive.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';
import 'package:p2p_communicator/ui/chat_screen.dart';
import 'package:p2p_communicator/ui/home_screen.dart';
import 'package:p2p_communicator/ui/invite_screen.dart';
import 'package:p2p_communicator/ui/members_screen.dart';
import 'package:p2p_communicator/ui/my_profile_screen.dart';
import 'package:p2p_communicator/ui/new_room_screen.dart';
import 'package:p2p_communicator/ui/pin_screen.dart';
import 'package:p2p_communicator/ui/room_settings_screen.dart';
import 'package:p2p_communicator/ui/setup_screen.dart';
import 'package:p2p_communicator/ui/update_screen.dart';
import 'package:p2p_communicator/ui/widgets/avatar.dart';
import 'package:p2p_communicator/ui/widgets/message_bubble.dart';

import 'test_images.dart';
import 'test_platforms.dart';

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

  /// From the home screen: "Nowa" → pick [mode] → fill → create.
  Future<void> newRoom(
    WidgetTester t, {
    required String mode,
    Map<String, String> fields = const {},
  }) async {
    await tapKey(t, 'new-room');
    await pumpUntil(t, find.byType(NewRoomScreen));
    await settle(t);
    await t.tap(find.text(mode));
    await settle(t);
    for (final e in fields.entries) {
      await fill(t, e.key, e.value);
    }
    await hideKeyboard(t);
    await tapKey(t, 'new-room-submit');
    await pumpUntil(t, find.byType(ChatScreen));
    await settle(t);
  }

  Future<void> send(WidgetTester t, String text) async {
    await t.enterText(find.byType(TextField).last, text);
    await t.pump();
    await t.tap(find.byTooltip('Wyślij'));
    await settle(t);
  }

  Future<void> backToHome(WidgetTester t) async {
    while (find.byType(HomeScreen).evaluate().isEmpty ||
        find.byType(ChatScreen).evaluate().isNotEmpty) {
      await t.pageBack();
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

  testWidgets('app PIN, DM/groups, private rooms and screenshots', (t) async {
    // A tap that misses its widget should fail here, not minutes later.
    WidgetController.hitTestWarningShouldBeFatal = true;
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

    // A group: send a message, show the invite.
    await newRoom(t, mode: 'Grupa', fields: {'Nazwa grupy': 'Wyprawa w Tatry'});
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

    // In a public room "my profile" is the one global profile: picture,
    // status, bubble color.
    await openMenu(t, 'Mój profil');
    await pumpUntil(t, find.byType(MyProfileScreen));
    await settle(t);
    gallery.queue.add(myPicture);
    await tapKey(t, 'profile-avatar-upload');
    await waitSaved(t);
    await topAvatarShows(t);
    await tapKey(t, 'status-away');
    await waitSaved(t);
    // Opened from the group, it also takes a nickname for this group only.
    await t.drag(find.byType(ListView).first, const Offset(0, 1500));
    await settle(t);
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
    await pumpUntil(t, find.text('Teraz: „Marta z Tatr”'));
    await t.drag(find.byType(ListView).first, const Offset(0, 1500));
    await settle(t);
    await shot(t, '08_profile_status');
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
    // The picture runs under both bars; they take the room's background
    // color (#1B2A41) at the default 25 % transparency.
    final top = t.widget<AppBar>(find.byKey(const ValueKey('chat-top-bar')));
    final bottom = t.widget<Material>(
      find.byKey(const ValueKey('chat-bottom-bar')),
    );
    for (final c in [top.backgroundColor!, bottom.color!]) {
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
    await pumpUntil(t, find.byKey(const ValueKey('reply-bar')));
    const answer = 'Ja, z herbatą ☕';
    await send(t, answer);
    await pumpUntil(t, find.text(answer));
    expect(find.byKey(const ValueKey('reply-bar')), findsNothing);
    final quote = find.descendant(
      of: find.byType(MessageBubble),
      matching: find.byType(ReplyQuote),
    );
    await pumpUntil(t, quote);
    expect(
      find.descendant(of: quote, matching: find.text(question)),
      findsOneWidget,
    );
    await hideKeyboard(t);
    await t.tap(quote.first);
    await settle(t);
    expect(
      t
          .widgetList<MessageBubble>(find.byType(MessageBubble))
          .where((b) => b.highlighted)
          .map((b) => b.message.text),
      [question],
    );

    await openMenu(t, 'Osoby');
    await pumpUntil(t, find.byType(MembersScreen));
    // The group nickname, with the global name behind it.
    await pumpUntil(t, find.text('Marta z Tatr (ty)'));
    expect(find.textContaining('globalnie: Marta'), findsOneWidget);
    await shot(t, '07_members');
    await t.pageBack();
    await settle(t);

    // A DM started with a QR code, listed under "DM".
    await backToHome(t);
    await newRoom(t, mode: 'DM');
    await pumpUntil(t, find.text('Rozmowa'));
    await backToHome(t);
    await t.tap(find.textContaining('DM ('));
    await settle(t);
    await pumpUntil(t, find.text('Rozmowa'));

    // The home list: groups segment, with the group's last message.
    await t.tap(find.textContaining('Grupy ('));
    await settle(t);
    await pumpUntil(t, find.text('Wyprawa w Tatry'));
    await shot(t, '02_home');

    // A private room: created from private mode with a password, never
    // listed, opened only by that password.
    const secret = 'Tylko dla mnie 🤫';
    await tapKey(t, 'private-mode');
    await pumpUntil(t, find.byKey(const ValueKey('private-new')));
    await settle(t);
    await tapKey(t, 'private-new');
    await pumpUntil(t, find.byType(NewRoomScreen));
    await settle(t);
    for (final e in {
      'Nazwa pokoju': 'Pamiętnik',
      'Twoja nazwa w tym pokoju': 'M.',
      'Hasło do tego pokoju': 'tajne haslo',
      'Powtórz hasło': 'tajne haslo',
    }.entries) {
      await fill(t, e.key, e.value);
    }
    await hideKeyboard(t);
    await tapKey(t, 'new-room-submit');
    await pumpUntil(t, find.byType(ChatScreen));
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
    expect(names, containsAll(['app/payload', 'app/data', 'priv/0/secrets']));
    expect(
      names.where((n) => n.startsWith('pub/') && n.endsWith('/secrets')),
      hasLength(greaterThanOrEqualTo(2)),
      reason: 'the group and the DM',
    );
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
