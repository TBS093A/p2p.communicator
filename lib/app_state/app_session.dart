import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:veilid/veilid.dart';

import '../core/crypto.dart';
import '../core/image_prep.dart';
import '../core/media_cache.dart';
import '../room/blob_store.dart';
import '../room/dht.dart';
import '../room/invite.dart';
import '../room/message.dart';
import '../room/room_protocol.dart';
import '../room/room_session.dart';
import '../vault/pin_vault.dart';
import '../vault/room_secrets.dart';
import 'app_link.dart';
import 'global_profile.dart';
import 'profile_directory.dart';

/// A public room on the home list.
class PublicRoom {
  PublicRoom(this.session, {this.peer});
  final RoomSession session;

  /// For a DM: the other person's global profile key.
  final String? peer;

  RoomKind get kind => session.kind;
}

/// A DM invite that arrived for us, waiting for accept/decline.
class PendingInvite {
  PendingInvite(this.id, this.fromKey, this.invite);
  final String id;
  final String fromKey;
  final Invite invite;
}

/// The unlocked app (after the app PIN): our identity and global profile,
/// presence heartbeat, every public room kept open and synced, and DM
/// invites. Locking the app closes all of it.
class AppSession extends ChangeNotifier implements AppLink, MediaSource {
  AppSession._(this._unlocked, this._identity, this._profileKey);

  static const _inviteContext = 'p2pc-dm-invite-v1';

  final UnlockedApp _unlocked;
  final KeyPair _identity;
  final String _profileKey;
  late final RecordKey _profileRecord = RecordKey.fromString(_profileKey);
  late final MediaCache _media;

  @override
  late final ProfileDirectory directory = ProfileDirectory(myKey: _profileKey);

  late GlobalProfile _me;
  final List<PublicRoom> rooms = [];
  final List<PendingInvite> pendingInvites = [];
  final Set<String> _handledInvites = {};
  Timer? _heartbeat;
  Timer? _saveTimer;
  bool _closed = false;

  @override
  String get myProfileKey => _profileKey;
  @override
  GlobalProfile get myGlobal => _me;

  // ------------------------------------------------------------ lifecycle

  /// First run: creates the identity and global profile, stores them under
  /// the app PIN, and opens the app.
  static Future<AppSession> setUp({
    required String pin,
    required String name,
  }) async {
    final identity = await Crypto.newIdentity();
    final record = await Dht.rc.createDHTRecord(
      bestCryptoKind,
      const DHTSchema.dflt(oCnt: 1),
      owner: identity,
    );
    final profile = GlobalProfile(
      name: name.trim(),
      identity: identity.key.toString(),
      seen: DateTime.now().millisecondsSinceEpoch,
    );
    await Dht.setJsonSoon(record.key, 0, profile.toJson());
    final unlocked = await PinVault.instance.createApp(pin, {
      'v': 1,
      'identity': identity.toString(),
      'profileKey': record.key.toString(),
    });
    final app = AppSession._(unlocked, identity, record.key.toString());
    await app._open(initialProfile: profile);
    return app;
  }

  /// Opens the app with its PIN, or null for a wrong PIN.
  static Future<AppSession?> unlock(String pin) async {
    final unlocked = await PinVault.instance.unlockApp(pin);
    if (unlocked == null) return null;
    final p = unlocked.payload;
    final app = AppSession._(
      unlocked,
      KeyPair.fromString(p['identity'] as String),
      p['profileKey'] as String,
    );
    await app._open();
    return app;
  }

  Future<void> _open({GlobalProfile? initialProfile}) async {
    _media = await MediaCache.open(_unlocked);
    final data = await _loadData();
    _me =
        initialProfile ??
        (data['me'] is Map
            ? GlobalProfile.fromJson((data['me'] as Map).cast())
            : GlobalProfile(name: '?', identity: _identity.key.toString()));
    _handledInvites.addAll(
      ((data['handled'] as List?) ?? const []).cast<String>(),
    );

    directory
      ..setMine(_me)
      ..start();
    for (final raw in ((data['rooms'] as List?) ?? const [])) {
      final j = (raw as Map).cast<String, dynamic>();
      await _openRoom(
        RoomSecrets.fromJson((j['secrets'] as Map).cast()),
        peer: j['peer'] as String?,
      );
    }
    unawaited(_connectProfile());
    _heartbeat = Timer.periodic(GlobalProfile.heartbeat, (_) => _beat());
  }

