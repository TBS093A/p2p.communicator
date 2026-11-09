import 'message.dart';

/// Consecutive messages from one author, shown with one avatar (Telegram
/// style) and the author's name only above the first bubble.
class MessageGroup {
  MessageGroup(this.author, this.messages);

  final String author;

  /// Oldest first.
  final List<ChatMessage> messages;
}

/// Splits [messages] (oldest first) into groups: same author, each message
/// at most [gap] after the previous one. A longer pause starts a new group,
/// like in most messengers.
List<MessageGroup> groupMessages(
  List<ChatMessage> messages, {
  Duration gap = const Duration(minutes: 10),
}) {
  final groups = <MessageGroup>[];
  for (final m in messages) {
    final last = groups.isEmpty ? null : groups.last;
    if (last != null &&
        last.author == m.author &&
        m.ts - last.messages.last.ts <= gap.inMilliseconds) {
      last.messages.add(m);
    } else {
      groups.add(MessageGroup(m.author, [m]));
    }
  }
  return groups;
}
