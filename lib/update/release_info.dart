/// Pure parts of updating: versions, GitHub release metadata, checksums.
library;

/// `major.minor.patch` as built by CI (`0.1.12`; the patch is the CI run
/// number, also the Android version code).
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  /// Accepts `v0.1.12`, `0.1.12`, `0.1.12+12`; null for anything else.
  static AppVersion? tryParse(String raw) {
    final m = RegExp(
      r'^v?(\d{1,6})\.(\d{1,6})\.(\d{1,9})(?:\+\d+)?$',
    ).firstMatch(raw.trim());
    if (m == null) return null;
    return AppVersion(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }

  @override
  int compareTo(AppVersion other) => major != other.major
      ? major.compareTo(other.major)
      : minor != other.minor
      ? minor.compareTo(other.minor)
      : patch.compareTo(other.patch);

  bool operator >(AppVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

/// The newest GitHub release, as far as updating needs it.
class GithubRelease {
  const GithubRelease({
    required this.version,
    required this.notes,
    required this.pageUrl,
    required this.apkName,
    required this.apkUrl,
    required this.apkSize,
    required this.checksumUrl,
  });

  final AppVersion version;
  final String notes;
  final Uri pageUrl;
  final String apkName;
  final Uri apkUrl;
  final int apkSize;
  final Uri checksumUrl;

  /// Downloads only ever come from GitHub over HTTPS.
  static bool _trusted(Uri u) =>
      u.scheme == 'https' &&
      (u.host == 'github.com' || u.host.endsWith('.githubusercontent.com'));

  /// From `GET /repos/{owner}/{repo}/releases/latest`. Null when the
  /// release is not usable: no version tag, no arm64 APK with its
  /// `.sha256`, a draft/prerelease, or a download outside GitHub.
  static GithubRelease? fromJson(Map<String, dynamic> j) {
    if (j['draft'] == true || j['prerelease'] == true) return null;
    final version = AppVersion.tryParse(j['tag_name'] as String? ?? '');
    if (version == null) return null;
    final assets = (j['assets'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    Map<String, dynamic>? named(bool Function(String) test) {
      for (final a in assets) {
        if (test(a['name'] as String? ?? '')) return a;
      }
      return null;
    }

    final apk = named((n) => n.endsWith('-arm64.apk'));
    if (apk == null) return null;
    final apkName = apk['name'] as String;
    final sum = named((n) => n == '$apkName.sha256');
    if (sum == null) return null;
    final apkUrl = Uri.tryParse(apk['browser_download_url'] as String? ?? '');
    final sumUrl = Uri.tryParse(sum['browser_download_url'] as String? ?? '');
    final page = Uri.tryParse(j['html_url'] as String? ?? '');
    if (apkUrl == null || sumUrl == null || page == null) return null;
    if (!_trusted(apkUrl) || !_trusted(sumUrl) || !_trusted(page)) return null;
    return GithubRelease(
      version: version,
      notes: (j['body'] as String? ?? '').trim(),
      pageUrl: page,
      apkName: apkName,
      apkUrl: apkUrl,
      apkSize: apk['size'] as int? ?? 0,
      checksumUrl: sumUrl,
    );
  }
}

/// The hex SHA-256 for [fileName] from a `sha256sum` output line
/// (`<64 hex>  <name>`), or null if it is not there.
String? sha256For(String checksumFile, String fileName) {
  for (final line in checksumFile.split('\n')) {
    final m = RegExp(
      r'^([0-9a-fA-F]{64})\s+\*?(\S+)\s*$',
    ).firstMatch(line.trim());
    if (m != null && m[2] == fileName) return m[1]!.toLowerCase();
  }
  return null;
}
