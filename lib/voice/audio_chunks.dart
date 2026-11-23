/// Turning a stream of raw PCM into the WAV files Whisper expects.
///
/// The live-capture path records raw 16-bit mono PCM at 16 kHz — exactly what
/// whisper.cpp wants — but Whisper reads *files*, not streams. So every few
/// seconds the PCM collected so far is wrapped in a WAV header and handed over
/// as a finished clip. These helpers are pure functions of bytes, which keeps
/// them easy to test without a microphone.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Bytes per PCM sample. 16-bit mono is the only format the app records.
const int pcmBytesPerSample = 2;

/// Samples per second for capture. Whisper's native rate, so no resampling.
const int captureSampleRate = 16000;

/// How many bytes one second of captured audio occupies.
const int pcmBytesPerSecond = captureSampleRate * pcmBytesPerSample;

/// Wraps [pcm] in a 44-byte canonical WAV header.
///
/// The input is little-endian signed 16-bit mono, which is what both `record`
/// and whisper.cpp use. Returns an empty list for empty input, since a header
/// with no samples is not a valid clip to transcribe.
Uint8List pcmToWav(Uint8List pcm) {
  if (pcm.isEmpty) return Uint8List(0);

  final byteRate = captureSampleRate * pcmBytesPerSample;
  final header = ByteData(44)
    ..setUint32(0, 0x46464952, Endian.little) // "RIFF"
    ..setUint32(4, 36 + pcm.length, Endian.little) // file size - 8
    ..setUint32(8, 0x45564157, Endian.little) // "WAVE"
    ..setUint32(12, 0x20746D66, Endian.little) // "fmt "
    ..setUint32(16, 16, Endian.little) // PCM chunk size
    ..setUint16(20, 1, Endian.little) // PCM format
    ..setUint16(22, 1, Endian.little) // mono
    ..setUint32(24, captureSampleRate, Endian.little)
    ..setUint32(28, byteRate, Endian.little)
    ..setUint16(32, pcmBytesPerSample, Endian.little) // block align
    ..setUint16(34, 16, Endian.little) // bits per sample
    ..setUint32(36, 0x61746164, Endian.little) // "data"
    ..setUint32(40, pcm.length, Endian.little);

  final out = Uint8List(44 + pcm.length);
  out.setRange(0, 44, header.buffer.asUint8List());
  out.setRange(44, out.length, pcm);
  return out;
}

/// A duration in samples, for talking about how much audio has been captured.
Duration pcmDuration(int byteLength) => Duration(
  milliseconds: (byteLength / pcmBytesPerSample / captureSampleRate * 1000)
      .round(),
);

/// The loudest sample in [pcm], as a fraction of full scale (0–1).
///
/// Used for the level meter, which should read a voice immediately rather than
/// averaging it away.
double pcmPeak(Uint8List pcm) {
  if (pcm.length < pcmBytesPerSample) return 0;
  final view = ByteData.sublistView(pcm);
  var peak = 0;
  for (var i = 0; i + 1 < pcm.length; i += pcmBytesPerSample) {
    final sample = view.getInt16(i, Endian.little).abs();
    if (sample > peak) peak = sample;
  }
  return (peak / 32768).clamp(0.0, 1.0);
}

/// The root-mean-square level of [pcm], as a fraction of full scale (0–1).
///
/// RMS is the right measure for "is somebody talking": a click can make a peak
/// reading look loud, but a single sample barely moves an average over a
/// hundred milliseconds of audio.
double pcmRms(Uint8List pcm) {
  final samples = pcm.length ~/ pcmBytesPerSample;
  if (samples == 0) return 0;
  final view = ByteData.sublistView(pcm);
  var sum = 0.0;
  for (var i = 0; i < samples; i++) {
    final sample = view.getInt16(i * pcmBytesPerSample, Endian.little) / 32768;
    sum += sample * sample;
  }
  final value = math.sqrt(sum / samples);
  return value.clamp(0.0, 1.0).toDouble();
}

/// Below this RMS, a stretch of audio is treated as room tone rather than
/// speech.
///
/// Deliberately low. The cost of setting it too high is cutting somebody off
/// mid-sentence, which is far worse than the cost of setting it too low
/// (occasionally transcribing a quiet room). Quiet speech into a laptop
/// microphone sits around 0.03–0.08; a fan or a distant road sits under 0.01.
const double speechRmsThreshold = 0.012;

/// Whether [pcm] contains anything worth sending to Whisper.
///
/// This is what makes live capture feel responsive: a pause can end a chunk
/// immediately instead of waiting out a fixed interval, and stretches below the
/// threshold are skipped instead of being transcribed and thrown away.
///
/// It is a cheap gate, not a classifier. A knock or a keyboard tap can clear the
/// threshold and start a pass, and Whisper's own silence handling then returns
/// nothing — a little wasted work, never a wrong word. Erring low is deliberate:
/// the failure that actually hurts is cutting somebody off.
bool pcmHasSpeech(Uint8List pcm, {double threshold = speechRmsThreshold}) =>
    pcmRms(pcm) >= threshold;

/// The text to show for a chunk that is still being recognised.
///
/// Whisper re-reads the whole chunk on every pass, so [next] is normally the
/// better answer. The exception is that a later pass sometimes hears one word
/// fewer than the one before. Displaying that would make the last word blink
/// out and reappear, so when [next] merely agrees with the start of [previous]
/// and then stops short, the longer [previous] is kept. Words only ever get
/// added while someone is still speaking.
String liveChunkText(String previous, String next) {
  final p = previous.trim();
  final n = next.trim();
  if (n.isEmpty) return p;
  if (p.isEmpty) return n;

  final previousWords = p.split(_whitespace);
  final nextWords = n.split(_whitespace);
  if (nextWords.length < previousWords.length) {
    var shared = 0;
    while (shared < nextWords.length &&
        previousWords[shared] == nextWords[shared]) {
      shared++;
    }
    if (shared == nextWords.length) return p;
  }
  return n;
}

final RegExp _whitespace = RegExp(r'\s+');
