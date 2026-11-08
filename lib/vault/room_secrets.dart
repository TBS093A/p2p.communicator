/// Everything needed to (re)open one room. Lives only inside an encrypted
/// vault slot, so it is readable only after the matching PIN is typed.
class RoomSecrets {
  RoomSecrets({
    required this.roomName,
    required this.rosterKey,
    required this.rosterWriter,
    required this.myName,
    required this.outboxKey,
    required this.outboxWriter,
    required this.rosterSlot,
  });

  final String roomName;

  /// Shared room record (member list). Holding [rosterKey] + [rosterWriter]
  /// is what makes someone a member: it is exactly the invite.
  final String rosterKey;
  final String rosterWriter;

  /// This device's identity in the room. A fresh key pair per room, so rooms
  /// cannot be linked to each other on the network.
  final String myName;
  final String outboxKey;
  final String outboxWriter;
  final int rosterSlot;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'roomName': roomName,
    'rosterKey': rosterKey,
    'rosterWriter': rosterWriter,
    'myName': myName,
    'outboxKey': outboxKey,
    'outboxWriter': outboxWriter,
    'rosterSlot': rosterSlot,
  };

  factory RoomSecrets.fromJson(Map<String, dynamic> j) => RoomSecrets(
    roomName: j['roomName'] as String,
    rosterKey: j['rosterKey'] as String,
    rosterWriter: j['rosterWriter'] as String,
    myName: j['myName'] as String,
    outboxKey: j['outboxKey'] as String,
    outboxWriter: j['outboxWriter'] as String,
    rosterSlot: j['rosterSlot'] as int,
  );
}
