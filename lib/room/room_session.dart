import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:veilid/veilid.dart';

import '../app_state/app_link.dart';
import '../core/crypto.dart';
import '../core/image_prep.dart';
import '../core/media_cache.dart';
import '../core/veilid_node.dart';
import '../vault/pin_vault.dart';
import '../vault/room_secrets.dart';
import 'blob_store.dart';
import 'dht.dart';
import 'invite.dart';
import 'message.dart';
import 'room_protocol.dart';
import 'room_style.dart';

class StyleException implements Exception {
  StyleException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One unlocked room: keeps the member outboxes watched, merges their logs
/// into [messages], sends, and keeps an encrypted local cache.
///
/// Public rooms (DM, group) get an [app] link: members are shown with their
/// global profile, and ours is the app-wide one. Private rooms have none and
/// keep a per-room identity in each member's outbox head.
class RoomSession extends ChangeNotifier implements MediaSource {
  RoomSession(this.room, {this.app});

  final UnlockedRoom room;
  final AppLink? app;

  bool get isPublic => app != null && room.secrets.kind.isPublic;

  final List<ChatMessage> messages = [];

  /// Outbox key -> how that member presents themselves (us included).
  final Map<String, MemberProfile> profiles = {};
  final ValueNotifier<String?> networkError = ValueNotifier(null);

  /// Shared room look: name, avatar, accent color, custom emoji. Usable
  /// before [open] finishes (the chat app bar renders right away).
  late RoomMeta meta = RoomMeta(name: room.secrets.roomName);

  /// Upload/download progress per message id, 0..1.
  final Map<String, double> progress = {};

  final _ids = <String>{};
  final _lastSeen = <String, int>{}; // outbox key -> messages read
  final _watched = <String, RecordKey>{}; // other members' outboxes
  final _profileKeys = <String, String>{}; // outbox -> global profile key
  final _uuid = const Uuid();

  late final RecordKey _rosterKey;
  late final KeyPair _rosterWriter;
  late final RecordKey _outboxKey;
  late final KeyPair _outboxWriter;
  late final MediaCache _media;

  int _myCount = 0;
  int _pollTick = 0;
  bool _profileFromCache = false;
  bool _closed = false;
  bool _connected = false;
  Future<void> _sendChain = Future.value();
  Future<void>? _syncing;
  StreamSubscription<VeilidUpdate>? _sub;
  Timer? _poll;
  Timer? _saveTimer;

  String get roomName => meta.name;
  String get myOutbox => room.secrets.outboxKey;
  RoomKind get kind => room.secrets.kind;

  MemberProfile get myProfile => isPublic
      ? app!.myGlobal.toMember()
      : profiles[myOutbox] ?? MemberProfile(name: room.secrets.myName);

  /// In public rooms a member's global profile wins over their outbox head.
  MemberProfile profileOf(String author) {
    if (author == myOutbox) return myProfile;
    final key = _profileKeys[author];
    final global = key == null ? null : app?.directory[key];
    if (global != null) return global.toMember();
    return profiles[author] ?? const MemberProfile(name: '?');
  }

  String nameOf(String author) => profileOf(author).name;

  /// Global profile key of a member of a public room, if known.
  String? profileKeyOf(String author) =>
      author == myOutbox ? app?.myProfileKey : _profileKeys[author];

  /// Outbox keys of everyone in the room, us included.
  Iterable<String> get memberOutboxes => {myOutbox, ...profiles.keys};

  Invite get invite => Invite(
    roomName: meta.name,
    rosterKey: room.secrets.rosterKey,
    rosterWriter: room.secrets.rosterWriter,
    kind: room.secrets.kind,
  );

  // ------------------------------------------------------------ lifecycle

  Future<void> open() async {
    final s = room.secrets;
    _rosterKey = RecordKey.fromString(s.rosterKey);
    _rosterWriter = KeyPair.fromString(s.rosterWriter);
    _outboxKey = RecordKey.fromString(s.outboxKey);
    _outboxWriter = KeyPair.fromString(s.outboxWriter);
    _media = await MediaCache.open(room);
    app?.directory.addListener(notifyListeners);

    await _loadCache();
    _profileFromCache = profiles.containsKey(myOutbox);
    profiles.putIfAbsent(myOutbox, () => MemberProfile(name: s.myName));
    unawaited(_connect());
  }

