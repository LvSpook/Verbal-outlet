/// Keeping up with new builds, without an account or a store.
///
/// The app is distributed as a GitHub Release: one zip for Windows and one APK
/// for Android, both built by CI from a tag. So the update source is the
/// repository's releases API — a public, versioned, no-auth endpoint — and the
/// "latest version" question has a single answer that is the same on every
/// device.
///
/// Two pieces live here, kept apart on purpose:
///
/// * [ReleaseInfo] and [UpdateService], which talk to GitHub and decide whether
///   a newer build exists. This is plain HTTP and pure comparison, so it can be
///   tested without a network, a release, or a real app.
/// * The install step, which is unavoidably platform-specific and lives behind
///   [UpdateInstaller] in its own files.
library;

import 'dart:convert';
import 'dart:io';

/// One downloadable build published as a GitHub Release.
class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.notes,
    required this.downloadUrl,
    required this.publishedAt,
  });

  /// Dotted version, e.g. `1.2.0`, without a leading `v`.
  final String version;

  /// The release body, as written in the tag's release. Shown as-is.
  final String notes;

  /// Where the asset for this platform can be fetched.
  final String downloadUrl;

  final DateTime? publishedAt;

  /// A filename safe to write the download to.
  String get fileName {
    final fromUrl = downloadUrl.split('/').last.split('?').first;
    return fromUrl.isEmpty ? 'verbal-outlet-update' : fromUrl;
  }
}

/// Greek for "I could not reach the releases", kept distinct from "there is no
/// newer build" — those are different things to tell someone.
class UpdateCheckException implements Exception {
  const UpdateCheckException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Talks to the GitHub Releases API and turns it into [ReleaseInfo].
///
/// Deliberately takes its HTTP call as a function so tests can supply a canned
/// body and never open a socket. The default uses [HttpClient], which keeps the
/// app dependency-free for this one request.
class UpdateService {
  UpdateService({
    required this.owner,
    required this.repo,
    Future<String> Function(Uri url)? fetch,
    this.userAgent = 'VerbalOutlet',
  }) : _fetch = fetch ?? _httpGet;

  final String owner;
  final String repo;

  /// Sent so GitHub does not reject the request, and so a maintainer can tell
  /// where traffic came from.
  final String userAgent;

  final Future<String> Function(Uri url) _fetch;

  Uri get latestUri =>
      Uri.parse('https://api.github.com/repos/$owner/$repo/releases/latest');

  /// The newest published release, or null when the repository has none yet.
  ///
  /// Throws [UpdateCheckException] when the request fails, so a caller can keep
  /// quiet (an offline laptop) rather than claiming it is up to date.
  Future<ReleaseInfo?> latest() async {
    final String body;
    try {
      body = await _fetch(latestUri);
    } catch (error) {
      throw UpdateCheckException('Could not reach GitHub: $error');
    }

    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const UpdateCheckException('The release list was not what we expected.');
    }
    // GitHub answers {"message": "Not Found"} for a repo with no releases.
    if (decoded['tag_name'] is! String) {
      throw UpdateCheckException(
        decoded['message'] is String
            ? 'No release found: ${decoded['message']}'
            : 'No release found.',
      );
    }

    final version = normaliseVersion(decoded['tag_name'] as String);
    final assets = (decoded['assets'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();

    final wanted = platformUpdatePattern();
    // Prefer the asset named for this platform; fall back to the first asset,
    // so a repository that names things differently still works.
    final asset = assets.where((a) {
          final name = (a['name'] as String? ?? '').toLowerCase();
          return wanted != null && name.endsWith(wanted);
        }).firstOrNull ??
        assets.firstOrNull;
    final url = asset?['browser_download_url'];

    if (url is! String || url.isEmpty) {
      throw const UpdateCheckException('The latest release has no download.');
    }

    return ReleaseInfo(
      version: version,
      notes: (decoded['body'] as String? ?? '').trim(),
      downloadUrl: url,
      publishedAt: DateTime.tryParse(decoded['published_at'] as String? ?? ''),
    );
  }

  /// The file suffix this platform needs in a release, or null for "any".
  static String? platformUpdatePattern() {
    if (Platform.isWindows) return '.zip';
    if (Platform.isAndroid) return '.apk';
    return null;
  }

  static Future<String> _httpGet(Uri url) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.userAgentHeader, 'VerbalOutlet');
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close();
      if (response.statusCode != 200) {
        throw UpdateCheckException('GitHub answered ${response.statusCode}.');
      }
      return await response.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }
}

/// Whether [candidate] is newer than [current], comparing dotted numbers.
///
/// Missing parts count as zero, so `1.2` equals `1.2.0`, and a tag like `v1.2.0`
/// or `1.2.0+7` still compares by its numeric part. Anything that cannot be
/// read is treated as not newer, which is the safe direction: never nag.
bool isNewerVersion(String candidate, String current) {
  final a = _parts(candidate);
  final b = _parts(current);
  if (a == null || b == null) return false;
  final length = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < length; i++) {
    final left = i < a.length ? a[i] : 0;
    final right = i < b.length ? b[i] : 0;
    if (left != right) return left > right;
  }
  return false;
}

/// Drops a leading `v` and anything from a `+` build suffix.
String normaliseVersion(String raw) {
  var value = raw.trim();
  if (value.startsWith('v') || value.startsWith('V')) {
    value = value.substring(1);
  }
  final plus = value.indexOf('+');
  if (plus != -1) value = value.substring(0, plus);
  return value;
}

List<int>? _parts(String raw) {
  final value = normaliseVersion(raw);
  if (value.isEmpty) return null;
  final parts = <int>[];
  for (final piece in value.split('.')) {
    // A pre-release tag like `1.2.0-beta` compares by its leading number.
    final digits = RegExp(r'^\d+').firstMatch(piece)?.group(0);
    if (digits == null) return parts.isEmpty ? null : parts;
    parts.add(int.parse(digits));
  }
  return parts.isEmpty ? null : parts;
}
