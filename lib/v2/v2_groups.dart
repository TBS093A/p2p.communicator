// Experimental v2 groups (docs/V2_PLAN.md phase 2): each group is one
// CoreSession (its own MLS identity, unlinkable to the global profile),
// driven over the DHT by CoreHost, and shown through a V2RoomSession in the
// regular chat screen. The core state lives in the app's encrypted data and
// the conversation in an encrypted room cache, both under the app PIN.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:p2pc_core/p2pc_core.dart';

import '../room/message.dart';
import '../room/room_session.dart';
import '../vault/room_secrets.dart';
import 'v2_room_session.dart';

/// The public part of a `p2pc2.` invite.
class V2Invite {
  V2Invite._(this.code, this.rendezvous, this.adminCik);
  final String code;
  final String rendezvous;
  final String adminCik;

  static V2Invite? tryParse(String raw) {
    final code = raw.trim();
    if (!code.startsWith('p2pc2.')) return null;
    try {
      final j = jsonDecode(code.substring(6));
      if (j is! Map) return null;
      final r = j['rendezvous'];
      final a = j['admin_cik'];
      if (r is! String || a is! String || r.isEmpty) return null;
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(a)) return null;
      return V2Invite._(code, r, a);
    } on FormatException {
      return null;
    }
  }
}

/// A DM invite from another member of a shared group (PROTOCOL §B10): an
/// MLS message from [from] (their key in that group), meant for us.
class V2DmOffer {
  V2DmOffer({required this.from, required this.code, required this.id});

  final String from;
  final String code;

  /// The message it came in (so it is offered once).
  final String id;

  Map<String, dynamic> toJson() => {'from': from, 'code': code, 'id': id};

  static V2DmOffer? fromJson(Object? j) {
    if (j is! Map) return null;
    final from = j['from'], code = j['code'], id = j['id'];
    if (from is! String || code is! String || id is! String) return null;
    if (V2Invite.tryParse(code) == null) return null;
    return V2DmOffer(from: from, code: code, id: id);
  }
}

/// A move to v2 announced in a v1 room (PROTOCOL §B11), with the invite
/// meant for us. Only a hint: a v1 room proves nothing about its writer,
/// so joining still needs the admin's fingerprint checked and approval.
class V1Move {
  const V1Move({
    required this.from,
    required this.name,
    required this.code,
    required this.messageId,
  });

  /// v1 outbox of whoever announced it.
  final String from;
  final String name;
  final String code;
  final String messageId;

  /// Key of the move data in a v1 text message's `x`.
  static const key = RoomSession.moveKey;

  /// Most invites in one v1 message (a v1 outbox subkey holds 32 KiB).
  static const invitesPerMessage = 20;

  /// The newest announced move with an invite for [myOutbox], if any.
  static V1Move? find(Iterable<ChatMessage> messages, String myOutbox) {
    for (final m in messages.toList().reversed) {
      if (m.type != MsgType.text || m.author == myOutbox) continue;
      final x = m.extra?[key];
      if (x is! Map) continue;
      final inv = x['inv'];
      final name = x['name'];
      if (inv is! Map) continue;
      final code = inv[myOutbox];
      if (code is! String || V2Invite.tryParse(code) == null) continue;
      return V1Move(
        from: m.author,
        name: name is String && name.trim().isNotEmpty
            ? name.trim()
            : 'Grupa v2',
        code: code,
        messageId: m.id,
      );
    }
    return null;
  }

  /// The data for one announcing message.
  static Map<String, dynamic> extra(String name, Map<String, String> inv) => {
    key: {'name': name, 'inv': inv},
  };
}

/// A join request waiting for the admin (PROTOCOL §B4 step 4): the name
/// the joiner chose and their key, to compare with them before approving.
class V2JoinRequest {
  const V2JoinRequest({
    required this.rendezvous,
    required this.cik,
    required this.name,
  });

  final String rendezvous;
  final String cik;
  final String name;
}

/// A conversation identity key for people to compare, in 16 groups of 4.
String v2Fingerprint(String cik) {
  final s = cik.toUpperCase();
  return [
    for (var i = 0; i < s.length; i += 4) s.substring(i, min(i + 4, s.length)),
  ].join(' ');
}

