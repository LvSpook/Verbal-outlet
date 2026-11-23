/// The live capture itself, kept apart from the microphone.
///
/// This class knows nothing about `record` or whisper.cpp: it is handed a stream
/// of PCM, a function that turns a WAV file into text, and two callbacks. That is
/// deliberate. Chunk boundaries, speech detection and the "words only ever get
/// added" rule are the parts most likely to be wrong and the hardest to notice by
/// ear, so they belong somewhere a test can drive them byte by byte.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'audio_chunks.dart';
import 'voice_engine.dart';
import 'voice_settings.dart';

/// A live capture driven by speech detection and rolling re-transcription.
///
/// Raw PCM arrives from the recorder in small buffers. Two things decide when a
/// chunk is sent to Whisper:
///
/// * **A pause.** When the level has been near silence for [_pause] after
///   speech, the sentence has ended; that is the natural place to stop, and the
///   moment the person expects their words to appear. Waiting out a fixed timer
///   instead is what made the old version feel seconds behind.
/// * **Time.** While somebody talks without pausing, a pass runs every
///   [_partial] so the transcript still grows, and a segment is force-ended at
///   [_maxSegment] so no single transcription grows without bound.
///
/// Silence is never transcribed. That is most of the saving: before, every
/// interval was spent re-reading room tone.
///
/// whether somebody talked over the last few hundred milliseconds, not by a
/// stopwatch.
///
/// Whisper cannot continue a previous result and stitching clips loses words at
/// the joins, so a segment is re-transcribed from its own start on each pass,
/// and its finished text is *committed* when a pause ends it. What is shown is
/// the committed text plus the current segment, so words are only ever added —
/// never replaced by a shorter reading of the same audio.
class WhisperLiveSession implements LiveVoiceSession {
  WhisperLiveSession(
    Stream<Uint8List> stream,
    this._transcribe,
    this._stopRecorder,
    this._onDone, {
    this.tempDirectory,
    bool ticking = true,
    Duration? pause,
    Duration? partial,
    Duration? maxSegment,
  }) : _pause = pause ?? VoiceSettings.defaultPauseAfterSpeech,
       _partial = partial ?? const Duration(milliseconds: 2500),
       _maxSegment = maxSegment ?? const Duration(seconds: 15) {
    _subscription = stream.listen(
      _onAudio,
      onError: (Object error) =>
          _fail(VoiceException('The microphone stopped: $error')),
      onDone: () => _closed = true,
    );
    _transcriptController = StreamController<String>.broadcast();
    _levelController = StreamController<double>.broadcast();
    _cutController = StreamController<ChunkCut>.broadcast();
    if (ticking) _timer = Timer.periodic(_tick, (_) => considerFlush());
  }

  /// How often the session checks whether a chunk is due. Short, because it is
  /// only a check: the stream of captured audio is where the work happens.
  static const Duration _tick = Duration(milliseconds: 150);

  /// Silence after speech that closes a sentence.
  final Duration _pause;

  /// A pass while somebody is still speaking, so their words keep arriving.
  final Duration _partial;

  /// The longest audio one transcription is asked to read at once.
  final Duration _maxSegment;

  /// Below this much audio a clip is mostly silence; Whisper's own VAD trims
  /// it, but skipping the call saves a pointless wake-up.
  static const int _minBytes = pcmBytesPerSecond ~/ 3;

  static int _bytesFor(Duration d) =>
      (d.inMilliseconds * pcmBytesPerSecond / 1000).round();

  final Future<String> Function(File file) _transcribe;
  final Future<void> Function() _stopRecorder;
  final VoidCallback _onDone;

  /// Where the temporary clips are written. Overridable so a test can point it
  /// at a directory it made.
  final Directory? tempDirectory;

  /// Everything captured, kept for the one accurate pass in [finish].
  final BytesBuilder _all = BytesBuilder(copy: true);

  /// Audio since the last committed sentence.
  final BytesBuilder _segment = BytesBuilder(copy: true);

  StreamSubscription<Uint8List>? _subscription;
  late final StreamController<String> _transcriptController;
  late final StreamController<double> _levelController;
  late final StreamController<ChunkCut> _cutController;
  Timer? _timer;

