import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_communicator/room/typing.dart';

void main() {
  const s = 1000;
  final show = Typing.showFor.inMilliseconds;
  final refresh = Typing.refreshEvery.inMilliseconds;

  group('TypingBoard', () {
    test('a fresh stamp shows, an old one expires', () {
      final b = TypingBoard();
      expect(b.note('ola', 100 * s), isTrue);
      expect(b.typing(100 * s + 1), ['ola']);
      expect(b.typing(100 * s + show - 1), ['ola']);
      expect(b.typing(100 * s + show), isEmpty);
    });

    test('a stale stamp read later (poll, reopened room) is not shown', () {
      final b = TypingBoard();
      b.note('ola', 100 * s);
      expect(b.typing(100 * s + 60 * s), isEmpty);
    });

    test('a stamp far in the future (wrong clock) is not shown', () {
      final b = TypingBoard();
      b.note('ola', 200 * s);
      expect(b.typing(100 * s), isEmpty);
      // Small clock differences are tolerated.
      b.note('ola', 105 * s);
      expect(b.typing(100 * s), ['ola']);
    });

    test('a head without `ty` or a message from them clears it', () {
      final b = TypingBoard();
      b.note('ola', 100 * s);
      expect(b.note('ola', null), isTrue);
      expect(b.typing(100 * s), isEmpty);
      b.note('ola', 100 * s);
      expect(b.messageFrom('ola'), isTrue);
      expect(b.typing(100 * s), isEmpty);
      expect(b.messageFrom('ola'), isFalse);
      expect(b.note('ola', 'garbage'), isFalse);
    });

    test('several typists, oldest first; next expiry', () {
      final b = TypingBoard();
      b.note('jan', 102 * s);
      b.note('ola', 100 * s);
      expect(b.typing(103 * s), ['ola', 'jan']);
      expect(
        b.nextExpiry(103 * s),
        Duration(milliseconds: 100 * s + show - 103 * s),
      );
      expect(b.nextExpiry(200 * s), isNull);
      expect(b.note('ola', 100 * s), isFalse, reason: 'same stamp: no change');
    });
  });

  group('TypingThrottle', () {
    test('first keystroke sends, then at most every refresh period', () {
      final t = TypingThrottle();
      expect(t.shouldSend(0), isTrue);
      expect(t.shouldSend(1), isFalse);
      expect(t.shouldSend(refresh - 1), isFalse);
      expect(t.shouldSend(refresh), isTrue);
    });

    test('after a message the next keystroke sends again', () {
      final t = TypingThrottle();
      t.shouldSend(0);
      t.reset();
      expect(t.shouldSend(1), isTrue);
    });

    test('refresh is shorter than the receiver window: no flicker', () {
      expect(refresh, lessThan(show));
    });
  });

  test('incoming label', () {
    expect(Typing.incomingLabel(0), '');
    expect(Typing.incomingLabel(1), 'Odbieram 1 wiadomość…');
    expect(Typing.incomingLabel(3), 'Odbieram 3 wiadomości…');
    expect(Typing.incomingLabel(12), 'Odbieram 12 wiadomości…');
  });

  test('labels', () {
    expect(Typing.label([]), '');
    expect(Typing.label(['Ola']), 'Ola pisze…');
    expect(Typing.label(['Ola', 'Jan']), 'Ola i Jan piszą…');
    expect(Typing.label(['Ola', 'Jan', 'Ewa']), 'Kilka osób pisze…');
  });
}
