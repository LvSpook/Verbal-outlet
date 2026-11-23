/// Getting into the app fast enough that a thought is not lost on the way.
///
/// Capture has three parts, kept apart so the interesting logic can be tested
/// without a desktop or a phone:
///
/// * [CaptureTrigger] is *how* the app was entered: a global hotkey on a
///   computer, a home-screen shortcut on a phone, or an ordinary launch.
/// * [CaptureRequest] is a one-shot signal the home screen listens to, asking
///   for today's note with the composer focused.
/// * [QuickCapture] is the platform glue: registering the hotkey, and telling
///   Android about the shortcut tile.
///
/// The request is a value rather than a callback so that a trigger arriving
/// before the UI exists (Android shortcuts start the app cold, and a hotkey can
/// fire during startup) is not dropped: it waits in the request until a screen
/// picks it up.
library;

import 'package:flutter/foundation.dart';

/// How the app was opened.
enum CaptureTrigger {
  /// A normal launch: show the calendar as usual.
  normal,

  /// "New thought" from the Windows global hotkey or the Android shortcut.
  /// Opens today's note and puts the cursor in the composer.
  quick,
}

/// A pending request for quick capture.
///
/// Mutable and long-lived: [capture] may be called from a platform callback at
/// any time, and the UI consumes it when it is ready.
class CaptureRequest extends ChangeNotifier {
  CaptureTrigger _pending = CaptureTrigger.normal;

  /// Whether something is waiting to be acted on.
  bool get isPending => _pending == CaptureTrigger.quick;

  /// Asks for a quick capture. Safe to call from anywhere, including before the
  /// first frame.
  void capture() {
    _pending = CaptureTrigger.quick;
    notifyListeners();
  }

  /// Takes the pending request, leaving none behind.
  ///
  /// Returns [CaptureTrigger.normal] when there was nothing waiting, so a
  /// caller can `if (trigger != CaptureTrigger.quick) return;`.
  CaptureTrigger consume() {
    final trigger = _pending;
    _pending = CaptureTrigger.normal;
    return trigger;
  }

  /// Drops a pending request without acting on it.
  void clear() => _pending = CaptureTrigger.normal;
}
