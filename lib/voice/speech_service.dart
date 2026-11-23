/// A small text-to-speech service for reading AI questions aloud.
///
/// Deliberately not a pub plugin. The obvious choice, `flutter_tts`, needs
/// `nuget.exe` at build time on Windows, which is a fragile extra toolchain for
/// a diary app. Both platforms already ship a speech engine, so a short method
/// channel reaches them directly: SAPI on Windows, the platform TextToSpeech on
/// Android.
///
/// Speech is always optional (off by default) and failure is never fatal: if the
/// channel is missing, [speak] quietly does nothing, because a question that
/// cannot be read aloud is still a question on screen.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Speaks short pieces of text, if the platform can.
class SpeechService {
  SpeechService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('verbal_outlet/speech');

  final MethodChannel _channel;

  /// Reads [text] aloud, interrupting anything already being spoken.
  ///
  /// Returns false when the platform could not speak, which callers treat as
  /// "no voice, no problem" rather than an error worth showing.
  Future<bool> speak(String text) async {
    final spoken = text.trim();
    if (spoken.isEmpty) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('speak', {'text': spoken});
      return ok ?? false;
    } catch (error) {
      debugPrint('Speaking aloud failed: $error');
      return false;
    }
  }

  /// Stops whatever is being spoken.
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (error) {
      debugPrint('Stopping speech failed: $error');
    }
  }
}
