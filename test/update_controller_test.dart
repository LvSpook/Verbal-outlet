import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verbal_outlet/update/android_installer.dart';
import 'package:verbal_outlet/update/update_controller.dart';
import 'package:verbal_outlet/update/update_installer.dart';
import 'package:verbal_outlet/update/updates.dart';

/// A release as the service would return it.
ReleaseInfo _release({String version = '1.3.0'}) => ReleaseInfo(
  version: version,
  notes: 'Faster notes.',
  downloadUrl: 'https://example.com/verbal-outlet.zip',
  publishedAt: DateTime.utc(2026, 5, 1),
);

/// An installer that records the attempt and optionally fails.
class _FakeInstaller implements UpdateInstaller {
  _FakeInstaller({this.error});

  final Object? error;
  final List<ReleaseInfo> installed = [];

  @override
  Future<void> install(
    ReleaseInfo release, {
    void Function(double fraction)? progress,
  }) async {
    progress?.call(0.5);
    if (error != null) throw error!;
    installed.add(release);
  }
}

/// A service whose answer is scripted, with no network.
UpdateService _service(Future<ReleaseInfo?> Function() answer) =>
    UpdateService(owner: 'me', repo: 'app', fetch: (_) async {
      final release = await answer();
      if (release == null) throw const UpdateCheckException('none');
      return '{"tag_name":"v${release.version}","body":"${release.notes}",'
          '"assets":[{"name":"a.zip","browser_download_url":"${release.downloadUrl}"}]}';
    });

void main() {
  // The Android hand-off uses a method channel, which needs the test binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a newer release is offered, an equal one is not', () async {
    var offer = _release();
    final controller = UpdateController(
      service: _service(() async => offer),
      installer: _FakeInstaller(),
      currentVersionOverride: '1.2.0',
    );

    await controller.check(quiet: false);
    expect(controller.state.available?.version, '1.3.0');

    offer = _release(version: '1.2.0');
    await controller.check(quiet: false);
    expect(controller.state.available, isNull);
    expect(controller.state.checked, isTrue);
  });

  test('a quiet failure leaves no error behind', () async {
    final controller = UpdateController(
      service: _service(() async => throw const SocketException('offline')),
      installer: _FakeInstaller(),
      currentVersionOverride: '1.2.0',
    );

    await controller.check();

    expect(controller.state.error, isNull);
    expect(controller.state.checked, isTrue);
    expect(controller.state.available, isNull);
  });

  test('a hand-checked failure is explained', () async {
    final controller = UpdateController(
      service: _service(() async => throw const SocketException('offline')),
      installer: _FakeInstaller(),
      currentVersionOverride: '1.2.0',
    );

    await controller.check(quiet: false);

    expect(controller.state.error, contains('GitHub'));
  });

  test('installing reports progress and hands the release over', () async {
    final installer = _FakeInstaller();
    final controller = UpdateController(
      service: _service(() async => _release()),
      installer: installer,
      currentVersionOverride: '1.2.0',
    );

    await controller.check(quiet: false);
    await controller.install();

    expect(installer.installed, hasLength(1));
    expect(installer.installed.single.version, '1.3.0');
    expect(controller.state.downloading, isFalse);
  });

  test('an install failure is shown, and the app carries on', () async {
    final controller = UpdateController(
      service: _service(() async => _release()),
      installer: _FakeInstaller(error: const FormatException('bad zip')),
      currentVersionOverride: '1.2.0',
    );

    await controller.check(quiet: false);
    await controller.install();

    expect(controller.state.downloading, isFalse);
    expect(controller.state.error, contains('could not be installed'));
  });

  test('installing without a found update does nothing', () async {
    final installer = _FakeInstaller();
    final controller = UpdateController(
      service: _service(() async => _release(version: '1.2.0')),
      installer: installer,
      currentVersionOverride: '1.2.0',
    );

    await controller.check(quiet: false);
    await controller.install();

    expect(installer.installed, isEmpty);
  });

  group('the Android hand-off', () {
    late Directory cache;
    late List<MethodCall> calls;

    setUp(() async {
      cache = await Directory.systemTemp.createTemp('vo-update-test');
      calls = [];
    });

    tearDown(() => cache.delete(recursive: true));

    /// A channel that answers as MainActivity does after a download.
    MethodChannel channel({bool opened = true}) {
      const channel = MethodChannel('verbal_outlet/update');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'installApk') return opened;
            return null;
          });
      return channel;
    }

    /// Writes fixed bytes where the real download would stream them.
    Future<File> fakeDownload(
      Uri url,
      File destination, {
      void Function(double fraction)? progress,
    }) async {
      await destination.writeAsBytes([1, 2, 3, 4]);
      progress?.call(1);
      return destination;
    }

    test('the APK is downloaded and the installer asked to open it', () async {
      final installer = AndroidUpdateInstaller(
        channel: channel(),
        cacheDirectory: cache,
        download: fakeDownload,
      );

      await installer.install(
        ReleaseInfo(
          version: '1.3.0',
          notes: '',
          downloadUrl: 'https://example.com/app.apk',
          publishedAt: null,
        ),
      );

      final apk = File('${cache.path}${Platform.pathSeparator}verbal-outlet.apk');
      expect(apk.existsSync(), isTrue);
      expect(apk.readAsBytesSync(), [1, 2, 3, 4]);
      expect(calls.single.method, 'installApk');
      expect((calls.single.arguments as Map)['path'], apk.path);
    });

    test('a refused installer is reported as a reason, not silence', () async {
      final installer = AndroidUpdateInstaller(
        channel: channel(opened: false),
        cacheDirectory: cache,
        download: fakeDownload,
      );

      await expectLater(
        installer.install(
          ReleaseInfo(
            version: '1.3.0',
            notes: '',
            downloadUrl: 'https://example.com/app.apk',
            publishedAt: null,
          ),
        ),
        throwsA(isA<UpdateCheckException>()),
      );
    });
  });
}

