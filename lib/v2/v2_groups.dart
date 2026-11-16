// Experimental v2 groups (docs/V2_PLAN.md phase 2): each group is one
// CoreSession (its own MLS identity, unlinkable to the global profile),
// driven over the DHT by CoreHost. The state lives in the app's encrypted
// data under the app PIN, so moving to a new phone carries it along.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:p2pc_core/p2pc_core.dart';

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

class V2Message {
  V2Message({
    required this.from,
    required this.text,
    required this.ts,
    this.mine = false,
  });
  final String from; // sender's CIK hex
  final String text;
  final int ts; // ms since epoch: when sent (mine) or received
  final bool mine;

  Map<String, dynamic> toJson() => {
    'f': from,
    't': text,
    'ts': ts,
    if (mine) 'm': true,
  };

  static V2Message fromJson(Map<String, dynamic> j) => V2Message(
    from: j['f'] as String,
    text: j['t'] as String,
    ts: j['ts'] as int,
    mine: j['m'] == true,
  );
}

class V2Group {
  V2Group({
    required this.id,
    required this.name,
    required this.state,
    this.joinInvite,
    List<String>? openInvites,
    this.inboxSeen = 0,
    List<V2Message>? messages,
  }) : openInvites = openInvites ?? [],
       messages = messages ?? [];

  final String id;
  String name;
  Uint8List state;

  /// Set while our join request waits for the admin to let us in.
  String? joinInvite;

  /// Admin: rendezvous records of invites handed out and not used yet.
  final List<String> openInvites;
  int inboxSeen;
  final List<V2Message> messages;

  /// Last problem seen while syncing (not stored).
  String? problem;

  bool get joining => joinInvite != null;

  static const maxMessages = 1000;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'state': base64.encode(state),
    'join': ?joinInvite,
    'invites': openInvites,
    'seen': inboxSeen,
    'msgs': [for (final m in messages) m.toJson()],
  };

  static V2Group fromJson(Map<String, dynamic> j) => V2Group(
    id: j['id'] as String,
    name: j['name'] as String,
    state: base64.decode(j['state'] as String),
    joinInvite: j['join'] as String?,
    openInvites: ((j['invites'] as List?) ?? const []).cast<String>().toList(),
    inboxSeen: j['seen'] as int? ?? 0,
    messages: [
      for (final m in (j['msgs'] as List?) ?? const [])
        V2Message.fromJson((m as Map).cast()),
    ],
  );
}

class V2Groups extends ChangeNotifier {
  V2Groups(CoreDht dht, {required Future<void> Function() save})
    : _save = save,
      _host = CoreHost(dht);

  final CoreHost _host;
  final Future<void> Function() _save;

  final List<V2Group> groups = [];
  final _sessions = <String, CoreSession>{};
  Timer? _timer;
  Future<void> _queue = Future.value();
  bool _closed = false;
  bool _syncing = false;

  // ------------------------------------------------------------- lifecycle

  void load(List<dynamic>? json) {
    for (final raw in json ?? const []) {
      try {
        final g = V2Group.fromJson((raw as Map).cast());
        final s = CoreSession.restore(g.state);
        if (s == null) {
          debugPrint('[v2] group state could not be restored');
          continue;
        }
        groups.add(g);
        _sessions[g.id] = s;
      } on Object catch (e) {
        debugPrint('[v2] bad group entry: $e');
      }
    }
  }

  List<Map<String, dynamic>> toJson() => [for (final g in groups) g.toJson()];

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
    for (final s in _sessions.values) {
      s.close();
    }
    _sessions.clear();
  }

  // ------------------------------------------------------------- reading

  V2Group? byId(String id) => groups.where((g) => g.id == id).firstOrNull;

  Map<String, dynamic> info(V2Group g) =>
      _sessions[g.id]?.info(since: 1 << 30) ?? const {};

  String myCik(V2Group g) => info(g)['cik'] as String? ?? '';

  bool isAdmin(V2Group g) => info(g)['is_admin'] == true;

  /// Who wrote [m], as people see it.
  String senderLabel(V2Group g, V2Message m) =>
      m.mine ? 'Ty' : 'Członek ${m.from.substring(0, min(6, m.from.length))}';

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

  Future<V2Group> create(String name) => _serial(() async {
    final s = CoreSession.create('me');
    final g = V2Group(id: _newId(), name: name.trim(), state: s.save());
    _sessions[g.id] = s;
    groups.add(g);
    try {
      await _run(g, {'op': 'create_group'});
    } on Object {
      groups.remove(g);
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
  Future<V2Group> join(V2Invite invite, String name) => _serial(() async {
    final s = CoreSession.create('me');
    final g = V2Group(
      id: _newId(),
      name: name.trim(),
      state: s.save(),
      joinInvite: invite.code,
    );
    _sessions[g.id] = s;
    groups.add(g);
    try {
      await _run(g, {
        'op': 'request_join',
        'invite': invite.code,
        'verified_admin': invite.adminCik,
      });
    } on Object {
      groups.remove(g);
      _sessions.remove(g.id)?.close();
      rethrow;
    }
    await _save();
    notifyListeners();
    return g;
  });

  Future<void> send(V2Group g, String text) => _serial(() async {
    await _run(g, {'op': 'send_text', 'text': text});
    _add(
      g,
      V2Message(
        from: myCik(g),
        text: text,
        ts: DateTime.now().millisecondsSinceEpoch,
        mine: true,
      ),
    );
    await _save();
    notifyListeners();
  });

  Future<void> leave(V2Group g) => _serial(() async {
    groups.remove(g);
    _sessions.remove(g.id)?.close();
    await _save();
    notifyListeners();
  });

  void _add(V2Group g, V2Message m) {
    g.messages.add(m);
    if (g.messages.length > V2Group.maxMessages) {
      g.messages.removeRange(0, g.messages.length - V2Group.maxMessages);
    }
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
      if (g.joining) {
        final done = await _run(g, {
          'op': 'complete_join',
          'invite': g.joinInvite,
        });
        if (done != true) return;
        g.joinInvite = null;
        await _save();
      }
      await _run(g, {'op': 'sync'});
      if (isAdmin(g)) await _admit(g);
      final before = g.messages.length;
      _pull(g);
      if (g.messages.length != before) await _save();
      g.problem = null;
    } on Object catch (e) {
      g.problem = '$e';
      debugPrint('[v2] sync: $e');
    } finally {
      notifyListeners();
    }
  });

  Future<void> _admit(V2Group g) async {
    for (final rv in g.openInvites.toList()) {
      try {
        await _run(g, {'op': 'stage_add', 'rendezvous': rv});
      } on CoreError catch (e) {
        final waiting =
            e.message.contains('no join request yet') ||
            e.message.contains('join request incomplete');
        if (waiting) continue;
        // Used, unknown or a bad request: that invite is spent.
        debugPrint('[v2] invite dropped: ${e.message}');
        g.openInvites.remove(rv);
        await _save();
        continue;
      }
      g.openInvites.remove(rv);
      await _save();
      await _run(g, {'op': 'publish_pending'});
    }
    if (info(g)['has_pending'] == true) {
      await _run(g, {'op': 'publish_pending'});
    }
  }

  void _pull(V2Group g) {
    final s = _sessions[g.id];
    if (s == null) return;
    final i = s.info(since: g.inboxSeen);
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final m in (i['inbox'] as List).cast<Map<String, dynamic>>()) {
      _add(
        g,
        V2Message(
          from: m['from'] as String,
          text: m['text'] as String,
          ts: now,
        ),
      );
    }
    g.inboxSeen = i['inbox_len'] as int;
  }
}
