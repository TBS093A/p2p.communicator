import 'package:flutter/material.dart';

import '../app_state/app_session.dart';
import '../room/room_session.dart';
import '../vault/room_secrets.dart';
import 'widgets/avatar.dart';

/// Someone else's profile, opened by tapping their avatar in the chat:
/// picture, name in this room (and their global name if they use a
/// nickname here), presence when they share it, and how much they wrote.
class MemberProfileScreen extends StatelessWidget {
  const MemberProfileScreen({
    super.key,
    required this.session,
    required this.outbox,
    this.app,
  });

  final RoomSession session;
  final String outbox;
  final AppSession? app;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, ?app]),
      builder: (context, _) {
        final p = session.profileOf(outbox);
        final global = session.globalNameOf(outbox);
        final key = session.profileKeyOf(outbox);
        final presence = key == null ? null : app?.directory[key]?.presence;
        final sent = session.messages.where((m) => m.author == outbox).length;
        final where = session.kind == RoomKind.dm
            ? 'tej rozmowie'
            : 'tej grupie';
        final text = Theme.of(context).textTheme;
        return Scaffold(
          appBar: AppBar(title: Text(p.name)),
          body: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Center(
                child: Avatar.member(
                  session,
                  outbox,
                  radius: 56,
                  key: const ValueKey('member-profile-avatar'),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  p.name,
                  key: const ValueKey('member-profile-name'),
                  style: text.headlineSmall,
                  textAlign: TextAlign.center,
                ),
              ),
              if (global != null && global != p.name)
                Center(
                  child: Text('globalnie: $global', style: text.bodyMedium),
                ),
              if (presence != null) ...[
                const SizedBox(height: 8),
                Center(child: Chip(label: Text(presence.label))),
              ],
              const SizedBox(height: 24),
              ListTile(
                leading: const Icon(Icons.chat_bubble_outline),
                title: Text('Wiadomości w $where: $sent'),
              ),
            ],
          ),
        );
      },
    );
  }
}