  Future<void> _connectProfile() async {
    try {
      await Dht.retry(
        () => Dht.rc.openDHTRecord(_profileRecord, writer: _identity),
      );
      // Reinstall/new phone: take the network copy if we have none locally.
      final remote = await Dht.getJson(_profileRecord, 0);
      if (remote != null && _me.name == '?') {
        _me = GlobalProfile.fromJson(remote);
        directory.setMine(_me);
        notifyListeners();
      }
      await _beat();
    } on Object catch (e) {
      debugPrint('[app] profile record unavailable: $e');
    }
  }

  /// Presence heartbeat. Invisible means no heartbeats at all, so others
  /// see us as offline.
  Future<void> _beat() async {
    if (_closed || _me.status == UserStatus.invisible) return;
    _me = _me.copyWith(seen: DateTime.now().millisecondsSinceEpoch);
    directory.setMine(_me);
    await Dht.setJsonSoon(_profileRecord, 0, _me.toJson());
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _heartbeat?.cancel();
    _saveTimer?.cancel();
    await _save();
    for (final r in rooms) {
      await r.session.close();
    }
    await directory.close();
    await Dht.close(_profileRecord);
    await _media.close();
  }

  // ---------------------------------------------------------------- rooms

  List<PublicRoom> roomsOf(RoomKind kind) =>
      rooms.where((r) => r.kind == kind).toList()
        ..sort((a, b) => _lastActivity(b).compareTo(_lastActivity(a)));

  static int _lastActivity(PublicRoom r) =>
      r.session.messages.isEmpty ? 0 : r.session.messages.last.ts;

  Future<PublicRoom> _openRoom(RoomSecrets secrets, {String? peer}) async {
    final area = await PinVault.instance.publicRoomArea(_unlocked, secrets);
    final session = RoomSession(area, app: this);
    await session.open();
    session.addListener(notifyListeners);
    if (peer != null) directory.track(peer);
    final room = PublicRoom(session, peer: peer);
    rooms.add(room);
    notifyListeners();
    return room;
  }

  Future<PublicRoom> createRoom({
    required RoomKind kind,
    required String name,
    String? peer,
  }) async {
    assert(kind.isPublic);
    final secrets = await RoomProtocol.create(
      roomName: name.trim(),
      myName: _me.name,
      kind: kind,
      profileKey: _profileKey,
    );
    final room = await _openRoom(secrets, peer: peer);
    await _save();
    return room;
  }

  Future<PublicRoom> joinRoom(Invite invite, {String? peer}) async {
    final existing = rooms
        .where((r) => r.session.room.secrets.rosterKey == invite.rosterKey)
        .firstOrNull;
    if (existing != null) return existing;
    final secrets = await RoomProtocol.join(
      invite: invite,
      myName: _me.name,
      profileKey: _profileKey,
    );
    final room = await _openRoom(secrets, peer: peer);
    await _save();
    return room;
  }

  Future<void> leave(PublicRoom room) async {
    rooms.remove(room);
    room.session.removeListener(notifyListeners);
    await room.session.close();
    await _save();
    notifyListeners();
  }

  /// The DM with [peer], if we have one.
  PublicRoom? dmWith(String peer) => rooms
      .where((r) => r.kind == RoomKind.dm && peerKeyOf(r) == peer)
      .firstOrNull;

  /// The other person in a DM: known from the invite, or (for a DM started
  /// with a QR code) whoever joined it.
  String? peerKeyOf(PublicRoom room) {
    if (room.kind != RoomKind.dm) return null;
    if (room.peer != null) return room.peer;
    final s = room.session;
    for (final o in s.memberOutboxes) {
      if (o == s.myOutbox) continue;
      final k = s.profileKeyOf(o);
      if (k != null) return k;
    }
    return null;
  }

  GlobalProfile? peerOf(RoomSession session) {
    final room = rooms.where((r) => r.session == session).firstOrNull;
    final key = room == null ? null : peerKeyOf(room);
    return key == null ? null : directory[key];
  }

  // -------------------------------------------------------------- profile

