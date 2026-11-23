import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:verbal_outlet/voice/audio_chunks.dart';
import 'package:verbal_outlet/voice/live_session.dart';
import 'package:verbal_outlet/voice/voice_engine.dart';

/// A stretch of steady tone at [amplitude] of full scale.
///
/// Alternating sign keeps the average near zero while the level is real, the
/// same shape a voice has at this resolution.
Uint8List _tone(double amplitude, Duration duration) {
  final samples = captureSampleRate * duration.inMilliseconds ~/
      Duration.millisecondsPerSecond;
  final value = (amplitude * 32767).round();
  final out = Uint8List(samples * pcmBytesPerSample);
  final view = ByteData.sublistView(out);
  for (var i = 0; i < samples; i++) {
    view.setInt16(i * 2, i.isEven ? value : -value, Endian.little);
  }
  return out;
}

Uint8List _silence(Duration duration) =>
    Uint8List(pcmBytesPerSecond * duration.inMilliseconds ~/
        Duration.millisecondsPerSecond);

/// Feeds captured audio and records what the session asked to transcribe.
class _Harness {
  _Harness({this.answer}) {
    directory = Directory.systemTemp.createTempSync('vo-live-test');
    _controller = StreamController<Uint8List>();
    session = WhisperLiveSession(
      _controller.stream,
      _transcribe,
      () async => stopCalls++,
      () => done = true,
      tempDirectory: directory,
      // Driven by hand, so the test decides when a chunk is due. The intervals
      // are in audio time, so short clips are enough to reach them.
      ticking: false,
      pause: const Duration(milliseconds: 500),
      partial: const Duration(milliseconds: 300),
    );
    heard = session.transcripts.listen(seen.add);
    cutHeard = session.cuts.listen(cuts.add);
  }

  /// What each pass says, or null for Pass N.
  final Future<String> Function(int pass)? answer;

  late final Directory directory;
  late final StreamController<Uint8List> _controller;
  late final WhisperLiveSession session;
  late final StreamSubscription<String> heard;
  late final StreamSubscription<ChunkCut> cutHeard;

  final List<String> seen = [];
  final List<ChunkCut> cuts = [];
  final List<int> readSizes = [];
  int stopCalls = 0;
  bool done = false;

  /// What each pass said, in order. Defaults to "Pass N".
  Future<String> _transcribe(File file) async {
    readSizes.add(file.lengthSync());
    final pass = readSizes.length;
    final custom = answer;
    return custom == null ? 'Pass $pass' : custom(pass);
  }

  /// Audio delivered, then a check, then the pass allowed to finish.
  Future<void> feed(Uint8List pcm) async {
    _controller.add(pcm);
    await Future<void>.delayed(Duration.zero);
    session.considerFlush();
    await _settle();
  }

