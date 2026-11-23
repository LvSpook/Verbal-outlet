/// Watching where live capture cuts a sentence, so the pause length can be
/// suggested rather than guessed.
///
/// The pause is the one voice setting that depends on the speaker: brisk speech
/// with short breaths gets chopped at 0.7 s, while someone thinking aloud wants
/// longer. Rather than asking people to guess a millisecond value, the app
/// notices what actually happened — and only speaks up when the pattern is
/// clear.
///
/// Two pieces:
///
/// * [PauseTrace], a tiny running summary of every chunk boundary, persisted in
///   preferences. The decisions are made in audio time and never include the
///   words, so this is not a second copy of anybody's diary.
/// * [PauseEvidence], the small number of **possibly** awkward joins, sent to
///   the AI to judge a single yes-or-no question: does this cut fall in the
///   middle of a thought?
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'voice_settings.dart';

/// Where one chunk boundary fell, and what was on either side of it.
///
/// Only kept for the handful of joins that look suspicious. The text is the
/// committed sentence and the one after it, so a model can tell whether the cut
/// broke something rather than merely came after a full stop.
@immutable
class PauseEvidence {
  const PauseEvidence({
    required this.pause,
    required this.before,
    required this.after,
  });

  /// The pause at the moment the chunk was cut.
  final Duration pause;

  /// The last words before the cut.
  final String before;

  /// The first words after it.
  final String after;

  Map<String, Object?> toJson() => {
    'p': pause.inMilliseconds,
    'a': before,
    'b': after,
  };

  static PauseEvidence? fromJson(Object? json) {
    if (json is! Map) return null;
    final pause = json['p'];
    final before = json['a'];
    final after = json['b'];
    if (pause is! int || before is! String || after is! String) return null;
    return PauseEvidence(
      pause: Duration(milliseconds: pause),
      before: before,
      after: after,
    );
  }
}

/// What the app has seen lately, and what it makes of it.
@immutable
class PauseTrace {
  const PauseTrace({
    this.boundaries = 0,
    this.hints = 0,
    this.evidence = const [],
    this.suggested,
    this.dismissed = false,
  });

  /// How many chunk boundaries have been observed, which is a rough measure of
  /// whether there is enough to go on.
  final int boundaries;

  /// How long the chunks were when the cuts were made. Kept as a running count
  /// per value so the most common setting can be reported without a list of
  /// every recording ever made.
  final int hints;

  /// Joins that looked potentially awkward, oldest first, capped at [maxEvidence].
  final List<PauseEvidence> evidence;

  /// A pause length the evidence supports, or null when it is not clear.
  final Duration? suggested;

  /// Whether the person has already said no to a suggestion, so it is not made
  /// again on every launch.
  final bool dismissed;

  static const int maxEvidence = 3;

  /// Roughly how many boundaries before a suggestion is worth making. Below
  /// this, one unusual recording could change the setting for no reason.
  static const int minBoundaries = 12;

  bool get hasEnough => boundaries >= minBoundaries;

  /// Whether there is a suggestion to show.
  bool get showsSuggestion => !dismissed && suggested != null;

  PauseTrace copyWith({
    int? boundaries,
    int? hints,
    List<PauseEvidence>? evidence,
    Duration? suggested,
    bool? dismissed,
    bool clearSuggestion = false,
  }) {
    return PauseTrace(
      boundaries: boundaries ?? this.boundaries,
      hints: hints ?? this.hints,
      evidence: evidence ?? this.evidence,
      suggested: clearSuggestion ? null : (suggested ?? this.suggested),
      dismissed: dismissed ?? this.dismissed,
    );
  }

  Map<String, Object?> toJson() => {
    'n': boundaries,
    'h': hints,
    'e': evidence.map((e) => e.toJson()).toList(),
    's': suggested?.inMilliseconds,
    'd': dismissed,
  };

