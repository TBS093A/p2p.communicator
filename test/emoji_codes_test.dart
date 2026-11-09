import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_communicator/room/emoji_codes.dart';
import 'package:p2p_communicator/room/room_style.dart';

void main() {
  test('codes come from file names, sanitized', () {
    expect(
      suggestEmojiCodes([
        '/x/Party Parrot.gif',
        '/x/kot-2.PNG',
        '/x/__ok__.webp',
      ], {}),
      ['party_parrot', 'kot_2', 'ok'],
    );
  });

  test('duplicates and taken codes get a number suffix', () {
    expect(
      suggestEmojiCodes(['/a/cat.gif', '/b/cat.gif', '/c/Cat.png'], {'cat'}),
      ['cat_2', 'cat_3', 'cat_4'],
    );
  });

  test('unusable names fall back to emoji_N; all results are valid', () {
    final codes = suggestEmojiCodes([
      '/x/ż.gif', // nothing left after sanitizing
      '/x/a.gif', // too short
      '/x/${'x' * 60}.gif', // too long
      '/x/!!!.png',
    ], {});
    expect(codes[0], 'emoji');
    expect(codes[1], 'emoji_2');
    expect(codes[2].length, lessThanOrEqualTo(32));
    expect(codes[3], 'emoji_3');
    expect(codes.every(EmojiCode.isValid), isTrue);
    expect(codes.toSet().length, codes.length);
  });
}