  Future<void> _connect() async {
    while (!_closed) {
      try {
        await VeilidNode.instance.waitUntilOnline(
          timeout: const Duration(seconds: 60),
        );
        final rc = Dht.rc;
        await Dht.retry(
          () => rc.openDHTRecord(_rosterKey, writer: _rosterWriter),
        );
        await Dht.retry(
          () => rc.openDHTRecord(_outboxKey, writer: _outboxWriter),
        );
        final head = await Dht.getJson(_outboxKey, 0);
        final count = head?['count'] as int? ?? 0;
        if (count > _myCount) _myCount = count;
        // No local cache (e.g. reinstalled app): take our profile back from
        // the network copy instead of resetting it.
        if (!isPublic &&
            !_profileFromCache &&
            head != null &&
            head['name'] != null) {
          profiles[myOutbox] = MemberProfile.fromJson(head);
          notifyListeners();
        }

        if (_closed) return; // left while connecting
        _sub = VeilidNode.instance.updates.listen(_onUpdate);
        await rc.watchDHTValues(_rosterKey);
        _connected = true;
        _setNetworkError(null);

        await _sync(roster: true);
        if (_closed) return;
        _poll = Timer.periodic(const Duration(seconds: 20), (_) {
          // Watches can lapse; a slow poll is the safety net.
          _pollTick++;
          unawaited(_sync(roster: _pollTick % 6 == 0));
        });
        return;
      } on Object catch (e) {
        _setNetworkError('Brak połączenia z siecią Veilid ($e)');
        await Future<void>.delayed(const Duration(seconds: 10));
      }
    }
  }

  void _setNetworkError(String? message) {
    if (!_disposed) networkError.value = message;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _poll?.cancel();
    await _sub?.cancel();
    _saveTimer?.cancel();
    app?.directory.removeListener(notifyListeners);
    // Let a message sent just before leaving actually go out before its
    // records are closed (bounded, so locking never hangs).
    // (Future.any rather than .timeout(onTimeout:): the chain's runtime type
    // is Future<Null>, which rejects a void onTimeout callback at runtime.)
    await Future.any<void>([
      _sendChain.catchError((Object _) {}),
      Future<void>.delayed(const Duration(seconds: 20)),
    ]);
    await _saveCache();
    if (_connected) {
      await Dht.close(_rosterKey);
      await Dht.close(_outboxKey);
      for (final k in _watched.values) {
        await Dht.close(k);
      }
    }
    await _media.close();
  }

  // -------------------------------------------------------------- receive

  void _onUpdate(VeilidUpdate u) {
    if (u is! VeilidUpdateValueChange || _closed) return;
    if (u.key.opaque == _rosterKey.opaque) {
      unawaited(_sync(roster: true));
      return;
    }
    for (final e in _watched.entries) {
      if (e.value.opaque == u.key.opaque) {
        unawaited(_syncMember(e.key, e.value));
        return;
      }
    }
  }

  Future<void> _sync({bool roster = false}) {
    // Coalesce overlapping syncs.
    return _syncing ??= () async {
      try {
        if (roster) await _refreshRoster();
        for (final e in _watched.entries.toList()) {
          await _syncMember(e.key, e.value);
        }
      } on Object catch (e) {
        debugPrint('sync failed: $e');
      } finally {
        _syncing = null;
      }
    }();
  }

