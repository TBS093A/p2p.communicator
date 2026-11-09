// The migration file against the real veilid-core crypto (host build).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veilid/veilid.dart';
import 'package:p2p_communicator/core/crypto.dart';
import 'package:p2p_communicator/core/veilid_node.dart';
import 'package:p2p_communicator/migration/migration_archive.dart';

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('p2pc_move_test');
    await VeilidNode.instance.start(
      storageDirectory: '${dir.path}/veilid',
      attach: false,
      insecureKeyStorage: true,
    );
  });

  // No VeilidNode.stop(): shutting veilid-core down inside the test runner
  // blocks, and the test process ends right after anyway.
  tearDownAll(() => dir.delete(recursive: true));

  Future<File> write(KeyPair to, Map<String, List<int>> entries) async {
    final f = File('${dir.path}/move-${DateTime.now().microsecondsSinceEpoch}');
    final w = await MigrationWriter.create(f, to.key);
    for (final e in entries.entries) {
      await w.add(e.key, e.value);
    }
    await w.close();
    return f;
  }

  test('round-trip: names and bytes come back in order', () async {
    final phone = await Crypto.newIdentity();
    final big = Uint8List(3 * 1024 * 1024)..fillRange(0, 1000, 7);
    final f = await write(phone, {
      'app.json': utf8.encode('{"me":"Marta"}'),
      'room/abc/media/h1': big,
      'empty': const [],
    });

    final r = await MigrationReader.open(f, phone);
    final got = await r.entries().toList();
    expect(got.map((e) => e.$1), ['app.json', 'room/abc/media/h1', 'empty']);
    expect(utf8.decode(got[0].$2), '{"me":"Marta"}');
    expect(got[1].$2.length, big.length);
    expect(got[1].$2.sublist(0, 1000).every((b) => b == 7), isTrue);
    expect(got[2].$2, isEmpty);
  });

  test('nothing readable in the file: names are encrypted too', () async {
    final phone = await Crypto.newIdentity();
    final f = await write(phone, {
      'private/0/password': utf8.encode('tajne haslo'),
    });
    final raw = latin1.decode(await f.readAsBytes());
    expect(raw.contains('private'), isFalse);
    expect(raw.contains('tajne'), isFalse);
  });

  test('another phone (wrong QR key) cannot open it', () async {
    final phone = await Crypto.newIdentity();
    final other = await Crypto.newIdentity();
    final f = await write(phone, {
      'x': [1],
    });
    await expectLater(
      MigrationReader.open(f, other),
      throwsA(isA<MigrationException>()),
    );
  });

  test('a cut-off transfer is detected, not silently accepted', () async {
    final phone = await Crypto.newIdentity();
    final f = await write(phone, {
      'a': List.filled(5000, 1),
      'b': List.filled(5000, 2),
    });
    final bytes = await f.readAsBytes();
    // Drop the end marker (and part of the last entry).
    await f.writeAsBytes(bytes.sublist(0, bytes.length - 200));
    final r = await MigrationReader.open(f, phone);
    await expectLater(r.entries().toList(), throwsA(isA<MigrationException>()));
  });

  test('a flipped byte is detected', () async {
    final phone = await Crypto.newIdentity();
    final f = await write(phone, {'a': List.filled(5000, 1)});
    final bytes = await f.readAsBytes();
    bytes[bytes.length - 300] ^= 0x40;
    await f.writeAsBytes(bytes);
    final r = await MigrationReader.open(f, phone);
    await expectLater(r.entries().toList(), throwsA(isA<MigrationException>()));
  });

  test('QR move code round-trips; junk is rejected', () async {
    final phone = await Crypto.newIdentity();
    final code = MoveCode.encode(phone.key);
    expect(MoveCode.tryParse(code), phone.key);
    expect(MoveCode.tryParse('p2pc1.something'), isNull);
    expect(MoveCode.tryParse('p2pc-move1.garbage'), isNull);
  });

  test('not a migration file', () async {
    final f = File('${dir.path}/junk')..writeAsStringSync('hello world!!');
    final phone = await Crypto.newIdentity();
    await expectLater(
      MigrationReader.open(f, phone),
      throwsA(isA<MigrationException>()),
    );
  });
}
