import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_communicator/room/sync_gate.dart';

void main() {
  group('FreshnessGate', () {
    test('first value is newer, then same, newer, older', () {
      final g = FreshnessGate();
      expect(g.check('rec', 0, 3), Freshness.newer);
      expect(g.check('rec', 0, 3), Freshness.same);
      expect(g.check('rec', 0, 5), Freshness.newer);
      expect(g.seen('rec', 0), 5);
    });

    test('a value older than one already read is rejected and not kept', () {
      // A change notification delivered after a poll already read a newer
      // head (or a lagging replica): it must not roll the head back.
      final g = FreshnessGate();
      expect(g.check('alice', 0, 7), Freshness.newer);
      expect(g.check('alice', 0, 6), Freshness.older);
      expect(g.seen('alice', 0), 7);
      expect(g.check('alice', 0, 7), Freshness.same);
    });

    test('records and subkeys are independent; forget clears a record', () {
      final g = FreshnessGate();
      g.check('alice', 0, 9);
      expect(g.check('bob', 0, 1), Freshness.newer);
      expect(g.check('alice', 1, 1), Freshness.newer);
      g.forget('alice');
      expect(g.seen('alice', 0), isNull);
      expect(g.seen('bob', 0), 1);
    });
  });

  group('RetryBackoff', () {
    test('1, 2, 4 seconds, then gives up', () {
      final b = RetryBackoff();
      expect(b.next('a'), const Duration(seconds: 1));
      expect(b.next('a'), const Duration(seconds: 2));
      expect(b.next('a'), const Duration(seconds: 4));
      expect(b.next('a'), isNull);
      expect(b.attempts('a'), 3);
    });

    test('per member, and reset starts again', () {
      final b = RetryBackoff();
      b.next('a');
      b.next('a');
      expect(b.next('b'), const Duration(seconds: 1));
      b.reset('a');
      expect(b.next('a'), const Duration(seconds: 1));
    });
  });
}
