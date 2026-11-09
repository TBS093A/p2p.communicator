import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_communicator/update/release_info.dart';

Map<String, dynamic> _release({
  String tag = 'v0.1.13',
  String host = 'github.com',
  bool withSum = true,
  bool prerelease = false,
}) => {
  'tag_name': tag,
  'html_url': 'https://github.com/TBS093A/p2p.communicator/releases/tag/$tag',
  'body': '## What changed\n* Nicknames\n',
  'draft': false,
  'prerelease': prerelease,
  'assets': [
    {
      'name': 'p2p-communicator-0.1.13-arm64.apk',
      'size': 91000000,
      'browser_download_url':
          'https://$host/TBS093A/p2p.communicator/releases/download/$tag/'
          'p2p-communicator-0.1.13-arm64.apk',
    },
    if (withSum)
      {
        'name': 'p2p-communicator-0.1.13-arm64.apk.sha256',
        'size': 100,
        'browser_download_url':
            'https://github.com/TBS093A/p2p.communicator/releases/download/'
            '$tag/p2p-communicator-0.1.13-arm64.apk.sha256',
      },
  ],
};

void main() {
  test('versions compare numerically, not as text', () {
    final a = AppVersion.tryParse('0.1.9')!;
    final b = AppVersion.tryParse('v0.1.12')!;
    expect(b > a, isTrue);
    expect(AppVersion.tryParse('0.2.0')! > b, isTrue);
    expect(
      AppVersion.tryParse('1.0.0')! > AppVersion.tryParse('0.99.99')!,
      isTrue,
    );
    expect(AppVersion.tryParse('0.1.12+12'), b);
    for (final bad in ['', 'v1', '1.2', 'latest', '1.2.3-beta', '1.2.x']) {
      expect(AppVersion.tryParse(bad), isNull, reason: bad);
    }
  });

  test('latest release: APK with its checksum, from GitHub only', () {
    final r = GithubRelease.fromJson(_release())!;
    expect(r.version.toString(), '0.1.13');
    expect(r.apkName, 'p2p-communicator-0.1.13-arm64.apk');
    expect(r.apkSize, 91000000);
    expect(r.notes, contains('Nicknames'));
    expect(r.checksumUrl.path, endsWith('.apk.sha256'));

    expect(
      GithubRelease.fromJson(_release(withSum: false)),
      isNull,
      reason: 'no checksum, no update',
    );
    expect(
      GithubRelease.fromJson(_release(host: 'evil.example')),
      isNull,
      reason: 'download outside GitHub',
    );
    expect(GithubRelease.fromJson(_release(prerelease: true)), isNull);
    expect(GithubRelease.fromJson(_release(tag: 'nightly')), isNull);
  });

  test('checksum file: the line for that file, lowercase', () {
    final hash = 'AB' * 32;
    final file = 'ffff${'0' * 60}  other.apk\n$hash  app.apk\n';
    expect(sha256For(file, 'app.apk'), hash.toLowerCase());
    expect(sha256For('$hash *app.apk', 'app.apk'), hash.toLowerCase());
    expect(sha256For(file, 'missing.apk'), isNull);
    expect(sha256For('nonsense', 'app.apk'), isNull);
  });
}