class V2Group {
  V2Group({
    required this.id,
    required this.name,
    required this.me,
    required this.state,
    this.joinInvite,
    this.joinedWith,
    List<String>? openInvites,
    this.inboxSeen = 0,
    this.metaTs = 0,
    this.membersSeen = 0,
    this.legacy,
    this.keysAt = 0,
    this.sentSinceKeys = 0,
    List<V2DmOffer>? dmOffers,
    this.dm = false,
    this.presence = false,
    this.presenceAt = 0,
    this.presenceSent,
    Map<String, Map<String, dynamic>>? partials,
  }) : openInvites = openInvites ?? [],
       dmOffers = dmOffers ?? [],
       partials = partials ?? {};

  /// The admin deleted this conversation for everyone (PROTOCOL §B5.5);
  /// it is deleted here at the end of the sync that read it.
  bool closedByAdmin = false;

  /// Split messages still arriving: "author|id" -> {n, p: {index: text}}
  /// (see V2RoomSession.appendMessage). Saved, so a restart loses nothing.
  final Map<String, Map<String, dynamic>> partials;

  /// A private conversation (PROTOCOL §B10): each side names it after the
  /// other person, so the room look never renames it.
  final bool dm;

  /// Opt-in (PROTOCOL §B8): show the members of this conversation, and
  /// only them, whether we are around. Off by default.
  bool presence;

  /// When we last sent our presence here (ms) and what it said.
  int presenceAt;
  String? presenceSent;

  /// DM invites other members of this group sent us (PROTOCOL §B10), not
  /// accepted or declined yet.
  final List<V2DmOffer> dmOffers;

  /// When our leaf key was last refreshed (ms), and messages sent since:
  /// PROTOCOL §B5.1 asks for an Update every 7 days or 500 messages.
  int keysAt;
  int sentSinceKeys;

  final String id;

  /// The name we gave the group when creating or joining it (the room look
  /// shared later may rename it).
  final String name;

  /// Our name in this group.
  final String me;
  Uint8List state;

  /// Set while our join request waits for the admin to let us in.
  String? joinInvite;

  /// The invite we joined with (kept after joining), so a move announced
  /// in a v1 room is not offered again.
  final String? joinedWith;

  /// Admin: rendezvous records of invites handed out and not used yet.
  final List<String> openInvites;
  int inboxSeen;

  /// Time of the room look we show (the newest one wins).
  int metaTs;

  /// Members when we last told them who we are.
  int membersSeen;

  /// Messages kept by the first v2 screens, moved into the room once.
  List<Map<String, dynamic>>? legacy;

  /// Last problem seen while syncing (not stored).
  String? problem;

  bool get joining => joinInvite != null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'me': me,
    'state': base64.encode(state),
    'join': ?joinInvite,
    'via': ?joinedWith,
    'invites': openInvites,
    'seen': inboxSeen,
    'metaTs': metaTs,
    'members': membersSeen,
    'keysAt': keysAt,
    'sentSinceKeys': sentSinceKeys,
    if (dmOffers.isNotEmpty) 'dmOffers': [for (final o in dmOffers) o.toJson()],
    if (dm) 'dm': true,
    if (presence) 'presence': true,
    if (presenceAt > 0) 'presenceAt': presenceAt,
    'presenceSent': ?presenceSent,
    if (partials.isNotEmpty) 'parts': partials,
    if (closedByAdmin) 'closed': true,
  };

  static V2Group fromJson(Map<String, dynamic> j) => V2Group(
    id: j['id'] as String,
    name: j['name'] as String,
    me: j['me'] as String? ?? 'Ja',
    state: base64.decode(j['state'] as String),
    joinInvite: j['join'] as String?,
    joinedWith: j['via'] as String?,
    openInvites: ((j['invites'] as List?) ?? const []).cast<String>().toList(),
    inboxSeen: j['seen'] as int? ?? 0,
    metaTs: j['metaTs'] as int? ?? 0,
    membersSeen: j['members'] as int? ?? 0,
    keysAt: j['keysAt'] as int? ?? 0,
    sentSinceKeys: j['sentSinceKeys'] as int? ?? 0,
    dm: j['dm'] == true,
    presence: j['presence'] == true,
    presenceAt: j['presenceAt'] as int? ?? 0,
    presenceSent: j['presenceSent'] as String?,
    partials: {
      for (final e in ((j['parts'] as Map?) ?? const {}).entries)
        if (e.key is String && e.value is Map)
          e.key as String: (e.value as Map).cast<String, dynamic>(),
    },
    dmOffers: [
      for (final o in (j['dmOffers'] as List?) ?? const [])
        ?V2DmOffer.fromJson(o),
    ],
    legacy: (j['msgs'] as List?)
        ?.map((m) => (m as Map).cast<String, dynamic>())
        .toList(),
  )..closedByAdmin = j['closed'] == true;
}