  Future<void> _refreshRoster() async {
    final metaJson = await Dht.getJson(_rosterKey, 0);
    if (metaJson != null) {
      meta = RoomMeta.fromJson(metaJson, fallbackName: meta.name);
    }
    final entries = <Map<String, dynamic>?>[];
    await Future.wait([
      for (var i = 1; i < RoomLayout.rosterSubkeys; i++)
        Dht.getJson(_rosterKey, i).then(entries.add),
    ]);
    for (final e in entries.whereType<Map<String, dynamic>>()) {
      final outbox = e['o'] as String?;
      if (outbox == null || outbox == myOutbox) continue;
      profiles.putIfAbsent(
        outbox,
        () => MemberProfile(name: e['n'] as String? ?? '?'),
      );
      final profileKey = e['p'] as String?;
      if (isPublic && profileKey != null) {
        _profileKeys[outbox] = profileKey;
        app!.directory.track(profileKey);
      }
      if (_watched.containsKey(outbox)) continue;
      final key = RecordKey.fromString(outbox);
      try {
        await Dht.retry(() => Dht.rc.openDHTRecord(key));
        await Dht.rc.watchDHTValues(
          key,
          subkeys: [const ValueSubkeyRange(low: 0, high: 0)],
        );
        _watched[outbox] = key;
      } on VeilidAPIException catch (err) {
        debugPrint('cannot open outbox of ${e['n']}: $err');
      }
    }
    notifyListeners();
  }

  Future<void> _syncMember(String outbox, RecordKey key) async {
    final head = await Dht.getJson(key, 0);
    if (head == null) return;
    final count = head['count'] as int? ?? 0;
    // Public rooms show the global profile; the head only carries a name
    // fallback. Private rooms keep the whole per-room profile in the head.
    final before = profiles[outbox];
    final profile = MemberProfile.fromJson(head);
    profiles[outbox] = profile;
    if (before?.name != profile.name ||
        before?.color != profile.color ||
        before?.avatar?.hash != profile.avatar?.hash) {
      notifyListeners();
      _scheduleSave();
    }

    var from = _lastSeen[outbox] ?? 0;
    if (count - from > RoomLayout.outboxRing) {
      from = count - RoomLayout.outboxRing; // older ones were overwritten
    }
    var added = false;
    for (var i = from; i < count; i++) {
      final j = await Dht.getJson(key, 1 + i % RoomLayout.outboxRing);
      if (j == null) continue;
      final ChatMessage msg;
      try {
        msg = ChatMessage.fromWire(outbox, j);
      } on FormatException {
        continue; // a type from a newer app version
      }
      if (msg.seq != i) continue; // slot already reused by a newer message
      if (msg.type.hidden) {
        if (_ids.add(msg.id)) app?.onHiddenMessage(this, msg);
        continue;
      }
      added |= _insert(msg);
    }
    _lastSeen[outbox] = count;
    if (added) {
      notifyListeners();
      _scheduleSave();
    }
  }

  bool _insert(ChatMessage m) {
    if (!_ids.add(m.id)) return false;
    var i = messages.length;
    while (i > 0 && messages[i - 1].ts > m.ts) {
      i--;
    }
    messages.insert(i, m);
    return true;
  }

  // ----------------------------------------------------------------- send

  Future<void> sendText(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final msg = _newMessage(MsgType.text, text: t);
    await _enqueue(msg, () async => null);
  }

  /// Sends an image, video or voice note from a local file.
  Future<void> sendFile(
    File file,
    MsgType type, {
    int? width,
    int? height,
    int? durationMs,
  }) async {
    final bytes = await file.readAsBytes();
    final mime = _mimeFor(file.path, type);
    // Shown at once from the local copy while the upload runs.
    final hash = await Crypto.hashHex(bytes);
    await _storeMedia(hash, bytes);
    final placeholder = MediaRef(
      mime: mime,
      size: bytes.length,
      hash: hash,
      records: const [],
      chunkSize: BlobStore.chunkSize,
      chunksPerRecord: BlobStore.chunksPerRecord,
      width: width,
      height: height,
      durationMs: durationMs,
    );
    var msg = _newMessage(type, media: placeholder);
    final id = msg.id;

    await _enqueue(msg, () async {
      final ref = await BlobStore.upload(
        bytes,
        mime: mime,
        width: width,
        height: height,
        durationMs: durationMs,
        onProgress: (v) {
          progress[id] = v;
          notifyListeners();
        },
      );
      progress.remove(id);
      final idx = messages.indexWhere((m) => m.id == id);
      msg = ChatMessage(
        id: id,
        author: myOutbox,
        ts: msg.ts,
        type: type,
        media: ref,
        status: MsgStatus.sending,
      );
      if (idx >= 0) messages[idx] = msg;
      return msg;
    });
  }

