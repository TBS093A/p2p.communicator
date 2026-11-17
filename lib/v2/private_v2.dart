// A private v2 conversation (PROTOCOL §B11.1): an ordinary v2 group on the
// wire whose local state lives in a password slot of the PIN vault, so the
// app unlocked with its PIN does not know it exists. It has its own
// V2Groups (holding just this group) and is synced only while open.
import 'dart:convert';
import 'dart:typed_data';

import 'package:p2pc_core/p2pc_core.dart';

import '../vault/pin_vault.dart';
import 'v2_groups.dart';
import 'v2_room_session.dart';
import 'veilid_core_dht.dart';

class PrivateV2 {
  PrivateV2._(this.groups, this._closeDht);

  final V2Groups groups;
  final Future<void> Function() _closeDht;
  bool _closed = false;

  /// The conversation (null until created or joined).
  V2Group? get group => groups.groups.firstOrNull;

  /// Labels of the areas derived from the slot (core state, chat cache).
  static const stateLabel = 'v2-state';
  static String roomLabel(String groupId) => 'v2-room:$groupId';

  /// Opens a conversation whose state [read]/[write] keep (tests: memory;
  /// the app: [inSlot]).
  static Future<PrivateV2> open({
    required CoreDht dht,
    required Future<Uint8List?> Function() read,
    required Future<void> Function(Uint8List data) write,
    required V2RoomOpener openRoom,
    int Function()? clock,
    bool Function()? appActive,
    Future<void> Function()? closeDht,
  }) async {
    late final V2Groups groups;
    groups = V2Groups(
      dht,
      save: () => write(utf8.encode(jsonEncode(groups.toJson()))),
      openRoom: openRoom,
      clock: clock,
      appActive: appActive,
      private: true,
    );
    final raw = await read();
    List<dynamic>? list;
    if (raw != null) {
      try {
        list = jsonDecode(utf8.decode(raw)) as List<dynamic>;
      } on Object {
        list = null; // a fresh slot's data file holds random bytes
      }
    }
    await groups.load(list);
    return PrivateV2._(groups, closeDht ?? () async {});
  }

  /// The conversation in [slot], over the device's Veilid node.
  static Future<PrivateV2> inSlot(PrivateSlot slot) async {
    final vault = PinVault.instance;
    final state = await vault.derivedDataArea(slot, stateLabel);
    final dht = VeilidCoreDht();
    return open(
      dht: dht,
      read: () => vault.readData(state),
      write: (data) => vault.writeData(state, data),
      openRoom: (groups, group, secrets) async {
        final room = V2RoomSession(
          groups,
          group,
          await vault.derivedArea(slot, roomLabel(group.id), secrets),
        );
        await room.open(); // its cache and media, as in the app's groups
        return room;
      },
      closeDht: dht.close,
    );
  }

  /// Saves and stops: nothing of it runs while it is closed.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await groups.saveState();
    await groups.close();
    await _closeDht();
  }
}
