/// Windows updates: replace the app's own folder, then start it again.
///
/// A running executable cannot overwrite itself, so the work is handed to a
/// short command script that waits for this process to exit, copies the new
/// files over the old ones, and launches the new build. The script then deletes
/// itself, so an update leaves nothing behind but the app.
///
/// Copying rather than reinstalling is deliberate: the app is a self-contained
/// folder with the Flutter engine, the DLLs and the database beside it, so a
/// plain file copy over the existing folder is the whole install. No admin
/// rights, no MSI, no registry entries.
library;

import 'dart:io';

import 'update_installer.dart';
import 'updates.dart';

class WindowsUpdateInstaller implements UpdateInstaller {
  WindowsUpdateInstaller({this.executable, this.restartScript});

  /// The running `verbal_outlet.exe`. Defaults to the real one.
  final String? executable;

  /// Where to write the wait-and-copy script. Defaults to the temp folder, so
  /// a permission problem in the install folder cannot block the update.
  final String? restartScript;

  @override
  Future<void> install(
    ReleaseInfo release, {
    void Function(double fraction)? progress,
  }) async {
    final exe = executable ?? Platform.resolvedExecutable;
    final installDir = File(exe).parent;

    final scratch = await updateScratchDirectory();
    final archiveFile = File(
      '${scratch.path}${Platform.pathSeparator}update.zip',
    );
    await downloadFile(
      Uri.parse(release.downloadUrl),
      archiveFile,
      progress: progress,
    );

    // Unpack beside the app first, so a truncated download cannot leave the
    // installed copy half old and half new.
    final staged = Directory('${scratch.path}${Platform.pathSeparator}staged');
    await staged.create(recursive: true);
    await extractZip(archiveFile, staged);

    final script = await _writeRestartScript(
      installDir: installDir,
      staged: staged,
      exe: File(exe),
    );

    // Detached, so it survives this process exiting.
    await Process.start(
      'cmd',
      ['/c', script.path],
      mode: ProcessStartMode.detached,
      runInShell: true,
    );

    exit(0); // ignore: avoid_returning_null_for_void
  }

  Future<File> _writeRestartScript({
    required Directory installDir,
    required Directory staged,
    required File exe,
  }) async {
    final path = restartScript ??
        '${Directory.systemTemp.path}${Platform.pathSeparator}verbal-outlet-update.cmd';
    final file = File(path);

    String q(String value) => '"$value"';

    // The loop waits for the app to go away before touching its files; copying
    // over a running exe would fail. `robocopy` is on every supported Windows.
    final script = StringBuffer()
      ..writeln('@echo off')
      ..writeln('setlocal')
      ..writeln(':wait')
      ..writeln('tasklist /FI "IMAGENAME eq ${exe.uri.pathSegments.last}" | find /I "${exe.uri.pathSegments.last}" >nul')
      ..writeln('if not errorlevel 1 (')
      ..writeln('  timeout /t 1 /nobreak >nul')
      ..writeln('  goto wait')
      ..writeln(')')
      ..writeln(
        'robocopy ${q(staged.path)} ${q(installDir.path)} /E /IS /NFL /NDL /NJH /NJS >nul',
      )
      ..writeln('start "" ${q(exe.path)}')
      ..writeln('rmdir /s /q ${q(staged.parent.path)} >nul 2>&1')
      ..writeln('del "%~f0" >nul 2>&1');

    await file.writeAsString(script.toString());
    return file;
  }
}

