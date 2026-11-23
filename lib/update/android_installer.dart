/// Android updates: download the APK, then hand it to the system installer.
///
/// A phone will not let an app replace itself silently — by design. So the
/// honest flow is: download, open the installer, and let the person tap
/// "Update". If they have not allowed installs from this app yet, Android shows
/// that permission screen first, and the next tap on Install finishes the job.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'update_installer.dart';
import 'updates.dart';

/// The `verbal_outlet/update` channel implemented in `MainActivity.kt`.
const MethodChannel updateChannel = MethodChannel('verbal_outlet/update');

class AndroidUpdateInstaller implements UpdateInstaller {
  AndroidUpdateInstaller({this.channel, this.cacheDirectory, this.download});

  /// Overridable for tests, which must not touch the real platform channel.
  final MethodChannel? channel;

  /// Where the APK is written. Defaults to the app's cache folder, which is the
  /// one place the manifest's FileProvider exposes to the installer.
  final Directory? cacheDirectory;

  /// Fetches a URL to a file. Overridable so tests need no socket; production
  /// streams from GitHub.
  final Future<File> Function(
    Uri url,
    File destination, {
    void Function(double fraction)? progress,
  })? download;

  @override
  Future<void> install(
    ReleaseInfo release, {
    void Function(double fraction)? progress,
  }) async {
    final base = cacheDirectory ??
        Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}updates');
    await base.create(recursive: true);

    final apk = File('${base.path}${Platform.pathSeparator}verbal-outlet.apk');
    if (await apk.exists()) await apk.delete();

    final fetch = download ?? downloadFile;
    await fetch(Uri.parse(release.downloadUrl), apk, progress: progress);

    final channel = this.channel ?? updateChannel;
    final opened = await channel.invokeMethod<bool>('installApk', {
      'path': apk.path,
    });

    if (opened != true) {
      throw const UpdateCheckException(
        'The installer could not be opened. Allow installs from Verbal Outlet '
        'in Settings, then try again.',
      );
    }
  }
}