  ChatMessage _newMessage(MsgType type, {String? text, MediaRef? media}) =>
      ChatMessage(
        id: _uuid.v4(),
        author: myOutbox,
        ts: DateTime.now().millisecondsSinceEpoch,
        type: type,
        text: text,
        media: media,
        status: MsgStatus.sending,
      );

  /// Shows [msg] now, then runs [prepare] (uploads) and appends the final
  /// message to our outbox. Sends go out one at a time, in order.
  Future<void> _enqueue(
    ChatMessage msg,
    Future<ChatMessage?> Function() prepare,
  ) {
    _insert(msg);
    notifyListeners();
    final job = _sendChain.then((_) async {
      var m = msg;
      try {
        m = await prepare() ?? msg;
        await _append(m);
        m.status = MsgStatus.sent;
      } on Object catch (e) {
        debugPrint('send failed: $e');
        m.status = MsgStatus.failed;
      }
      notifyListeners();
      _scheduleSave();
    });
    _sendChain = job;
    return job;
  }

  Future<void> _append(ChatMessage msg) async {
    final seq = _myCount;
    msg.seq = seq;
    final data = Uint8List.fromList(utf8.encode(jsonEncode(msg.toWire())));
    if (data.length > RoomLayout.maxMessageBytes) {
      throw StateError('message too large');
    }
    await Dht.set(_outboxKey, 1 + seq % RoomLayout.outboxRing, data);
    await Dht.setJson(_outboxKey, 0, _head(seq + 1));
    _myCount = seq + 1;
  }

  /// Outbox head. Public rooms point to the global profile (`p`) and keep a
  /// name as fallback; private rooms carry the full per-room profile.
  Map<String, dynamic> _head(int count) => isPublic
      ? {'name': app!.myGlobal.name, 'p': app!.myProfileKey, 'count': count}
      : {...myProfile.toJson(), 'count': count};

  /// Appends a message that is not shown in the conversation (e.g. a sealed
  /// DM invite). Goes through the same ordered send queue.
  Future<void> sendHidden(MsgType type, Map<String, dynamic> extra) {
    assert(type.hidden);
    final msg = ChatMessage(
      id: _uuid.v4(),
      author: myOutbox,
      ts: DateTime.now().millisecondsSinceEpoch,
      type: type,
      extra: extra,
      status: MsgStatus.sending,
    );
    _ids.add(msg.id);
    final job = _sendChain.then((_) => _append(msg));
    _sendChain = job.catchError((Object e) => debugPrint('hidden send: $e'));
    return job;
  }

  // ---------------------------------------------------------------- style

  /// Changes how we appear in this room. Others see it on their next sync.
  Future<void> updateMyProfile({
    String? name,
    File? avatar,
    bool clearAvatar = false,
    int? color,
    bool clearColor = false,
  }) async {
    if (isPublic) {
      // One global profile for all public rooms.
      await app!.updateGlobalProfile(
        name: name,
        avatar: avatar,
        clearAvatar: clearAvatar,
        color: color,
        clearColor: clearColor,
      );
      notifyListeners();
      return;
    }
    final ref = avatar == null
        ? null
        : await _uploadImage(avatar, ImageUse.avatar);
    profiles[myOutbox] = myProfile.copyWith(
      name: name?.trim().isEmpty == true ? null : name?.trim(),
      avatar: ref,
      clearAvatar: clearAvatar,
      color: color,
      clearColor: clearColor,
    );
    notifyListeners();
    _scheduleSave();
    // Serialized with sends so the head never goes backwards.
    final job = _sendChain.then(
      (_) => Dht.setJsonSoon(_outboxKey, 0, _head(_myCount)),
    );
    _sendChain = job.catchError((Object e) => debugPrint('profile: $e'));
    await job;
  }

