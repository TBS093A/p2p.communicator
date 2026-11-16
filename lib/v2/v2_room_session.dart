// A v2 group shown in the regular chat screen: the same messages as v1
// (text, media, replies, reactions) travel as JSON inside MLS application
// messages instead of in DHT outboxes. Profiles and the room look, which v1
// keeps in outbox heads and the roster, are hidden messages here.
import 'dart:convert';
import 'dart:math';

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

  // Sending typing stamps would cost a message each time (and a slot of the
  // outbox ring): not in v2 yet.
  @override
  bool get typingSupported => false;

  @override
  void userTyping() {}

  @override
  Future<void> connectTransport() async {} // V2Groups syncs

  @override
  Future<void> appendMessage(ChatMessage msg) =>
      groups.sendPayload(group, jsonEncode(msg.toWire()));

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
    for (final m in messages) {
      if (m.author == myOutbox) continue; // ours are listed when sent
      added |= receive(m);
    }
    if (added) {
      notifyListeners();
      scheduleSave();
    }
  }

  /// The group changed (members, join state): redraw the chat.
  void refresh() => notifyListeners();

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
          meta = RoomMeta.fromJson(m.cast(), fallbackName: meta.name);
        } on Object {
          return;
        }
        group.metaTs = msg.ts;
      default:
        return; // DM invites and the like have no meaning in v2
    }
    notifyListeners();
    scheduleSave();
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
