import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_communicator/room/message.dart';
import 'package:p2p_communicator/room/room_style.dart';

MediaRef _ref(String hash, {String mime = 'image/gif'}) => MediaRef(
  mime: mime,
  size: 1000,
  hash: hash,
  records: ['VLD0:$hash'],
  chunkSize: 32000,
  chunksPerRecord: 30,
);

void main() {
  group('EmojiCode', () {
    test('valid codes', () {
      expect(EmojiCode.isValid('party_parrot'), isTrue);
      expect(EmojiCode.isValid('ok'), isTrue);
      expect(EmojiCode.isValid('a'), isFalse);
      expect(EmojiCode.isValid('Party'), isFalse);
      expect(EmojiCode.isValid('has space'), isFalse);
      expect(EmojiCode.isValid('x' * 33), isFalse);
    });

    test('splits text around known codes only', () {
      final parts = EmojiCode.split('hej :wave: i :nope: :cat:!', {
        'wave',
        'cat',
      });
      expect(parts.map((p) => p.code ?? '[${p.text}]').toList(), [
        '[hej ]',
        'wave',
        '[ i :nope: ]',
        'cat',
        '[!]',
      ]);
    });

    test('no codes means one text part', () {
      final parts = EmojiCode.split('zwykły tekst', {'wave'});
      expect(parts, hasLength(1));
      expect(parts.single.text, 'zwykły tekst');
    });

    test('jumbo only for 1-3 emoji and whitespace', () {
      bool jumbo(String s) =>
          EmojiCode.isJumbo(EmojiCode.split(s, {'a1', 'b2'}));
      expect(jumbo(':a1:'), isTrue);
      expect(jumbo(' :a1: :b2: '), isTrue);
      expect(jumbo(':a1::a1::a1:'), isTrue);
      expect(jumbo(':a1::a1::a1::a1:'), isFalse);
      expect(jumbo('hej :a1:'), isFalse);
      expect(jumbo(':zz:'), isFalse);
      expect(jumbo(''), isFalse);
    });
  });

  group('RoomMeta', () {
    test('round-trips through JSON', () {
      final m = RoomMeta(
        name: 'Wyprawa w Tatry',
        avatar: _ref('av', mime: 'image/jpeg'),
        background: 0xFF1B2A41,
        emoji: {'party': _ref('p1'), 'cat': _ref('c1')},
      );
      final back = RoomMeta.fromJson(m.toJson());
      expect(back.name, 'Wyprawa w Tatry');
      expect(back.avatar!.hash, 'av');
      expect(back.background, 0xFF1B2A41);
      expect(back.emoji.keys, unorderedEquals(['party', 'cat']));
      expect(back.emoji['party']!.mime, 'image/gif');
    });

    test('reads the original v0.1 meta (name only)', () {
      final m = RoomMeta.fromJson({'name': 'Stary', 'v': 1});
      expect(m.name, 'Stary');
      expect(m.avatar, isNull);
      expect(m.background, isNull);
      expect(m.accent, isNull);
      expect(m.emoji, isEmpty);
    });

    test('keeps a v0.1.3 theme tint until a background is chosen', () {
      final old = RoomMeta.fromJson({'name': 'x', 'accent': 0xFF00897B});
      expect(old.accent, 0xFF00897B);
      expect(old.copyWith(name: 'y').accent, 0xFF00897B);
      final chosen = old.copyWith(background: 0xFF000000);
      expect(chosen.background, 0xFF000000);
      expect(chosen.accent, isNull);
      expect(old.copyWith(clearBackground: true).accent, isNull);
    });

    test('background image and dim round-trip, clamp and reset', () {
      final m = RoomMeta(name: 'x', backgroundImage: _ref('bg'), dim: 45);
      final back = RoomMeta.fromJson(m.toJson());
      expect(back.backgroundImage!.hash, 'bg');
      expect(back.backgroundImage!.mime, 'image/gif');
      expect(back.effectiveDim, 45);
      expect(RoomMeta(name: 'x').effectiveDim, RoomMeta.defaultDim);
      expect(RoomMeta(name: 'x', dim: 99).effectiveDim, RoomMeta.maxDim);
      final cleared = back.copyWith(clearBackgroundImage: true);
      expect(cleared.backgroundImage, isNull);
      expect(back.copyWith(name: 'y').backgroundImage!.hash, 'bg');
    });

    test('background can be reset to the default', () {
      final m = RoomMeta(name: 'x', background: 0xFF123456);
      expect(m.copyWith(clearBackground: true).background, isNull);
      expect(m.copyWith(name: 'y').background, 0xFF123456);
    });

    test('drops invalid emoji codes from the network', () {
      final m = RoomMeta.fromJson({
        'name': 'x',
        'emoji': {
          'ok_one': _ref('a').toJson(),
          'BAD CODE': _ref('b').toJson(),
          'also_bad': 'not a map',
        },
      });
      expect(m.emoji.keys, ['ok_one']);
    });

    test('blank name falls back', () {
      expect(RoomMeta.fromJson({'name': '  '}, fallbackName: 'F').name, 'F');
    });

    test('copyWith can clear the avatar', () {
      final m = RoomMeta(name: 'x', avatar: _ref('a'));
      expect(m.copyWith(clearAvatar: true).avatar, isNull);
      expect(m.copyWith(background: 1).avatar!.hash, 'a');
    });

    test('a full emoji pack fits in one roster subkey', () {
      final m = RoomMeta(
        name: 'x' * 40,
        avatar: _ref('a' * 64),
        background: 0xFF000000,
        emoji: {
          for (var i = 0; i < RoomMeta.maxEmoji; i++)
            'emoji_code_number_$i': MediaRef(
              mime: 'image/gif',
              size: 500000,
              hash: 'h' * 64,
              // Real record keys: kind + 43-char key + 43-char secret.
              records: ['VLD0:${'k' * 43}:${'s' * 43}'],
              chunkSize: 32000,
              chunksPerRecord: 30,
            ),
        },
      );
      final bytes = utf8.encode(jsonEncode(m.toJson())).length;
      expect(bytes, lessThan(RoomMeta.maxEncodedBytes));
    });
  });

  group('MemberProfile', () {
    test('round-trips and tolerates the old head format', () {
      final p = MemberProfile(
        name: 'Ala',
        avatar: _ref('av'),
        color: 0xFFE53935,
      );
      final back = MemberProfile.fromJson({...p.toJson(), 'count': 7});
      expect(back.name, 'Ala');
      expect(back.avatar!.hash, 'av');
      expect(back.color, 0xFFE53935);

      final old = MemberProfile.fromJson({'count': 3, 'name': 'Ola'});
      expect(old.name, 'Ola');
      expect(old.color, isNull);
    });

    test('bubble color can be reset to the default', () {
      const p = MemberProfile(name: 'x', color: 0xFF112233);
      expect(p.copyWith(clearColor: true).color, isNull);
      expect(p.copyWith(name: 'y').color, 0xFF112233);
    });
  });

  test('text on presets and default bubbles stays readable', () {
    for (final c in [
      ...stylePalette,
      defaultMyBubble,
      defaultOtherBubbleLight,
      defaultOtherBubbleDark,
    ]) {
      final bg = Color(c);
      final fg = onColor(bg);
      final l1 = bg.computeLuminance();
      final l2 = fg.computeLuminance();
      final ratio =
          (l1 > l2 ? l1 + 0.05 : l2 + 0.05) / (l1 > l2 ? l2 + 0.05 : l1 + 0.05);
      expect(
        ratio,
        greaterThanOrEqualTo(3.0),
        reason: 'contrast on #${c.toRadixString(16)}',
      );
    }
  });
}
