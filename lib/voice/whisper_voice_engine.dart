/// The real recogniser: microphone to text, on this machine.
///
/// Two packages do the work. `record` captures the microphone into a 16 kHz
/// mono WAV file, which is exactly what whisper.cpp wants; `whisper_ggml_plus`
/// runs a local Whisper model over that file through FFI.
///
/// A note on why this is a download rather than bundled: Whisper's smallest
/// usable model is tens of megabytes, and the bigger ones are hundreds. Shipping
/// one inside the installer would bloat a diary app for people who never speak
/// into it, so the model is fetched once, from the app, and then works offline.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:whisper_ggml_plus/whisper_ggml_plus.dart';

import 'audio_chunks.dart';
import 'live_session.dart';
import 'voice_engine.dart';

/// The model the app suggests.
///
/// `base.en` is the smallest English model that is comfortable for everyday
/// speech on a laptop CPU. `tiny.en` is quicker but makes enough mistakes to be
/// annoying in a diary; `small.en` is noticeably better but several times slower
/// without a GPU. The settings screen offers all three.
const WhisperModel defaultVoiceModel = WhisperModel.baseEn;

/// A recogniser that is not ready yet: the model has to be downloaded.
class MissingVoiceModel implements Exception {
  const MissingVoiceModel(this.model);

  final WhisperModel model;

  @override
  String toString() => 'The ${model.modelName} voice model is not downloaded.';
}

/// Records the microphone and transcribes it with a local Whisper model.
class WhisperVoiceEngine implements VoiceEngine {
  WhisperVoiceEngine({
    AudioRecorder? recorder,
    WhisperController? controller,
    this.model = defaultVoiceModel,
    String? language,
  }) : _recorder = recorder ?? AudioRecorder(),
       _controller = controller ?? WhisperController(),
       _language =
           language ?? (Platform.localeName.split(RegExp('[-_]')).first);

  final AudioRecorder _recorder;
  final WhisperController _controller;

  /// Which Whisper model to run. Chosen in settings.
  final WhisperModel model;

  /// The language to expect. Kept to the device's language so an entry is not
  /// silently translated into English.
  final String _language;

  String? _path;
  DateTime? _startedAt;

  /// True while a [LiveVoiceSession] owns the microphone, so [start] does not
  /// try to open a second recording on top of it.
  bool _live = false;

  @override
  Stream<double> get levels {
    // The plugin reports negative dBFS. Mapping about -50 dB..0 dB onto 0..1
    // gives a meter that moves for quiet speech without pegging on a hum.
    return _recorder.onAmplitudeChanged(const Duration(milliseconds: 90)).map((
      amplitude,
    ) {
      final db = amplitude.current;
      if (db.isNaN || db.isInfinite) return 0.0;
      return ((db + 50) / 50).clamp(0.0, 1.0);
    });
  }

  /// Whether the model file is already on disk.
  ///
  /// Checked directly rather than through the controller, because asking the
  /// controller would create its directory as a side effect during a plain
  /// "is it ready?" question.
  @override
  Future<bool> isReady() async {
    final path = await _controller.getPath(model);
    return File(path).exists();
  }

  /// The path the model will be stored at, for the settings screen to show.
  Future<String> modelPath() => _controller.getPath(model);

