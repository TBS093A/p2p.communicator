/// Newest DHT value sequence number seen per record subkey.
///
/// Values can arrive out of order: a change notification can be delivered
/// after a newer value was already read, and a lagging replica can still
/// serve an older one. Such a value must not roll back what is shown (a
/// member's profile, the room look).
class FreshnessGate {
  final _seq = <String, int>{};

  /// The newest sequence number seen for [record] / [subkey], if any.
  int? seen(String record, int subkey) => _seq['$record#$subkey'];

  /// Records [seq] and says how it compares with what was seen before.
  Freshness check(String record, int subkey, int seq) {
    final k = '$record#$subkey';
    final known = _seq[k];
    if (known != null && seq < known) return Freshness.older;
    _seq[k] = seq;
    return known == seq ? Freshness.same : Freshness.newer;
  }

  void forget(String record) =>
      _seq.removeWhere((k, _) => k.startsWith('$record#'));
}

enum Freshness { older, same, newer }

/// Quick retries for a value that has not propagated yet: 1, 2 and 4 s,
/// then give up until the next change notification or the slow poll.
/// One schedule per member, so many members cannot cause a retry storm.
class RetryBackoff {
  RetryBackoff({this.delays = const [1, 2, 4]});

  /// Seconds to wait before each retry.
  final List<int> delays;
  final _attempt = <String, int>{};

  /// The wait before the next retry of [id], or null when the retries are
  /// used up.
  Duration? next(String id) {
    final n = _attempt[id] ?? 0;
    if (n >= delays.length) return null;
    _attempt[id] = n + 1;
    return Duration(seconds: delays[n]);
  }

  /// Something new arrived for [id]: the next delay starts again from 1 s.
  void reset(String id) => _attempt.remove(id);

  int attempts(String id) => _attempt[id] ?? 0;
}
