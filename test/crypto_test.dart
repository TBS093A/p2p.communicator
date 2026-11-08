// Runs the app's crypto helpers against the real veilid-core (host build,
// detached from the network), so FFI-level problems show up in `flutter test`
// instead of only on a device.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_communicator/core/crypto.dart';
import 'package:p2p_communicator/core/veilid_node.dart';

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('p2pc_crypto_test');
    await VeilidNode.instance.start(
      storageDirectory: dir.path,
      attach: false,
      insecureKeyStorage: true,
    );
  });

  // No VeilidNode.stop() here: shutting veilid-core down inside the test
  // runner blocks, and the test process ends right after anyway.
  tearDownAll(() => dir.delete(recursive: true));

  Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

  test('seal/open round-trips, with and without context', () async {
    final key = Crypto.secretFromBytes(await Crypto.randomBytes(32));
    final plain = bytes('wiadomość 👋');

    expect(await Crypto.open(key, await Crypto.seal(key, plain)), plain);
    expect(
      await Crypto.open(
        key,
        await Crypto.seal(key, plain, context: 'slot'),
        context: 'slot',
      ),
      plain,
    );
  });

  test('a different context or key does not open the data', () async {
    final key = Crypto.secretFromBytes(await Crypto.randomBytes(32));
    final other = Crypto.secretFromBytes(await Crypto.randomBytes(32));
    final sealed = await Crypto.seal(key, bytes('x'), context: 'slot');

    await expectLater(
      Crypto.open(key, sealed, context: 'data'),
      throwsA(anything),
    );
    await expectLater(
      Crypto.open(other, sealed, context: 'slot'),
      throwsA(anything),
    );
  });

  test('password derivation is deterministic and salt-dependent', () async {
    final salt = await Crypto.randomBytes(await Crypto.saltLength());
    final salt2 = await Crypto.randomBytes(await Crypto.saltLength());
    final a = await Crypto.deriveFromPassword(bytes('1234'), salt);
    final b = await Crypto.deriveFromPassword(bytes('1234'), salt);
    final c = await Crypto.deriveFromPassword(bytes('1234'), salt2);
    final d = await Crypto.deriveFromPassword(bytes('1235'), salt);
    expect(a, b);
    expect(a, isNot(c));
    expect(a, isNot(d));
  });

  test('sealed size matches what decoy slots assume', () async {
    final key = Crypto.secretFromBytes(await Crypto.randomBytes(32));
    final sealed = await Crypto.seal(key, Uint8List(4096), context: 'slot');
    expect(
      sealed.length,
      await Crypto.nonceLength() + 4096 + await Crypto.aeadOverhead(),
    );
  });
}
