/// The app's view of "is there a new version, and how is getting it going".
///
/// One controller, so the launch check and the Settings card cannot disagree
/// about what has been found. It is deliberately quiet about failure: most
/// checks happen while nobody is looking (at launch), and "could not reach
/// GitHub" is not something a person needs to fix. Only an explicit check from
/// the Updates card surfaces a reason.
library;

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'update_installer.dart';
import 'updates.dart';

/// What the Updates card should show.
class UpdateState {
  const UpdateState({
    this.checking = false,
    this.downloading = false,
    this.progress,
    this.available,
    this.checked = false,
    this.error,
    this.installing = false,
  });

  /// The newer release, when there is one.
  final ReleaseInfo? available;

  /// True while asking GitHub.
  final bool checking;

  /// True while the new build is being fetched.
  final bool downloading;

  /// Download fraction, or null when the size is unknown.
  final double? progress;

  /// True once a check has finished, successfully or not.
  final bool checked;

  /// A reason to show, only when a check was asked for by hand.
  final String? error;

  /// True while the installer is being opened (or the app is about to restart).
  final bool installing;

  bool get hasUpdate => available != null;

  UpdateState copyWith({
    ReleaseInfo? available,
    bool? checking,
    bool? downloading,
    double? progress,
    bool? checked,
    String? error,
    bool? installing,
    bool clearError = false,
    bool clearProgress = false,
  }) {
    return UpdateState(
      available: available ?? this.available,
      checking: checking ?? this.checking,
      downloading: downloading ?? this.downloading,
      progress: clearProgress ? null : (progress ?? this.progress),
      checked: checked ?? this.checked,
      error: clearError ? null : (error ?? this.error),
      installing: installing ?? this.installing,
    );
  }
}

class UpdateController extends ChangeNotifier {
  UpdateController({
    required this.service,
    required UpdateInstaller installer,
    this.currentVersionOverride,
    PackageInfo? packageInfo,
  }) : // A named parameter cannot be private, so these two cannot be initializing
       // formals; the ignore keeps the intent (they are never set elsewhere).
       // ignore: prefer_initializing_formals
       _installer = installer,
       // ignore: prefer_initializing_formals
       _packageInfo = packageInfo;

  final UpdateService service;
  final UpdateInstaller _installer;

  /// Overrides the running version. Tests pass one; production reads it from
  /// the platform, which knows what was actually built.
  final String? currentVersionOverride;
  final PackageInfo? _packageInfo;

  UpdateState _state = const UpdateState();
  UpdateState get state => _state;

  String? _version;
  bool _disposed = false;

  /// The version this build was made from, e.g. `1.2.0`.
  Future<String> currentVersion() async {
    if (_version != null) return _version!;
    final override = currentVersionOverride;
    if (override != null) return _version = override;
    final info = _packageInfo ?? await PackageInfo.fromPlatform();
    return _version = info.version;
  }

  /// Asks GitHub whether there is something newer.
  ///
  /// [quiet] is for the launch check: a failure leaves no error behind, because
  /// being offline at startup is normal and not the person's problem.
  Future<void> check({bool quiet = true}) async {
    if (_state.checking || _state.downloading) return;

    _state = _state.copyWith(checking: true, clearError: true);
    _notify();

    try {
      final current = await currentVersion();
      final release = await service.latest();
      if (_disposed) return;

      final available =
          release != null && isNewerVersion(release.version, current)
          ? release
          : null;

      _state = UpdateState(
        checking: false,
        checked: true,
        available: available,
      );
      _notify();
    } catch (error) {
      if (_disposed) return;
      _state = UpdateState(
        checking: false,
        checked: true,
        available: _state.available,
        error: quiet ? null : '$error',
      );
      _notify();
    }
  }

  /// Downloads the newer build and hands it to the installer.
  ///
  /// On Windows this ends the process, so nothing after [install] runs. On
  /// Android it opens the system installer and returns.
  Future<void> install() async {
    final release = _state.available;
    if (release == null || _state.downloading || _state.installing) return;

    _state = _state.copyWith(
      downloading: true,
      clearError: true,
      clearProgress: true,
    );
    _notify();

    try {
      await _installer.install(
        release,
        progress: (fraction) {
          if (_disposed || !_state.downloading) return;
          _state = _state.copyWith(progress: fraction);
          _notify();
        },
      );
      if (_disposed) return;
      _state = _state.copyWith(downloading: false, installing: false);
      _notify();
    } catch (error) {
      if (_disposed) return;
      _state = _state.copyWith(
        downloading: false,
        installing: false,
        error: 'The update could not be installed: $error',
        clearProgress: true,
      );
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

