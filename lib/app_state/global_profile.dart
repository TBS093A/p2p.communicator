import '../room/message.dart';
import '../room/room_style.dart';

/// What a user chooses to show.
enum UserStatus {
  available('Dostępny'),
  away('Zaraz wracam'),
  dnd('Nie przeszkadzać'),
  invisible('Niewidoczny');

  const UserStatus(this.label);
  final String label;

  static UserStatus parse(Object? raw) => UserStatus.values.firstWhere(
    (s) => s.name == raw,
    orElse: () => UserStatus.available,
  );
}

/// What others see, combining the chosen status with the heartbeat.
enum Presence {
  online('dostępny'),
  away('zaraz wraca'),
  dnd('nie przeszkadzać'),
  offline('offline');

  const Presence(this.label);
  final String label;
}

/// One person's public profile: a single DHT record that every public room
/// they are in points to, so a change (or a heartbeat) is one write.
///
/// Private rooms never reference it; there each member has a separate,
/// per-room identity instead.
class GlobalProfile {
  const GlobalProfile({
    required this.name,
    required this.identity,
    this.avatar,
    this.color,
    this.status = UserStatus.available,
    this.seen = 0,
  });

  final String name;

  /// Identity public key (`VLD0:…`): DM invites are sealed to it.
  final String identity;
  final MediaRef? avatar;
  final int? color;
  final UserStatus status;

  /// Last heartbeat, ms since epoch. Not updated while [UserStatus.invisible].
  final int seen;

  /// A profile without a heartbeat for this long counts as offline.
  static const offlineAfter = Duration(minutes: 3);
  static const heartbeat = Duration(seconds: 60);

  Presence presenceAt(DateTime now) {
    if (status == UserStatus.invisible) return Presence.offline;
    final age = now.difference(DateTime.fromMillisecondsSinceEpoch(seen));
    if (age > offlineAfter) return Presence.offline;
    return switch (status) {
      UserStatus.away => Presence.away,
      UserStatus.dnd => Presence.dnd,
      _ => Presence.online,
    };
  }

  Presence get presence => presenceAt(DateTime.now());

  MemberProfile toMember() =>
      MemberProfile(name: name, avatar: avatar, color: color);

  GlobalProfile copyWith({
    String? name,
    MediaRef? avatar,
    bool clearAvatar = false,
    int? color,
    bool clearColor = false,
    UserStatus? status,
    int? seen,
  }) => GlobalProfile(
    name: name ?? this.name,
    identity: identity,
    avatar: clearAvatar ? null : (avatar ?? this.avatar),
    color: clearColor ? null : (color ?? this.color),
    status: status ?? this.status,
    seen: seen ?? this.seen,
  );

  Map<String, dynamic> toJson() => {
    'v': 1,
    'name': name,
    'id': identity,
    if (avatar != null) 'avatar': avatar!.toJson(),
    if (color != null) 'color': color,
    'status': status.name,
    'seen': seen,
  };

  factory GlobalProfile.fromJson(Map<String, dynamic> j) => GlobalProfile(
    name: j['name'] as String? ?? '?',
    identity: j['id'] as String? ?? '',
    avatar: j['avatar'] is Map
        ? MediaRef.fromJson((j['avatar'] as Map).cast<String, dynamic>())
        : null,
    color: j['color'] as int?,
    status: UserStatus.parse(j['status']),
    seen: j['seen'] as int? ?? 0,
  );
}
