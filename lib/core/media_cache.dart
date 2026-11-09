import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:veilid/veilid.dart';

import '../room/blob_store.dart';
import '../room/message.dart';
import '../vault/pin_vault.dart';
import 'crypto.dart';

/// Anything that can turn a [MediaRef] into a local file to display.
abstract class MediaSource {
  Future<File> mediaFile(String id, MediaRef ref);
}

/// Encrypted local cache of media for one vault area (a room, or the app
/// itself for avatars on the home screen). Files are downloaded from the DHT
/// once, kept sealed with the area's key, and decrypted into a temp folder
/// that is removed on [close] (i.e. when the app or room is locked).
///
/// A crash or a killed process skips [close], so every plaintext temp file
/// lives under one folder ([plainDir]) that is wiped before the first cache
/// of a process run opens.
class MediaCache {
  MediaCache._(this._key, this._dir, this._tmp);

  static Future<MediaCache> open(VaultArea area) async {
    final key = await Crypto.subsecret(area.key, 'media');
    final dir = await PinVault.instance.mediaDir(area);
    final tmp = await Directory(
      p.join(
        (await plainDir()).path,
        'r${Crypto.hex(await Crypto.randomBytes(8))}',
      ),
    ).create(recursive: true);
    return MediaCache._(key, dir, tmp);
  }

  /// Parent of every decrypted or not-yet-encrypted temp file (shown media,
  /// voice recordings in progress). Leftovers from an earlier run that ended
  /// without locking are removed the first time this is called.
  static Future<Directory> plainDir() async {
    await (_swept ??= _sweepLeftovers());
    return Directory(p.join((await getTemporaryDirectory()).path, _plain));
  }

  static const _plain = 'plain';
  static Future<void>? _swept;

  static Future<void> _sweepLeftovers() async {
    final base = await getTemporaryDirectory();
    if (!await base.exists()) return;
    await for (final e in base.list()) {
      final name = p.basename(e.path);
      // `plain/` now; `r<hex>/` and `voice_*.m4a` straight in the temp dir
      // were written by versions before it existed.
      final leftover =
          name == _plain ||
          (e is Directory && RegExp(r'^r[0-9a-f]{16}$').hasMatch(name)) ||
          (e is File && name.startsWith('voice_') && name.endsWith('.m4a'));
      if (!leftover) continue;
      try {
        await e.delete(recursive: true);
      } on FileSystemException {
        // Gone already or not ours to delete: nothing to protect.
      }
    }
  }

  final SharedSecret _key;
  final Directory _dir;
  final Directory _tmp;
  final _jobs = <String, Future<File>>{};

  /// A plain file for [ref], downloading it first if needed.
  Future<File> file(MediaRef ref, {void Function(double)? onProgress}) =>
      _jobs[ref.hash] ??=
          () async {
            final out = File(p.join(_tmp.path, '${ref.hash}${_ext(ref.mime)}'));
            if (await out.exists()) return out;
            var bytes = await load(ref.hash);
            if (bytes == null) {
              bytes = await BlobStore.download(ref, onProgress: onProgress);
              await store(ref.hash, bytes);
            }
            await out.writeAsBytes(bytes, flush: true);
            return out;
          }().catchError((Object e) {
            _jobs.remove(ref.hash);
            throw e;
          });

  Future<void> store(String hash, Uint8List bytes) async {
    final sealed = await Crypto.seal(_key, bytes, context: hash);
    await File(p.join(_dir.path, hash)).writeAsBytes(sealed);
  }

  Future<Uint8List?> load(String hash) async {
    final f = File(p.join(_dir.path, hash));
    if (!await f.exists()) return null;
    try {
      return await Crypto.open(_key, await f.readAsBytes(), context: hash);
    } on Object {
      return null;
    }
  }

  /// Content hashes of everything cached here (for migration).
  Future<List<String>> hashes() async => [
    await for (final e in _dir.list())
      if (e is File) p.basename(e.path),
  ];

  Future<void> close() async {
    if (await _tmp.exists()) await _tmp.delete(recursive: true);
  }

  static String _ext(String mime) => switch (mime) {
    'image/gif' => '.gif',
    'image/png' => '.png',
    'image/webp' => '.webp',
    'image/heic' => '.heic',
    'image/jpeg' => '.jpg',
    'video/quicktime' => '.mov',
    'video/3gpp' => '.3gp',
    'video/webm' => '.webm',
    'video/mp4' => '.mp4',
    'audio/mp4' => '.m4a',
    _ => '.bin',
  };
}
