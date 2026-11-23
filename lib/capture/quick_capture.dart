/// The platform half of quick capture: a hotkey on Windows, a shortcut on
/// Android.
///
/// Everything here is best effort and silent on failure. A refused hotkey (some
/// other app already owns the combination) must not stop the app opening, and
/// it must not nag: the feature simply is not there, and pressing the button in
/// the calendar still works.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:window_manager/window_manager.dart';

import 'capture_request.dart';

/// The action id Android's shortcut tile sends back.
const String kQuickCaptureAction = 'quick_capture';

/// The label shown on the shortcut tile.
const String kQuickCaptureLabel = 'New thought';

/// Registers the ways into the app.
class QuickCapture {
  QuickCapture({this.onError = _ignore});

  /// Called with a description when a registration fails, for a debug log. The
  /// app does not show these to the user.
  final void Function(String message) onError;

  static void _ignore(String message) {}

  /// Whether this build has a platform-level trigger to set up.
  static bool get supported =>
      !kIsWeb && (Platform.isWindows || Platform.isAndroid);

  /// Sets up the trigger for this platform. Await before the first frame where
  /// possible, so an early press is not missed.
  Future<void> start(CaptureRequest request) async {
    if (!supported) return;
    if (Platform.isWindows) {
      await _startWindows(request);
    } else if (Platform.isAndroid) {
      await _startAndroid(request);
    }
  }

  /// Windows: a global hotkey, plus raising the window so the press is visibly
  /// worth something.
  ///
  /// Ctrl+Shift+Space: convenient one-handed, and unlikely to be taken by an
  /// editor or a browser.
  Future<void> _startWindows(CaptureRequest request) async {
    try {
      await windowManager.ensureInitialized();
      final hotKey = HotKey(
        key: LogicalKeyboardKey.space,
        modifiers: const [HotKeyModifier.control, HotKeyModifier.shift],
        scope: HotKeyScope.system,
        identifier: 'verbal-outlet-quick-capture',
      );
      await HotKeyManager.instance.register(
        hotKey,
        keyDownHandler: (_) async {
          request.capture();
          try {
            // The window may be minimised or behind something when the key is
            // pressed; showing it is the point of a quick capture.
            if (await windowManager.isMinimized()) {
              await windowManager.restore();
            }
            await windowManager.show();
            await windowManager.focus();
          } catch (error) {
            onError('Raising the window failed: $error');
          }
        },
      );
    } catch (error) {
      onError('Registering the quick capture hotkey failed: $error');
    }
  }

  /// Android: a long-press shortcut on the launcher icon.
  ///
  /// The launcher also offers "Scan a code" style actions from here if they are
  /// added later; one tile is enough for now.
  Future<void> _startAndroid(CaptureRequest request) async {
    try {
      final quickActions = const QuickActions();
      await quickActions.initialize((type) {
        if (type == kQuickCaptureAction) request.capture();
      });
      await quickActions.setShortcutItems(const [
        ShortcutItem(
          type: kQuickCaptureAction,
          localizedTitle: kQuickCaptureLabel,
          icon: 'ic_quick_capture',
        ),
      ]);
    } catch (error) {
      onError('Setting the home-screen shortcut failed: $error');
    }
  }
}
