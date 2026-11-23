/// Turning speech into the words that become a diary entry.
///
/// Everything here runs on the machine: the microphone is recorded by `record`,
/// and the audio is transcribed by a bundled whisper.cpp through
/// `whisper_ggml_plus`. No audio is uploaded anywhere, which matters for a
/// diary — the most personal thing in the app should not need a cloud account.
///
/// The engine is deliberately split from the UI. [VoiceEngine] is the narrow
/// interface the add-thought sheet talks to, so a test can substitute a fake
/// without touching a microphone, and so a different recogniser could be
/// swapped in later without rewriting the sheet.
///
/// There are two ways to capture. [VoiceEngine.start] records one clip and
/// transcribes it when it ends; [VoiceEngine.startLive] keeps listening and
/// re-transcribes the audio in short chunks, so the words appear while the
/// person is still talking. Local Whisper cannot stream word by word, so "live"
/// means a transcript that grows every few seconds — a handful of seconds
/// behind the voice. It stays on the device and costs nothing, which is the
/// trade the app deliberately makes.
library;

/// One recogniser attempt, with the parts the UI needs to show progress.
class TranscriptResult {
  const TranscriptResult({
    required this.text,
    this.duration = Duration.zero,
    this.elapsed = Duration.zero,
  });

  /// What was heard, trimmed. Empty when nothing intelligible was said.
  final String text;

  /// Length of the recording that produced it.
  final Duration duration;

  /// How long transcription took, for a quiet "that was quick" note.
  final Duration elapsed;
}

/// Something went wrong that the person can act on.
class VoiceException implements Exception {
  const VoiceException(this.message, {this.hint});

  final String message;

  /// A concrete next step, shown under the message when there is one.
  final String? hint;

  @override
  String toString() => message;
}

/// One place where a pause ended a chunk.
///
/// Live capture cuts a sentence when the speaker goes quiet for
/// [VoiceSettings.pauseAfterSpeech]. That is the right guess most of the time,
/// but a short breath in the middle of a thought looks the same as a full stop,
/// so the join is worth judging afterwards. This records just enough to judge:
/// the words on each side, and the pause that was in effect.
class ChunkCut {
  const ChunkCut({
    required this.pause,
    required this.before,
    required this.after,
  });

  /// The pause length the session was using when it cut here.
  final Duration pause;

  /// The end of the text before the cut.
  final String before;

  /// The start of the text after it.
  final String after;
}

/// A capture that is still running, reporting a growing transcript.
///
/// [text] is the full transcript so far, always the latest [transcripts] value.
/// The UI listens rather than polls, but [text] is there for the moment a
/// chunk arrives before a rebuild.
abstract interface class LiveVoiceSession {
  /// The transcript after each chunk, oldest first, then the final text once
  /// [finish] completes. Emits only when the text actually changed.
  ///
  /// Words are only ever added: a later pass may correct spelling, but a word
  /// that has been heard does not vanish, so the screen never rewinds while
  /// somebody is still talking.
  Stream<String> get transcripts;

  /// The latest transcript, for a caller that missed a stream event.
  String get text;

  /// The part of [text] that a pause has closed and a later pass will not
  /// change.
  ///
  /// Always a prefix of [text]. What follows it is the sentence being spoken
  /// right now, which may still be corrected — which is why the sheet shows it
  /// in a softer tone, and in full ink once it settles.
  String get settled;

  /// A 0–1 loudness reading, updated from the audio that is arriving.
  Stream<double> get levels;

  /// Each sentence a pause has just closed, for tuning the pause length.
  ///
  /// Optional: an engine that does not report cuts simply has no stream, and
  /// everything else works the same.
  Stream<ChunkCut>? get cuts;

  /// Stops the microphone, transcribes whatever is left, and returns the final
  /// text. Safe to call once.
  Future<TranscriptResult> finish();

  /// Stops and throws the recording away, keeping nothing.
  Future<void> cancel();
}

/// A recogniser the sheet can drive.
abstract interface class VoiceEngine {
  /// Whether a recogniser is ready to use right now. Downloads are not done
  /// here; the settings screen owns that.
  Future<bool> isReady();

  /// Holds the microphone open until [stop].
  ///
  /// Throws [VoiceException] when the microphone is unavailable or permission
  /// was refused.
  Future<void> start();

  /// Stops recording and transcribes what was captured.
  ///
  /// Throws [VoiceException] when nothing usable was recorded or the engine
  /// could not read the audio.
  Future<TranscriptResult> stopAndTranscribe();

  /// Starts a capture that reports a growing transcript while it runs.
  ///
  /// [pauseAfterSpeech] is how much silence closes a sentence; it comes from the
  /// settings, because how long a natural pause lasts depends on the speaker.
  ///
  /// Throws [VoiceException] when the microphone or model is unavailable, the
  /// same way [start] does.
  Future<LiveVoiceSession> startLive({Duration? pauseAfterSpeech});

  /// Abandons the current recording without keeping it.
  Future<void> cancel();

  /// A 0–1 loudness reading for the level meter, or null when unavailable.
  Stream<double> get levels;

  Future<void> dispose();
}
