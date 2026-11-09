import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app.dart';
import '../core/ui_prefs.dart';
import 'release_info.dart';

/// Where this build gets its updates from (Android flavor).
enum UpdateStore { github, play }

enum UpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  installing,
  failed,
}

/// Finds and installs new versions.
///
/// * **GitHub build**: asks the GitHub API for the latest release (about
///   once a day if allowed, or on demand), downloads its arm64 APK, checks
///   it against the release's SHA-256 file, and hands it to Android's
///   installer. Android itself then checks it is the same app, newer, and
///   signed with the same key, and always asks the user to confirm.
/// * **Play build**: asks Google Play and starts Play's own update screen.
class UpdateService extends ChangeNotifier {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  static const repo = 'TBS093A/p2p.communicator';
  static const _channel = MethodChannel('p2pc/update');
  static const _maxApkBytes = 300 * 1024 * 1024;
  static const _autoEvery = Duration(hours: 20);

  UpdateStore get store =>
      appFlavor == 'play' ? UpdateStore.play : UpdateStore.github;

  AppVersion? current;
  UpdatePhase phase = UpdatePhase.idle;

  /// Human-readable detail of the last state (error, "you're up to date").
  String? message;

  /// 0..1 while downloading.
  double? progress;

  /// GitHub build: the newer release, when [phase] is available or later.
  GithubRelease? release;

  /// Play build: the version code Play offers.
  int? playVersionCode;

  /// Banner on the home screen was closed for this run of the app.
  bool bannerDismissed = false;

  void dismissBanner() {
    bannerDismissed = true;
    notifyListeners();
  }

  bool _ready = false;
  Completer<String>? _installResult;

  bool get hasUpdate =>
      phase == UpdatePhase.available ||
      phase == UpdatePhase.downloading ||
      phase == UpdatePhase.installing;

  String get newVersionLabel =>
      release?.version.toString() ??
      (playVersionCode == null ? '' : 'kompilacja $playVersionCode');

  /// Reads the installed version (for the updates screen) without checking
  /// for anything.
  Future<void> prepare() async {
    await _init();
    notifyListeners();
  }