  Future<void> updateRoom({
    String? name,
    File? avatar,
    bool clearAvatar = false,
    int? background,
    bool clearBackground = false,
    File? backgroundImage,
    bool clearBackgroundImage = false,
    int? dim,
    int? bubble,
    bool clearBubble = false,
    int? otherBubble,
    bool clearOtherBubble = false,
    int? barTransparency,
  }) async {
    final ref = avatar == null
        ? null
        : await _uploadImage(avatar, ImageUse.avatar);
    final bgRef = backgroundImage == null
        ? null
        : await _uploadImage(backgroundImage, ImageUse.background);
    await _editMeta(
      (m) => m.copyWith(
        name: name?.trim().isEmpty == true ? null : name?.trim(),
        avatar: ref,
        clearAvatar: clearAvatar,
        background: background,
        clearBackground: clearBackground,
        backgroundImage: bgRef,
        clearBackgroundImage: clearBackgroundImage,
        dim: dim?.clamp(0, RoomMeta.maxDim),
        bubble: bubble,
        clearBubble: clearBubble,
        otherBubble: otherBubble,
        clearOtherBubble: clearOtherBubble,
        barTransparency: barTransparency?.clamp(0, RoomMeta.maxBarTransparency),
      ),
    );
  }

  /// Adds a custom emoji from an image file. GIF/WebP stay animated: the file
  /// is stored as-is, never re-encoded.
  Future<void> addEmoji(String code, File image) async {
    if (!EmojiCode.isValid(code)) {
      throw StyleException('Kod: 2–32 znaki, małe litery, cyfry i _');
    }
    if (meta.emoji.length >= RoomMeta.maxEmoji &&
        !meta.emoji.containsKey(code)) {
      throw StyleException('Limit ${RoomMeta.maxEmoji} emoji na pokój');
    }
    // Shrunk automatically to fit (see ImagePrep); GIFs stay animated.
    final ref = await _uploadImage(image, ImageUse.emoji);
    await _editMeta((m) => m.copyWith(emoji: {...m.emoji, code: ref}));
  }

  /// Adds many emoji at once: every image is uploaded (GIFs stay animated),
  /// then the room meta is written once. Returns the codes that were skipped
  /// with the reason (too big, bad code, over the room limit).
  Future<Map<String, String>> addEmojis(
    Map<String, File> images, {
    void Function(int done, int total)? onProgress,
  }) async {
    final skipped = <String, String>{};
    final uploaded = <String, MediaRef>{};
    final free = RoomMeta.maxEmoji - meta.emoji.length;
    var done = 0;
    for (final e in images.entries) {
      final code = e.key;
      final replacing = meta.emoji.containsKey(code);
      if (!EmojiCode.isValid(code)) {
        skipped[code] = 'nieprawidłowy kod';
      } else if (!replacing && uploaded.length >= free) {
        skipped[code] = 'limit ${RoomMeta.maxEmoji} emoji na pokój';
      } else {
        try {
          uploaded[code] = await _uploadImage(e.value, ImageUse.emoji);
        } on ImagePrepException catch (err) {
          skipped[code] = err.message;
        }
      }
      onProgress?.call(++done, images.length);
    }
    if (uploaded.isNotEmpty) {
      await _editMeta((m) => m.copyWith(emoji: {...m.emoji, ...uploaded}));
    }
    return skipped;
  }

  Future<void> removeEmoji(String code) =>
      _editMeta((m) => m.copyWith(emoji: {...m.emoji}..remove(code)));

