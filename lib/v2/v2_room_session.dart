// A v2 group shown in the regular chat screen: the same messages as v1
// (text, media, replies, reactions) travel as JSON inside MLS application
// messages instead of in DHT outboxes. Profiles and the room look, which v1
// keeps in outbox heads and the roster, are hidden messages here.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../room/message.dart';
import '../room/room_session.dart';
import '../room/room_style.dart';
import '../vault/pin_vault.dart';
import 'v2_groups.dart';

class V2RoomSession extends RoomSession {
  V2RoomSession(this.groups, this.group, UnlockedRoom room) : super(room);

  final V2Groups groups;
  final V2Group group;

  static const _uuid = Uuid();

  /// Members as the MLS group has them (their conversation identity keys),
  /// not only those whose profile arrived.
  @override
  Iterable<String> get memberOutboxes {
    final members = (groups.info(group)['members'] as List?)?.cast<String>();
    return members == null || members.isEmpty ? {myOutbox} : members;
  }

  /// Someone whose profile has not arrived yet is shown by key.
  @override
  MemberProfile profileOf(String author) {
    if (author == myOutbox) return myProfile;
    return profiles[author] ??
        MemberProfile(
          name: 'Członek ${author.substring(0, min(6, author.length))}',
        );
  }

  // Typing: opt-in here, sent as an ephemeral message (see sendTypingStamp).
  @override
  bool get typingSupported => true;

  // v2 conversations are the ones that write (PROTOCOL §B11).
  @override
  bool get readOnly => false;

  // PROTOCOL §B9: files are sealed with their own key before chunking; a
  // leaked blob record key shows only the size.
  @override
  bool get encryptMedia => true;

  @override
  Future<void> connectTransport() async {} // V2Groups syncs

  /// The core takes application messages up to 4096 bytes (PROTOCOL §B8,
  /// §B3.1), of which this much is its own envelope (id, `prev`, `ctl`).
  static const coreLimit = 4096;
  static const coreOverhead = 320;

  /// Most parts one message may be split into (about 50 KB of message).
  static const maxParts = 16;

  /// Unfinished split messages kept per group at most (oldest dropped).
  static const maxPartial = 8;

  /// Whether [payload] fits one core message as it is (the core escapes it
  /// as a JSON string).
  static bool fitsInline(String payload) =>
      utf8.encode(jsonEncode(payload)).length + coreOverhead <= coreLimit;

