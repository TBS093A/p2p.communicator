import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_communicator/app_state/dm_invite.dart';

void main() {
  test('signed bytes bind invite, sender and recipient', () {
    final base = dmInviteSignedBytes(invite: 'i', from: 'f', to: 't');
    expect(
      dmInviteSignedBytes(invite: 'i', from: 'f', to: 't'),
      base,
      reason: 'deterministic',
    );
    for (final other in [
      dmInviteSignedBytes(invite: 'i2', from: 'f', to: 't'),
      dmInviteSignedBytes(invite: 'i', from: 'f2', to: 't'),
      dmInviteSignedBytes(invite: 'i', from: 'f', to: 't2'),
    ]) {
      expect(other, isNot(base));
    }
  });

  test('fields cannot be shifted into each other', () {
    // With plain concatenation "ab"+"c" and "a"+"bc" would sign the same.
    expect(
      dmInviteSignedBytes(invite: 'ab', from: 'c', to: 't'),
      isNot(dmInviteSignedBytes(invite: 'a', from: 'bc', to: 't')),
    );
  });

  test('carries a version label', () {
    final s = utf8.decode(dmInviteSignedBytes(invite: 'i', from: 'f', to: 't'));
    expect(s, startsWith('["p2pc-dm-invite-sig-v1"'));
  });
}
