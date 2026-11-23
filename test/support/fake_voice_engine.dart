/// A voice engine that never touches a microphone.
///
/// The add-thought sheet talks only to [VoiceEngine], so a test can drive the
/// whole flow - record, transcribe, review, send - with any transcript it
/// likes, instantly, and without a Whisper model on disk.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:verbal_outlet/voice/voice_engine.dart';

class FakeVoiceEngine implements VoiceEngine {
  FakeVoiceEngine({
    this.transcript = 'A spoken thought',
    this.ready = true,
    this.levelValues = const [0.2, 0.6, 0.9],
    this.liveChunks = const [],
    this.liveSettled = 0,
    this.liveCuts = const [],
  });

  /// What [stopAndTranscribe] will answer, and the final live transcript.
  String transcript;

  /// What [isReady] answers.
  bool ready;

  /// Values the level stream emits while recording.
  final List<double> levelValues;

  /// Transcripts a live session emits, one per simulated chunk. Empty means
  /// the session reports nothing until it finishes.
  final List<String> liveChunks;

  /// How many of [liveChunks] a pause has already settled, so the sheet shows a
  /// committed part and a sentence still being spoken, as a real session does.
  final int liveSettled;

  /// Cuts the session reports as a pause closes a sentence, for testing the
  /// pause tuning. Empty means the session does not report cuts at all.
  final List<ChunkCut> liveCuts;

  /// Thrown by [start] or [startLive] when set, to stand in for missing
  /// permission.
  VoiceException? startError;

  bool recording = false;
  bool cancelled = false;
  int started = 0;
  int stopped = 0;
  int liveStarted = 0;
  FakeLiveSession? live;

  @override
  Future<bool> isReady() async => ready;

  @override
  Future<void> start() async {
    if (startError != null) throw startError!;
    started++;
    recording = true;
    cancelled = false;
  }

  @override
  Future<TranscriptResult> stopAndTranscribe() async {
    stopped++;
    recording = false;
    return TranscriptResult(text: transcript);
  }

  /// How long a silence the sheet asked for when starting, so a test can check
  /// the setting is honoured.
  Duration? requestedPause;

  @override
  Future<LiveVoiceSession> startLive({Duration? pauseAfterSpeech}) async {
    if (startError != null) throw startError!;
    liveStarted++;
    requestedPause = pauseAfterSpeech;
    recording = true;
    final session = FakeLiveSession(
      chunks: liveChunks,
      settledChunks: liveSettled,
      finalText: transcript,
      levelValues: levelValues,
      plannedCuts: liveCuts,      onFinish: () => recording = false,
      onCancel: () {
        recording = false;
        cancelled = true;
      },
    );
    live = session;
    return session;
  }

  @override
  Future<void> cancel() async {
    recording = false;
    cancelled = true;
    await live?.cancel();
  }

  @override
  Stream<double> get levels => Stream.fromIterable(levelValues);

  @override
  Future<void> dispose() async {}
}

/// A live session that emits prepared chunks as soon as it is listened to.
class FakeLiveSession implements LiveVoiceSession {
  FakeLiveSession({
    required this.chunks,
    this.settledChunks = 0,
    required this.finalText,
    required this.levelValues,
    this.plannedCuts = const [],
    required this.onFinish,
    required this.onCancel,
  });

  final List<String> chunks;

  /// The first this-many chunks are treated as settled by a pause.
  final int settledChunks;

  /// Cuts reported as soon as the session is listened to.
  final List<ChunkCut> plannedCuts;

  final String finalText;
  final List<double> levelValues;
  final VoidCallback onFinish;
  final VoidCallback onCancel;

  final _transcripts = StreamController<String>.broadcast();
  final _levels = StreamController<double>.broadcast();

  String _text = '';
  String _settled = '';
  bool _finished = false;
  bool _started = false;

  @override
  Stream<String> get transcripts {
    if (!_started) {
      _started = true;
      // Deliver after the caller has subscribed, like a real capture would.
      scheduleMicrotask(() {
        for (var i = 0; i < chunks.length; i++) {
          final chunk = chunks[i];
          _text = chunk;
          if (i < settledChunks) _settled = chunk;
          _transcripts.add(chunk);
        }
      });
    }
    return _transcripts.stream;
  }

  @override
  String get text => _text;

  /// Whatever a simulated pause has closed.
  @override
  String get settled => _settled;

  @override
  Stream<double> get levels {
    scheduleMicrotask(() {
      for (final value in levelValues) {
        _levels.add(value);
      }
    });
    return _levels.stream;
  }

  /// Cuts the sheet can listen to, so a test can check pause tuning.
  @override
  Stream<ChunkCut>? get cuts {
    if (plannedCuts.isEmpty) return null;
    if (!_cutsStarted) {
      _cutsStarted = true;
      scheduleMicrotask(() {
        for (final cut in plannedCuts) {
          if (!_cuts.isClosed) _cuts.add(cut);
        }
      });
    }
    return _cuts.stream;
  }

  final _cuts = StreamController<ChunkCut>.broadcast();
  bool _cutsStarted = false;

  @override
  Future<TranscriptResult> finish() async {
    if (_finished) return TranscriptResult(text: _text);
    _finished = true;
    onFinish();
    if (finalText.isNotEmpty) _text = finalText;
    await _transcripts.close();
    await _levels.close();
    if (!_cuts.isClosed) await _cuts.close();
    return TranscriptResult(text: _text);
  }

  @override
  Future<void> cancel() async {
    if (_finished) return;
    _finished = true;
    onCancel();
    await _transcripts.close();
    await _levels.close();
    if (!_cuts.isClosed) await _cuts.close();
  }
}



