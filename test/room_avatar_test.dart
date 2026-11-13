import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_communicator/room/blob_store.dart';
import 'package:p2p_communicator/room/room_session.dart';

Map<String, dynamic> av({
  String mime = 'image/png',
  int size = 50000,
  int cs = BlobStore.chunkSize,
  int cpr = BlobStore.chunksPerRecord,
  List<String> rec = const ['VLD0:r1'],
  String hash = 'h',
}) => {
  'mime': mime,
  'size': size,
  'hash': hash,
  'rec': rec,
  'cs': cs,
  'cpr': cpr,
};

void main() {
  test('a plausible avatar is accepted', () {
    final ref = RoomSession.parseRoomAvatar(av());
    expect(ref, isNotNull);
    expect(ref!.mime, 'image/png');
    for (final m in ['image/gif', 'image/webp', 'image/jpeg']) {
      expect(RoomSession.parseRoomAvatar(av(mime: m)), isNotNull, reason: m);
    }
  });

  test('anything else from another head is ignored', () {
    for (final bad in <Object?>[
      null,
      'x',
      42,
      [1],
      <String, dynamic>{},
      {'mime': 'image/png'}, // missing fields
      av(mime: 'video/mp4'),
      av(mime: 'application/octet-stream'),
      av(mime: 'image/svg+xml'),
      av(size: 0),
      av(size: 50 * 1024 * 1024), // far over the avatar limit
      av(cs: 1), // would mean a huge number of chunk fetches
      av(cpr: 1),
      av(rec: const []), // records inconsistent with the size
      av(rec: const ['VLD0:a', 'VLD0:b']),
      av(rec: const ['']),
      av(hash: ''),
      {...av(), 'size': 'big'},
    ]) {
      expect(RoomSession.parseRoomAvatar(bad), isNull, reason: '$bad');
    }
  });
}
