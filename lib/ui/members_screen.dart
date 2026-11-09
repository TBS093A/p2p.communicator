import 'package:flutter/material.dart';

import '../app_state/app_session.dart';
import '../room/room_session.dart';
import 'widgets/avatar.dart';

class MembersScreen extends StatelessWidget {
  const MembersScreen({super.key, required this.session, this.app});

  final RoomSession session;
  final AppSession? app;

  @override
  Widget build(BuildContext context) {
    final listen = Listenable.merge([session, ?app]);
    return ListenableBuilder(
      listenable: listen,
      builder: (context, _) {
        final outboxes = session.memberOutboxes.toList()
          ..sort((a, b) {
            if (a == session.myOutbox) return -1;
            if (b == session.myOutbox) return 1;
            return session
                .nameOf(a)
                .toLowerCase()
                .compareTo(session.nameOf(b).toLowerCase());
          });
        return Scaffold(
          appBar: AppBar(title: Text('Osoby (${outboxes.length})')),
          body: ListView.builder(
            itemCount: outboxes.length,
            itemBuilder: (context, i) {
              final o = outboxes[i];
              final me = o == session.myOutbox;
              final p = session.profileOf(o);
              final key = session.profileKeyOf(o);
              final presence = key == null
                  ? null
                  : app?.directory[key]?.presence;
              final sent = session.messages.where((m) => m.author == o).length;
              return ListTile(
                leading: Avatar.member(session, o),
                title: Text(me ? '${p.name} (ty)' : p.name),
                subtitle: Text(
                  [?presence?.label, 'wiadomości: $sent'].join(' · '),
                ),
                trailing: p.color == null
                    ? null
                    : Icon(Icons.circle, color: Color(p.color!)),
              );
            },
          ),
        );
      },
    );
  }
}
