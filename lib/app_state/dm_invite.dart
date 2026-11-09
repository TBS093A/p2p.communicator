import 'dart:convert';
import 'dart:typed_data';

/// The bytes a DM invite's sender signs.
///
/// HPKE (`Crypto.sealTo`) only hides the invite from everyone but the
/// recipient; it says nothing about who sealed it. Without a signature any
/// member of a shared group could seal an invite claiming `from` = someone
/// else's profile. So the sender signs these bytes with the identity key
/// published in their global profile, and the recipient checks the
/// signature against that profile before showing the invite.
///
/// The recipient's identity is part of the signed bytes, so a signed invite
/// cannot be re-sealed to a third person and passed off as addressed to them.
Uint8List dmInviteSignedBytes({
  required String invite,
  required String from,
  required String to,
}) => Uint8List.fromList(
  utf8.encode(jsonEncode(['p2pc-dm-invite-sig-v1', invite, from, to])),
);
