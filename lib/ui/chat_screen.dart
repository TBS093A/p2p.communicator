import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../app.dart';
import '../room/message.dart';
import '../room/room_session.dart';
import '../room/room_style.dart';
import '../vault/pin_vault.dart';
import 'invite_screen.dart';
import 'members_screen.dart';
import 'profile_screen.dart';
import 'room_settings_screen.dart';
import 'widgets/avatar.dart';
import 'widgets/emoji_text.dart';
import 'widgets/message_bubble.dart';
import 'widgets/network_dot.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.room});

  final UnlockedRoom room;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  static const _maxVideoBytes = 25 * 1024 * 1024;
  static const _maxVoice = Duration(minutes: 5);

  late final RoomSession _session = RoomSession(widget.room);
  late final Future<void> _opened = _session.open();
  final _text = TextEditingController();
  final _picker = ImagePicker();
  final _recorder = AudioRecorder();

  DateTime? _recordingSince;
  Timer? _recordTicker;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _recordTicker?.cancel();
    unawaited(_recorder.dispose());
    _text.dispose();
    _session.dispose();
    super.dispose();
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  // ----------------------------------------------------------- composing

  Future<void> _sendText() async {
    final t = _text.text;
    _text.clear();
    await _session.sendText(t);
  }

  Future<void> _attach() async {
    final choice = await showModalBottomSheet<(MsgType, ImageSource)>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            for (final (icon, label, value) in [
              (
                Icons.photo_camera,
                'Zrób zdjęcie',
                (MsgType.image, ImageSource.camera),
              ),
              (
                Icons.photo,
                'Zdjęcie z galerii',
                (MsgType.image, ImageSource.gallery),
              ),
              (
                Icons.videocam,
                'Nagraj wideo',
                (MsgType.video, ImageSource.camera),
              ),
              (
                Icons.video_library,
                'Wideo z galerii',
                (MsgType.video, ImageSource.gallery),
              ),
            ])
              ListTile(
                leading: Icon(icon),
                title: Text(label),
                onTap: () => Navigator.pop(context, value),
              ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    final (type, source) = choice;

    final XFile? picked = await AutoLock.suppress(
      () => type == MsgType.image
          ? _picker.pickImage(
              source: source,
              maxWidth: 1920,
              maxHeight: 1920,
              imageQuality: 80,
            )
          : _picker.pickVideo(
              source: source,
              maxDuration: const Duration(minutes: 2),
            ),
    );
    if (picked == null) return;
    final file = File(picked.path);

    if (type == MsgType.video && await file.length() > _maxVideoBytes) {
      _toast('Wideo jest za duże (max 25 MB). Nagraj krótsze.');
      return;
    }
    int? w, h;
    if (type == MsgType.image) {
      final img = await decodeImageFromList(await file.readAsBytes());
      w = img.width;
      h = img.height;
      img.dispose();
    }
    await _session.sendFile(file, type, width: w, height: h);
  }

  Future<void> _toggleRecording() async {
    if (_recordingSince == null) {
      final ok = await AutoLock.suppress(_recorder.hasPermission);
      if (!ok) {
        _toast('Brak zgody na mikrofon');
        return;
      }
      final dir = await getTemporaryDirectory();
      final path = p.join(
        dir.path,
        'voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
      );
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 32000,
          sampleRate: 22050,
          numChannels: 1,
        ),
        path: path,
      );
      setState(() => _recordingSince = DateTime.now());
      _recordTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (DateTime.now().difference(_recordingSince!) >= _maxVoice) {
          unawaited(_toggleRecording());
        } else {
          setState(() {});
        }
      });
    } else {
      await _finishRecording(send: true);
    }
  }

  Future<void> _finishRecording({required bool send}) async {
    _recordTicker?.cancel();
    final started = _recordingSince!;
    setState(() => _recordingSince = null);
    final path = await _recorder.stop();
    if (path == null) return;
    final file = File(path);
    final duration = DateTime.now().difference(started);
    if (!send || duration < const Duration(milliseconds: 700)) {
      if (await file.exists()) await file.delete();
      return;
    }
    await _session.sendFile(
      file,
      MsgType.voice,
      durationMs: duration.inMilliseconds,
    );
    await file.delete();
  }

  // ---------------------------------------------------------------- menu

  Future<void> _menu(String action) async {
    switch (action) {
      case 'invite':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => InviteScreen(invite: _session.invite),
          ),
        );
      case 'members':
        await _open(MembersScreen(session: _session));
      case 'profile':
        await _open(ProfileScreen(session: _session));
      case 'settings':
        await _open(RoomSettingsScreen(session: _session));
      case 'forget':
        final yes = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Usunąć pokój z telefonu?'),
            content: const Text(
              'Wiadomości i PIN tego pokoju znikną z tego urządzenia. '
              'Pozostali członkowie zachowają swoje kopie.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Anuluj'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Usuń'),
              ),
            ],
          ),
        );
        if (yes == true) {
          await _session.close();
          await PinVault.instance.forget(widget.room);
          AutoLock.lockNow();
        }
      case 'lock':
        AutoLock.lockNow();
    }
  }

  /// Settings screens keep the normal app theme; the chosen background is
  /// for the conversation itself (and shown in the pickers' previews).
  Future<void> _open(Widget screen) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => screen));

  /// The room's chat background. When set, the screen switches to the light
  /// or dark scheme that keeps text readable on it (a dark background gets
  /// light text and inputs), and the background itself is exactly the
  /// chosen RGB color. Rooms from v0.1.3 with only a theme tint keep it.
  ThemeData _roomTheme(BuildContext context) {
    final base = Theme.of(context);
    final bg = _session.meta.background;
    final accent = _session.meta.accent;
    if (bg == null && accent == null) return base;
    final brightness = bg == null
        ? base.brightness
        : (Color(bg).computeLuminance() > 0.45
              ? Brightness.light
              : Brightness.dark);
    final themed = ThemeData(
      colorSchemeSeed: Color(accent ?? 0xFF3F51B5),
      brightness: brightness,
      useMaterial3: true,
    );
    return bg == null
        ? themed
        : themed.copyWith(
            scaffoldBackgroundColor: Color(bg),
            appBarTheme: AppBarTheme(
              backgroundColor: Color(bg),
              foregroundColor: onColor(Color(bg)),
              surfaceTintColor: Colors.transparent,
            ),
          );
  }

  Future<void> _pickEmoji() async {
    final codes = _session.meta.emoji.keys.toList()..sort();
    final code = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: codes.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Ten pokój nie ma jeszcze własnych emoji. Dodasz je w '
                  'ustawieniach pokoju.',
                ),
              )
            : GridView.extent(
                shrinkWrap: true,
                maxCrossAxisExtent: 64,
                padding: const EdgeInsets.all(12),
                children: [
                  for (final c in codes)
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => Navigator.pop(context, c),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: EmojiImage(session: _session, code: c, size: 44),
                      ),
                    ),
                ],
              ),
      ),
    );
    if (code == null) return;
    final sel = _text.selection;
    final at = sel.isValid ? sel.start : _text.text.length;
    final end = sel.isValid ? sel.end : _text.text.length;
    final insert = ':$code: ';
    _text.value = TextEditingValue(
      text: _text.text.replaceRange(at, end, insert),
      selection: TextSelection.collapsed(offset: at + insert.length),
    );
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _session,
      builder: (context, _) =>
          Theme(data: _roomTheme(context), child: _scaffold(context)),
    );
  }

  Widget _scaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Builder(
          builder: (context) => InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _menu('settings'),
            child: Row(
              children: [
                Avatar.room(_session),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_session.roomName, overflow: TextOverflow.ellipsis),
                      Row(
                        children: [
                          const NetworkDot(showLabel: false),
                          const SizedBox(width: 6),
                          Text(
                            'osób: ${_session.profiles.length}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Zablokuj',
            icon: const Icon(Icons.lock),
            onPressed: AutoLock.lockNow,
          ),
          PopupMenuButton<String>(
            onSelected: _menu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'invite', child: Text('Zaproś')),
              PopupMenuItem(value: 'members', child: Text('Osoby')),
              PopupMenuItem(value: 'profile', child: Text('Mój profil')),
              PopupMenuItem(
                value: 'settings',
                child: Text('Ustawienia pokoju'),
              ),
              PopupMenuItem(value: 'forget', child: Text('Usuń z telefonu')),
            ],
          ),
        ],
      ),
      body: FutureBuilder<void>(
        future: _opened,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          return Column(
            children: [
              ValueListenableBuilder<String?>(
                valueListenable: _session.networkError,
                builder: (context, err, _) => err == null
                    ? const SizedBox.shrink()
                    : MaterialBanner(
                        content: Text(err, maxLines: 2),
                        actions: const [SizedBox.shrink()],
                      ),
              ),
              Expanded(
                child: ListenableBuilder(
                  listenable: _session,
                  builder: (context, _) {
                    final msgs = _session.messages;
                    if (msgs.isEmpty) {
                      return const Center(
                        child: Text('Brak wiadomości. Zaproś kogoś z menu.'),
                      );
                    }
                    return ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: msgs.length,
                      itemBuilder: (context, i) {
                        final m = msgs[msgs.length - 1 - i];
                        return MessageBubble(
                          key: ValueKey(m.id),
                          message: m,
                          session: _session,
                        );
                      },
                    );
                  },
                ),
              ),
              _composer(context),
            ],
          );
        },
      ),
    );
  }

  Widget _composer(BuildContext context) {
    final recording = _recordingSince != null;
    final hasText = _text.text.trim().isNotEmpty;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Row(
          children: [
            if (recording) ...[
              IconButton(
                tooltip: 'Anuluj',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _finishRecording(send: false),
              ),
              const Icon(Icons.fiber_manual_record, color: Colors.red),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _fmt(DateTime.now().difference(_recordingSince!)),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ] else ...[
              IconButton(
                tooltip: 'Załącz',
                icon: const Icon(Icons.add_circle_outline),
                onPressed: _attach,
              ),
              IconButton(
                tooltip: 'Emoji pokoju',
                icon: const Icon(Icons.emoji_emotions_outlined),
                onPressed: _pickEmoji,
              ),
              Expanded(
                child: TextField(
                  controller: _text,
                  minLines: 1,
                  maxLines: 5,
                  maxLength: 3000,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: 'Wiadomość',
                    counterText: '',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(24)),
                    ),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
            ],
            IconButton.filled(
              tooltip: hasText
                  ? 'Wyślij'
                  : (recording ? 'Wyślij głosówkę' : 'Nagraj głosówkę'),
              icon: Icon(hasText || recording ? Icons.send : Icons.mic),
              onPressed: hasText ? _sendText : _toggleRecording,
            ),
          ],
        ),
      ),
    );
  }

  static String _fmt(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}
