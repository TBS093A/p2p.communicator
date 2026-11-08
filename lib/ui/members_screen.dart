import 'package:flutter/material.dart';

import '../room/room_session.dart';
import 'widgets/avatar.dart';

class MembersScreen extends StatelessWidget {
  const MembersScreen({super.key, required this.session});

  final RoomSession session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final entries = session.profiles.entries.toList()
          ..sort((a, b) {
            if (a.key == session.myOutbox) return -1;
            if (b.key == session.myOutbox) return 1;
            return a.value.name.toLowerCase().compareTo(
              b.value.name.toLowerCase(),
            );
          });
        return Scaffold(
          appBar: AppBar(title: Text('Osoby (${entries.length})')),
          body: ListView.builder(
            itemCount: entries.length,
            itemBuilder: (context, i) {
              final e = entries[i];
              final me = e.key == session.myOutbox;
              final sent = session.messages
                  .where((m) => m.author == e.key)
                  .length;
              return ListTile(
                leading: Avatar.member(session, e.key),
                title: Text(me ? '${e.value.name} (ty)' : e.value.name),
                subtitle: Text('wiadomości: $sent'),
                trailing: e.value.color == null
                    ? null
                    : Icon(Icons.circle, color: Color(e.value.color!)),
              );
            },
          ),
        );
      },
    );
  }
}