  @override
  Future<void> updateGlobalProfile({
    String? name,
    File? avatar,
    bool clearAvatar = false,
    int? color,
    bool clearColor = false,
    UserStatus? status,
  }) async {
    MediaRef? ref;
    if (avatar != null) {
      final prepared = await ImagePrep.prepare(
        await avatar.readAsBytes(),
        ImageUse.avatar,
      );
      ref = await BlobStore.upload(prepared.bytes, mime: prepared.mime);
      await _media.store(ref.hash, prepared.bytes);
    }
    _me = _me.copyWith(
      name: name?.trim().isEmpty == true ? null : name?.trim(),
      avatar: ref,
      clearAvatar: clearAvatar,
      color: color,
      clearColor: clearColor,
      status: status,
      seen: DateTime.now().millisecondsSinceEpoch,
    );
    directory.setMine(_me);
    notifyListeners();
    _scheduleSave();
    await Dht.setJsonSoon(_profileRecord, 0, _me.toJson());
  }

  Future<void> setStatus(UserStatus status) =>
      updateGlobalProfile(status: status);

  @override
  Future<File> mediaFile(String id, MediaRef ref) => _media.file(ref);

  // ----------------------------------------------------------- DM invites

  /// Opens (or starts) a DM with [peer]. A new DM's invite is sealed to the
  /// peer's identity key and dropped into a group we share with them, as a
  /// hidden message: every member tries to open it, only [peer] can, and
  /// nobody else learns who invited whom.
  Future<PublicRoom> startDm(String peer) async {
    final existing = dmWith(peer);
    if (existing != null) return existing;
    final them = directory[peer];
    if (them == null || them.identity.isEmpty) {
      throw StateError('Profil tej osoby jeszcze się nie wczytał');
    }
    final via = rooms
        .where(
          (r) =>
              r.kind == RoomKind.group &&
              r.session.memberOutboxes.any(
                (o) => r.session.profileKeyOf(o) == peer,
              ),
        )
        .firstOrNull;
    if (via == null) {
      throw StateError('Nie macie wspólnej grupy, przez którą można zaprosić');
    }

    final dm = await createRoom(
      kind: RoomKind.dm,
      name: '${_me.name} & ${them.name}',
      peer: peer,
    );
    final payload = utf8.encode(
      jsonEncode({'invite': dm.session.invite.encode(), 'from': _profileKey}),
    );
    final sealed = await Crypto.sealTo(
      PublicKey.fromString(them.identity),
      Uint8List.fromList(payload),
      context: _inviteContext,
    );
    await via.session.sendHidden(MsgType.dmInvite, {
      's': base64Url.encode(sealed),
    });
    return dm;
  }

  @override
  void onHiddenMessage(RoomSession room, ChatMessage message) {
    if (message.type != MsgType.dmInvite) return;
    if (_handledInvites.contains(message.id)) return;
    unawaited(_tryInvite(message));
  }

  Future<void> _tryInvite(ChatMessage message) async {
    final sealed = message.extra?['s'];
    if (sealed is! String) return;
    try {
      final plain = await Crypto.openWith(
        _identity,
        base64Url.decode(sealed),
        context: _inviteContext,
      );
      final j = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      final invite = Invite.tryParse(j['invite'] as String? ?? '');
      final from = j['from'] as String?;
      if (invite == null || from == null) return;
      if (rooms.any(
        (r) => r.session.room.secrets.rosterKey == invite.rosterKey,
      )) {
        _markHandled(message.id);
        return;
      }
      if (pendingInvites.any((p) => p.id == message.id)) return;
      directory.track(from);
      pendingInvites.add(PendingInvite(message.id, from, invite));
      notifyListeners();
    } on Object {
      // Sealed to someone else: that is the normal case, stay silent.
    }
  }

  Future<PublicRoom> acceptInvite(PendingInvite p) async {
    pendingInvites.remove(p);
    _markHandled(p.id);
    notifyListeners();
    return joinRoom(p.invite, peer: p.fromKey);
  }

  void declineInvite(PendingInvite p) {
    pendingInvites.remove(p);
    _markHandled(p.id);
    notifyListeners();
  }

  void _markHandled(String id) {
    _handledInvites.add(id);
    _scheduleSave();
  }

  // ------------------------------------------------------------- storage

  Future<Map<String, dynamic>> _loadData() async {
    final data = await PinVault.instance.readData(_unlocked);
    if (data == null) return {};
    try {
      return jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
    } on Object {
      return {};
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), _save);
  }

  Future<void> _save() async {
    final json = jsonEncode({
      'me': _me.toJson(),
      'rooms': [
        for (final r in rooms)
          {'secrets': r.session.room.secrets.toJson(), 'peer': ?r.peer},
      ],
      'handled': _handledInvites.toList(),
    });
    await PinVault.instance.writeData(_unlocked, utf8.encode(json));
  }
}
