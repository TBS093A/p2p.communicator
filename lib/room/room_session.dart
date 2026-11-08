import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:veilid/veilid.dart';

import '../core/crypto.dart';
import '../core/veilid_node.dart';
import '../vault/pin_vault.dart';
import 'blob_store.dart';
import 'dht.dart';
import 'invite.dart';
import 'message.dart';
import 'room_protocol.dart';

/// One unlocked room: keeps the member outboxes watched, merges their logs
/// into [messages], sends, and keeps an encrypted local cache.
class RoomSession extends ChangeNotifier {
  RoomSession(this.room);

  final UnlockedRoom room;

  final List<ChatMessage> messages = [];
  final Map<String, String> members = {}; // outbox key -> display name
  final ValueNotifier<String?> networkError = ValueNotifier(null);

  /// Upload/download progress per message id, 0..1.
  final Map<String, double> progress = {};

  final _ids = <String>{};
  final _lastSeen = <String, int>{}; // outbox key -> messages read
  final _watched = <String, RecordKey>{}; // other members' outboxes
  final _mediaJobs = <String, Future<File>>{};
  final _uuid = const Uuid();

  late final RecordKey _rosterKey;
  late final KeyPair _rosterWriter;
  late final RecordKey _outboxKey;
  late final KeyPair _outboxWriter;
  late final SharedSecret _mediaKey;
  late final Directory _mediaDir;
  late final Directory _tmpDir;

  int _myCount = 0;
  int _pollTick = 0;
  bool _closed = false;
  bool _connected = false;
  Future<void> _sendChain = Future.value();
  Future<void>? _syncing;
  StreamSubscription<VeilidUpdate>? _sub;
  Timer? _poll;
  Timer? _saveTimer;

  String get roomName => room.secrets.roomName;
  String get myOutbox => room.secrets.outboxKey;

  String nameOf(String author) =>
      author == myOutbox ? room.secrets.myName : (members[author] ?? '?');

  Invite get invite => Invite(
    roomName: room.secrets.roomName,
    rosterKey: room.secrets.rosterKey,
    rosterWriter: room.secrets.rosterWriter,
  );

  // ------------------------------------------------------------ lifecycle

  Future<void> open() async {
    final s = room.secrets;
    _rosterKey = RecordKey.fromString(s.rosterKey);
    _rosterWriter = KeyPair.fromString(s.rosterWriter);
    _outboxKey = RecordKey.fromString(s.outboxKey);
    _outboxWriter = KeyPair.fromString(s.outboxWriter);
    _mediaKey = await Crypto.subsecret(room.key, 'media');
    _mediaDir = await PinVault.instance.mediaDir(room);
    final tmpBase = await getTemporaryDirectory();
    _tmpDir = await Directory(
      p.join(tmpBase.path, 'r${Crypto.hex(await Crypto.randomBytes(8))}'),
    ).create();

    await _loadCache();
    members[myOutbox] = s.myName;
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

        _sub = VeilidNode.instance.updates.listen(_onUpdate);
        await rc.watchDHTValues(_rosterKey);
        _connected = true;
        networkError.value = null;

        await _sync(roster: true);
        _poll = Timer.periodic(const Duration(seconds: 20), (_) {
          // Watches can lapse; a slow poll is the safety net.
          _pollTick++;
          unawaited(_sync(roster: _pollTick % 6 == 0));
        });
        return;
      } on Object catch (e) {
        networkError.value = 'Brak połączenia z siecią Veilid ($e)';
        await Future<void>.delayed(const Duration(seconds: 10));
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _poll?.cancel();
    await _sub?.cancel();
    _saveTimer?.cancel();
    await _saveCache();
    if (_connected) {
      await Dht.close(_rosterKey);
      await Dht.close(_outboxKey);
      for (final k in _watched.values) {
        await Dht.close(k);
      }
    }
    if (await _tmpDir.exists()) await _tmpDir.delete(recursive: true);
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
    final entries = <Map<String, dynamic>?>[];
    await Future.wait([
      for (var i = 1; i < RoomLayout.rosterSubkeys; i++)
        Dht.getJson(_rosterKey, i).then(entries.add),
    ]);
    for (final e in entries.whereType<Map<String, dynamic>>()) {
      final outbox = e['o'] as String?;
      if (outbox == null || outbox == myOutbox) continue;
      members.putIfAbsent(outbox, () => e['n'] as String? ?? '?');
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
    final name = head['name'] as String?;
    if (name != null) members[outbox] = name;

    var from = _lastSeen[outbox] ?? 0;
    if (count - from > RoomLayout.outboxRing) {
      from = count - RoomLayout.outboxRing; // older ones were overwritten
    }
    var added = false;
    for (var i = from; i < count; i++) {
      final j = await Dht.getJson(key, 1 + i % RoomLayout.outboxRing);
      if (j == null) continue;
      final msg = ChatMessage.fromWire(outbox, j);
      if (msg.seq != i) continue; // slot already reused by a newer message
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
    await Dht.setJson(_outboxKey, 0, {
      'count': seq + 1,
      'name': room.secrets.myName,
    });
    _myCount = seq + 1;
  }

  // ---------------------------------------------------------------- media

  /// A playable plain file for [ref], downloading it first if needed. Plain
  /// copies live in a temp folder removed when the room is locked.
  Future<File> mediaFile(String messageId, MediaRef ref) =>
      _mediaJobs[ref.hash] ??=
          () async {
            final out = File(
              p.join(_tmpDir.path, '${ref.hash}${_ext(ref.mime)}'),
            );
            if (await out.exists()) return out;
            var bytes = await _loadMedia(ref.hash);
            if (bytes == null) {
              bytes = await BlobStore.download(
                ref,
                onProgress: (v) {
                  progress[messageId] = v;
                  notifyListeners();
                },
              );
              progress.remove(messageId);
              await _storeMedia(ref.hash, bytes);
            }
            await out.writeAsBytes(bytes, flush: true);
            return out;
          }().catchError((Object e) {
            _mediaJobs.remove(ref.hash);
            progress.remove(messageId);
            throw e;
          });

  Future<void> _storeMedia(String hash, Uint8List bytes) async {
    final sealed = await Crypto.seal(_mediaKey, bytes, context: hash);
    await File(p.join(_mediaDir.path, hash)).writeAsBytes(sealed);
  }

  Future<Uint8List?> _loadMedia(String hash) async {
    final f = File(p.join(_mediaDir.path, hash));
    if (!await f.exists()) return null;
    try {
      return await Crypto.open(_mediaKey, await f.readAsBytes(), context: hash);
    } on Object {
      return null;
    }
  }

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
        return 'text/plain';
    }
  }

  static String _ext(String mime) => switch (mime) {
    'image/png' => '.png',
    'image/webp' => '.webp',
    'image/heic' => '.heic',
    'image/jpeg' => '.jpg',
    'video/quicktime' => '.mov',
    'video/3gpp' => '.3gp',
    'video/webm' => '.webm',
    'video/mp4' => '.mp4',
    'audio/mp4' => '.m4a',
    _ => '.bin',
  };

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
      'members': members,
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
      members.addAll((j['members'] as Map).cast<String, String>());
      _lastSeen.addAll((j['lastSeen'] as Map).cast<String, int>());
      _myCount = j['myCount'] as int? ?? 0;
      for (final m in (j['messages'] as List).cast<Map<String, dynamic>>()) {
        _insert(ChatMessage.fromCache(m));
      }
    } on Object catch (e) {
      debugPrint('cache unreadable, starting empty: $e');
    }
  }

  @override
  void dispose() {
    unawaited(close());
    networkError.dispose();
    super.dispose();
  }
}
