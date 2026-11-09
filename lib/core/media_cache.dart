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
class MediaCache {
  MediaCache._(this._key, this._dir, this._tmp);

  static Future<MediaCache> open(VaultArea area) async {
    final key = await Crypto.subsecret(area.key, 'media');
    final dir = await PinVault.instance.mediaDir(area);
    final tmpBase = await getTemporaryDirectory();
    final tmp = await Directory(
      p.join(tmpBase.path, 'r${Crypto.hex(await Crypto.randomBytes(8))}'),
    ).create();
    return MediaCache._(key, dir, tmp);
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
