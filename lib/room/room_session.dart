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
import 'outbox_cursor.dart';
import 'reactions.dart';
import 'room_protocol.dart';
import 'room_style.dart';
import 'sync_gate.dart';
import 'typing.dart';

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
  final _cursors = <String, OutboxCursor>{}; // outbox key -> read position
  final _watched = <String, RecordKey>{}; // other members' outboxes
  final _profileKeys = <String, String>{}; // outbox -> global profile key
  final _nicks = <String, String>{}; // outbox -> nickname in this room
  final _roomAvatars = <String, MediaRef>{}; // outbox -> picture in this room

  /// Our own picture in this public room (null = the global one).
  MediaRef? get myRoomAvatar => _roomAvatars[myOutbox];
  final _uuid = const Uuid();

  /// Our nickname in this public room (null = the global name).
  String? get myNick => _nicks[myOutbox];

  static const maxNickLength = 40;

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
  Future<void> _rosterChain = Future.value();
  final _fresh = FreshnessGate();
  final _backoff = RetryBackoff();
  final _retryTimers = <String, Timer>{}; // outbox -> pending quick retry
  // One sync per member at a time; a request arriving meanwhile is kept
  // (newest notified value wins) and run right after, never dropped.
  final _memberRuns = <String, Future<void>>{};
  final _memberAgain = <String, ValueData?>{};
  final _memberAgainExpect = <String, bool>{};
  StreamSubscription<VeilidUpdate>? _sub;
  Timer? _poll;
  Timer? _saveTimer;

  // "Is typing" (v1: a `ty` stamp in the outbox head; see typing.dart).
  final _typing = TypingBoard();
  final _typingThrottle = TypingThrottle();
  Timer? _typingTimer;

  /// Whether this conversation shows others that I am typing. Off by
  /// default (presence is opt-in), kept only in the local encrypted cache.
  bool get shareTyping => _shareTyping;
  bool _shareTyping = false;

  /// Messages the others' heads already announced but whose (encrypted)
  /// content has not reached us yet, per member. Shown as "Odbieram N
  /// wiadomości…" so waiting for the DHT is visible before the text lands.
  final _incoming = <String, int>{};
  final _incomingAt = <String, DateTime>{};
  Timer? _incomingTimer;

  /// A message that stays missing this long (lost, not just slow) no longer
  /// counts as "on its way"; the cursor still retries it in the background.
  static const incomingShownFor = Duration(seconds: 60);

  /// How many announced messages are still on their way, in total.
  int get incomingCount {
    final now = DateTime.now();
    var n = 0;
    _incoming.forEach((o, c) {
      final at = _incomingAt[o];
      if (at != null && now.difference(at) < incomingShownFor) n += c;
    });
    return n;
  }

  void _setIncoming(String outbox, int n) {
    final before = _incoming[outbox] ?? 0;
    if (n == before) return;
    if (n == 0) {
      _incoming.remove(outbox);
      _incomingAt.remove(outbox);
    } else {
      _incoming[outbox] = n;
      _incomingAt[outbox] = DateTime.now();
      _incomingTimer?.cancel();
      if (!_closed) {
        // Redraw once the oldest count stops being shown.
        _incomingTimer = Timer(incomingShownFor, () {
          if (!_closed) notifyListeners();
        });
      }
    }
    notifyListeners();
  }

  /// Display names of the others typing right now (oldest first).
  List<String> get typingNames => [
    for (final o in _typing.typing(DateTime.now().millisecondsSinceEpoch))
      if (o != myOutbox) nameOf(o),
  ];

  String get roomName => meta.name;
  String get myOutbox => room.secrets.outboxKey;
  RoomKind get kind => room.secrets.kind;

  MemberProfile get myProfile => isPublic
      ? _withNick(myOutbox, app!.myGlobal.toMember())
      : profiles[myOutbox] ?? MemberProfile(name: room.secrets.myName);

  /// In public rooms a member's global profile wins over their outbox head,
  /// except for the name and picture they set for this room only.
  MemberProfile profileOf(String author) {
    if (author == myOutbox) return myProfile;
    final key = _profileKeys[author];
    final global = key == null ? null : app?.directory[key];
    if (global != null) return _withNick(author, global.toMember());
    return _withNick(
      author,
      profiles[author] ?? const MemberProfile(name: '?'),
    );
  }

  MemberProfile _withNick(String author, MemberProfile p) {
    if (!isPublic) return p;
    final nick = _nicks[author];
    final avatar = _roomAvatars[author];
    if (nick == null && avatar == null) return p;
    return p.copyWith(name: nick, avatar: avatar);
  }

  static MediaRef? _parseAvatar(Object? raw) => parseRoomAvatar(raw);

  /// A room picture from another member's outbox head. It is untrusted and
  /// makes us download it, so only a plausible avatar is accepted: an image
  /// type, at most the avatar size limit, chunked the way our blobs are,
  /// with as many records as that size needs. Anything else (or malformed)
  /// is null: the member's global picture is shown instead.
  @visibleForTesting
  static MediaRef? parseRoomAvatar(Object? raw) {
    if (raw is! Map) return null;
    final MediaRef ref;
    try {
      ref = MediaRef.fromJson(raw.cast<String, dynamic>());
    } on Object {
      return null;
    }
    const mimes = {'image/gif', 'image/webp', 'image/png', 'image/jpeg'};
    if (!mimes.contains(ref.mime)) return null;
    if (ref.size <= 0 || ref.size > ImageUse.avatar.maxAnimated) return null;
    if (ref.chunkSize != BlobStore.chunkSize ||
        ref.chunksPerRecord != BlobStore.chunksPerRecord) {
      return null;
    }
    final records =
        (ref.chunkCount + ref.chunksPerRecord - 1) ~/ ref.chunksPerRecord;
    if (ref.records.length != records) return null;
    if (ref.hash.isEmpty || ref.records.any((r) => r.isEmpty)) return null;
    return ref;
  }

  String nameOf(String author) => profileOf(author).name;

  /// The global name behind a nickname in a public room; null when the
  /// member uses no nickname here (or in private rooms).
  String? globalNameOf(String author) {
    if (!isPublic || _nicks[author] == null) return null;
    if (author == myOutbox) return app!.myGlobal.name;
    final key = _profileKeys[author];
    return (key == null ? null : app?.directory[key]?.name) ??
        profiles[author]?.name;
  }

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
        // Same for our nickname in a public room.
        if (isPublic && !_profileFromCache && head?['nick'] is String) {
          _nicks[myOutbox] = head!['nick'] as String;
          notifyListeners();
        }
        // And our picture for this room.
        final av = isPublic && !_profileFromCache
            ? _parseAvatar(head?['av'])
            : null;
        if (av != null) {
          _roomAvatars[myOutbox] = av;
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
    for (final t in _retryTimers.values) {
      t.cancel();
    }
    _retryTimers.clear();
    // Reactions still waiting for their debounce go out now (the send
    // queue below gets a bounded moment to finish).
    for (final t in _reactTimers.values) {
      t.cancel();
    }
    _reactTimers.clear();
    for (final target in _pendingReactions.keys.toList()) {
      unawaited(_sendReaction(target));
    }
    _typingTimer?.cancel();
    _incomingTimer?.cancel();
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
      _rosterChain = _rosterChain
          .then((_) => _rosterChanged(u))
          .catchError((Object e) => debugPrint('roster update: $e'));
      return;
    }
    for (final e in _watched.entries) {
      if (e.value.opaque == u.key.opaque) {
        // The notification usually carries the new head itself: use it and
        // save a network read (which could also hit a lagging replica).
        unawaited(
          _syncMember(e.key, e.value, update: u.value, expectNew: true),
        );
        return;
      }
    }
  }

  /// A roster change: read only the subkeys that changed, and sync only
  /// members that just appeared, instead of the whole room.
  Future<void> _rosterChanged(VeilidUpdateValueChange u) async {
    if (_closed) return;
    final changed = <int>{
      for (final r in u.subkeys)
        for (var i = r.low; i <= r.high && i < RoomLayout.rosterSubkeys; i++) i,
    };
    final added = await _refreshRoster(
      only: changed.isEmpty ? null : changed,
      meta0: changed.contains(0) ? u.value : null,
    );
    for (final outbox in added) {
      final key = _watched[outbox];
      if (key != null) unawaited(_syncMember(outbox, key));
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

  /// Applies the room look from subkey 0 unless it is older than what is
  /// shown already.
  void _applyMeta(ValueData v) {
    if (_fresh.check(_rosterKey.toString(), 0, v.seq) == Freshness.older) {
      return;
    }
    final j = Dht.decodeJson(v.data);
    if (j != null) meta = RoomMeta.fromJson(j, fallbackName: meta.name);
  }

  /// Reads the roster: all subkeys, or [only] those (subkey 0 taken from
  /// [meta0] when the change notification carried it). Returns the outboxes
  /// that were not watched before.
  Future<List<String>> _refreshRoster({
    Set<int>? only,
    ValueData? meta0,
  }) async {
    final wanted =
        only ?? {for (var i = 0; i < RoomLayout.rosterSubkeys; i++) i};
    if (wanted.contains(0)) {
      final v = meta0 ?? await Dht.getValue(_rosterKey, 0);
      if (v != null) _applyMeta(v);
    }
    final entries = <Map<String, dynamic>?>[];
    await Future.wait([
      for (final i in wanted)
        if (i > 0) Dht.getJson(_rosterKey, i).then(entries.add),
    ]);
    final added = <String>[];
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
        added.add(outbox);
      } on VeilidAPIException catch (err) {
        debugPrint('cannot open outbox of ${e['n']}: $err');
      }
    }
    notifyListeners();
    return added;
  }

  /// Syncs one member. At most one run per member at a time; a request
  /// arriving meanwhile runs right after (with the newest notified head),
  /// so a notification is never lost to an overlapping sync.
  Future<void> _syncMember(
    String outbox,
    RecordKey key, {
    ValueData? update,
    bool expectNew = false,
  }) {
    final running = _memberRuns[outbox];
    if (running != null) {
      final prev = _memberAgain[outbox];
      if (!_memberAgain.containsKey(outbox) ||
          (update != null && (prev == null || update.seq > prev.seq))) {
        _memberAgain[outbox] = update;
      }
      _memberAgainExpect[outbox] =
          (_memberAgainExpect[outbox] ?? false) || expectNew;
      return running;
    }
    final run = () async {
      try {
        var u = update;
        var expect = expectNew;
        while (true) {
          await _syncMemberOnce(outbox, key, u, expect);
          if (_closed || !_memberAgain.containsKey(outbox)) break;
          u = _memberAgain.remove(outbox);
          expect = _memberAgainExpect.remove(outbox) ?? false;
        }
      } on Object catch (e) {
        debugPrint('member sync failed: $e');
      } finally {
        // This run itself; it never completes with an error.
        _memberRuns.remove(outbox)?.ignore();
      }
    }();
    _memberRuns[outbox] = run;
    return run;
  }

  /// Retries a member soon (1, 2, 4 s) when something it announced has not
  /// reached the replicas we read yet, instead of waiting for the 20 s poll.
  void _retrySoon(String outbox, RecordKey key) {
    if (_closed || _retryTimers.containsKey(outbox)) return;
    final delay = _backoff.next(outbox);
    if (delay == null) return; // the slow poll takes over
    _retryTimers[outbox] = Timer(delay, () {
      _retryTimers.remove(outbox);
      if (!_closed) unawaited(_syncMember(outbox, key, expectNew: true));
    });
  }

  Future<void> _syncMemberOnce(
    String outbox,
    RecordKey key,
    ValueData? update,
    bool expectNew,
  ) async {
    // A notification may carry no value (only the subkey list): read it.
    final v = update ?? await Dht.getValue(key, 0);
    if (v == null) {
      if (expectNew) _retrySoon(outbox, key);
      return;
    }
    final fresh = _fresh.check(outbox, 0, v.seq);
    if (fresh == Freshness.older) {
      // A late notification or a lagging replica: never roll back.
      if (expectNew) _retrySoon(outbox, key);
      return;
    }
    final head = Dht.decodeJson(v.data);
    if (head == null) return;
    final count = head['count'] as int? ?? 0;
    _noteTyping(outbox, head);
    // Public rooms show the global profile; the head only carries a name
    // fallback. Private rooms keep the whole per-room profile in the head.
    final before = profiles[outbox];
    final profile = MemberProfile.fromJson(head);
    profiles[outbox] = profile;
    final nickBefore = _nicks[outbox];
    final nick = isPublic ? _cleanNick(head['nick']) : null;
    if (nick == null) {
      _nicks.remove(outbox);
    } else {
      _nicks[outbox] = nick;
    }
    final avatarBefore = _roomAvatars[outbox]?.hash;
    final roomAvatar = isPublic ? _parseAvatar(head['av']) : null;
    if (roomAvatar == null) {
      _roomAvatars.remove(outbox);
    } else {
      _roomAvatars[outbox] = roomAvatar;
    }
    if (nickBefore != nick ||
        avatarBefore != roomAvatar?.hash ||
        before?.name != profile.name ||
        before?.color != profile.color ||
        before?.avatar?.hash != profile.avatar?.hash) {
      notifyListeners();
      _scheduleSave();
    }

    final cursor = _cursors.putIfAbsent(outbox, OutboxCursor.new);
    final due = cursor.due(count, RoomLayout.outboxRing);
    _setIncoming(outbox, due.length);
    final missed = <int>{};
    var added = false;
    for (final i in due) {
      final Map<String, dynamic>? j;
      try {
        j = await Dht.getJson(key, 1 + i % RoomLayout.outboxRing);
      } on VeilidAPIException catch (e) {
        debugPrint('outbox ${e.runtimeType} at #$i, retrying later');
        missed.add(i);
        continue;
      }
      // Not propagated to the replica we asked yet: try again next sync.
      if (j == null) {
        missed.add(i);
        continue;
      }
      final ChatMessage msg;
      try {
        msg = ChatMessage.fromWire(outbox, j);
      } on FormatException {
        continue; // a type from a newer app version
      }
      final seq = msg.seq;
      if (seq == null) continue; // malformed: nothing to wait for
      if (seq < i) {
        missed.add(i); // still the previous lap's message: not propagated yet
        continue;
      }
      if (seq > i) continue; // slot already reused by a newer message
      if (msg.type == MsgType.reaction) {
        if (_ids.add(msg.id) && reactions.apply(msg)) {
          notifyListeners();
          _scheduleSave();
        }
        continue;
      }
      if (msg.type.hidden) {
        if (_ids.add(msg.id)) app?.onHiddenMessage(this, msg);
        continue;
      }
      added |= _insert(msg);
    }
    final hadMissing = cursor.missing.isNotEmpty;
    cursor.settle(count, due, missed);
    _setIncoming(outbox, cursor.missing.length);
    if (cursor.missing.isNotEmpty || hadMissing) _scheduleSave();
    if (cursor.missing.isNotEmpty) {
      // Slots the head announced but our replica does not have yet.
      _retrySoon(outbox, key);
    } else if (expectNew && update == null && fresh == Freshness.same) {
      // Notified, but the head we read was not newer: lagging replica.
      _retrySoon(outbox, key);
    } else if (fresh == Freshness.newer || added) {
      _backoff.reset(outbox);
    }
    if (added) {
      notifyListeners();
      _scheduleSave();
    }
  }

  /// A member's head was read: update who is typing.
  void _noteTyping(String outbox, Map<String, dynamic> head) {
    if (_typing.note(outbox, head['ty'])) _typingChanged();
  }

  /// Redraws now and again when the next typing stamp runs out.
  void _typingChanged() {
    notifyListeners();
    _typingTimer?.cancel();
    final next = _typing.nextExpiry(DateTime.now().millisecondsSinceEpoch);
    if (next != null && !_closed) {
      _typingTimer = Timer(next + const Duration(milliseconds: 50), () {
        if (!_closed) _typingChanged();
      });
    }
  }

  /// The composer's text changed. With [shareTyping] on, stamps our head
  /// at the start of typing and at most every 8 s after (never per
  /// keystroke, never on focus alone). Serialized with sends, so the head's
  /// message count can never go backwards.
  void userTyping() {
    if (!_shareTyping || !_connected || _closed) return;
    if (!_typingThrottle.shouldSend(DateTime.now().millisecondsSinceEpoch)) {
      return;
    }
    final job = _sendChain.then(
      (_) => Dht.setJsonSoon(
        _outboxKey,
        0,
        _head(_myCount, ty: DateTime.now().millisecondsSinceEpoch),
      ),
    );
    _sendChain = job.catchError((Object e) => debugPrint('typing: $e'));
  }

  void setShareTyping(bool on) {
    if (_shareTyping == on) return;
    _shareTyping = on;
    _typingThrottle.reset();
    notifyListeners();
    _scheduleSave();
  }

  bool _insert(ChatMessage m) {
    if (m.author != myOutbox && _typing.messageFrom(m.author)) {
      _typingChanged();
    }
    if (!_ids.add(m.id)) return false;
    var i = messages.length;
    while (i > 0 && messages[i - 1].ts > m.ts) {
      i--;
    }
    messages.insert(i, m);
    return true;
  }

  // ----------------------------------------------------------------- send

  Future<void> sendText(String text, {ChatMessage? replyTo}) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final msg = _newMessage(MsgType.text, text: t, replyTo: replyTo);
    await _enqueue(msg, () async => null);
  }

  /// The loaded message with [id], if it is still here (it may have left
  /// the outbox ring or the cache, or predate our joining).
  ChatMessage? messageById(String id) =>
      messages.where((m) => m.id == id).firstOrNull;

  /// Sends an image, video or voice note from a local file.
  Future<void> sendFile(
    File file,
    MsgType type, {
    int? width,
    int? height,
    int? durationMs,
    ChatMessage? replyTo,
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
    var msg = _newMessage(type, media: placeholder, replyTo: replyTo);
    final id = msg.id;
    final reply = msg.replyTo;

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
        replyTo: reply,
      );
      if (idx >= 0) messages[idx] = msg;
      return msg;
    });
  }

  ChatMessage _newMessage(
    MsgType type, {
    String? text,
    MediaRef? media,
    ChatMessage? replyTo,
  }) => ChatMessage(
    id: _uuid.v4(),
    author: myOutbox,
    ts: DateTime.now().millisecondsSinceEpoch,
    type: type,
    text: text,
    media: media,
    status: MsgStatus.sending,
    replyTo: replyTo == null ? null : ReplyRef.of(replyTo),
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
    _typingThrottle.reset(); // the head has no `ty` any more
    _myCount = seq + 1;
  }

  /// Outbox head. Public rooms point to the global profile (`p`) and keep a
  /// name as fallback; private rooms carry the full per-room profile.
  Map<String, dynamic> _head(int count, {int? ty}) => isPublic
      ? {
          'name': app!.myGlobal.name,
          'p': app!.myProfileKey,
          'nick': ?myNick,
          'av': ?myRoomAvatar?.toJson(),
          'count': count,
          'ty': ?ty,
        }
      : {...myProfile.toJson(), 'count': count, 'ty': ?ty};

  static String? _cleanNick(Object? raw) => cleanNick(raw, max: maxNickLength);

  /// Sets (or with null/blank clears) our nickname in this public room. It
  /// replaces the global name here only; picture and status stay global.
  Future<void> setNick(String? nick) async {
    if (!isPublic) {
      throw StateError('private rooms have their own per-room profile');
    }
    final clean = _cleanNick(nick);
    if (clean == myNick) return;
    if (clean == null) {
      _nicks.remove(myOutbox);
    } else {
      _nicks[myOutbox] = clean;
    }
    notifyListeners();
    _scheduleSave();
    final job = _sendChain.then(
      (_) => Dht.setJsonSoon(_outboxKey, 0, _head(_myCount)),
    );
    _sendChain = job.catchError((Object e) => debugPrint('nick: $e'));
    await job;
  }

  /// Sets our picture for this public room only ([file] null = back to the
  /// global picture). Like a nickname: everyone here sees it, nobody
  /// elsewhere. The image is uploaded like any avatar (encrypted blob).
  Future<void> setRoomAvatar(File? file) async {
    if (!isPublic) {
      throw StateError('private rooms have their own per-room profile');
    }
    if (file == null && myRoomAvatar == null) return;
    final ref = file == null ? null : await _uploadImage(file, ImageUse.avatar);
    if (ref == null) {
      _roomAvatars.remove(myOutbox);
    } else {
      _roomAvatars[myOutbox] = ref;
    }
    notifyListeners();
    _scheduleSave();
    final job = _sendChain.then(
      (_) => Dht.setJsonSoon(_outboxKey, 0, _head(_myCount)),
    );
    _sendChain = job.catchError((Object e) => debugPrint('room avatar: $e'));
    await job;
  }

  // ------------------------------------------------------------ reactions

  /// Reactions with the room's custom emoji, from everyone's outboxes.
  final reactions = Reactions();

  /// Our reaction choices not sent yet (target id -> code, null = none),
  /// shown at once and sent after [reactDebounce].
  final _pendingReactions = <String, String?>{};
  final _reactTimers = <String, Timer>{};

  /// Every reaction takes a slot in our 200-message outbox ring, so changes
  /// made within this time go out as one.
  static const reactDebounce = Duration(seconds: 3);

  /// Our current reaction to [target] (including one not sent yet).
  String? myReaction(String target) => _pendingReactions.containsKey(target)
      ? _pendingReactions[target]
      : reactions.mine(target, myOutbox);

  /// Reactions to [target] as shown: only emoji the room still has, ours
  /// already updated with a choice that is not sent yet.
  List<(String code, List<String> authors)> reactionsOf(String target) {
    bool known(String c) => meta.emoji.containsKey(c);
    final list = reactions.of(target, show: known);
    if (!_pendingReactions.containsKey(target)) return list;
    final pending = _pendingReactions[target];
    final out = <String, List<String>>{
      for (final (c, a) in list) c: [...a.where((x) => x != myOutbox)],
    };
    if (pending != null && known(pending)) {
      out.putIfAbsent(pending, () => []).add(myOutbox);
    }
    return [
      for (final e in out.entries)
        if (e.value.isNotEmpty) (e.key, e.value),
    ]..sort((a, b) => b.$2.length.compareTo(a.$2.length));
  }

  /// Reacts to [target] with [code]; choosing our current reaction again
  /// takes it back (Messenger style). Shown at once, sent after a short
  /// pause so quick changes cost one outbox slot.
  void react(ChatMessage target, String code) {
    if (target.type.hidden || _closed) return;
    final next = myReaction(target.id) == code ? null : code;
    _pendingReactions[target.id] = next;
    notifyListeners();
    _reactTimers[target.id]?.cancel();
    _reactTimers[target.id] = Timer(reactDebounce, () {
      _reactTimers.remove(target.id);
      unawaited(_sendReaction(target.id));
    });
  }

  Future<void> _sendReaction(String target) async {
    if (!_pendingReactions.containsKey(target)) return;
    final code = _pendingReactions[target];
    // Nothing to send if it ends where it started.
    if (code == reactions.mine(target, myOutbox)) {
      _pendingReactions.remove(target);
      notifyListeners();
      return;
    }
    final msg = ChatMessage(
      id: _uuid.v4(),
      author: myOutbox,
      ts: DateTime.now().millisecondsSinceEpoch,
      type: MsgType.reaction,
      extra: {'to': target, 'e': code},
      status: MsgStatus.sending,
    );
    _ids.add(msg.id);
    final job = _sendChain.then((_) async {
      await _append(msg); // assigns msg.seq
      reactions.apply(msg);
      if (_pendingReactions[target] == code) _pendingReactions.remove(target);
      if (!_disposed) notifyListeners();
      _scheduleSave();
    });
    _sendChain = job.catchError((Object e) => debugPrint('reaction: $e'));
    await _sendChain;
  }

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
      case MsgType.reaction:
        return 'text/plain';
    }
  }

  // ---------------------------------------------------------------- cache

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), _saveCache);
  }

  /// Writes the local cache now (before a migration export reads it).
  Future<void> flush() async {
    _saveTimer?.cancel();
    await _saveCache();
  }

  Future<void> _saveCache() async {
    final keep = messages.length > 3000
        ? messages.sublist(messages.length - 3000)
        : messages;
    final json = jsonEncode({
      'meta': meta.toJson(),
      'profiles': {for (final e in profiles.entries) e.key: e.value.toJson()},
      'nicks': _nicks,
      'roomAvatars': {
        for (final e in _roomAvatars.entries) e.key: e.value.toJson(),
      },
      'lastSeen': {for (final e in _cursors.entries) e.key: e.value.toJson()},
      'myCount': _myCount,
      if (_shareTyping) 'shareTyping': true,
      'messages': [for (final m in keep) m.toCache()],
      'reactions': (reactions..prune({for (final m in keep) m.id})).toJson(),
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
      final nicks = j['nicks'];
      if (nicks is Map) {
        for (final e in nicks.entries) {
          if (e.key is String && e.value is String) {
            _nicks[e.key as String] = e.value as String;
          }
        }
      }
      final avatars = j['roomAvatars'];
      if (avatars is Map) {
        for (final e in avatars.entries) {
          final ref = _parseAvatar(e.value);
          if (e.key is String && ref != null) {
            _roomAvatars[e.key as String] = ref;
          }
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
      for (final e in (j['lastSeen'] as Map).entries) {
        _cursors[e.key as String] = OutboxCursor.fromJson(e.value);
      }
      _myCount = j['myCount'] as int? ?? 0;
      _shareTyping = j['shareTyping'] == true;
      for (final m in (j['messages'] as List).cast<Map<String, dynamic>>()) {
        _insert(ChatMessage.fromCache(m));
      }
      reactions.loadJson(j['reactions']);
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
