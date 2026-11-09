/// Read position in one member's outbox ring.
///
/// DHT replicas lag: the head can already say `count = 5` while slot 3 still
/// reads empty (or still holds the message from the previous lap). Such a
/// slot is remembered in [missing] and fetched again on every later sync,
/// instead of being skipped for good. A missing seq is given up only once the
/// ring has wrapped past it, because then the slot holds a newer message and
/// the old one is gone from the network anyway.
class OutboxCursor {
  OutboxCursor({this.next = 0, Iterable<int> missing = const []})
    : missing = {...missing};

  /// First seq never asked for.
  int next;

  /// Seqs below [next] that were asked for but not read yet.
  final Set<int> missing;

  /// Seqs to fetch for an outbox whose head says [count]: the still-missing
  /// ones first, then everything new. Drops seqs the ring already overwrote.
  List<int> due(int count, int ring) {
    final floor = count - ring;
    missing.removeWhere((s) => s < floor);
    final start = next < floor ? floor : next;
    return [
      ...(missing.where((s) => s < count).toList()..sort()),
      for (var i = start; i < count; i++) i,
    ];
  }

  /// Records the outcome of fetching [asked] (from [due]): [missed] are the
  /// seqs that could not be read yet.
  void settle(int count, Iterable<int> asked, Set<int> missed) {
    missing
      ..removeAll(asked)
      ..addAll(missed);
    if (count > next) next = count;
  }

  Map<String, dynamic> toJson() => {
    'next': next,
    if (missing.isNotEmpty) 'missing': missing.toList()..sort(),
  };

  /// Accepts the old cache format too, where the value was just `next`.
  factory OutboxCursor.fromJson(Object? j) {
    if (j is int) return OutboxCursor(next: j);
    if (j is Map) {
      return OutboxCursor(
        next: j['next'] as int? ?? 0,
        missing: (j['missing'] as List? ?? const []).cast<int>(),
      );
    }
    return OutboxCursor();
  }
}