  /// Waits for any pass to finish and its stream event to be delivered.
  Future<void> _settle() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (session.isWorking && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> close() async {
    await heard.cancel();
    await cutHeard.cancel();
    if (!_controller.isClosed) await _controller.close();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}

void main() {
  test('a pause after speech closes the sentence and keeps its words', () async {
    final h = _Harness(answer: (_) async => 'I walked to the river.');
    addTearDown(h.close);

    await h.feed(_tone(0.1, const Duration(milliseconds: 600)));
    expect(h.session.settled, '', reason: 'not a pause yet, so not settled');
    expect(h.session.text, 'I walked to the river.', reason: 'but it is shown');

    await h.feed(_silence(const Duration(milliseconds: 600)));

    expect(h.session.settled, 'I walked to the river.', reason: 'committed');
    expect(h.session.text, 'I walked to the river.');
  });

  test('room tone on its own is never sent to Whisper', () async {
    final h = _Harness();
    addTearDown(h.close);

    await h.feed(_silence(const Duration(seconds: 2)));
    await h.feed(_tone(0.001, const Duration(seconds: 1)));

    expect(h.readSizes, isEmpty, reason: 'nothing worth reading');
    expect(h.seen, isEmpty);
  });

  test('a pause with nothing said since the last pass does nothing', () async {
    final h = _Harness();
    addTearDown(h.close);

    await h.feed(_tone(0.1, const Duration(milliseconds: 600)));
    expect(h.readSizes, hasLength(1));

    // Only a little quiet, not enough to be a pause, and no new speech.
    await h.feed(_silence(const Duration(milliseconds: 200)));
    expect(h.readSizes, hasLength(1), reason: 'no new pass');
  });

  test('the transcript only ever grows while somebody is speaking', () async {
    // The later passes hear the same words, then one word fewer, which is
    // exactly what real Whisper does at the tail of a chunk.
    final h = _Harness(
      answer: (pass) async => switch (pass) {
        1 => 'I walked to the',
        2 => 'I walked to the river',
        3 => 'I walked to the',
        _ => 'I walked to the river bank',
      },
    );
    addTearDown(h.close);

    await h.feed(_tone(0.1, const Duration(milliseconds: 400)));
    expect(h.session.text, 'I walked to the');

    await h.feed(_tone(0.1, const Duration(milliseconds: 400)));
    expect(h.session.text, 'I walked to the river');

    await h.feed(_tone(0.1, const Duration(milliseconds: 400)));
    expect(
      h.session.text,
      'I walked to the river',
      reason: 'the dropped reading did not remove the word',
    );

    await h.feed(_tone(0.1, const Duration(milliseconds: 400)));
    expect(h.session.text, 'I walked to the river bank');
  });

  test('a second sentence is added to the first, not swapped for it', () async {
    // Pass one is the partial while speaking, pass two the pause that commits
    // it, and only then does the next sentence arrive.
    final h = _Harness(
      answer: (pass) async => pass <= 2 ? 'First sentence.' : 'Second one.',
    );
    addTearDown(h.close);

    await h.feed(_tone(0.1, const Duration(milliseconds: 400)));
    await h.feed(_silence(const Duration(milliseconds: 600)));
    expect(h.session.settled, 'First sentence.');

    await h.feed(_tone(0.1, const Duration(milliseconds: 400)));

    expect(h.session.text, 'First sentence. Second one.');
  });

  test('a pause reports where it cut, with the length in force', () async {
    // A cut is a join, so it needs a sentence behind it: the first commit has
    // nothing to join to, the second does.
    final h = _Harness(
      answer: (pass) async => pass <= 2 ? 'I wanted to ask you about' : 'the job',
    );
    addTearDown(h.close);

    await h.feed(_tone(0.1, const Duration(milliseconds: 600)));
    await h.feed(_silence(const Duration(milliseconds: 600)));
    expect(h.cuts, isEmpty, reason: 'nothing before it to join to');

    await h.feed(_tone(0.1, const Duration(milliseconds: 400)));
    await h.feed(_silence(const Duration(milliseconds: 600)));

    expect(h.cuts, hasLength(1));
    expect(h.cuts.single.pause, const Duration(milliseconds: 500));
    expect(h.cuts.single.before, 'I wanted to ask you about');
    expect(h.cuts.single.after, 'the job');
  });

  test('the cut keeps only the tail of what came before it', () async {
    // A long first sentence (two passes: partial, then the pause that commits
    // it), then a short second one, so the before side has to be capped.
    final long = List.filled(40, 'word').join(' ');
    final h = _Harness(
      answer: (pass) async => pass <= 2 ? long : 'Second one.',
    );
    addTearDown(h.close);

    await h.feed(_tone(0.1, const Duration(milliseconds: 400)));
    await h.feed(_silence(const Duration(milliseconds: 600)));
    await h.feed(_tone(0.1, const Duration(milliseconds: 400)));
    await h.feed(_silence(const Duration(milliseconds: 600)));

    expect(h.cuts, hasLength(1), reason: 'only the second sentence cut');
    expect(h.cuts.single.before.length, lessThanOrEqualTo(80));
    expect(h.cuts.single.before, endsWith('word'));
    expect(h.cuts.single.after, 'Second one.');
  });

  test('a partial pass is not a cut', () async {
    final h = _Harness(answer: (_) async => 'Still talking');
    addTearDown(h.close);

    await h.feed(_tone(0.1, const Duration(milliseconds: 400)));

    expect(h.cuts, isEmpty, reason: 'the sentence has not ended');
  });

  test('finishing stops the recorder and reads the whole thing once more', () async {
    final h = _Harness(answer: (pass) async => pass == 1 ? 'Hm.' : 'The whole lot.');
    addTearDown(h.close);

    await h.feed(_tone(0.1, const Duration(milliseconds: 400)));
    await h.feed(_tone(0.1, const Duration(milliseconds: 400)));

    final result = await h.session.finish();

    expect(result.text, 'The whole lot.');
    expect(h.stopCalls, 1, reason: 'the microphone is released');
    expect(h.done, isTrue);
    expect(result.duration, greaterThan(Duration.zero));
  });

  test('a failed final pass still reports what was already heard', () async {
    var passes = 0;
    final h = _Harness(
      answer: (pass) async {
        passes++;
        if (passes == 1) return 'I said something.';
        throw const FileSystemException('disk');
      },
    );
    addTearDown(h.close);

    await h.feed(_tone(0.1, const Duration(seconds: 1)));

    await expectLater(h.session.finish(), throwsA(isA<VoiceException>()));
    expect(h.session.text, contains('I said something'));
    expect(h.done, isTrue, reason: 'the microphone flag was released');
  });

  test('cancelling throws the recording away', () async {
    final h = _Harness();
    addTearDown(h.close);

    await h.feed(_tone(0.1, const Duration(milliseconds: 600)));
    await h.session.cancel();

    expect(h.stopCalls, 1);
    expect(h.done, isTrue);
    // A later check does no work, because the session is finished.
    final before = h.readSizes.length;
    await h.feed(_tone(0.1, const Duration(milliseconds: 600)));
    expect(h.readSizes, hasLength(before));
  });
}