/// Opens the chat session of [group]: its encrypted cache and media live in
/// an area of the app vault named after [secrets].rosterKey.
typedef V2RoomOpener =
    Future<V2RoomSession> Function(
      V2Groups groups,
      V2Group group,
      RoomSecrets secrets,
    );

class V2Groups extends ChangeNotifier {
  V2Groups(
    CoreDht dht, {
    required Future<void> Function() save,
    required V2RoomOpener openRoom,
    int Function()? clock,
    bool Function()? appActive,
    this.private = false,
  }) : _save = save,
       _openRoom = openRoom,
       clock = clock ?? _wallClock,
       appActive = appActive ?? _appInForeground,
       _dht = dht,
       _host = CoreHost(dht);

  final CoreDht _dht;

  /// A private conversation's own instance (PROTOCOL §B11.1): one group in
  /// a password slot. DMs are not started from it or offered in it: they
  /// would live outside that slot.
  final bool private;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  static bool _appInForeground() {
    final s = WidgetsBinding.instance.lifecycleState;
    return s == null || s == AppLifecycleState.resumed;
  }

  /// Whether the user has the app open (presence says "active" then).
  final bool Function() appActive;

  /// Milliseconds since the epoch (tests move it forward).
  final int Function() clock;

  final CoreHost _host;
  final Future<void> Function() _save;
  final V2RoomOpener _openRoom;

  final List<V2Group> groups = [];

  /// Names of conversations their admin deleted for everyone since the user
  /// last looked; the screen showing the list says so once and clears it.
  final List<String> deletedByAdmin = [];

  final _sessions = <String, CoreSession>{};
  final _rooms = <String, V2RoomSession>{};
  Timer? _timer;
  Future<void> _queue = Future.value();
  bool _closed = false;
  bool _syncing = false;

  // ------------------------------------------------------------- lifecycle

  Future<void> load(List<dynamic>? json) async {
    for (final raw in json ?? const []) {
      try {
        final g = V2Group.fromJson((raw as Map).cast());
        final s = CoreSession.restore(g.state);
        if (s == null) {
          debugPrint('[v2] group state could not be restored');
          continue;
        }
        _sessions[g.id] = s;
        await _attach(g);
      } on Object catch (e) {
        debugPrint('[v2] bad group entry (${e.runtimeType})');
      }
    }
  }

  /// The conversation's room session, opened and listed.
  Future<void> _attach(V2Group g) async {
    final room = await _openRoom(this, g, secretsOf(g));
    _rooms[g.id] = room;
    room.addListener(notifyListeners);
    groups.add(g);
    final legacy = g.legacy;
    if (legacy != null) {
      room.importLegacy(legacy);
      g.legacy = null;
    }
  }

  /// What the chat session needs to know about [g]. The roster key is only
  /// a name for the vault area (v2 has no roster record).
  RoomSecrets secretsOf(V2Group g) => RoomSecrets(
    roomName: g.name,
    rosterKey: 'v2:${g.id}',
    rosterWriter: '',
    myName: g.me,
    outboxKey: myCik(g),
    outboxWriter: '',
    rosterSlot: 0,
    kind: RoomKind.private, // its own identity, no global profile
  );

  List<Map<String, dynamic>> toJson() => [for (final g in groups) g.toJson()];

  Future<void> saveState() => _save();