  static PauseTrace fromJson(Object? json) {
    if (json is! Map) return const PauseTrace();
    int asInt(Object? value, [int fallback = 0]) =>
        value is int ? value : fallback;

    final rawEvidence = json['e'];
    final evidence = <PauseEvidence>[];
    if (rawEvidence is List) {
      for (final item in rawEvidence) {
        final parsed = PauseEvidence.fromJson(item);
        if (parsed != null) evidence.add(parsed);
      }
    }

    final rawSuggested = json['s'];
    return PauseTrace(
      boundaries: asInt(json['n']),
      hints: asInt(json['h']),
      evidence: evidence,
      suggested: rawSuggested is int
          ? clampPause(Duration(milliseconds: rawSuggested))
          : null,
      dismissed: json['d'] == true,
    );
  }
}

/// Records what live capture did, and decides whether to suggest a change.
class PauseTraceStore {
  static const String _key = 'voice.pauseTrace';

  SharedPreferences? _preferences;

  Future<SharedPreferences> get _prefs async =>
      _preferences ??= await SharedPreferences.getInstance();

  Future<PauseTrace> load() async {
    try {
      final raw = (await _prefs).getString(_key);
      if (raw == null) return const PauseTrace();
      return PauseTrace.fromJson(jsonDecode(raw));
    } catch (_) {
      // A corrupt blob is not worth a crash; start over.
      return const PauseTrace();
    }
  }

  Future<void> save(PauseTrace trace) async {
    try {
      await (await _prefs).setString(_key, jsonEncode(trace.toJson()));
    } catch (error) {
      debugPrint('Saving the pause trace failed: $error');
    }
  }
}

/// One chunk boundary as live capture saw it.
@immutable
class PauseBoundary {
  const PauseBoundary({
    required this.pause,
    required this.before,
    required this.after,
  });

  final Duration pause;
  final String before;
  final String after;
}

/// Adds one boundary to [trace], keeping the suspicious ones.
///
/// Deliberately selective: only joins that look like they fell inside a sentence
/// are kept, and only a few of those, because each one is a sentence from
/// somebody's diary waiting to be judged. Everything else is just a count.
PauseTrace noteBoundary(PauseTrace trace, PauseBoundary boundary) {
  final next = trace.copyWith(boundaries: trace.boundaries + 1);

  final before = boundary.before.trimRight();
  final after = boundary.after.trimLeft();
  if (before.isEmpty || after.isEmpty || !_looksCut(before, after)) {
    return next;
  }
  if (next.evidence.length >= PauseTrace.maxEvidence) return next;

  return next.copyWith(
    evidence: [
      ...next.evidence,
      PauseEvidence(pause: boundary.pause, before: before, after: after),
    ],
  );
}

/// Whether a cut looks like it fell inside a sentence.
///
/// A cheap filter, not a verdict: it only keeps the joins worth asking the AI
/// about. A full stop, a question mark or a capital letter after the cut all
/// suggest the sentence genuinely ended.
bool _looksCut(String before, String after) {
  const enders = ['.', '?', '!', '…'];
  for (final ender in enders) {
    if (before.endsWith(ender)) return false;
  }
  final first = after.substring(0, 1);
  if (first.toUpperCase() == first && first.toLowerCase() != first) {
    return false;
  }
  return true;
}

/// Turns a set of AI verdicts about the collected evidence into a suggestion.
///
/// [brokenJoins] counts how many of [trace.evidence] the AI agreed fell mid
/// thought. The suggested value is the length that would have let those pauses
/// finish, rounded up to a friendly step and clamped to the slider's range.
///
/// Returns null when the case is not strong enough, which is the normal answer.
Duration? suggestPause(
  PauseTrace trace, {
  required int brokenJoins,
}) {
  if (!trace.hasEnough) return null;
  if (brokenJoins < 2) return null;
  if (trace.evidence.isEmpty) return null;

  // The longest pause among the confirmed cuts is the one that was cut short.
  var longest = Duration.zero;
  for (final item in trace.evidence) {
    if (item.pause > longest) longest = item.pause;
  }
  if (longest == Duration.zero) return null;

  // Add a little headroom: the point is to clear the pause, not to match it.
  final wanted = longest.inMilliseconds + 250;

  // Round to the nearest 50 ms so the value reads like a choice, not a reading.
  final stepped = (wanted / 50).round() * 50;
  final clamped = clampPause(Duration(milliseconds: stepped));
  return clamped.inMilliseconds == VoiceSettings.defaultPauseAfterSpeech
          .inMilliseconds
      ? null
      : clamped;
}
