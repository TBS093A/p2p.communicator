import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:veilid/veilid.dart';

import '../core/crypto.dart';

class MigrationException implements Exception {
  MigrationException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The QR the new phone shows: a one-time public key the old phone seals the
/// migration file to. Only the new phone, which holds the secret half in
/// memory, can open that file.
class MoveCode {
  static const _prefix = 'p2pc-move1.';

  static String encode(PublicKey key) => '$_prefix$key';

  static PublicKey? tryParse(String raw) {
    final s = raw.trim();
    if (!s.startsWith(_prefix)) return null;
    try {
      return PublicKey.fromString(s.substring(_prefix.length));
    } on Object {
      return null;
    }
  }
}

/// Streamed, encrypted container for moving everything to a new phone.
///
/// ```
/// "P2PCMOVE1"                              magic
/// u32 len | HPKE-seal(receiver, dataKey)   only the new phone opens it
/// ( u32 len | AEAD(dataKey, u16 nameLen | name | data) )*
/// last entry: "__end__" with u32 count    detects a cut-off transfer
/// ```
///
/// Entry names are inside the encryption too, so the file reveals nothing
/// but its size. Entries are written one by one, so big media never sit in
/// memory all at once.
class MigrationWriter {
  MigrationWriter._(this._out, this._key);

  static const _magic = 'P2PCMOVE1';
  static const keyContext = 'p2pc-move-v1-key';
  static const entryContext = 'p2pc-move-v1-entry';
  static const endName = '__end__';

  final RandomAccessFile _out;
  final SharedSecret _key;
  int _count = 0;

  static Future<MigrationWriter> create(File file, PublicKey receiver) async {
    final dataKey = await Crypto.randomBytes(32);
    final sealedKey = await Crypto.sealTo(
      receiver,
      dataKey,
      context: keyContext,
    );
    final out = await file.open(mode: FileMode.write);
    await out.writeFrom(ascii.encode(_magic));
    await out.writeFrom(_u32(sealedKey.length));
    await out.writeFrom(sealedKey);
    return MigrationWriter._(out, Crypto.secretFromBytes(dataKey));
  }

  Future<void> add(String name, List<int> data) async {
    if (name == endName) throw ArgumentError('reserved entry name');
    await _write(name, data);
    _count++;
  }

  Future<void> addJson(String name, Object json) =>
      add(name, utf8.encode(jsonEncode(json)));

  Future<void> close() async {
    await _write(endName, _u32(_count));
    await _out.flush();
    await _out.close();
  }

  Future<void> _write(String name, List<int> data) async {
    final n = utf8.encode(name);
    final plain =
        (BytesBuilder(copy: false)
              ..add(_u16(n.length))
              ..add(n)
              ..add(data))
            .toBytes();
    final sealed = await Crypto.seal(_key, plain, context: entryContext);
    await _out.writeFrom(_u32(sealed.length));
    await _out.writeFrom(sealed);
  }
}

/// Reads a [MigrationWriter] file with the new phone's one-time key pair.
class MigrationReader {
  MigrationReader._(this._in, this._key);

  final RandomAccessFile _in;
  final SharedSecret _key;
  bool _ended = false;

  static Future<MigrationReader> open(File file, KeyPair me) async {
    final input = await file.open();
    try {
      final magic = await input.read(MigrationWriter._magic.length);
      if (ascii.decode(magic, allowInvalid: true) != MigrationWriter._magic) {
        throw MigrationException('To nie jest plik przeniesienia');
      }
      final sealedKey = await _readBlock(input);
      final Uint8List dataKey;
      try {
        dataKey = await Crypto.openWith(
          me,
          sealedKey,
          context: MigrationWriter.keyContext,
        );
      } on Object {
        throw MigrationException(
          'Ten plik był przygotowany dla innego kodu QR. Zeskanuj kod z '
          'tego ekranu i utwórz plik jeszcze raz.',
        );
      }
      return MigrationReader._(input, Crypto.secretFromBytes(dataKey));
    } on Object {
      await input.close();
      rethrow;
    }
  }

  /// All entries in order. Throws if the file was altered or cut off.
  Stream<(String, Uint8List)> entries() async* {
    var count = 0;
    try {
      while (true) {
        if (await _in.position() >= await _in.length()) break;
        final sealed = await _readBlock(_in);
        final Uint8List plain;
        try {
          plain = await Crypto.open(
            _key,
            sealed,
            context: MigrationWriter.entryContext,
          );
        } on Object {
          throw MigrationException('Plik przeniesienia jest uszkodzony');
        }
        final view = ByteData.sublistView(plain);
        final nameLen = view.getUint16(0);
        final name = utf8.decode(Uint8List.sublistView(plain, 2, 2 + nameLen));
        final data = Uint8List.sublistView(plain, 2 + nameLen);
        if (name == MigrationWriter.endName) {
          if (ByteData.sublistView(data).getUint32(0) != count) {
            throw MigrationException('Plik przeniesienia jest niekompletny');
          }
          _ended = true;
          break;
        }
        count++;
        yield (name, data);
      }
      if (!_ended) {
        throw MigrationException(
          'Plik przeniesienia jest niekompletny (przerwany transfer?)',
        );
      }
    } finally {
      await _in.close();
    }
  }

  static Future<Uint8List> _readBlock(RandomAccessFile input) async {
    final lenBytes = await input.read(4);
    if (lenBytes.length < 4) {
      throw MigrationException('Plik przeniesienia jest niekompletny');
    }
    final len = ByteData.sublistView(lenBytes).getUint32(0);
    final block = await input.read(len);
    if (block.length < len) {
      throw MigrationException('Plik przeniesienia jest niekompletny');
    }
    return block;
  }
}

Uint8List _u32(int v) => (ByteData(4)..setUint32(0, v)).buffer.asUint8List();
Uint8List _u16(int v) => (ByteData(2)..setUint16(0, v)).buffer.asUint8List();
