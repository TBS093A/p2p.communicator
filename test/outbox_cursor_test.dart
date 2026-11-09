import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_communicator/room/outbox_cursor.dart';

void main() {
  const ring = 200;

  test('a slot that was not propagated yet is fetched again later', () {
    final c = OutboxCursor();
    final first = c.due(5, ring);
    expect(first, [0, 1, 2, 3, 4]);
    c.settle(5, first, {2}); // #2 read empty

    final second = c.due(7, ring);
    expect(second, [2, 5, 6]); // missing one first, then the new ones
    c.settle(7, second, {});
    expect(c.missing, isEmpty);
    expect(c.next, 7);
    expect(c.due(7, ring), isEmpty);
  });

  test('a missing seq is dropped once the ring overwrote its slot', () {
    final c = OutboxCursor();
    c.settle(3, c.due(3, ring), {1});
    final due = c.due(3 + ring, ring);
    expect(due.first, 3); // #1 (and #0..#2) are below the floor now
    expect(c.missing, isEmpty);
  });

  test('a stale head does not move the cursor back', () {
    final c = OutboxCursor(next: 10, missing: [8]);
    final due = c.due(8, ring); // head from a lagging replica
    expect(due, isEmpty);
    c.settle(8, due, {});
    expect(c.next, 10);
    expect(c.missing, {8});
  });

  test('cache round trip, including the old int format', () {
    final c = OutboxCursor(next: 12, missing: [9, 4]);
    final back = OutboxCursor.fromJson(c.toJson());
    expect(back.next, 12);
    expect(back.missing, {4, 9});

    final legacy = OutboxCursor.fromJson(42);
    expect(legacy.next, 42);
    expect(legacy.missing, isEmpty);
  });
}