  bool _closed = false;
  bool _busy = false;
  bool _finished = false;
  String _text = '';

  /// The text of sentences already closed by a pause.
  String _committed = '';

  /// The last reading of the current, still-open segment.
  String _segmentText = '';

  /// Silent audio since the last speech, in bytes.
  int _silence = 0;

  /// Whether any speech has been heard since the last pass.
  bool _spoke = false;

  /// Whether the open segment contains any speech at all.
  ///
  /// Distinct from [_spoke], which resets after every pass: a sentence that was
  /// already read once still has to be committed when its speaker stops.
  bool _segmentSpoke = false;

  /// Audio captured since the last pass, in bytes.
  ///
  /// The partial interval is measured against this rather than a clock: what
  /// matters is how much new speech is waiting to be read, and audio time keeps
  /// that honest even if buffers arrive in bursts.
  int _sincePass = 0;

  @override
  Stream<String> get transcripts => _transcriptController.stream;

  @override
  String get text => _text;

  /// Sentences already closed by a pause.
  @override
  String get settled => _committed;

  /// Whether a transcription pass is running. Exposed so a test can wait for
  /// one to finish rather than guess at timings.
  @visibleForTesting
  bool get isWorking => _busy;

  @override
  Stream<double> get levels => _levelController.stream;

  /// Where each pause ended a sentence, for tuning the pause length.
  ///
  /// Only emitted when somebody actually listened, so an ordinary recording
  /// pays nothing for a feature it is not using.
  @override
  Stream<ChunkCut> get cuts => _cutController.stream;

  void _onAudio(Uint8List bytes) {
    if (_closed || _finished || bytes.isEmpty) return;
    _all.add(bytes);
    _segment.add(bytes);
    _sincePass += bytes.length;

    if (pcmHasSpeech(bytes)) {
      _spoke = true;
      _segmentSpoke = true;
      _silence = 0;
    } else {
      _silence += bytes.length;
    }
    _emitLevel(bytes);
  }

  /// A loudness reading from the chunk, on the same 0–1 scale as the one-shot
  /// recorder's amplitude stream, so the meter looks the same.
  void _emitLevel(Uint8List bytes) {
    if (!_levelController.hasListener) return;
    _levelController.add(pcmPeak(bytes));
  }

  /// Whether the current audio is worth sending to Whisper yet.
  ///
  /// Public so a test can drive the decision without waiting on wall-clock
  /// timers, which would make the assertions a race.
  void considerFlush() {
    if (_busy || _closed || _finished) return;
    // Nothing but silence in this segment: nothing to read, and nothing gained
    // by waking Whisper for it.
    if (!_segmentSpoke) return;

    final segmentBytes = _segment.length;
    if (segmentBytes < _minBytes) return;

    final paused = _silence >= _bytesFor(_pause);
    final long = segmentBytes >= _bytesFor(_maxSegment);
    // `_spoke` gates the partial re-read: with no new speech since the last
    // pass there is nothing new to hear, but a sentence already read still has
    // to be committed when it ends.
    final due = _spoke && _sincePass >= _bytesFor(_partial);
    if (!paused && !long && !due) return;

    // A pause is a sentence end: its text is committed and the audio let go.
    // Otherwise the segment is only re-read, so a word can be corrected but
    // never lost.
    unawaited(_flush(commit: paused));
  }