  /// [payload] cut into pieces whose part messages each fit the core.
  static List<String> split(String id, String payload) {
    final parts = <String>[];
    var start = 0;
    while (start < payload.length) {
      // Largest end that still fits, found by halving (UTF-8 and JSON
      // escaping make the size per character vary).
      var lo = start + 1, hi = payload.length;
      while (lo < hi) {
        final mid = (lo + hi + 1) ~/ 2;
        final probe = _partJson(id, 99, 99, payload.substring(start, mid));
        if (fitsInline(probe)) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      // Never split a UTF-16 surrogate pair.
      var end = lo;
      if (end < payload.length &&
          end > start + 1 &&
          (payload.codeUnitAt(end - 1) & 0xFC00) == 0xD800) {
        end--;
      }
      parts.add(payload.substring(start, end));
      start = end;
    }
    return parts;
  }

  static String _partJson(String id, int i, int n, String d) => jsonEncode({
    'part': {'id': id, 'i': i, 'n': n, 'd': d},
  });

  /// A message too large for one core message (a long text, a rich room
  /// look, a video with many chunks) goes as several part messages in a
  /// row; receivers show it as still arriving until every part is there,
  /// then list it once. Every part comes from the same MLS-proven sender.
  @override
  Future<void> appendMessage(ChatMessage msg) async {
    final payload = jsonEncode(msg.toWire());
    if (fitsInline(payload)) return groups.sendPayload(group, payload);
    final parts = split(msg.id, payload);
    if (parts.length > maxParts) throw StateError('Wiadomość jest za duża');
    for (final (i, d) in parts.indexed) {
      await groups.sendPayload(group, _partJson(msg.id, i, parts.length, d));
    }
  }

  /// Missing parts of split messages still arriving (shown like v1's
  /// "Odbieram … wiadomości").
  @override
  int get incomingCount {
    var missing = 0;
    for (final p in group.partials.values) {
      final n = p['n'] as int? ?? 0;
      missing += n - ((p['p'] as Map?)?.length ?? 0);
    }
    return super.incomingCount + missing;
  }

  /// One part of a split message from [author] (MLS-proven): kept (in the
  /// group's saved state, so a restart loses nothing) until all are here.
  void _takePart(String author, Map<dynamic, dynamic> part) {
    final id = part['id'], i = part['i'], n = part['n'], d = part['d'];
    if (id is! String || id.isEmpty || i is! int || n is! int) return;
    if (d is! String || n < 2 || n > maxParts || i < 0 || i >= n) return;
    final key = '$author|$id';
    final entry = group.partials.putIfAbsent(key, () {
      // Too many unfinished at once: drop the oldest.
      while (group.partials.length >= maxPartial) {
        group.partials.remove(group.partials.keys.first);
      }
      return {'n': n, 'p': <String, String>{}};
    });
    if (entry['n'] != n) return;
    final got = (entry['p'] as Map).cast<String, String>()..['$i'] = d;
    entry['p'] = got;
    if (got.length == n) {
      group.partials.remove(key);
      final whole = [for (var k = 0; k < n; k++) got['$k'] ?? ''].join();
      try {
        final j = jsonDecode(whole);
        if (j is Map<String, dynamic>) {
          final real = ChatMessage.fromWire(author, j);
          if (real.id == id) receive(real); // what the parts announced
        }
      } on Object {
        debugPrint('[v2] a split message was malformed');
      }
    }
    unawaited(groups.saveState());
  }

  // PROTOCOL §B8: typing is an ephemeral message, opt-in per conversation
  // ("Pokazuj, że piszę"), at most every 8 s like v1's head stamp.
  @override
  Future<void> sendTypingStamp(int ts) =>
      appendMessage(_hidden(MsgType.typing, {'ty': ts}));

  @override
  Future<void> publishProfile() =>
      appendMessage(_hidden(MsgType.profile, {'p': myProfile.toJson()}));

  @override
  Future<void> editMeta(RoomMeta Function(RoomMeta) change) async {
    final next = change(meta);
    final data = utf8.encode(jsonEncode(next.toJson()));
    if (data.length > RoomMeta.maxEncodedBytes) {
      throw StyleException('Za dużo emoji w pokoju');
    }
    final msg = _hidden(MsgType.meta, {'m': next.toJson()});
    await appendMessage(msg);
    meta = next;
    group.metaTs = msg.ts;
    notifyListeners();
    scheduleSave();
    await groups.saveState();
  }

  /// After someone joined: they cannot read what was sent before, so tell
  /// them who we are (and, admin, how the room looks).
  Future<void> announce({bool withMeta = false}) async {
    await sendHidden(MsgType.profile, {'p': myProfile.toJson()});
    if (withMeta) await sendHidden(MsgType.meta, {'m': meta.toJson()});
  }

  ChatMessage _hidden(MsgType type, Map<String, dynamic> extra) => ChatMessage(
    id: _uuid.v4(),
    author: myOutbox,
    ts: DateTime.now().millisecondsSinceEpoch,
    type: type,
    extra: extra,
    status: MsgStatus.sending,
  );

  /// Messages read from the group, in the order the core delivered them.
  void deliver(Iterable<ChatMessage> messages) {
    var added = false;
    var parts = false;
    for (final m in messages) {
      if (m.author == myOutbox) continue; // ours are listed when sent
      final part = m.extra?['part'];
      if (m.type == MsgType.text && m.text == null && part is Map) {
        _takePart(m.author, part);
        parts = true;
        continue;
      }
      added |= receive(m);
    }
    if (added || parts) {
      notifyListeners();
      scheduleSave();
    }
  }

  /// The group changed (members, join state): redraw the chat.
  void refresh() => notifyListeners();

  /// After moving a v1 room to this group (PROTOCOL §B11), or joining it
  /// from the move card: the v1 conversation as this phone has it, kept
  /// here so nothing is reset. Local only, nothing is sent: every member
  /// who comes from the v1 room has its history already.
  ///
  /// * every message, with replies, media and reactions; our own v1
  ///   messages count as ours here;
  /// * who the other v1 members were (names and pictures, as shown there);
  /// * the room look (name, picture, background, bubbles, emoji);
  /// * our own name, picture and colour from that room.
  ///
  /// The new members' keys differ from their v1 ones, so their v2
  /// messages show under their v2 profiles (they introduce themselves).
  void importFromV1(RoomSession v1) {
    String map(String author) => author == v1.myOutbox ? myOutbox : author;

    for (final o in {
      ...v1.memberOutboxes,
      for (final m in v1.messages) m.author,
    }) {
      if (o == v1.myOutbox || o == myOutbox) continue;
      final p = v1.profileOf(o);
      profiles.putIfAbsent(o, () => p.copyWith(name: v1.nameOf(o)));
    }
    final mine = v1.myProfile;
    profiles[myOutbox] = mine.copyWith(name: v1.nameOf(v1.myOutbox));

    for (final m in v1.messages) {
      if (m.type.hidden) continue;
      final copy = ChatMessage.fromCache({...m.toCache(), 'a': map(m.author)})
        ..status = MsgStatus.sent;
      insertImported(copy);
    }
    final r = v1.reactions.toJson();
    reactions.loadJson({
      for (final t in r.entries)
        t.key: {
          for (final a in (t.value as Map).entries)
            map(a.key as String): a.value,
        },
    });

    meta = v1.meta;
    notifyListeners();
    scheduleSave();
  }

  /// The admin of a moved room: shares the v1 room look with the group
  /// (a large one goes in parts) and our profile.
  Future<void> shareImported() async {
    await editMeta((_) => meta);
    await publishProfile();
  }

  /// Messages kept by the first v2 screens (`{f, t, ts, m}`), listed once.
  void importLegacy(List<Map<String, dynamic>> legacy) {
    for (final (i, j) in legacy.indexed) {
      final from = j['f'];
      final text = j['t'];
      final ts = j['ts'];
      if (from is! String || text is! String || ts is! int) continue;
      receive(
        ChatMessage(
          id: 'v2-legacy-$i-$ts',
          author: j['m'] == true ? myOutbox : from,
          ts: ts,
          type: MsgType.text,
          text: text,
          status: MsgStatus.sent,
        ),
      );
    }
    notifyListeners();
    scheduleSave();
  }

  @override
  void onHidden(ChatMessage msg) {
    final x = msg.extra;
    if (x == null) return;
    switch (msg.type) {
      case MsgType.profile:
        final p = x['p'];
        if (p is! Map) return;
        try {
          profiles[msg.author] = MemberProfile.fromJson(p.cast());
        } on Object {
          return;
        }
      case MsgType.meta:
        final m = x['m'];
        if (m is! Map || msg.ts <= group.metaTs) return;
        try {
          final next = RoomMeta.fromJson(m.cast(), fallbackName: meta.name);
          // A DM is named after the other person on each side.
          meta = group.dm ? next.copyWith(name: meta.name) : next;
        } on Object {
          return;
        }
        group.metaTs = msg.ts;
      // PROTOCOL §B10: a DM invite for one member, sent through this group
      // (MLS proved who sent it). Everyone else ignores it.
      case MsgType.dmInvite:
        final v = x['v2'];
        if (v is! Map || msg.author == myOutbox) return;
        final code = v['i'];
        if (v['to'] != myOutbox || code is! String) return;
        groups.offerDm(group, msg.author, code, msg.id);
        return;
      case MsgType.typing:
        if (msg.author != myOutbox) noteTypingStamp(msg.author, x['ty']);
        return;
      // PROTOCOL §B8: coarse, opt-in presence of one member here. Kept in
      // memory only; dated by the sender (a backlog read later is old).
      case MsgType.presence:
        final s = x['s'];
        if (s is! String || msg.author == myOutbox) return;
        if (s != 'active' && s != 'away') return;
        final at = x['at'] is int ? x['at'] as int : msg.ts;
        final seen = _presence[msg.author];
        if (seen != null && seen.$2 >= at) return;
        _presence[msg.author] = (s, at);
        notifyListeners();
        return;
      default:
        return;
    }
    notifyListeners();
    scheduleSave();
  }

  final _presence = <String, (String, int)>{};

  /// What [author] last said about being around, if they share it here and
  /// it is recent: 'active' or 'away'; null otherwise.
  String? presenceOf(String author) {
    final p = _presence[author];
    if (p == null) return null;
    final age = groups.clock() - p.$2;
    if (age > V2Groups.presenceValid.inMilliseconds) return null;
    return p.$1;
  }

  /// A message from the group's core inbox: v1 wire JSON, or plain text
  /// (sent by the first v2 screens before this format).
  static ChatMessage? parse(String from, String text, int index) {
    Object? j;
    try {
      j = jsonDecode(text);
    } on FormatException {
      j = null; // plain text
    }
    if (j is Map<String, dynamic>) {
      // One part of a split message: put together in deliver.
      final part = j['part'];
      if (part is Map) {
        return ChatMessage(
          id: 'v2-part-$from-$index',
          author: from,
          ts: DateTime.now().millisecondsSinceEpoch,
          type: MsgType.text,
          extra: {'part': part},
        );
      }
      try {
        return ChatMessage.fromWire(from, j);
      } on Object {
        return null; // malformed, or a type from a newer app version
      }
    }
    return ChatMessage(
      id: 'v2-$from-$index',
      author: from,
      ts: DateTime.now().millisecondsSinceEpoch,
      type: MsgType.text,
      text: text,
    );
  }
}
