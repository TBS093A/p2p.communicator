import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_communicator/app_state/global_profile.dart';
import 'package:p2p_communicator/room/invite.dart';
import 'package:p2p_communicator/room/message.dart';
import 'package:p2p_communicator/vault/room_secrets.dart';

void main() {
  group('presence', () {
    final now = DateTime(2026, 11, 9, 12);
    GlobalProfile at(Duration ago, UserStatus status) => GlobalProfile(
      name: 'Ola',
      identity: 'VLD0:x',
      status: status,
      seen: now.subtract(ago).millisecondsSinceEpoch,
    );

    test('a fresh heartbeat shows the chosen status', () {
      const recent = Duration(seconds: 30);
      expect(at(recent, UserStatus.available).presenceAt(now), Presence.online);
      expect(at(recent, UserStatus.away).presenceAt(now), Presence.away);
      expect(at(recent, UserStatus.dnd).presenceAt(now), Presence.dnd);
    });

    test('invisible is offline even with a heartbeat', () {
      expect(
        at(Duration.zero, UserStatus.invisible).presenceAt(now),
        Presence.offline,
      );
    });

    test('no heartbeat for longer than the limit is offline', () {
      final stale = GlobalProfile.offlineAfter + const Duration(seconds: 1);
      expect(at(stale, UserStatus.available).presenceAt(now), Presence.offline);
      expect(
        at(GlobalProfile.offlineAfter, UserStatus.available).presenceAt(now),
        Presence.online,
      );
    });

    test('heartbeat comes well within the offline window', () {
      expect(GlobalProfile.heartbeat * 2, lessThan(GlobalProfile.offlineAfter));
    });

    test('profile round-trips; unknown status falls back to available', () {
      final p = at(Duration.zero, UserStatus.dnd).copyWith(color: 0xFF112233);
      final back = GlobalProfile.fromJson(p.toJson());
      expect(back.name, 'Ola');
      expect(back.identity, 'VLD0:x');
      expect(back.status, UserStatus.dnd);
      expect(back.color, 0xFF112233);
      expect(back.seen, p.seen);
      expect(
        GlobalProfile.fromJson({'name': 'x', 'status': 'party'}).status,
        UserStatus.available,
      );
    });
  });

  group('room kinds', () {
    test('invites carry their kind; old invites are groups', () {
      for (final k in RoomKind.values) {
        final inv = Invite(
          roomName: 'r',
          rosterKey: 'VLD0:a',
          rosterWriter: 'VLD0:b:c',
          kind: k,
        );
        expect(Invite.tryParse(inv.encode())!.kind, k);
      }
      // An invite from before kinds existed: no "k" field.
      const legacy = 'p2pc1.eyJuIjoiciIsInIiOiJWTEQwOmEiLCJ3IjoiVkxEMDpiOmMifQ';
      expect(Invite.tryParse(legacy)!.kind, RoomKind.group);
    });

    test('slots from v0.1 (no kind) open as private rooms', () {
      final s = RoomSecrets.fromJson({
        'roomName': 'Stary pokój',
        'rosterKey': 'k',
        'rosterWriter': 'w',
        'myName': 'Ala',
        'outboxKey': 'o',
        'outboxWriter': 'ow',
        'rosterSlot': 1,
      });
      expect(s.kind, RoomKind.private);
      expect(s.kind.isPublic, isFalse);
    });

    test('public kinds round-trip', () {
      for (final k in [RoomKind.dm, RoomKind.group]) {
        final s = RoomSecrets(
          roomName: 'r',
          rosterKey: 'k',
          rosterWriter: 'w',
          myName: 'm',
          outboxKey: 'o',
          outboxWriter: 'ow',
          rosterSlot: 2,
          kind: k,
        );
        expect(RoomSecrets.fromJson(s.toJson()).kind, k);
        expect(k.isPublic, isTrue);
      }
    });
  });

  group('messages', () {
    test('a DM invite is hidden and keeps its sealed payload', () {
      final m = ChatMessage(
        id: 'i',
        author: 'o',
        ts: 1,
        type: MsgType.dmInvite,
        seq: 3,
        extra: {'s': 'c2VhbGVk'},
      );
      final back = ChatMessage.fromWire('o', m.toWire());
      expect(back.type.hidden, isTrue);
      expect(back.extra, {'s': 'c2VhbGVk'});
      expect(MsgType.text.hidden, isFalse);
    });

    test('a type from a newer app version is a FormatException', () {
      expect(
        () => ChatMessage.fromWire('o', {
          'id': 'x',
          'ts': 1,
          't': 'hologram',
          'seq': 0,
        }),
        throwsFormatException,
      );
    });
  });
}
