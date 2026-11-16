// Experimental v2 groups (docs/V2_PLAN.md phase 2): each group is one
// CoreSession (its own MLS identity, unlinkable to the global profile),
// driven over the DHT by CoreHost, and shown through a V2RoomSession in the
// regular chat screen. The core state lives in the app's encrypted data and
// the conversation in an encrypted room cache, both under the app PIN.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:p2pc_core/p2pc_core.dart';

import '../room/message.dart';
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
    List<String>? openInvites,
    this.inboxSeen = 0,
    this.metaTs = 0,
    this.membersSeen = 0,
    this.legacy,
    this.keysAt = 0,
    this.sentSinceKeys = 0,
  }) : openInvites = openInvites ?? [];

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
    'invites': openInvites,
    'seen': inboxSeen,
    'metaTs': metaTs,
    'members': membersSeen,
    'keysAt': keysAt,
    'sentSinceKeys': sentSinceKeys,
  };

  static V2Group fromJson(Map<String, dynamic> j) => V2Group(
    id: j['id'] as String,
    name: j['name'] as String,
    me: j['me'] as String? ?? 'Ja',
    state: base64.decode(j['state'] as String),
    joinInvite: j['join'] as String?,
    openInvites: ((j['invites'] as List?) ?? const []).cast<String>().toList(),
    inboxSeen: j['seen'] as int? ?? 0,
    metaTs: j['metaTs'] as int? ?? 0,
    membersSeen: j['members'] as int? ?? 0,
    keysAt: j['keysAt'] as int? ?? 0,
    sentSinceKeys: j['sentSinceKeys'] as int? ?? 0,
    legacy: (j['msgs'] as List?)
        ?.map((m) => (m as Map).cast<String, dynamic>())
        .toList(),
  );
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
  }) : _save = save,
       _openRoom = openRoom,
       clock = clock ?? _wallClock,
       _dht = dht,
       _host = CoreHost(dht);

  final CoreDht _dht;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  /// Milliseconds since the epoch (tests move it forward).
  final int Function() clock;

  final CoreHost _host;
  final Future<void> Function() _save;
  final V2RoomOpener _openRoom;

  final List<V2Group> groups = [];
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
        );
        _sessions[g.id] = s;
        try {
          await _run(g, {
            'op': 'request_join',
            'invite': invite.code,
            'verified_admin': invite.adminCik,
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

  Future<void> leave(V2Group g) => _serial(() async {
    groups.remove(g);
    final room = _rooms.remove(g.id);
    if (room != null) {
      room.removeListener(notifyListeners);
      await room.close();
    }
    _sessions.remove(g.id)?.close();
    await _save();
    notifyListeners();
  });

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
      if (info(g)['removed'] != true) {
        if (isAdmin(g)) {
          await _adminDuties(g);
        } else {
          await _memberDuties(g);
        }
      }
      _greetNewcomers(g);
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

  Future<void> _admit(V2Group g) async {
    for (final rv in g.openInvites.toList()) {
      try {
        await _run(g, {'op': 'stage_add', 'rendezvous': rv});
      } on CoreError catch (e) {
        final waiting =
            e.message.contains('no join request yet') ||
            e.message.contains('join request incomplete');
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
          .announce(withMeta: isAdmin(g))
          .catchError((Object e) => debugPrint('[v2] announce failed')),
    );
  }
}
