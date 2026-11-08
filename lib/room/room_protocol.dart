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

  static Future<RoomSecrets> create({
    required String roomName,
    required String myName,
  }) async {
    final rc = Dht.rc;
    final roster = await rc.createDHTRecord(
      bestCryptoKind,
      const DHTSchema.dflt(oCnt: RoomLayout.rosterSubkeys),
    );
    try {
      await Dht.setJson(roster.key, 0, {'name': roomName, 'v': 1});
      final outbox = await _createOutbox(myName);
      await Dht.setJson(roster.key, 1, {
        'o': outbox.key.toString(),
        'n': myName,
      });
      return RoomSecrets(
        roomName: roomName,
        rosterKey: roster.key.toString(),
        rosterWriter: roster.ownerKeyPair!.toString(),
        myName: myName,
        outboxKey: outbox.key.toString(),
        outboxWriter: outbox.ownerKeyPair!.toString(),
        rosterSlot: 1,
      );
    } finally {
      await Dht.close(roster.key);
    }
  }

  static Future<RoomSecrets> join({
    required Invite invite,
    required String myName,
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

      final outbox = await _createOutbox(myName);
      final entry = Uint8List.fromList(
        utf8.encode(jsonEncode({'o': outbox.key.toString(), 'n': myName})),
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
      );
    } finally {
      await Dht.close(rosterKey);
    }
  }

  static Future<DHTRecordDescriptor> _createOutbox(String myName) async {
    // A random owner key per outbox, i.e. per room: rooms are unlinkable.
    final outbox = await Dht.rc.createDHTRecord(
      bestCryptoKind,
      const DHTSchema.dflt(oCnt: 1 + RoomLayout.outboxRing),
    );
    await Dht.setJson(outbox.key, 0, {'count': 0, 'name': myName});
    await Dht.close(outbox.key);
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
