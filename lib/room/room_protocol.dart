import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:veilid/veilid.dart';

import '../core/veilid_node.dart';
import '../vault/room_secrets.dart';
import 'dht.dart';
import 'invite.dart';

/// On-network layout of a room. All records are DHT records encrypted by
/// Veilid with their own secret, which only travels inside invites and the
/// roster, so the nodes storing them see ciphertext.
///
/// Roster record (DFLT, writer key shared through the invite):
///   subkey 0          {name, v}                      room meta
///   subkey 1..63      {o: outboxKey, n: displayName} one per member
///
/// Outbox record (DFLT, written only by its member's own key):
///   subkey 0          {count, name}                  head
///   subkey 1..ring    message #i lives at 1 + i % ring
///
/// Readers watch every outbox head, so a new message costs the sender two
/// writes and each reader one change notification plus one read.
class RoomLayout {
  static const rosterSubkeys = 64;
  static const outboxRing = 200;
  static const maxMessageBytes = 4000; // 200 * 4000 stays under 1 MiB/record
}

class RoomFullException implements Exception {}

class RoomNotFoundException implements Exception {}

class RoomProtocol {
  RoomProtocol._();

  /// Roster entry / outbox head for us. Public rooms also point to our
  /// global profile record ([profileKey]); private rooms never do, so they
  /// cannot be linked to it.
  static Map<String, dynamic> _entry(
    String outbox,
    String myName,
    String? profileKey,
  ) => {'o': outbox, 'n': myName, 'p': ?profileKey};

  static Map<String, dynamic> _head(String myName, String? profileKey) => {
    'count': 0,
    'name': myName,
    'p': ?profileKey,
  };

  static Future<RoomSecrets> create({
    required String roomName,
    required String myName,
    RoomKind kind = RoomKind.private,
    String? profileKey,
  }) async {
    assert(kind.isPublic == (profileKey != null));
    // A random owner key per record, i.e. per room: rooms are unlinkable.
    // Local-first: both records are brand new and only reachable through our
    // invite, so nobody can race us. Write locally, let Veilid publish in the
    // background, and leave the records open for the room session (which
    // re-opens them; closing now would wait on the pending pushes).
    final rc = Dht.rc;
    final roster = await rc.createDHTRecord(
      bestCryptoKind,
      const DHTSchema.dflt(oCnt: RoomLayout.rosterSubkeys),
    );
    final outbox = await rc.createDHTRecord(
      bestCryptoKind,
      const DHTSchema.dflt(oCnt: 1 + RoomLayout.outboxRing),
    );
    await Future.wait([
      Dht.setJsonSoon(roster.key, 0, {
        'name': roomName,
        'v': 1,
        'kind': kind.name,
      }),
      Dht.setJsonSoon(
        roster.key,
        1,
        _entry(outbox.key.toString(), myName, profileKey),
      ),
      Dht.setJsonSoon(outbox.key, 0, _head(myName, profileKey)),
    ]);
    return RoomSecrets(
      roomName: roomName,
      rosterKey: roster.key.toString(),
      rosterWriter: roster.ownerKeyPair!.toString(),
      myName: myName,
      outboxKey: outbox.key.toString(),
      outboxWriter: outbox.ownerKeyPair!.toString(),
      rosterSlot: 1,
      kind: kind,
    );
  }

  /// Joins the room in [invite]. Its kind comes from the room itself (falls
  /// back to the invite's); [asPrivate] forces a private, unlinked identity.
  static Future<RoomSecrets> join({
    required Invite invite,
    required String myName,
    String? profileKey,
    bool asPrivate = false,
  }) async {
    await VeilidNode.instance.waitUntilOnline(
      timeout: const Duration(seconds: 90),
    );
    final rosterKey = RecordKey.fromString(invite.rosterKey);
    final writer = KeyPair.fromString(invite.rosterWriter);
    try {
      await Dht.retry(() => Dht.rc.openDHTRecord(rosterKey, writer: writer));
    } on VeilidAPIExceptionKeyNotFound {
      throw RoomNotFoundException();
    }
    try {
      final meta = await Dht.getJson(rosterKey, 0);
      if (meta == null) throw RoomNotFoundException();

      final kind = asPrivate
          ? RoomKind.private
          : (meta['kind'] != null ? RoomKind.parse(meta['kind']) : invite.kind);
      final pKey = kind.isPublic ? profileKey : null;
      final outbox = await _createOutbox(myName, pKey);
      final entry = Uint8List.fromList(
        utf8.encode(jsonEncode(_entry(outbox.key.toString(), myName, pKey))),
      );
      final slot = await _claimSlot(rosterKey, entry);
      return RoomSecrets(
        roomName: meta['name'] as String? ?? invite.roomName,
        rosterKey: invite.rosterKey,
        rosterWriter: invite.rosterWriter,
        myName: myName,
        outboxKey: outbox.key.toString(),
        outboxWriter: outbox.ownerKeyPair!.toString(),
        rosterSlot: slot,
        kind: kind,
      );
    } finally {
      await Dht.close(rosterKey);
    }
  }

  static Future<DHTRecordDescriptor> _createOutbox(
    String myName,
    String? profileKey,
  ) async {
    // A random owner key per outbox: even in public rooms the outbox itself
    // is not tied to our identity key; only the `p` pointer links it.
    final outbox = await Dht.rc.createDHTRecord(
      bestCryptoKind,
      const DHTSchema.dflt(oCnt: 1 + RoomLayout.outboxRing),
    );
    // Only we write here: local-first, left open for the room session.
    await Dht.setJsonSoon(outbox.key, 0, _head(myName, profileKey));
    return outbox;
  }

  /// Everyone shares the roster writer key, so two people joining at once
  /// could pick the same subkey. Write, then check the network kept ours.
  static Future<int> _claimSlot(RecordKey roster, Uint8List entry) async {
    for (var slot = 1; slot < RoomLayout.rosterSubkeys; slot++) {
      if (await Dht.get(roster, slot) != null) continue;
      final winner = await Dht.set(roster, slot, entry);
      if (winner != null && !listEquals(winner, entry)) continue;
      final check = await Dht.get(roster, slot);
      if (check != null && listEquals(check, entry)) return slot;
    }
    throw RoomFullException();
  }
}
