import 'package:path/path.dart' as p;

import 'room_style.dart';

/// Suggests `:code:`s for picked emoji files from their names: lower-case,
/// `[a-z0-9_]` only, 2–32 chars, unique among [taken] and each other
/// (`party`, `party_2`, …). Unusable names fall back to `emoji_N`.
List<String> suggestEmojiCodes(List<String> paths, Set<String> taken) {
  final used = {...taken};
  final out = <String>[];
  for (final path in paths) {
    var base = p
        .basenameWithoutExtension(path)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (base.length > 28) base = base.substring(0, 28);
    if (!EmojiCode.isValid(base)) base = 'emoji';
    var code = base;
    for (var n = 2; used.contains(code) || !EmojiCode.isValid(code); n++) {
      code = '${base}_$n';
    }
    used.add(code);
    out.add(code);
  }
  return out;
}
