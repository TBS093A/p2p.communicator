// PROTOCOL §B11.2: every v1 conversation moves to v2 by itself. One member
// creates the v2 group and announces it in the v1 room with an invite for
// each other member; their apps join it on their own and the admin's app
// lets them in. The v1 history, people and look come along, and the v1
// room is then deleted from the phone.
import 'package:flutter/foundation.dart';

import '../room/room_session.dart';
import '../vault/room_secrets.dart';
import 'v2_groups.dart';

class V1Mover {
  V1Mover(
    this.groups, {
    this.leaderFirst = true,
    Map<String, int>? waiting,
    int Function()? clock,
  }) : waiting = waiting ?? {},
       clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final V2Groups groups;

  /// Public rooms: the member with the lowest v1 outbox moves the room;
  /// the others move it themselves only after [leaderGrace] without a move.
  /// A private room (open only with its password) moves at once.
  final bool leaderFirst;

  /// v1 roster key -> when we first saw the room not moved (ms).
  final Map<String, int> waiting;
  final int Function() clock;

  static const leaderGrace = Duration(days: 2);

  /// The mover keeps the v1 room this long for members who join late.
  static const keepV1 = Duration(days: 14);

  static String keyOf(RoomSession v1) => v1.room.secrets.rosterKey;

  /// The v2 group the conversation of [v1] lives in, if any.
  V2Group? groupOf(RoomSession v1) =>
      groups.groups.where((g) => g.fromV1 == keyOf(v1)).firstOrNull;

  /// One step for [v1]: join the earliest move announced in it, or move it
  /// ourselves. Returns the v2 group, or null while there is none yet.
  Future<V2Group?> step(RoomSession v1) async {
    if (!v1.syncedOnce) return groupOf(v1);
    final me = v1.myOutbox;
    final first = V1Move.all(v1.messages, me).firstOrNull;
    final mine = groupOf(v1);
    if (mine != null) {
      // Two members moved it at once: the earliest announcement wins, ours
      // goes (for whoever already joined it too) and we join that one.
      if (mine.movedAt > 0 && first != null && first.from != me) {
        await groups.deleteForAll(mine);
      } else {
        return mine;
      }
    }
    if (first != null && first.from != me) return _join(v1, first);
    if (first != null) return null; // ours, its group lost on this phone
    if (leaderFirst && !_leader(v1)) {
      final since = waiting.putIfAbsent(keyOf(v1), clock);
      if (clock() - since < leaderGrace.inMilliseconds) return null;
    }
    return _move(v1);
  }

  /// Whether [v1] can go from this phone: its conversation is in [g].
  bool doneWith(V2Group g) {
    if (g.joining) return false;
    if (g.movedAt == 0) return true; // we joined someone's move
    return g.moveInvites.isEmpty || clock() - g.movedAt > keepV1.inMilliseconds;
  }

  bool _leader(RoomSession v1) =>
      (v1.memberOutboxes.toList()..sort()).first == v1.myOutbox;

  bool _dm(RoomSession v1) => v1.kind == RoomKind.dm;

  /// The other person in a v1 DM.
  String? _peer(RoomSession v1) =>
      v1.memberOutboxes.where((o) => o != v1.myOutbox).firstOrNull;

  String _name(RoomSession v1) {
    final peer = _dm(v1) ? _peer(v1) : null;
    return peer != null ? v1.nameOf(peer) : v1.roomName;
  }

  Future<V2Group> _join(RoomSession v1, V1Move move) async {
    final invite = V2Invite.tryParse(move.code)!;
    final g = await groups.join(
      invite,
      _dm(v1) ? v1.nameOf(move.from) : move.name,
      v1.nameOf(v1.myOutbox),
      fromV1: keyOf(v1),
      dm: _dm(v1),
    );
    // The v1 history, people and look come along.
    groups.roomOf(g).importFromV1(v1);
    await groups.saveState();
    return g;
  }

  Future<V2Group> _move(RoomSession v1) async {
    final others = v1.memberOutboxes.where((o) => o != v1.myOutbox).toList();
    final (g, invites) = await groups.createForMove(
      _name(v1),
      v1.nameOf(v1.myOutbox),
      others,
      dm: _dm(v1),
    );
    try {
      final room = groups.roomOf(g);
      room.importFromV1(v1);
      await room.shareImported();
      final entries = invites.entries.toList();
      for (var i = 0; i < entries.length; i += V1Move.invitesPerMessage) {
        final part = entries.skip(i).take(V1Move.invitesPerMessage);
        await v1.sendText(
          'Ta rozmowa przeniosła się do v2 (szyfrowanie MLS). Zaktualizuj '
          'aplikację: przeniesie cię sama.',
          extra: V1Move.extra(v1.roomName, Map.fromEntries(part)),
        );
      }
    } on Object {
      // Not announced: nobody can join it, so it goes (tried again later).
      await groups.leave(g);
      rethrow;
    }
    g.fromV1 = keyOf(v1);
    waiting.remove(keyOf(v1));
    await groups.saveState();
    debugPrint('[v1→v2] moved a room (${others.length} invites)');
    return g;
  }
}
