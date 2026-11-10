import 'package:characters/characters.dart';

enum MsgType {
  text,
  image,
  video,
  voice,

  /// Hidden: a DM invite sealed to one member's identity key. Never shown in
  /// the conversation; only the addressee can open it.
  dmInvite;

  bool get hidden => this == MsgType.dmInvite;
}

enum MsgStatus { sending, sent, failed }

/// Pointer to a media file stored in the DHT as encrypted chunk records.
class MediaRef {
  MediaRef({
    required this.mime,
    required this.size,
    required this.hash,
    required this.records,
    required this.chunkSize,
    required this.chunksPerRecord,
    this.width,
    this.height,
    this.durationMs,
  });

  final String mime;
  final int size;

  /// BLAKE3 of the plain file, checked after download.
  final String hash;

  /// DHT record keys (including their encryption secret) holding the chunks.
  final List<String> records;
  final int chunkSize;
  final int chunksPerRecord;
  final int? width;
  final int? height;
  final int? durationMs;

  int get chunkCount => (size + chunkSize - 1) ~/ chunkSize;

  Map<String, dynamic> toJson() => {
    'mime': mime,
    'size': size,
    'hash': hash,
    'rec': records,
    'cs': chunkSize,
    'cpr': chunksPerRecord,
    if (width != null) 'w': width,
    if (height != null) 'h': height,
    if (durationMs != null) 'd': durationMs,
  };

  factory MediaRef.fromJson(Map<String, dynamic> j) => MediaRef(
    mime: j['mime'] as String,
    size: j['size'] as int,
    hash: j['hash'] as String,
    records: (j['rec'] as List).cast<String>(),
    chunkSize: j['cs'] as int,
    chunksPerRecord: j['cpr'] as int,
    width: j['w'] as int?,
    height: j['h'] as int?,
    durationMs: j['d'] as int?,
  );
}

/// What a reply quotes: enough to show the quote even when the original is
/// no longer available (outbox ring overwritten, cache trimmed, joined
/// later). Media is quoted by type and caption only, never by MediaRef.
class ReplyRef {
  const ReplyRef({
    required this.id,
    required this.author,
    required this.type,
    this.preview = '',
  });

  /// Longest preview kept, in user-perceived characters.
  static const maxPreview = 100;

  final String id;

  /// Outbox key of the original's author.
  final String author;
  final MsgType type;

  /// Start of the original's text (or caption), at most [maxPreview]
  /// characters.
  final String preview;

  /// Quote of [m]; null for types that cannot be replied to.
  static ReplyRef? of(ChatMessage m) {
    if (m.type.hidden) return null;
    return ReplyRef(
      id: m.id,
      author: m.author,
      type: m.type,
      preview: clip(m.text ?? ''),
    );
  }

  /// [s] cut to [maxPreview] characters by grapheme, so an emoji or an
  /// accented letter is never split.
  static String clip(String s) {
    final flat = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    final c = flat.characters;
    return c.length <= maxPreview ? flat : '${c.take(maxPreview)}…';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'a': author,
    't': type.name,
    if (preview.isNotEmpty) 'p': preview,
  };

  /// Never throws: anything malformed gives null, so the reply itself is
  /// still shown (as a normal message).
  static ReplyRef? tryParse(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    final author = j['a'];
    final type = MsgType.values.where((t) => t.name == j['t']).firstOrNull;
    final preview = j['p'];
    if (id is! String || id.isEmpty || author is! String || type == null) {
      return null;
    }
    if (type.hidden) return null;
    return ReplyRef(
      id: id,
      author: author,
      type: type,
      preview: preview is String ? clip(preview) : '',
    );
  }
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.author,
    required this.ts,
    required this.type,
    this.text,
    this.media,
    this.seq,
    this.status = MsgStatus.sent,
    this.extra,
    this.replyTo,
  });

  final String id;

  /// The message this one answers, if any (wire key `re`).
  final ReplyRef? replyTo;

  /// Type-specific fields (a DM invite's addressee and sealed payload).
  final Map<String, dynamic>? extra;

  /// Outbox record key of the author; the roster maps it to a display name.
  final String author;
  final int ts;
  final MsgType type;
  final String? text;
  final MediaRef? media;

  /// Position in the author's outbox log.
  int? seq;
  MsgStatus status;

  /// What goes into the author's outbox subkey.
  Map<String, dynamic> toWire() => {
    'id': id,
    'seq': seq,
    'ts': ts,
    't': type.name,
    if (text != null) 'text': text,
    if (media != null) 'm': media!.toJson(),
    if (extra != null) 'x': extra,
    if (replyTo != null) 're': replyTo!.toJson(),
  };

  /// Throws [FormatException] for message types this version does not know
  /// (sent by a newer app); callers skip those.
  factory ChatMessage.fromWire(String author, Map<String, dynamic> j) {
    final type = MsgType.values.where((t) => t.name == j['t']).firstOrNull;
    if (type == null) throw FormatException('unknown message type ${j['t']}');
    return ChatMessage(
      id: j['id'] as String,
      author: author,
      ts: j['ts'] as int,
      type: type,
      text: j['text'] as String?,
      media: j['m'] == null
          ? null
          : MediaRef.fromJson(j['m'] as Map<String, dynamic>),
      seq: j['seq'] as int?,
      extra: (j['x'] as Map?)?.cast<String, dynamic>(),
      replyTo: ReplyRef.tryParse(j['re']),
    );
  }

  /// Local cache form (adds author and status).
  Map<String, dynamic> toCache() => {
    ...toWire(),
    'a': author,
    's': status == MsgStatus.sending ? MsgStatus.failed.name : status.name,
  };

  factory ChatMessage.fromCache(Map<String, dynamic> j) =>
      ChatMessage.fromWire(j['a'] as String, j)
        ..status = MsgStatus.values.byName(j['s'] as String);
}
