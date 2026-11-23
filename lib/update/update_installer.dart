/// Downloading a new build and putting it in place.
///
/// The two platforms differ enough that pretending otherwise would produce a
/// worse app on both. Windows can replace its own files and restart itself;
/// Android cannot install an app from within itself — the operating system
/// insists on a confirmation screen. So the shared part is the download, and
/// the hand-off is platform-specific.
library;

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

import 'updates.dart';

/// What an installer needs from the app: a released build, and a way to say how
/// the download is going.
abstract class UpdateInstaller {
  /// Fetches [release] and installs it.
  ///
  /// On Windows this replaces the running app and restarts it, so it does not
  /// return: the caller should expect the process to end. On Android it opens
  /// the system installer and returns once it has been handed over.
  ///
  /// [progress] is called with a fraction from 0 to 1 while downloading.
  Future<void> install(
    ReleaseInfo release, {
    void Function(double fraction)? progress,
  });
}

/// Streams a URL to [destination], reporting progress from the content length.
///
/// Shared by both platforms. A missing content length means progress stays at
/// null rather than pretending to be zero, so the UI can show an indeterminate
/// state instead of a bar that never moves.
Future<File> downloadFile(
  Uri url,
  File destination, {
  void Function(double fraction)? progress,
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, 'VerbalOutlet');
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException(
        'Download failed (${response.statusCode}).',
        uri: url,
      );
    }

    final total = response.contentLength;
    var received = 0;
    final sink = destination.openWrite();
    try {
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) progress?.call(received / total);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    progress?.call(1);
    return destination;
  } finally {
    client.close(force: true);
  }
}

/// Unpacks a zip into [destination], preserving the folder structure.
///
/// Throws if the archive is empty, which usually means a failed or truncated
/// download; better to say so than to copy nothing and restart.
Future<void> extractZip(File zip, Directory destination) async {
  final bytes = await zip.readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  var files = 0;

  for (final entry in archive) {
    final name = entry.name.replaceAll('\\', '/');
    if (name.isEmpty || name.endsWith('/')) continue;
    // Zip-slip guard: an entry may not escape the destination.
    if (name.contains('..')) continue;

    final target = File(
      '${destination.path}${Platform.pathSeparator}'
      '${name.replaceAll('/', Platform.pathSeparator)}',
    );
    await target.parent.create(recursive: true);
    await target.writeAsBytes(entry.content as List<int>);
    files++;
  }

  if (files == 0) {
    throw const FormatException('The update file contained no app files.');
  }
}

/// A directory under the system temp folder for one update attempt.
Future<Directory> updateScratchDirectory() async {
  final base = await getTemporaryDirectory();
  final dir = Directory('${base.path}${Platform.pathSeparator}verbal-outlet-update');
  if (await dir.exists()) await dir.delete(recursive: true);
  await dir.create(recursive: true);
  return dir;
}