  /// Downloads the model, reporting 0–1 progress as bytes arrive.
  ///
  /// The plugin's own downloader buffers the whole file in memory and reports
  /// nothing, which is a poor fit for a 150 MB download over a slow line. This
  /// streams to a temporary file instead, so progress is real and a cancelled
  /// download does not leave a corrupt model behind.
  Stream<double> downloadModel({WhisperModel? which}) async* {
    final target = which ?? model;
    final destination = await _controller.getPath(target);
    if (await File(destination).exists()) {
      yield 1.0;
      return;
    }

    final directory = Directory(p.dirname(destination));
    await directory.create(recursive: true);
    final partial = File('$destination.part');

    final client = HttpClient();
    try {
      final request = await client.getUrl(target.modelUri);
      final response = await request.close();
      if (response.statusCode != 200) {
        throw VoiceException(
          'The voice model could not be downloaded.',
          hint:
              'The server answered HTTP ${response.statusCode}. Check the '
              'connection and try again.',
        );
      }

      final total = response.contentLength;
      var received = 0;
      final sink = partial.openWrite();
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) yield (received / total).clamp(0.0, 1.0);
        }
      } finally {
        await sink.close();
      }

      // Only rename once the whole file is written, so a half-download is never
      // mistaken for a usable model.
      await partial.rename(destination);
      yield 1.0;
    } on VoiceException {
      rethrow;
    } catch (error) {
      await partial.delete().catchError((_) => partial);
      throw VoiceException(
        'The voice model could not be downloaded: $error',
        hint: 'Check the connection, then try again.',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Deletes the downloaded model, e.g. when switching to a bigger one.
  Future<void> deleteModel({WhisperModel? which}) async {
    final file = File(await _controller.getPath(which ?? model));
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> start() async {
    if (await _recorder.isRecording()) await _recorder.cancel();

    final allowed = await _recorder.hasPermission();
    if (!allowed) {
      throw const VoiceException(
        'The microphone is not available.',
        hint:
            'Allow microphone access for Verbal Outlet in your system '
            'settings, then try again.',
      );
    }

    final directory = await getTemporaryDirectory();
    final path = p.join(
      directory.path,
      'entry-${DateTime.now().millisecondsSinceEpoch}.wav',
    );

    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          // Whisper expects 16 kHz mono, and recording at that rate avoids a
          // resample step that would only lose quality.
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
    } catch (error) {
      throw VoiceException(
        'The microphone could not be started: $error',
        hint: 'Check that no other app is using it, then try again.',
      );
    }

    _path = path;
    _startedAt = DateTime.now();
  }

  @override
  Future<TranscriptResult> stopAndTranscribe() async {
    final path = _path;
    final startedAt = _startedAt;
    if (path == null) {
      throw const VoiceException('There was nothing to transcribe.');
    }

    String? stopped;
    try {
      stopped = await _recorder.stop();
    } catch (error) {
      throw VoiceException('The recording could not be finished: $error');
    }
    _path = null;
    _startedAt = null;

    final file = File(stopped ?? path);
    if (!await file.exists() || await file.length() < 2000) {
      await file.delete().catchError((_) => file);
      throw const VoiceException(
        'That recording was too short to hear anything.',
        hint: 'Hold the microphone button while you speak, then release.',
      );
    }

    if (!await isReady()) {
      await file.delete().catchError((_) => file);
      throw const VoiceException(
        'The voice model is not downloaded yet.',
        hint: 'Open Settings, then Voice, and download a model.',
      );
    }

    final duration = startedAt == null
        ? Duration.zero
        : DateTime.now().difference(startedAt);
    final watch = Stopwatch()..start();
    try {
      final text = await _transcribeWav(file);
      watch.stop();

      if (text.isEmpty) {
        throw const VoiceException(
          'Nothing was recognised in that recording.',
          hint: 'Try again somewhere quieter, a little closer to the mic.',
        );
      }
      return TranscriptResult(
        text: text,
        duration: duration,
        elapsed: watch.elapsed,
      );
    } on VoiceException {
      rethrow;
    } finally {
      // The audio has served its purpose; keeping voice recordings around is a
      // privacy cost with no benefit once the words are extracted.
      await file.delete().catchError((_) => file);
    }
  }

  /// Transcribes one WAV file, translating failures into [VoiceException].
  ///
  /// Shared by the one-shot and live paths so both report problems the same
  /// way, and so a damaged model gives the same advice whichever route hit it.
  Future<String> _transcribeWav(File file) async {
    if (!await isReady()) {
      throw const VoiceException(
        'The voice model is not downloaded yet.',
        hint: 'Open Settings, then Voice, and download a model.',
      );
    }

    try {
      final result = await _controller.transcribe(
        model: model,
        audioPath: file.path,
        lang: _language,
        // Segments are not shown anywhere, and skipping them is a little
        // faster.
        withTimestamps: false,
        // The whole clip is spoken word; trimming silence on the edges only
        // helps and never cuts speech.
        vadMode: WhisperVadMode.auto,
      );
      return result?.transcription.text.trim() ?? '';
    } on VoiceException {
      rethrow;
    } catch (error) {
      throw VoiceException(
        'The recording could not be transcribed: $error',
        hint:
            'The voice model may be damaged. Try downloading it again in '
            'Settings, under Voice.',
      );
    }
  }

  /// Starts a capture that keeps listening and reports words as they land.
  ///
  /// Captures raw 16-bit mono PCM at 16 kHz and re-transcribes the current\r?\n  /// sentence as it is spoken. Whisper cannot stream, so this is the closest\r?\n  /// honest approximation: the transcript appears as a sentence ends, entirely\r?\n  /// on this machine. See [WhisperLiveSession] for when a chunk is cut.
  @override
  Future<LiveVoiceSession> startLive({Duration? pauseAfterSpeech}) async {
    if (_live) {
      throw const VoiceException('A recording is already running.');
    }
    if (await _recorder.isRecording()) await _recorder.cancel();

    final allowed = await _recorder.hasPermission();
    if (!allowed) {
      throw const VoiceException(
        'The microphone is not available.',
        hint:
            'Allow microphone access for Verbal Outlet in your system '
            'settings, then try again.',
      );
    }
    if (!await isReady()) {
      throw const VoiceException(
        'The voice model is not downloaded yet.',
        hint: 'Open Settings, then Voice, and download a model.',
      );
    }

    Stream<Uint8List> stream;
    try {
      stream = await _recorder.startStream(
        const RecordConfig(
          // Raw samples rather than a file: the bytes are wrapped into short
          // WAV clips by the session, which Whisper can read.
          encoder: AudioEncoder.pcm16bits,
          sampleRate: captureSampleRate,
          numChannels: 1,
        ),
      );
    } catch (error) {
      throw VoiceException(
        'The microphone could not be started: $error',
        hint: 'Check that no other app is using it, then try again.',
      );
    }

    _live = true;
    final session = WhisperLiveSession(
      stream,
      _transcribeWav,
      // The recorder, not the Dart stream, owns the microphone: stopping it is
      // what actually releases the device.
      () async {
        try {
          await _recorder.stop();
        } catch (error) {
          debugPrint('Stopping the live recorder failed: $error');
        }
      },
      () => _live = false,
      pause: pauseAfterSpeech,
    );
    return session;
  }

  @override
  Future<void> cancel() async {
    final path = _path;
    _path = null;
    _startedAt = null;
    try {
      if (await _recorder.isRecording()) await _recorder.cancel();
    } catch (error) {
      // Nothing to recover: the recording is being thrown away anyway.
      debugPrint('Could not cancel the recording: $error');
    }
    if (path != null) {
      final file = File(path);
      await file.delete().catchError((_) => file);
    }
  }

  @override
  Future<void> dispose() async {
    await cancel();
    await _recorder.dispose();
  }
}




