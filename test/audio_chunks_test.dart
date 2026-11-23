import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:verbal_outlet/voice/audio_chunks.dart';

void main() {
  test('an empty recording produces no WAV at all', () {
    expect(pcmToWav(Uint8List(0)), isEmpty);
  });

  test('a WAV header describes the PCM that follows it', () {
    final pcm = Uint8List.fromList(List<int>.generate(3200, (i) => i % 256));
    final wav = pcmToWav(pcm);

    expect(wav.length, 44 + pcm.length);

    final view = ByteData.sublistView(wav);
    String tag(int offset) =>
        String.fromCharCodes(wav.sublist(offset, offset + 4));

    expect(tag(0), 'RIFF');
    expect(tag(8), 'WAVE');
    expect(tag(12), 'fmt ');
    expect(tag(36), 'data');

    expect(view.getUint32(4, Endian.little), 36 + pcm.length);
    expect(view.getUint16(20, Endian.little), 1, reason: 'PCM');
    expect(view.getUint16(22, Endian.little), 1, reason: 'mono');
    expect(view.getUint32(24, Endian.little), captureSampleRate);
    expect(view.getUint32(28, Endian.little), pcmBytesPerSecond);
    expect(view.getUint16(34, Endian.little), 16, reason: 'bits per sample');
    expect(view.getUint32(40, Endian.little), pcm.length);
  });

  test('the PCM bytes are copied in unchanged after the header', () {
    final pcm = Uint8List.fromList([1, 2, 3, 4, 5, 6]);
    final wav = pcmToWav(pcm);
    expect(wav.sublist(44), pcm);
  });

  test('a byte length converts to the right duration', () {
    // One second of 16 kHz mono 16-bit audio.
    expect(pcmDuration(pcmBytesPerSecond), const Duration(seconds: 1));
    expect(pcmDuration(pcmBytesPerSecond ~/ 2), const Duration(milliseconds: 500));
    expect(pcmDuration(0), Duration.zero);
  });

  group('hearing whether anybody is talking', () {
    /// [milliseconds] of a steady tone at [amplitude] of full scale.
    Uint8List tone(double amplitude, {int milliseconds = 100}) {
      final samples = captureSampleRate * milliseconds ~/ 1000;
      final value = (amplitude * 32767).round();
      final out = Uint8List(samples * pcmBytesPerSample);
      final view = ByteData.sublistView(out);
      for (var i = 0; i < samples; i++) {
        // Alternating sign, so the average is zero but the level is not.
        view.setInt16(i * 2, i.isEven ? value : -value, Endian.little);
      }
      return out;
    }

    test('room tone is not speech, a normal voice is', () {
      expect(pcmHasSpeech(tone(0.002)), isFalse);
      expect(pcmHasSpeech(tone(0.05)), isTrue);
      expect(pcmHasSpeech(tone(0.3)), isTrue);
    });

    test('silence has no level at all', () {
      expect(pcmRms(Uint8List(pcmBytesPerSecond ~/ 10)), 0);
      expect(pcmHasSpeech(Uint8List(pcmBytesPerSecond ~/ 10)), isFalse);
      expect(pcmPeak(Uint8List(0)), 0);
    });

    test('one click barely moves the average, though the meter jumps', () {
      // A single loud sample in an otherwise silent tenth of a second.
      final pcm = Uint8List(pcmBytesPerSecond ~/ 10);
      ByteData.sublistView(pcm).setInt16(0, 32000, Endian.little);

      expect(pcmPeak(pcm), greaterThan(0.9), reason: 'the meter reacts at once');
      expect(
        pcmRms(pcm),
        lessThan(pcmPeak(pcm) / 20),
        reason: 'but a click is worth far less than speech to the chunker',
      );
    });

    test('a burst of clicks barely registers next to a voice', () {
      // A keyboard-ish rattle: a few short loud samples over half a second.
      final pcm = Uint8List(pcmBytesPerSecond ~/ 2);
      final view = ByteData.sublistView(pcm);
      for (var i = 0; i < 4; i++) {
        view.setInt16((i * 2000) * pcmBytesPerSample, 30000, Endian.little);
      }

      expect(
        pcmRms(pcm),
        lessThan(pcmRms(tone(0.05)) / 2),
        reason: 'speech is a sustained level, clicks are spikes',
      );
    });
  });

  group('showing a transcript that is still growing', () {
    test('a longer reading replaces the shorter one', () {
      expect(
        liveChunkText('I walked', 'I walked down to the river'),
        'I walked down to the river',
      );
    });

    test('a reading that drops a word keeps the longer one, so nothing blinks',
        () {
      expect(
        liveChunkText('I walked down to the river', 'I walked down to the'),
        'I walked down to the river',
      );
    });

    test('a real correction is taken', () {
      expect(liveChunkText('I walked to the river', 'I walk to the river'),
          'I walk to the river');
      expect(
        liveChunkText('I walked down to the river', 'I walked down to the river bank'),
        'I walked down to the river bank',
      );
    });

    test('nothing heard leaves what was there', () {
      expect(liveChunkText('I walked', ''), 'I walked');
      expect(liveChunkText('', 'I walked'), 'I walked');
      expect(liveChunkText('', ''), '');
    });
  });
}