  /// Background sync of every group at [every].
  void start({Duration every = const Duration(seconds: 15)}) {
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => unawaited(syncAll()));
    unawaited(syncAll());
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    await _queue;
    for (final r in _rooms.values) {
      r.removeListener(notifyListeners);
      await r.close();
    }
    _rooms.clear();
    for (final s in _sessions.values) {
      s.close();
    }
    _sessions.clear();
  }

  // ------------------------------------------------------------- reading

  V2Group? byId(String id) => groups.where((g) => g.id == id).firstOrNull;

  V2RoomSession roomOf(V2Group g) => _rooms[g.id]!;

  /// Every open conversation (for moving to a new phone).
  Iterable<V2RoomSession> get rooms => _rooms.values;

  Map<String, dynamic> info(V2Group g) =>
      _sessions[g.id]?.info(since: 1 << 30) ?? const {};

  String myCik(V2Group g) => info(g)['cik'] as String? ?? '';

  bool isAdmin(V2Group g) => info(g)['is_admin'] == true;

  // ---------------------------------------------------------- operations

  /// Runs [f] after every operation queued before it: a CoreSession and the
  /// host's record pool take one round at a time.
  Future<T> _serial<T>(Future<T> Function() f) {
    final next = _queue.then((_) => f());
    _queue = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  Future<Object?> _run(V2Group g, Map<String, dynamic> op) {
    final s = _sessions[g.id];
    if (s == null || _closed) throw StateError('Grupa jest zamknięta');
    return _host.run(
      s,
      op,
      persist: (state) async {
        if (listEquals(state, g.state)) return;
        g.state = state;
        await _save();
      },
    );
  }

  static String _newId() {
    final r = Random.secure();
    return [
      for (var i = 0; i < 16; i++)
        r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  /// A new group with us as its admin; [me] is our name in it.
  Future<V2Group> create(String name, String me) => _serial(() async {
    final s = CoreSession.create('me');
    final g = V2Group(
      id: _newId(),
      name: name.trim(),
      me: me.trim(),
      state: s.save(),
      membersSeen: 1,
      keysAt: clock(), // fresh keys
    );
    _sessions[g.id] = s;
    try {
      await _run(g, {'op': 'create_group'});
      await _attach(g);
    } on Object {
      _sessions.remove(g.id)?.close();
      rethrow;
    }
    await _save();
    notifyListeners();
    return g;
  });

  /// A new one-time invite (admin only). Whoever uses it is let in on a
  /// later sync.
  Future<String> createInvite(V2Group g) => _serial(() async {
    final code = await _run(g, {'op': 'create_invite'}) as String;
    g.openInvites.add(inviteRendezvous(code));
    await _save();
    return code;
  });

  /// Asks to join with [invite]; the admin's key must have been checked
  /// against the admin's screen ([V2Invite.adminCik]).
  Future<V2Group> join(V2Invite invite, String name, String me) =>
      _serial(() async {
        final s = CoreSession.create('me');
        final g = V2Group(
          id: _newId(),
          name: name.trim(),
          me: me.trim(),
          state: s.save(),
          joinInvite: invite.code,
          joinedWith: invite.code,
        );
        _sessions[g.id] = s;
        try {
          await _run(g, {
            'op': 'request_join',
            'invite': invite.code,
            'verified_admin': invite.adminCik,
            'name': me.trim(),
          });
          await _attach(g);
        } on Object {
          _sessions.remove(g.id)?.close();
          rethrow;
        }
        await _save();
        notifyListeners();
        return g;
      });

  // ------------------------------------------------- DMs (PROTOCOL §B10)

  /// Starts a DM with [peerCik], a member of [via]: a new two-member group
  /// with our own fresh identity, whose invite goes to them inside [via]
  /// and admits only a join request they signed there (F25).
  Future<V2Group> startDm(V2Group via, String peerCik, String peerName) async {
    final dm = await _serial(() async {
      final s = CoreSession.create('me');
      final g = V2Group(
        id: _newId(),
        name: peerName.trim(),
        me: via.me,
        state: s.save(),
        membersSeen: 1,
        keysAt: clock(),
        dm: true,
      );
      _sessions[g.id] = s;
      try {
        await _run(g, {'op': 'create_group'});
        final code =
            await _run(g, {'op': 'create_invite', 'for_cik': peerCik})
                as String;
        g.openInvites.add(inviteRendezvous(code));
        await _attach(g);
        await _save();
        notifyListeners();
        return (g, code);
      } on Object {
        _sessions.remove(g.id)?.close();
        rethrow;
      }
    });
    // Outside the queue: sending goes through it.
    await roomOf(via).sendHidden(MsgType.dmInvite, {
      'v2': {'i': dm.$2, 'to': peerCik},
    });
    return dm.$1;
  }

  /// A DM invite for us arrived in [via] from [from] (MLS proved who sent
  /// it). Kept until accepted or declined.
  void offerDm(V2Group via, String from, String code, String id) {
    if (private) return;
    if (V2Invite.tryParse(code) == null) return;
    if (via.dmOffers.any((o) => o.id == id || o.code == code)) return;
    if (groups.any((g) => g.joinInvite == code)) return;
    via.dmOffers.add(V2DmOffer(from: from, code: code, id: id));
    unawaited(_save());
    notifyListeners();
  }

  /// Whether [code] was already used to join one of our groups.
  bool joinedWith(String code) =>
      groups.any((g) => g.joinedWith == code || g.joinInvite == code);

  /// Moves a v1 conversation to a new v2 group (PROTOCOL §B11): we become
  /// its admin and make one invite per other member, keyed by their v1
  /// outbox. The caller announces them in the v1 room, which is only a
  /// hint: each joiner still checks our fingerprint and we approve them.
  Future<(V2Group, Map<String, String>)> createForMove(
    String name,
    String me,
    Iterable<String> members,
  ) async {
    final g = await create(name, me);
    final invites = <String, String>{};
    for (final m in members) {
      invites[m] = await createInvite(g);
    }
    return (g, invites);
  }

  /// Every DM offer with the group it came through.
  List<(V2Group, V2DmOffer)> get dmOffers => [
    for (final g in groups)
      for (final o in g.dmOffers) (g, o),
  ];

  /// Accepts [offer]: joins the DM with a fresh identity, proving with our
  /// key in [via] that we are the member it was meant for. No fingerprint
  /// check: the invite came from [V2DmOffer.from] through [via]'s MLS.
  Future<V2Group> acceptDm(V2Group via, V2DmOffer offer) => _serial(() async {
    final invite = V2Invite.tryParse(offer.code);
    if (invite == null) throw StateError('Zaproszenie jest uszkodzone');
    final s = CoreSession.create('me');
    final newCik = s.info()['cik'] as String;
    final proof = await _run(via, {
      'op': 'sign_dm_join',
      'rendezvous': invite.rendezvous,
      'new_cik': newCik,
    });
    final g = V2Group(
      id: _newId(),
      name: roomOf(via).nameOf(offer.from),
      me: via.me,
      state: s.save(),
      joinInvite: offer.code,
      dm: true,
    );
    _sessions[g.id] = s;
    try {
      await _run(g, {
        'op': 'request_join',
        'invite': offer.code,
        'verified_admin': invite.adminCik,
        'proof': proof,
      });
      await _attach(g);
    } on Object {
      _sessions.remove(g.id)?.close();
      rethrow;
    }
    via.dmOffers.remove(offer);
    await _save();
    notifyListeners();
    return g;
  });

  Future<void> declineDm(V2Group via, V2DmOffer offer) async {
    via.dmOffers.remove(offer);
    await _save();
    notifyListeners();
  }

  /// Sends one application payload (a v1 wire message as JSON) to [g].
  Future<void> sendPayload(V2Group g, String payload) => _serial(() async {
    if (g.joining) throw StateError('Admin jeszcze cię nie wpuścił');
    await _run(g, {'op': 'send_text', 'text': payload});
    g.sentSinceKeys++;
  });

  /// Admin: removes [cik] from [g]. The group moves to a new generation
  /// (new records the removed member never learns, PROTOCOL §B5.3); the
  /// publication resumes after a restart.
  Future<void> removeMember(V2Group g, String cik) => _serial(() async {
    await _rotateIfFull(g);
    await _run(g, {'op': 'stage_remove', 'cik': cik});
    await _run(g, {'op': 'publish_pending'});
    await _save();
    notifyListeners();
  });

  /// Admin: who takes over if this phone is lost ([cik] null: nobody).
  /// The list reaches the members with an (empty) commit, which also
  /// refreshes the admin's own keys.
  Future<void> setSuccessor(V2Group g, String? cik) => _serial(() async {
    await _rotateIfFull(g);
    await _run(g, {
      'op': 'set_successors',
      'successors': [?cik],
    });
    await _run(g, {'op': 'stage_commit_proposals'});
    await _run(g, {'op': 'publish_pending'});
    g.keysAt = clock();
    g.sentSinceKeys = 0;
    await _save();
    notifyListeners();
  });

  /// Admin: hands the admin role to [cik] (PROTOCOL §B5.4). Waiting key
  /// Updates are committed first; the new admin starts the next generation
  /// when it is next online, until then membership stays as it is.
  Future<void> handOver(V2Group g, String cik) => _serial(() async {
    await _rotateIfFull(g);
    if ((info(g)['pending_proposals'] as int? ?? 0) > 0) {
      await _run(g, {'op': 'stage_commit_proposals'});
      await _run(g, {'op': 'publish_pending'});
    }
    await _run(g, {'op': 'stage_handover', 'to': cik});
    await _run(g, {'op': 'publish_pending'});
    g.openInvites.clear(); // only the admin lets people in
    await _save();
    notifyListeners();
  });

  /// The successors (CIK hex, first one takes over), as the group knows them.
  List<String> successors(V2Group g) =>
      ((info(g)['successors'] as List?) ?? const []).cast<String>();

  static const keysEvery = Duration(days: 7);
  static const keysAfterMessages = 500;

  /// A member proposes its key Update only if the admin was active within
  /// this many hours (the core's clock is in hours).
  static const adminAroundHours = 48;

  /// PROTOCOL §B8: presence goes out at most this often.
  static const presenceEvery = Duration(minutes: 15);

  /// A received "active" counts for this long (one missed update plus
  /// slack); after that nothing is shown.
  static const presenceValid = Duration(minutes: 20);

  /// Turns presence in [g] on or off. Off stops further updates; what was
  /// sent last fades out for the others after [presenceValid].
  Future<void> setPresence(V2Group g, bool on) async {
    g.presence = on;
    if (on) g.presenceAt = 0; // say so on the next sync
    await _save();
    notifyListeners();
  }

  /// On a sync, if presence is on here: "active" while the app is open
  /// (repeated every 15 minutes so it does not fade), "away" once after.
  void _sendPresence(V2Group g) {
    final room = _rooms[g.id];
    if (!g.presence || g.joining || room == null) return;
    final now = clock();
    if (now - g.presenceAt < presenceEvery.inMilliseconds) return;
    final state = appActive() ? 'active' : 'away';
    if (state == 'away' && g.presenceSent != 'active') return;
    g.presenceAt = now;
    g.presenceSent = state;
    unawaited(_save());
    unawaited(
      room
          .sendHidden(MsgType.presence, {'s': state, 'at': now})
          .catchError((Object e) => debugPrint('[v2] presence not sent')),
    );
  }

  bool _keysStale(V2Group g) =>
      clock() - g.keysAt > keysEvery.inMilliseconds ||
      g.sentSinceKeys >= keysAfterMessages;

  /// Admin: a full control log moves the group to a new generation first
  /// (PROTOCOL §B3.1); nothing else can be committed before that.
  Future<void> _rotateIfFull(V2Group g) async {
    if (info(g)['has_pending'] == true) {
      await _run(g, {'op': 'publish_pending'});
    }
    if (info(g)['needs_rotation'] == true) {
      await _run(g, {'op': 'stage_rotate'});
      await _run(g, {'op': 'publish_pending'});
    }
  }

  /// Deletes [g] from this phone: its keys, history and media. The other
  /// members still see us in it.
  Future<void> leave(V2Group g) => _serial(() => _drop(g));

  /// Admin: deletes [g] for everyone (PROTOCOL §B5.5). The members are told
  /// inside the group (only the admin's word counts) and each phone deletes
  /// it at its next sync; this phone deletes it now.
  Future<void> deleteForAll(V2Group g) async {
    if (!isAdmin(g)) {
      throw StateError('Tylko admin może usunąć rozmowę dla wszystkich');
    }
    // Outside the queue: the message itself goes through it.
    await roomOf(g).sendHidden(MsgType.closed, {'at': clock()});
    await _serial(() => _drop(g));
  }

  /// The admin deleted [g] for everyone: it goes from this phone too, and
  /// the list says so once.
  Future<void> _deletedByAdmin(V2Group g) async {
    deletedByAdmin.add(_rooms[g.id]?.meta.name ?? g.name);
    await _drop(g);
  }

  Future<void> _drop(V2Group g) async {
    if (!groups.remove(g)) return;
    final room = _rooms.remove(g.id);
    if (room != null) {
      room.removeListener(notifyListeners);
      await room.close(erase: true);
    }
    _sessions.remove(g.id)?.close();
    await _save();
    notifyListeners();
  }

  // ---------------------------------------------------------------- sync

  Future<void> syncAll() async {
    if (_syncing || _closed) return;
    _syncing = true;
    try {
      for (final g in groups.toList()) {
        if (_closed) return;
        await sync(g);
      }
    } finally {
      _syncing = false;
    }
  }

  /// One sync of [g]: finish a pending join, read what is new, let in
  /// whoever used an invite (admin), publish what is staged.
  Future<void> sync(V2Group g) => _serial(() async {
    if (_closed || !groups.contains(g)) return;
    try {
      if (g.closedByAdmin) return await _deletedByAdmin(g);
      if (g.joining) {
        final done = await _run(g, {
          'op': 'complete_join',
          'invite': g.joinInvite,
        });
        if (done != true) return;
        g.joinInvite = null;
        g.keysAt = clock(); // the leaf key from the join is fresh
        await _save();
      }
      await _run(g, {'op': 'sync'});
      _pull(g);
      if (g.closedByAdmin) return await _deletedByAdmin(g);
      if (info(g)['removed'] != true) {
        if (isAdmin(g)) {
          await _adminDuties(g);
        } else {
          await _memberDuties(g);
        }
      }
      _greetNewcomers(g);
      if (info(g)['removed'] != true) _sendPresence(g);
      g.problem = null;
    } on Object catch (e) {
      g.problem = '$e';
      debugPrint('[v2] sync failed (${e.runtimeType})');
    } finally {
      _rooms[g.id]?.refresh();
      notifyListeners();
    }
  });

  /// What the admin does on every sync: finish a publication, move to a new
  /// generation when the log is full, let in whoever used an invite, and
  /// commit the members' key Updates (or, when its own keys are due or the
  /// core asks for one after a handover, an empty commit).
  Future<void> _adminDuties(V2Group g) async {
    await _rotateIfFull(g);
    await _admit(g);
    final proposals = info(g)['pending_proposals'] as int? ?? 0;
    final due = info(g)['commit_due'] == true;
    if (proposals > 0 || due || _keysStale(g)) {
      await _run(g, {'op': 'stage_commit_proposals'});
      await _run(g, {'op': 'publish_pending'});
      g.keysAt = clock();
      g.sentSinceKeys = 0;
      await _save();
    }
  }

  /// A member: a key Update when due (the admin commits it), and the first
  /// successor's takeover once the admin has been silent for 14 days (the
  /// core decides; PROTOCOL §B5.4).
  Future<void> _memberDuties(V2Group g) async {
    // MLS sends nothing while our own Update waits for the admin's commit,
    // so only propose while the admin is around (seen in the last 2 days).
    final i = info(g);
    final adminSeen = i['last_admin_activity'] as int? ?? 0;
    final adminAround = _dht.now - adminSeen <= adminAroundHours;
    if (i['move_stable'] == true &&
        i['my_update_pending'] != true &&
        adminAround &&
        _keysStale(g)) {
      await _run(g, {'op': 'propose_update'});
      g.keysAt = clock();
      g.sentSinceKeys = 0;
      await _save();
    }
    final first = successors(g).firstOrNull;
    if (first != null && first == myCik(g)) {
      final took = await _run(g, {'op': 'try_takeover'});
      if (took == true) {
        debugPrint('[v2] took over as admin');
        await _save();
      }
    }
  }

  /// Admin: looks at the join requests on open invites (PROTOCOL §B4 step
  /// 4). In a group they wait for approval (name and key fingerprint
  /// shown); in a DM the invite is bound to one member who proved who
  /// they are (§B10), so it is let in at once.
  Future<void> _admit(V2Group g) async {
    if (g.dm) return _admitDm(g);
    final waiting = <String, V2JoinRequest>{};
    for (final rv in g.openInvites.toList()) {
      try {
        final r = await _run(g, {'op': 'peek_join', 'rendezvous': rv});
        if (r is Map && r['cik'] is String) {
          waiting[rv] = V2JoinRequest(
            rendezvous: rv,
            cik: r['cik'] as String,
            name: (r['name'] as String?) ?? '',
          );
        }
      } on CoreError {
        // Never the error text: it may quote what the joiner sent.
        debugPrint('[v2] a join request was refused or already used');
        g.openInvites.remove(rv);
        await _save();
      }
    }
    _requests[g.id] = waiting;
  }

  final _requests = <String, Map<String, V2JoinRequest>>{};

  /// Admin: join requests in [g] waiting for approval.
  List<V2JoinRequest> joinRequests(V2Group g) =>
      _requests[g.id]?.values.toList() ?? const [];

  /// Admin: lets in the request shown in [r], only if it is still the same
  /// one (anyone holding the invite can rewrite it in between).
  Future<void> approveJoin(V2Group g, V2JoinRequest r) => _serial(() async {
    await _rotateIfFull(g);
    await _run(g, {
      'op': 'stage_add',
      'rendezvous': r.rendezvous,
      'cik': r.cik,
    });
    g.openInvites.remove(r.rendezvous);
    _requests[g.id]?.remove(r.rendezvous);
    await _save();
    await _run(g, {'op': 'publish_pending'});
    await _save();
    notifyListeners();
  });

  /// Admin: refuses [r]; its invite is not used any more.
  Future<void> rejectJoin(V2Group g, V2JoinRequest r) async {
    g.openInvites.remove(r.rendezvous);
    _requests[g.id]?.remove(r.rendezvous);
    await _save();
    notifyListeners();
  }

  Future<void> _admitDm(V2Group g) async {
    for (final rv in g.openInvites.toList()) {
      try {
        await _run(g, {'op': 'stage_add', 'rendezvous': rv});
      } on CoreError catch (e) {
        // A DM invite stays open when someone else tried it (F25): the
        // member it is meant for may still come.
        final waiting =
            e.message.contains('no join request yet') ||
            e.message.contains('join request incomplete') ||
            e.message.contains('not from the invited member');
        if (waiting) continue;
        // Never the error text: it may quote what the joiner sent.
        debugPrint('[v2] a join request was refused or already used');
        g.openInvites.remove(rv);
        await _save();
        continue;
      }
      g.openInvites.remove(rv);
      await _save();
      await _run(g, {'op': 'publish_pending'});
    }
  }

  void _pull(V2Group g) {
    final s = _sessions[g.id];
    final room = _rooms[g.id];
    if (s == null || room == null) return;
    final i = s.info(since: g.inboxSeen);
    final inbox = (i['inbox'] as List).cast<Map<String, dynamic>>();
    final messages = <ChatMessage>[];
    for (final (k, m) in inbox.indexed) {
      final msg = V2RoomSession.parse(
        m['from'] as String,
        m['text'] as String,
        g.inboxSeen + k,
      );
      if (msg != null) messages.add(msg);
    }
    final seen = i['inbox_len'] as int;
    if (seen == g.inboxSeen) return;
    g.inboxSeen = seen;
    room.deliver(messages);
    unawaited(_save());
  }

  /// Someone new cannot read what was sent before they joined: everyone
  /// tells them their name again (and the admin the room look). Queued
  /// after this sync, never awaited inside it.
  void _greetNewcomers(V2Group g) {
    final members = (info(g)['members'] as List?)?.length ?? 0;
    final room = _rooms[g.id];
    if (room == null || members <= g.membersSeen) {
      if (members < g.membersSeen) g.membersSeen = members;
      return;
    }
    g.membersSeen = members;
    unawaited(_save());
    unawaited(
      room
          .announce(withMeta: isAdmin(g) && !g.dm)
          .catchError((Object e) => debugPrint('[v2] announce failed')),
    );
  }
}
