import 'dart:io';

import '../room/message.dart';
import '../room/room_session.dart';
import 'global_profile.dart';
import 'profile_directory.dart';

/// What a public room needs from the unlocked app: the global identity and
/// profiles, and a place to hand over hidden control messages (DM invites).
abstract class AppLink {
  ProfileDirectory get directory;

  /// Our global profile record key (goes into roster entries as `p`).
  String get myProfileKey;
  GlobalProfile get myGlobal;

  Future<void> updateGlobalProfile({
    String? name,
    File? avatar,
    bool clearAvatar = false,
    int? color,
    bool clearColor = false,
    UserStatus? status,
  });

  /// A message not meant for the chat view (e.g. a sealed DM invite) arrived
  /// in [room].
  void onHiddenMessage(RoomSession room, ChatMessage message);
}
