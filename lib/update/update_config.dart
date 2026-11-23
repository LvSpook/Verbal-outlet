/// Where this build looks for its updates.
///
/// One place, and one line to change if the repository ever moves. It is a
/// constant rather than a setting because the address is part of the build: an
/// app that could be pointed at another repository could be pointed at one that
/// serves it anything.
library;

import 'dart:io';

import 'android_installer.dart';
import 'update_installer.dart';
import 'update_controller.dart';
import 'updates.dart';
import 'windows_installer.dart';

/// The GitHub repository whose releases are this app's updates.
const String updateRepoOwner = 'LvSpook';
const String updateRepoName = 'Verbal-outlet';

/// Builds the controller for this platform.
///
/// Android and Windows are the supported platforms; anywhere else there is no
/// installer, so the controller is still made but cannot install — the check
/// still works, which is useful while porting.
UpdateController buildUpdateController() {
  return UpdateController(
    service: UpdateService(owner: updateRepoOwner, repo: updateRepoName),
    installer: _platformInstaller(),
  );
}

UpdateInstaller _platformInstaller() {
  if (Platform.isWindows) return WindowsUpdateInstaller();
  if (Platform.isAndroid) return AndroidUpdateInstaller();
  return const _NoInstall();
}

/// A build with no installer: it can say an update exists, and nothing more.
class _NoInstall implements UpdateInstaller {
  const _NoInstall();

  @override
  Future<void> install(
    ReleaseInfo release, {
    void Function(double fraction)? progress,
  }) async {
    throw const UpdateCheckException(
      'Updating is only set up for Windows and Android.',
    );
  }
}
