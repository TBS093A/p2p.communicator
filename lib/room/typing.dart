/// "Someone is typing" for v1 rooms.
///
/// The sender puts `ty: <ms>` into its outbox head when it starts typing and
/// refreshes it at most every [refreshEvery] while typing goes on. There is
/// no "stopped" write: the next message rewrites the head without `ty`, and
/// an abandoned draft simply expires on the receiver after [showFor].
/// Sending it is opt-in per conversation (PROTOCOL §B8: presence is off by
/// default). In v2 this becomes an ephemeral E2EE message instead.
class Typing {
  Typing._();

  /// The receiver shows the dots this long after the stamp. Longer than
  /// [refreshEvery] so continued typing never flickers, and tolerant of
  /// some clock difference between phones.
  static const showFor = Duration(seconds: 12);

  /// The sender rewrites its head at most this often while typing.
  static const refreshEvery = Duration(seconds: 8);

  /// "X pisze…", "X i Y piszą…", "Kilka osób pisze…"; empty for nobody.
  static String label(List<String> names) => switch (names.length) {
    0 => '',
    1 => '${names[0]} pisze…',
    2 => '${names[0]} i ${names[1]} piszą…',
    _ => 'Kilka osób pisze…',
  };
}

/// Who is typing, from the `ty` stamps in members' heads.
class TypingBoard {
  final _since = <String, int>{};

  /// A head was read: [ty] is its stamp, or null when it has none.
  /// Returns whether the board changed.
  bool note(String member, Object? ty) {
    if (ty is! int) return _since.remove(member) != null;
    if (_since[member] == ty) return false;
    _since[member] = ty;
    return true;
  }

  /// A message from [member] arrived: they are not typing it any more.
  bool messageFrom(String member) => _since.remove(member) != null;

  /// Members whose stamp is recent at [nowMs], oldest stamp first. A stamp
  /// far in the future (a wrong clock) counts as stale too.
  List<String> typing(int nowMs) {
    final window = Typing.showFor.inMilliseconds;
    final live =
        _since.entries.where((e) => (nowMs - e.value).abs() < window).toList()
          ..sort((a, b) => a.value.compareTo(b.value));
    return [for (final e in live) e.key];
  }

  /// When the next currently shown member expires, if anyone is shown.
  Duration? nextExpiry(int nowMs) {
    final window = Typing.showFor.inMilliseconds;
    int? soonest;
    for (final ty in _since.values) {
      final left = ty + window - nowMs;
      if (left > 0 && (nowMs - ty).abs() < window) {
        if (soonest == null || left < soonest) soonest = left;
      }
    }
    return soonest == null ? null : Duration(milliseconds: soonest);
  }
}

/// Sender side: whether a keystroke should (re)write the head.
class TypingThrottle {
  int? _last;

  /// True at the start of typing and then at most every
  /// [Typing.refreshEvery].
  bool shouldSend(int nowMs) {
    final last = _last;
    if (last != null && nowMs - last < Typing.refreshEvery.inMilliseconds) {
      return false;
    }
    _last = nowMs;
    return true;
  }

  /// A message went out (its head has no stamp): the next keystroke starts
  /// a new typing period.
  void reset() => _last = null;
}