  Future<void> _init() async {
    if (_ready) return;
    _ready = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'installStatus') {
        final args = (call.arguments as Map).cast<String, Object?>();
        final status = args['status'] as String? ?? 'failed';
        if (status != 'confirm') {
          final c = _installResult;
          if (c != null && !c.isCompleted) {
            c.complete(
              status == 'failed' ? 'failed:${args['message'] ?? ''}' : status,
            );
          }
        }
      }
    });
    try {
      final v = await _channel.invokeMapMethod<String, Object?>('version');
      current = AppVersion.tryParse(v?['name'] as String? ?? '');
    } on Object {
      current = null; // not Android (tests): never offers anything
    }
    // Leftovers from an earlier download or an install that went through.
    try {
      final dir = await _downloadDir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } on Object {
      // Best effort.
    }
  }

  /// On the home screen: a quiet check, release builds only. GitHub is
  /// asked at most about once a day and only if allowed in settings.
  Future<void> autoCheck() async {
    if (!kReleaseMode || phase != UpdatePhase.idle) return;
    await _init();
    if (store == UpdateStore.github) {
      final prefs = UiPrefs.instance;
      if (!prefs.autoUpdateCheck.value) return;
      final last = DateTime.fromMillisecondsSinceEpoch(prefs.lastUpdateCheck);
      if (DateTime.now().difference(last) < _autoEvery) return;
    }
    await check(quiet: true);
  }

  /// Asks for the newest version. With [quiet], failures are not shown as
  /// an error (an automatic check offline is not worth a red message).
  Future<void> check({bool quiet = false}) async {
    if (phase == UpdatePhase.checking ||
        phase == UpdatePhase.downloading ||
        phase == UpdatePhase.installing) {
      return;
    }
    await _init();
    _set(UpdatePhase.checking, null);
    try {
      if (store == UpdateStore.github) {
        await _checkGithub();
      } else {
        await _checkPlay();
      }
    } on Object catch (e) {
      debugPrint('[update] check failed: $e');
      if (quiet) {
        _set(UpdatePhase.idle, null);
      } else {
        _set(UpdatePhase.failed, 'Nie udało się sprawdzić: ${_short(e)}');
      }
    }
  }

  Future<void> _checkGithub() async {
    final j = await _getJson(
      Uri.https('api.github.com', '/repos/$repo/releases/latest'),
    );
    await UiPrefs.instance.markUpdateChecked(DateTime.now());
    final r = GithubRelease.fromJson(j);
    if (r == null) {
      throw const _UpdateError('najnowsze wydanie nie ma pliku APK z sumą');
    }
    final mine = current;
    if (mine == null) {
      _set(UpdatePhase.upToDate, 'Nie znam wersji tej aplikacji');
      return;
    }
    if (r.version > mine) {
      release = r;
      bannerDismissed = false;
      _set(UpdatePhase.available, null);
    } else {
      release = null;
      _set(UpdatePhase.upToDate, 'Masz najnowszą wersję ($mine)');
    }
  }

  Future<void> _checkPlay() async {
    try {
      final r = await _channel.invokeMapMethod<String, Object?>('playCheck');
      if (r?['available'] == true) {
        playVersionCode = (r?['code'] as num?)?.toInt();
        bannerDismissed = false;
        _set(UpdatePhase.available, null);
      } else {
        _set(UpdatePhase.upToDate, 'Masz najnowszą wersję z Google Play');
      }
    } on PlatformException catch (e) {
      // Installed outside Play, no Play services or account.
      debugPrint('[update] play: ${e.code} ${e.message}');
      _set(
        UpdatePhase.upToDate,
        'Google Play nie zgłasza aktualizacji dla tej kopii aplikacji',
      );
    }
  }

  /// GitHub build: whether Android lets this app install updates. If not,
  /// [openInstallSettings] takes the user to the switch.
  Future<bool> canInstall() async {
    if (store == UpdateStore.play) return true;
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } on Object {
      return false;
    }
  }

  Future<void> openInstallSettings() => AutoLock.suppress(() async {
    await _channel.invokeMethod<void>('openInstallSettings');
    await _untilResumed();
  });

  /// Downloads, verifies and installs ([store] github), or opens Play's
  /// update screen ([store] play).
  Future<void> install() async {
    if (phase != UpdatePhase.available && phase != UpdatePhase.failed) return;
    if (store == UpdateStore.play) {
      try {
        await AutoLock.suppress(() async {
          final started = await _channel.invokeMethod<bool>('playUpdate');
          if (started == true) await _untilResumed();
        });
      } on Object catch (e) {
        _set(UpdatePhase.failed, 'Google Play: ${_short(e)}');
      }
      return;
    }
    final r = release;
    if (r == null) return;
    try {
      final apk = await _download(r);
      _set(UpdatePhase.installing, 'Potwierdź instalację');
      final result = await AutoLock.suppress(() async {
        _installResult = Completer<String>();
        await _channel.invokeMethod<void>('install', {'path': apk.path});
        return _installResult!.future.timeout(
          const Duration(minutes: 10),
          onTimeout: () => 'cancelled',
        );
      });
      // On success Android replaces the app and restarts it; we only get
      // here when it did not happen.
      if (result == 'done') {
        _set(UpdatePhase.upToDate, 'Zainstalowano');
      } else if (result == 'cancelled') {
        _set(UpdatePhase.available, 'Instalacja anulowana');
      } else {
        _set(
          UpdatePhase.failed,
          'Instalacja nie powiodła się ${result.substring(7)}'.trim(),
        );
      }
    } on PlatformException catch (e) {
      _set(UpdatePhase.failed, switch (e.code) {
        'bad-signature' =>
          'Plik jest podpisany innym kluczem niż ta aplikacja: odrzucono',
        'not-newer' => 'Plik nie jest nowszy niż ta wersja',
        'other-app' => 'Plik to inna aplikacja: odrzucono',
        _ => 'Instalacja nie powiodła się: ${e.message ?? e.code}',
      });
    } on Object catch (e) {
      _set(UpdatePhase.failed, _short(e));
    }
  }

  // ------------------------------------------------------------ download

  Future<Directory> _downloadDir() async =>
      Directory(p.join((await getTemporaryDirectory()).path, 'updates'));

  Future<File> _download(GithubRelease r) async {
    if (r.apkSize <= 0 || r.apkSize > _maxApkBytes) {
      throw const _UpdateError('nieprawidłowy rozmiar pliku w wydaniu');
    }
    _set(UpdatePhase.downloading, 'Pobieram ${r.apkName}');
    progress = 0;

    final checksum = utf8.decode(await _getBytes(r.checksumUrl, max: 4096));
    final expected = sha256For(checksum, r.apkName);
    if (expected == null) {
      throw const _UpdateError('brak sumy SHA-256 dla tego pliku');
    }

    final dir = await _downloadDir();
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, r.apkName));
    final client = HttpClient()..userAgent = 'p2p-communicator-updater';
    try {
      final res = await _open(client, r.apkUrl);
      final sink = file.openWrite();
      var got = 0;
      try {
        await for (final chunk in res) {
          got += chunk.length;
          if (got > r.apkSize) {
            throw const _UpdateError('plik większy niż zapowiadany');
          }
          sink.add(chunk);
          progress = got / r.apkSize;
          notifyListeners();
        }
      } finally {
        await sink.close();
      }
      if (got != r.apkSize) {
        throw const _UpdateError('pobieranie przerwane, spróbuj ponownie');
      }
    } finally {
      client.close(force: true);
    }

    _set(UpdatePhase.downloading, 'Sprawdzam sumę kontrolną');
    final actual = (await sha256.bind(file.openRead()).first).toString();
    if (actual != expected) {
      await file.delete();
      throw const _UpdateError(
        'suma SHA-256 się nie zgadza: plik uszkodzony lub podmieniony',
      );
    }
    progress = null;
    return file;
  }

  /// GET that only follows redirects within GitHub.
  Future<HttpClientResponse> _open(HttpClient client, Uri url) async {
    final req = await client.getUrl(url).timeout(const Duration(seconds: 30));
    req.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
    final res = await req.close().timeout(const Duration(seconds: 60));
    for (final hop in res.redirects) {
      final u = hop.location.hasScheme
          ? hop.location
          : url.resolveUri(hop.location);
      if (u.scheme != 'https' ||
          !(u.host == 'github.com' ||
              u.host.endsWith('.githubusercontent.com'))) {
        throw const _UpdateError('przekierowanie poza GitHub');
      }
    }
    if (res.statusCode != 200) {
      throw _UpdateError('HTTP ${res.statusCode}');
    }
    return res;
  }

  Future<Uint8List> _getBytes(Uri url, {required int max}) async {
    final client = HttpClient()..userAgent = 'p2p-communicator-updater';
    try {
      final res = await _open(client, url);
      final out = BytesBuilder(copy: false);
      await for (final chunk in res) {
        out.add(chunk);
        if (out.length > max) throw const _UpdateError('odpowiedź za duża');
      }
      return out.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _getJson(Uri url) async {
    final client = HttpClient()..userAgent = 'p2p-communicator-updater';
    try {
      final req = await client.getUrl(url).timeout(const Duration(seconds: 20));
      req.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set('X-GitHub-Api-Version', '2022-11-28');
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        throw _UpdateError('GitHub odpowiedział ${res.statusCode}');
      }
      final text = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 30));
      if (text.length > 1024 * 1024) {
        throw const _UpdateError('odpowiedź za duża');
      }
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  // -------------------------------------------------------------- helpers

  /// Waits until the app is back on screen after a system screen we opened.
  Future<void> _untilResumed() {
    final done = Completer<void>();
    late final AppLifecycleListener listener;
    var left = false;
    listener = AppLifecycleListener(
      onHide: () => left = true,
      onResume: () {
        if (left && !done.isCompleted) done.complete();
      },
    );
    return done.future
        .timeout(const Duration(minutes: 10), onTimeout: () {})
        .whenComplete(listener.dispose);
  }

  void _set(UpdatePhase p, String? msg) {
    phase = p;
    message = msg;
    if (p != UpdatePhase.downloading) progress = null;
    notifyListeners();
  }

  static String _short(Object e) => switch (e) {
    _UpdateError(:final message) => message,
    SocketException() => 'brak połączenia',
    TimeoutException() => 'przekroczono czas',
    PlatformException(:final message, :final code) => message ?? code,
    _ => '$e',
  };
}

class _UpdateError implements Exception {
  const _UpdateError(this.message);
  final String message;
  @override
  String toString() => message;
}
