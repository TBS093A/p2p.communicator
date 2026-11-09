/// What kind of room this is.
///
/// * [dm] and [group] are public rooms: listed on the home screen, shown
///   with your one global profile.
/// * [private] rooms open only with their own password and keep a separate,
///   unlinkable identity per room. v0.1 "PIN rooms" are private rooms.
enum RoomKind {
  dm,
  group,
  private;

  bool get isPublic => this != RoomKind.private;

  static RoomKind parse(Object? raw) => switch (raw) {
    'dm' => RoomKind.dm,
    'group' => RoomKind.group,
    _ => RoomKind.private,
  };
}

/// Everything needed to (re)open one room.
class RoomSecrets {
  RoomSecrets({
    required this.roomName,
    required this.rosterKey,
    required this.rosterWriter,
    required this.myName,
    required this.outboxKey,
    required this.outboxWriter,
    required this.rosterSlot,
    this.kind = RoomKind.private,
  });

  final String roomName;

  /// Shared room record (member list). Holding [rosterKey] + [rosterWriter]
  /// is what makes someone a member: it is exactly the invite.
  final String rosterKey;
  final String rosterWriter;

  /// This device's outbox in the room. In private rooms its owner key is a
  /// fresh key pair per room, so rooms cannot be linked to each other.
  final String myName;
  final String outboxKey;
  final String outboxWriter;
  final int rosterSlot;

  final RoomKind kind;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'roomName': roomName,
    'rosterKey': rosterKey,
    'rosterWriter': rosterWriter,
    'myName': myName,
    'outboxKey': outboxKey,
    'outboxWriter': outboxWriter,
    'rosterSlot': rosterSlot,
    'kind': kind.name,
  };

  factory RoomSecrets.fromJson(Map<String, dynamic> j) => RoomSecrets(
    roomName: j['roomName'] as String,
    rosterKey: j['rosterKey'] as String,
    rosterWriter: j['rosterWriter'] as String,
    myName: j['myName'] as String,
    outboxKey: j['outboxKey'] as String,
    outboxWriter: j['outboxWriter'] as String,
    rosterSlot: j['rosterSlot'] as int,
    // Slots from v0.1 carry no kind: they were PIN rooms, now private.
    kind: RoomKind.parse(j['kind']),
  );
}