  /// Transcribes the open segment, optionally committing it.
  Future<void> _flush({required bool commit}) async {
    if (_busy) return;
    final pcm = _segment.toBytes();
    if (pcm.length < _minBytes) return;

    _busy = true;
    _sincePass = 0;
    // Reset before the await: audio that arrives during the call belongs to the
    // next segment and must not be pulled into this snapshot.
    _spoke = false;
    _silence = 0;
    if (commit) _segment.clear();

    final directory = tempDirectory ?? await getTemporaryDirectory();
    final file = File(
      p.join(
        directory.path,
        'live-${DateTime.now().microsecondsSinceEpoch}.wav',
      ),
    );
    try {
      await file.writeAsBytes(pcmToWav(pcm), flush: true);
      final text = await _transcribe(file);
      if (_finished || text.isEmpty) return;

      if (commit) {
        final closed = liveChunkText(_segmentText, text);
        final before = _committed;
        _committed = _join(_committed, closed);
        _segmentText = '';
        _segmentSpoke = false;
        // Reported after the text advances, so a listener sees the sentence
        // that just ended. Only the tail of the earlier text is kept: a model
        // judging the join needs the last clause, not the whole recording.
        if (before.isNotEmpty && closed.isNotEmpty &&
            !_cutController.isClosed) {
          _cutController.add(
            ChunkCut(pause: _pause, before: _tail(before), after: closed),
          );
        }
      } else {
        _segmentText = liveChunkText(_segmentText, text);
      }
      _publish();
    } catch (error) {
      // A failed pass is not fatal: the recording is still running, and the
      // next pass may do better. The final [finish] surfaces a real problem.
      debugPrint('A live transcription pass failed: $error');
      // Keep the audio so the next pass can retry it.
      if (commit) _segment.add(pcm);
    } finally {
      _busy = false;
      await file.delete().catchError((_) => file);
    }
  }

  void _publish() {
    final text = _join(_committed, _segmentText);
    if (text.isEmpty || text == _text) return;
    _text = text;
    if (!_transcriptController.isClosed) _transcriptController.add(text);
  }

  static String _join(String a, String b) {
    if (a.isEmpty) return b;
    if (b.isEmpty) return a;
    return '$a $b';
  }

  /// The last few words of [text], capped so a long speech does not put the
  /// whole transcript into a pause report.
  static String _tail(String text) {
    const limit = 80;
    final trimmed = text.trimRight();
    if (trimmed.length <= limit) return trimmed;
    final cut = trimmed.length - limit;
    final space = trimmed.indexOf(' ', cut);
    return trimmed.substring(space == -1 ? cut : space + 1);
  }

  void _fail(VoiceException error) {
    debugPrint('Live capture stopped: ${error.message}');
    _closed = true;
  }

  @override
  Future<TranscriptResult> finish() async {
    if (_finished) return TranscriptResult(text: _text);
    _finished = true;
    _timer?.cancel();
    _timer = null;

    // Let the recorder finish delivering whatever it already captured, then
    // transcribe the whole thing once more so the last words are included and
    // the sentences read as one piece.
    await _stopRecorder();
    await _subscription?.cancel();
    _subscription = null;

    final pcm = _all.toBytes();
    if (pcm.length < _minBytes) return _closing(text: _text);

    final directory = tempDirectory ?? await getTemporaryDirectory();
    final file = File(
      p.join(
        directory.path,
        'final-${DateTime.now().microsecondsSinceEpoch}.wav',
      ),
    );
    final watch = Stopwatch()..start();
    TranscriptResult? result;
    Object? failure;
    try {
      await file.writeAsBytes(pcmToWav(pcm), flush: true);
      final text = await _transcribe(file);
      if (text.isNotEmpty) _text = text;
      watch.stop();
      result = TranscriptResult(
        text: _text,
        duration: pcmDuration(pcm.length),
        elapsed: watch.elapsed,
      );
    } catch (error) {
      failure = error;
    } finally {
      await file.delete().catchError((_) => file);
    }

    // The person's words are not lost when this pass fails: whatever the live
    // passes produced is returned, and the sheet reports the failure separately.
    return _closing(text: _text, result: result, error: failure);
  }

  Future<TranscriptResult> _closing({
    required String text,
    TranscriptResult? result,
    Object? error,
  }) async {
    _onDone();
    await _transcriptController.close();
    await _levelController.close();
    if (!_cutController.isClosed) await _cutController.close();
    if (result != null) return result;
    if (error != null) {
      throw VoiceException(
        'The recording could not be transcribed: $error',
        hint:
            'The voice model may be damaged. Try downloading it again in '
            'Settings, under Voice.',
      );
    }
    return TranscriptResult(text: text);
  }

  @override
  Future<void> cancel() async {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    _timer = null;
    await _stopRecorder();
    await _subscription?.cancel();
    _subscription = null;
    _all.clear();
    _segment.clear();
    _onDone();
    await _transcriptController.close();
    await _levelController.close();
    if (!_cutController.isClosed) await _cutController.close();
  }
}