  /// Read-modify-write of the shared room meta. Everyone shares the roster
  /// writer key, so start from the network's latest value and retry once if
  /// another member's write landed in between.
  Future<void> _editMeta(RoomMeta Function(RoomMeta) change) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final latest = await Dht.getJson(_rosterKey, 0);
      final base = latest == null
          ? meta
          : RoomMeta.fromJson(latest, fallbackName: meta.name);
      final next = change(base);
      final data = Uint8List.fromList(utf8.encode(jsonEncode(next.toJson())));
      if (data.length > RoomMeta.maxEncodedBytes) {
        throw StyleException('Za dużo emoji w pokoju');
      }
      final winner = await Dht.set(_rosterKey, 0, data);
      if (winner == null || listEquals(winner, data)) {
        meta = next;
        notifyListeners();
        _scheduleSave();
        return;
      }
    }
    throw StyleException(
      'Ktoś zmienił pokój w tym samym czasie, spróbuj ponownie',
    );
  }

  /// Avatar, background or emoji, prepared automatically (see [ImagePrep]):
  /// GIFs within the limit kept as-is, bigger ones and photos shrunk.
  Future<MediaRef> _uploadImage(File file, ImageUse use) async {
    final prepared = await ImagePrep.prepare(await file.readAsBytes(), use);
    return _uploadBytes(prepared.bytes, prepared.mime);
  }

  Future<MediaRef> _uploadBytes(Uint8List bytes, String mime) async {
    final ref = await BlobStore.upload(bytes, mime: mime);
    await _storeMedia(ref.hash, bytes);
    return ref;
  }

  // ---------------------------------------------------------------- media

  /// A playable plain file for [ref], downloading it first if needed. Plain
  /// copies live in a temp folder removed when the room is locked.
  @override
  Future<File> mediaFile(String messageId, MediaRef ref) async {
    try {
      return await _media.file(
        ref,
        onProgress: (v) {
          progress[messageId] = v;
          notifyListeners();
        },
      );
    } finally {
      if (progress.remove(messageId) != null) notifyListeners();
    }
  }

  Future<void> _storeMedia(String hash, Uint8List bytes) =>
      _media.store(hash, bytes);

  static String _mimeFor(String path, MsgType type) {
    final ext = p.extension(path).toLowerCase();
    switch (type) {
      case MsgType.image:
        return switch (ext) {
          '.png' => 'image/png',
          '.webp' => 'image/webp',
          '.heic' => 'image/heic',
          _ => 'image/jpeg',
        };
      case MsgType.video:
        return switch (ext) {
          '.mov' => 'video/quicktime',
          '.3gp' => 'video/3gpp',
          '.webm' => 'video/webm',
          _ => 'video/mp4',
        };
      case MsgType.voice:
        return 'audio/mp4';
      case MsgType.text:
      case MsgType.dmInvite:
        return 'text/plain';
    }
  }

  // ---------------------------------------------------------------- cache

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), _saveCache);
  }

  Future<void> _saveCache() async {
    final keep = messages.length > 3000
        ? messages.sublist(messages.length - 3000)
        : messages;
    final json = jsonEncode({
      'meta': meta.toJson(),
      'profiles': {for (final e in profiles.entries) e.key: e.value.toJson()},
      'lastSeen': _lastSeen,
      'myCount': _myCount,
      'messages': [for (final m in keep) m.toCache()],
    });
    await PinVault.instance.writeData(room, utf8.encode(json));
  }

  Future<void> _loadCache() async {
    final data = await PinVault.instance.readData(room);
    if (data == null) return;
    try {
      final j = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      if (j['meta'] is Map) {
        meta = RoomMeta.fromJson(
          (j['meta'] as Map).cast<String, dynamic>(),
          fallbackName: meta.name,
        );
      }
      final cached = j['profiles'];
      if (cached is Map) {
        for (final e in cached.entries) {
          profiles[e.key as String] = MemberProfile.fromJson(
            (e.value as Map).cast<String, dynamic>(),
          );
        }
      }
      // Caches written before profiles existed: names only.
      final legacy = j['members'];
      if (legacy is Map) {
        for (final e in legacy.entries) {
          profiles.putIfAbsent(
            e.key as String,
            () => MemberProfile(name: e.value as String),
          );
        }
      }
      _lastSeen.addAll((j['lastSeen'] as Map).cast<String, int>());
      _myCount = j['myCount'] as int? ?? 0;
      for (final m in (j['messages'] as List).cast<Map<String, dynamic>>()) {
        _insert(ChatMessage.fromCache(m));
      }
    } on Object catch (e) {
      debugPrint('cache unreadable, starting empty: $e');
    }
  }

  bool _disposed = false;

  /// Sends and syncs finish asynchronously, possibly after the screen that
  /// owned this session is gone: their updates are then simply dropped.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // close() keeps running after dispose: it flushes pending sends, saves
    // the cache and closes the records; it no longer notifies anyone.
    unawaited(close());
    networkError.dispose();
    super.dispose();
  }
}
