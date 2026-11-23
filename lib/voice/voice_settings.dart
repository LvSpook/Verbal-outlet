/// The handful of choices that change how talking to the app behaves.
///
/// These are deliberately few. Everything else about voice is a fixed, sensible
/// default (local transcription, a few seconds of lag); these are the switches
/// where people genuinely differ.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class VoiceSettings {
  const VoiceSettings({
    this.commandsEnabled = true,
    this.followUpsEnabled = true,
    this.speakQuestions = false,
    this.pauseAfterSpeech = defaultPauseAfterSpeech,
  });

  /// The default silence that ends a sentence: long enough for a spoken pause,
  /// short enough that words do not feel held back.
  static const Duration defaultPauseAfterSpeech = Duration(milliseconds: 700);

  /// The range the slider offers. Below half a second ordinary pauses between
  /// words start splitting sentences; above two seconds nothing arrives until
  /// long after you have stopped.
  static const Duration minPauseAfterSpeech = Duration(milliseconds: 350);
  static const Duration maxPauseAfterSpeech = Duration(milliseconds: 2000);

  /// Whether spoken requests like "search for the trip" are treated as commands
  /// to the app rather than as diary text. Off means everything you say becomes
  /// an entry, which some people prefer.
  final bool commandsEnabled;

  /// Whether the AI may interrupt with a question while you are talking.
  final bool followUpsEnabled;

  /// Whether those questions are also read aloud. Off by default: reading on
  /// screen is less startling, and speaking over someone mid-thought is rude
  /// unless they asked for it.
  final bool speakQuestions;

  /// How much silence ends a sentence during live capture.
  ///
  /// This is the one number that changes whether live capture feels right for a
  /// person, because it depends on how they speak: brisk speech with short
  /// breaths gets cut off at the default, while slow, thinking-aloud speech
  /// wants longer. Clamped to [minPauseAfterSpeech]..[maxPauseAfterSpeech].
  final Duration pauseAfterSpeech;

  VoiceSettings copyWith({
    bool? commandsEnabled,
    bool? followUpsEnabled,
    bool? speakQuestions,
    Duration? pauseAfterSpeech,
  }) {
    return VoiceSettings(
      commandsEnabled: commandsEnabled ?? this.commandsEnabled,
      followUpsEnabled: followUpsEnabled ?? this.followUpsEnabled,
      speakQuestions: speakQuestions ?? this.speakQuestions,
      pauseAfterSpeech: clampPause(pauseAfterSpeech ?? this.pauseAfterSpeech),
    );
  }
}

/// Keeps a pause length inside the range the UI offers.
Duration clampPause(Duration value) {
  if (value < VoiceSettings.minPauseAfterSpeech) {
    return VoiceSettings.minPauseAfterSpeech;
  }
  if (value > VoiceSettings.maxPauseAfterSpeech) {
    return VoiceSettings.maxPauseAfterSpeech;
  }
  return Duration(milliseconds: value.inMilliseconds);
}

/// Reads and writes [VoiceSettings] in preferences.
class VoiceBehaviourStore {
  static const String _keyCommands = 'voice.commandsEnabled';
  static const String _keyFollowUps = 'voice.followUpsEnabled';
  static const String _keySpeak = 'voice.speakQuestions';
  static const String _keyPause = 'voice.pauseAfterSpeechMs';

  SharedPreferences? _preferences;

  Future<SharedPreferences> get _prefs async =>
      _preferences ??= await SharedPreferences.getInstance();

  Future<VoiceSettings> load() async {
    try {
      final prefs = await _prefs;
      return VoiceSettings(
        commandsEnabled: prefs.getBool(_keyCommands) ?? true,
        followUpsEnabled: prefs.getBool(_keyFollowUps) ?? true,
        speakQuestions: prefs.getBool(_keySpeak) ?? false,
        pauseAfterSpeech: clampPause(
          Duration(
            milliseconds:
                prefs.getInt(_keyPause) ??
                VoiceSettings.defaultPauseAfterSpeech.inMilliseconds,
          ),
        ),
      );
    } catch (_) {
      // Preferences are a nicety: without them the defaults still work.
      return const VoiceSettings();
    }
  }

  Future<void> save(VoiceSettings settings) async {
    try {
      final prefs = await _prefs;
      await prefs.setBool(_keyCommands, settings.commandsEnabled);
      await prefs.setBool(_keyFollowUps, settings.followUpsEnabled);
      await prefs.setBool(_keySpeak, settings.speakQuestions);
      await prefs.setInt(_keyPause, settings.pauseAfterSpeech.inMilliseconds);
    } catch (error) {
      debugPrint('Saving voice settings failed: $error');
    }
  }
}
