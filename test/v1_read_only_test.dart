// PROTOCOL §B11: a v2 app opens v1 rooms read-only. Nothing new is
// written (messages, profile, room look, typing, new or joined rooms).
// (The one write still allowed, the move announcement, needs the network:
// DAST covers it.)
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_communicator/room/invite.dart';
import 'package:p2p_communicator/room/message.dart';
import 'package:p2p_communicator/room/room_protocol.dart';
import 'package:p2p_communicator/room/room_session.dart';
import 'package:p2p_communicator/room/room_style.dart';
import 'package:p2p_communicator/vault/pin_vault.dart';
import 'package:p2p_communicator/vault/room_secrets.dart';
import 'package:veilid/veilid.dart';

/// Exposes the protected transport hooks.
class _Room extends RoomSession {
  _Room(super.room);

  Future<void> append(ChatMessage m) => appendMessage(m);
  Future<void> restyle(RoomMeta Function(RoomMeta) f) => editMeta(f);
}

_Room _session() => _Room(
  UnlockedRoom(
    'slot',
    SharedSecret(
      kind: cryptoKindVLD0,
      value: BareSharedSecret.fromBytes(Uint8List(32)),
    ),
    RoomSecrets(
      roomName: 'Stara grupa',
      rosterKey: 'VLD0:roster',
      rosterWriter: 'VLD0:w',
      myName: 'Ja',
      outboxKey: 'VLD0:me',
      outboxWriter: 'VLD0:ow',
      rosterSlot: 1,
      kind: RoomKind.private,
    ),
  ),
);

ChatMessage _text() => ChatMessage(
  id: 'm1',
  author: 'VLD0:me',
  ts: 1,
  type: MsgType.text,
  text: 'cześć',
);

void main() {
  setUp(() => RoomSession.legacyWrites = false);
  tearDown(() => RoomSession.legacyWrites = false);

  test('a v1 room is read-only by default', () async {
    final s = _session();
    expect(s.readOnly, isTrue);
    expect(s.typingSupported, isFalse);
    await expectLater(s.append(_text()), throwsA(isA<StateError>()));
    await expectLater(
      s.restyle((m) => m.copyWith(name: 'nowa')),
      throwsA(isA<StyleException>()),
    );
    await expectLater(s.setNick('x'), throwsA(isA<StateError>()));
  });

  test('no new or joined v1 rooms', () async {
    await expectLater(
      RoomProtocol.create(roomName: 'x', myName: 'y'),
      throwsA(isA<StateError>()),
    );
    final invite = Invite.tryParse(
      Invite(
        rosterKey: 'VLD0:roster',
        rosterWriter: 'VLD0:w',
        roomName: 'x',
      ).encode(),
    );
    if (invite != null) {
      await expectLater(
        RoomProtocol.join(invite: invite, myName: 'y'),
        throwsA(isA<StateError>()),
      );
    }
  });

  test('tests of the old paths can turn writes back on', () {
    RoomSession.legacyWrites = true;
    expect(_session().readOnly, isFalse);
  });
}
