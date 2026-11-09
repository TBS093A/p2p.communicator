import 'dart:convert';

import '../vault/room_secrets.dart';

/// Room invite. It carries the roster record key and its writer key pair, so
/// it IS membership: anyone holding it can read the room and join. Hand it
/// over in person (QR), through a channel you already trust, or as an
/// encrypted DM invite (sealed to the recipient's key).
class Invite {
  Invite({
    required this.roomName,
    required this.rosterKey,
    required this.rosterWriter,
    this.kind = RoomKind.group,
  });

  static const _prefix = 'p2pc1.';

  final String roomName;
  final String rosterKey;
  final String rosterWriter;

  /// Invites made before room kinds existed carry none: treat as a group.
  final RoomKind kind;

  String encode() =>
      _prefix +
      base64Url
          .encode(
            utf8.encode(
              jsonEncode({
                'n': roomName,
                'r': rosterKey,
                'w': rosterWriter,
                'k': kind.name,
              }),
            ),
          )
          .replaceAll('=', '');

  static Invite? tryParse(String raw) {
    final s = raw.trim();
    if (!s.startsWith(_prefix)) return null;
    try {
      final body = base64Url.normalize(s.substring(_prefix.length));
      final j =
          jsonDecode(utf8.decode(base64Url.decode(body)))
              as Map<String, dynamic>;
      return Invite(
        roomName: j['n'] as String,
        rosterKey: j['r'] as String,
        rosterWriter: j['w'] as String,
        kind: j['k'] == null ? RoomKind.group : RoomKind.parse(j['k']),
      );
    } on Object {
      return null;
    }
  }
}
