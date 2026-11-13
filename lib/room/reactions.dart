import 'message.dart';
import 'room_style.dart';

/// Who reacted to which message with which of the room's custom emoji.
///
/// Each member has at most one reaction per message (like Messenger): their
/// newest `reaction` message for a target wins, and one with no emoji takes
/// the reaction back. Newest = higher `seq` in the author's outbox, which is
/// monotonic per author (unlike phone clocks), so every member arrives at
/// the same result whatever order the messages are delivered in.
class Reactions {
  /// target message id -> author outbox -> their latest reaction.
  final _latest = <String, Map<String, _Entry>>{};

  /// Applies a `reaction` message. Returns whether anything changed.
  bool apply(ChatMessage m) {
    if (m.type != MsgType.reaction) return false;
    final seq = m.seq;
    final x = m.extra;
    final to = x?['to'];
    final e = x?['e'];
    if (seq == null || to is! String || to.isEmpty) return false;
    if (e != null && (e is! String || !EmojiCode.isValid(e))) return false;
    final code = e as String?;
    final byAuthor = _latest.putIfAbsent(to, () => {});
    final prev = byAuthor[m.author];
    if (prev != null && seq <= prev.seq) return false;
    byAuthor[m.author] = _Entry(code, seq);
    return prev?.code != code;
  }

  /// Emoji code -> members who chose it, for [target], most chosen first.
  /// Only codes for which [show] is true (the room still has that emoji).
  List<(String code, List<String> authors)> of(
    String target, {
    bool Function(String code)? show,
  }) {
    final by = <String, List<String>>{};
    for (final e in (_latest[target] ?? const <String, _Entry>{}).entries) {
      final code = e.value.code;
      if (code == null || !(show?.call(code) ?? true)) continue;
      by.putIfAbsent(code, () => []).add(e.key);
    }
    final list = [for (final e in by.entries) (e.key, e.value..sort())];
    list.sort((a, b) {
      final n = b.$2.length.compareTo(a.$2.length);
      return n != 0 ? n : a.$1.compareTo(b.$1);
    });
    return list;
  }

  /// [author]'s current reaction to [target], if any.
  String? mine(String target, String author) => _latest[target]?[author]?.code;

  int get targetCount => _latest.length;

  /// Drops reactions to messages no longer kept (the cache keeps the newest
  /// 3000), once there are more targets than that. A reaction can arrive
  /// before its message, so the map is not pruned on every save.
  void prune(Set<String> keep, {int max = 3000}) {
    if (_latest.length <= max) return;
    _latest.removeWhere((target, _) => !keep.contains(target));
  }

  /// Local cache form.
  Map<String, dynamic> toJson() => {
    for (final t in _latest.entries)
      t.key: {
        for (final a in t.value.entries)
          a.key: {'e': a.value.code, 'seq': a.value.seq},
      },
  };

  void loadJson(Object? j) {
    if (j is! Map) return;
    for (final t in j.entries) {
      final authors = t.value;
      if (t.key is! String || authors is! Map) continue;
      for (final a in authors.entries) {
        final v = a.value;
        if (a.key is! String || v is! Map) continue;
        final code = v['e'];
        final seq = v['seq'];
        if (seq is! int) continue;
        if (code != null && (code is! String || !EmojiCode.isValid(code))) {
          continue;
        }
        _latest.putIfAbsent(t.key as String, () => {})[a.key as String] =
            _Entry(code as String?, seq);
      }
    }
  }
}

class _Entry {
  const _Entry(this.code, this.seq);
  final String? code;
  final int seq;
}
