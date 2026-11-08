enum MsgType { text, image, video, voice }

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
  });

  final String id;

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
  };

  factory ChatMessage.fromWire(String author, Map<String, dynamic> j) =>
      ChatMessage(
        id: j['id'] as String,
        author: author,
        ts: j['ts'] as int,
        type: MsgType.values.byName(j['t'] as String),
        text: j['text'] as String?,
        media: j['m'] == null
            ? null
            : MediaRef.fromJson(j['m'] as Map<String, dynamic>),
        seq: j['seq'] as int?,
      );

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
