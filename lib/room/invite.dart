import 'dart:convert';

/// Room invite. It carries the roster record key and its writer key pair, so
/// it IS membership: anyone holding it can read the room and join. Hand it
/// over in person (QR) or through a channel you already trust.
class Invite {
  Invite({
    required this.roomName,
    required this.rosterKey,
    required this.rosterWriter,
  });

  static const _prefix = 'p2pc1.';

  final String roomName;
  final String rosterKey;
  final String rosterWriter;

  String encode() =>
      _prefix +
      base64Url
          .encode(
            utf8.encode(
              jsonEncode({'n': roomName, 'r': rosterKey, 'w': rosterWriter}),
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
      );
    } on Object {
      return null;
    }
  }
}
