import 'package:flutter_test/flutter_test.dart';
import 'package:verbal_outlet/voice/pause_trace.dart';
import 'package:verbal_outlet/voice/voice_settings.dart';

PauseBoundary _cut(String before, String after, [int ms = 700]) =>
    PauseBoundary(
      pause: Duration(milliseconds: ms),
      before: before,
      after: after,
    );

/// A trace with [count] boundaries already seen, and some evidence.
PauseTrace _trace({
  int boundaries = 12,
  List<PauseEvidence> evidence = const [],
  Duration? suggested,
  bool dismissed = false,
}) => PauseTrace(
  boundaries: boundaries,
  evidence: evidence,
  suggested: suggested,
  dismissed: dismissed,
);

PauseEvidence _evidence(int ms) => PauseEvidence(
  pause: Duration(milliseconds: ms),
  before: 'I wanted to ask you about',
  after: 'the job, and whether it is worth it.',
);

void main() {
  group('noteBoundary', () {
    test('always counts the boundary', () {
      final trace = PauseTrace();
      final next = noteBoundary(trace, _cut('We went out.', 'It was good.'));
      expect(next.boundaries, 1);
    });

    test('does not keep a join after a full stop', () {
      final next = noteBoundary(PauseTrace(), _cut('We went out.', 'It was fine.'));
      expect(next.evidence, isEmpty);
    });

    test('does not keep a join before a capitalised word', () {
      final next = noteBoundary(PauseTrace(), _cut('We went out for', 'Dinner.'));
      expect(next.evidence, isEmpty);
    });

    test('keeps a join that looks cut mid-sentence', () {
      final next = noteBoundary(
        PauseTrace(),
        _cut('I wanted to ask you about', 'the job and whether', 900),
      );
      expect(next.evidence, hasLength(1));
      expect(next.evidence.single.pause, const Duration(milliseconds: 900));
      expect(next.evidence.single.after, 'the job and whether');
    });

    test('never keeps more than the cap', () {
      var trace = PauseTrace();
      for (var i = 0; i < 10; i++) {
        trace = noteBoundary(trace, _cut('and then I said', 'something quiet'));
      }
      expect(trace.evidence, hasLength(PauseTrace.maxEvidence));
      expect(trace.boundaries, 10);
    });

    test('ignores an empty side', () {
      final next = noteBoundary(PauseTrace(), _cut('', 'the job'));
      expect(next.evidence, isEmpty);
      expect(next.boundaries, 1);
    });
  });

  group('suggestPause', () {
    test('says nothing before there is enough evidence', () {
      final trace = _trace(boundaries: 4, evidence: [_evidence(900)]);
      expect(suggestPause(trace, brokenJoins: 3), isNull);
    });

    test('needs at least two confirmed broken joins', () {
      final trace = _trace(evidence: [_evidence(900), _evidence(800)]);
      expect(suggestPause(trace, brokenJoins: 1), isNull);
      expect(suggestPause(trace, brokenJoins: 2), const Duration(milliseconds: 1150));
    });

    test('takes the longest cut and adds headroom', () {
      final trace = _trace(
        evidence: [_evidence(900), _evidence(1200), _evidence(700)],
      );
      // 1200 + 250 = 1450, already a multiple of 50.
      expect(
        suggestPause(trace, brokenJoins: 2),
        const Duration(milliseconds: 1450),
      );
    });

    test('rounds to a friendly step', () {
      final trace = _trace(evidence: [_evidence(910), _evidence(880)]);
      // 910 + 250 = 1160 -> 1150.
      expect(
        suggestPause(trace, brokenJoins: 2),
        const Duration(milliseconds: 1150),
      );
    });

    test('stays inside the slider range', () {
      final trace = _trace(evidence: [_evidence(5000), _evidence(3000)]);
      expect(
        suggestPause(trace, brokenJoins: 2),
        VoiceSettings.maxPauseAfterSpeech,
      );
    });

    test('does not bother suggesting the default', () {
      final trace = _trace(evidence: [_evidence(450), _evidence(400)]);
      // 450 + 250 = 700, exactly the default.
      expect(suggestPause(trace, brokenJoins: 2), isNull);
    });
  });

  group('PauseTrace', () {
    test('survives a round trip through JSON', () {
      final trace = PauseTrace(
        boundaries: 20,
        evidence: [_evidence(900)],
        suggested: const Duration(milliseconds: 1150),
      );
      final restored = PauseTrace.fromJson(trace.toJson());
      expect(restored.boundaries, 20);
      expect(restored.evidence, hasLength(1));
      expect(restored.evidence.single.before, 'I wanted to ask you about');
      expect(restored.suggested, const Duration(milliseconds: 1150));
    });

    test('a corrupt blob becomes an empty trace', () {
      expect(PauseTrace.fromJson({'n': 'lots'}).boundaries, 0);
      expect(PauseTrace.fromJson([]).evidence, isEmpty);
      expect(PauseTrace.fromJson(null).boundaries, 0);
    });

    test('a suggested outside the range is clamped on load', () {
      final restored = PauseTrace.fromJson({'s': 90000});
      expect(restored.suggested, VoiceSettings.maxPauseAfterSpeech);
    });

    test('dismissing hides the suggestion', () {
      final trace = _trace(suggested: const Duration(milliseconds: 900));
      expect(trace.showsSuggestion, isTrue);
      expect(trace.copyWith(dismissed: true).showsSuggestion, isFalse);
    });

    test('clearSuggestion drops it', () {
      final trace = _trace(suggested: const Duration(milliseconds: 900));
      expect(trace.copyWith(clearSuggestion: true).suggested, isNull);
    });
  });

  group('clampPause', () {
    test('keeps a value inside the range', () {
      expect(
        clampPause(const Duration(milliseconds: 900)),
        const Duration(milliseconds: 900),
      );
    });

    test('lifts the floor and drops the ceiling', () {
      expect(
        clampPause(const Duration(milliseconds: 10)),
        VoiceSettings.minPauseAfterSpeech,
      );
      expect(
        clampPause(const Duration(minutes: 5)),
        VoiceSettings.maxPauseAfterSpeech,
      );
    });
  });
}
