import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verbal_outlet/update/update_installer.dart';
import 'package:verbal_outlet/update/updates.dart';

/// A GitHub "latest release" body, as close to the real shape as needed.
String _releaseJson({
  String tag = 'v1.3.0',
  String body = 'Faster notes.',
  List<Map<String, String>> assets = const [
    {
      'name': 'verbal-outlet-windows.zip',
      'browser_download_url':
          'https://github.com/me/verbal-outlet/releases/download/v1.3.0/verbal-outlet-windows.zip',
    },
  ],
}) {
  final assetJson = assets
      .map(
        (a) =>
            '{"name":"${a['name']}","browser_download_url":"${a['browser_download_url']}"}',
      )
      .join(',');
  return '{"tag_name":"$tag","body":"$body","published_at":"2026-05-01T10:00:00Z",'
      '"assets":[$assetJson]}';
}

void main() {
  group('comparing versions', () {
    test('a higher number is newer, in any position', () {
      expect(isNewerVersion('1.3.0', '1.2.0'), isTrue);
      expect(isNewerVersion('1.2.1', '1.2.0'), isTrue);
      expect(isNewerVersion('2.0.0', '1.9.9'), isTrue);
      expect(isNewerVersion('1.2.0', '1.3.0'), isFalse);
    });

    test('the same version is not newer', () {
      expect(isNewerVersion('1.2.0', '1.2.0'), isFalse);
      expect(isNewerVersion('1.2', '1.2.0'), isFalse);
      expect(isNewerVersion('v1.2.0', '1.2.0'), isFalse);
    });

    test('a build suffix is ignored', () {
      expect(isNewerVersion('1.2.0+7', '1.2.0'), isFalse);
      expect(isNewerVersion('1.2.1+1', '1.2.0+9'), isTrue);
    });

    test('a pre-release compares by its number, not its tag', () {
      expect(isNewerVersion('1.2.0-beta', '1.1.0'), isTrue);
      expect(isNewerVersion('1.1.0-beta', '1.2.0'), isFalse);
    });

    test('something unreadable is never an update', () {
      expect(isNewerVersion('', '1.2.0'), isFalse);
      expect(isNewerVersion('nightly', '1.2.0'), isFalse);
      expect(isNewerVersion('1.2.0', 'nightly'), isFalse);
    });

    test('a leading v and a +suffix are stripped', () {
      expect(normaliseVersion('v1.2.0'), '1.2.0');
      expect(normaliseVersion('1.2.0+12'), '1.2.0');
      expect(normaliseVersion(' 1.2.0 '), '1.2.0');
    });
  });

  group('reading GitHub releases', () {
    test('the newest release is parsed into a version and a download', () async {
      final service = UpdateService(
        owner: 'me',
        repo: 'verbal-outlet',
        fetch: (_) async => _releaseJson(),
      );

      final release = await service.latest();

      expect(release, isNotNull);
      expect(release!.version, '1.3.0');
      expect(release.notes, 'Faster notes.');
      expect(release.downloadUrl, endsWith('.zip'));
      expect(release.fileName, 'verbal-outlet-windows.zip');
      expect(release.publishedAt, DateTime.utc(2026, 5, 1, 10));
    });

    test('it asks the latest-release endpoint for this repo', () {
      final service = UpdateService(
        owner: 'me',
        repo: 'verbal-outlet',
        fetch: (_) async => _releaseJson(),
      );

      expect(
        service.latestUri.toString(),
        'https://api.github.com/repos/me/verbal-outlet/releases/latest',
      );
    });

    test('the asset for this platform is chosen over the others', () async {
      final service = UpdateService(
        owner: 'me',
        repo: 'verbal-outlet',
        fetch: (_) async => _releaseJson(
          assets: const [
            {
              'name': 'verbal-outlet-android.apk',
              'browser_download_url': 'https://example.com/app.apk',
            },
            {
              'name': 'verbal-outlet-windows.zip',
              'browser_download_url': 'https://example.com/app.zip',
            },
          ],
        ),
      );

      final release = await service.latest();
      final wanted = UpdateService.platformUpdatePattern();
      if (wanted != null) {
        expect(release!.downloadUrl, endsWith(wanted));
      } else {
        expect(release, isNotNull);
      }
    });

    test('a repository with no releases is an error, not "up to date"', () async {
      final service = UpdateService(
        owner: 'me',
        repo: 'verbal-outlet',
        fetch: (_) async => '{"message":"Not Found"}',
      );

      expect(
        service.latest(),
        throwsA(isA<UpdateCheckException>()),
      );
    });

    test('a release with no downloadable file is an error', () async {
      final service = UpdateService(
        owner: 'me',
        repo: 'verbal-outlet',
        fetch: (_) async => _releaseJson(assets: const []),
      );

      expect(service.latest(), throwsA(isA<UpdateCheckException>()));
    });

    test('a failed request is reported, not swallowed', () async {
      final service = UpdateService(
        owner: 'me',
        repo: 'verbal-outlet',
        fetch: (_) async => throw const SocketException('offline'),
      );

      expect(service.latest(), throwsA(isA<UpdateCheckException>()));
    });

    test('nonsense from the server is an error', () async {
      final service = UpdateService(
        owner: 'me',
        repo: 'verbal-outlet',
        fetch: (_) async => 'not json at all',
      );

      expect(service.latest(), throwsA(anything));
    });
  });

  group('extracting a downloaded build', () {
    test('a zip is unpacked with its folders', () async {
      final scratch = await Directory.systemTemp.createTemp('vo-zip-test');
      addTearDown(() => scratch.delete(recursive: true));

      // Build a tiny zip with the same library the updater uses.
      final archiveFile = File('${scratch.path}/app.zip');
      await archiveFile.writeAsBytes(
        _zip({'verbal_outlet.exe': 'MZ fake', 'data/app.so': 'binary'}),
      );

      final out = Directory('${scratch.path}/out');
      await out.create();
      await extractZip(archiveFile, out);

      expect(File('${out.path}/verbal_outlet.exe').existsSync(), isTrue);
      expect(File('${out.path}/data/app.so').existsSync(), isTrue);
      expect(await File('${out.path}/data/app.so').readAsString(), 'binary');
    });

    test('an empty zip is refused rather than half-installed', () async {
      final scratch = await Directory.systemTemp.createTemp('vo-zip-test');
      addTearDown(() => scratch.delete(recursive: true));

      final archiveFile = File('${scratch.path}/empty.zip');
      await archiveFile.writeAsBytes(_zip({}));

      final out = Directory('${scratch.path}/out');
      await out.create();

      expect(
        extractZip(archiveFile, out),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

/// Builds a zip in memory with the same library the updater reads, so the
/// fixture cannot be wrong in a way the reader would silently accept.
List<int> _zip(Map<String, String> files) {
  final archive = Archive();
  files.forEach((name, content) {
    final bytes = content.codeUnits;
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive);
}

