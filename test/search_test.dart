import 'package:flutter_test/flutter_test.dart';
import 'package:verbal_outlet/models/day_note.dart';
import 'package:verbal_outlet/search/note_search.dart';
import 'package:verbal_outlet/search/search_text.dart';

/// The snippet texts the engine is expected to understand.
const _snippets = [
  'Pretty tired today but I got through the list.',
  'Walked the long route along the river instead of the main road.',
  'Need to sort out the trip. Maybe leave Friday evening instead.',
  'Booked the flights and paid the deposit for the flat.',
  'I was absolutely knackered after work, could barely keep my eyes open.',
  'Spent the evening reading a novel on the sofa with a cup of tea.',
  'Caught up with Sam for a drink and we talked about the new job.',
  'Took the camera out on the hike, the weather was grey but dry.',
];

NoteStoreFixture _noteWith(List<String> lines) {
  final day = DateTime(2025, 3, 14);
  return NoteStoreFixture(
    DayNote(
      day: day,
      sections: [
        for (var i = 0; i < lines.length; i++)
          NoteSection(
            id: 's$i',
            createdAt: day.add(Duration(hours: 8 + i)),
            text: lines[i],
          ),
      ],
    ),
  );
}

/// Small holder so the tests read as "a note, and what it found".
class NoteStoreFixture {
  NoteStoreFixture(this.note);
  final DayNote note;
}

String _topMatch(NoteSearchResult result) =>
    result.hits.isEmpty ? '' : result.hits.first.section.text;

void main() {
  const searcher = LexicalSearcher();

  group('stemming', () {
    test('inflections collapse to the same root', () {
      expect(stem('walked'), stem('walking'));
      expect(stem('walks'), stem('walk'));
      expect(stem('booking'), stem('book'));
      expect(stem('tired'), stem('tiring'));
    });

    test('numbers and short words are left alone', () {
      expect(stem('2024'), '2024');
      expect(stem('to'), 'to');
    });
  });

  group('edit distance', () {
    test('finds a one-letter typo', () {
      expect(editDistance('exhausted', 'exausted'), 1);
    });

    test('gives up beyond the limit', () {
      expect(editDistance('cat', 'elephant', limit: 2), greaterThan(2));
    });
  });

  group('word forms', () {
    test('finds a different inflection of the query word', () {
      final result = searcher.search(_noteWith(_snippets).note, 'walk');
      expect(result.isNotEmpty, isTrue);
      expect(_topMatch(result), contains('Walked'));
    });

    test('finds a noun from its verb form', () {
      final result = searcher.search(_noteWith(_snippets).note, 'book');
      expect(_topMatch(result), contains('Booked'));
    });
  });

  group('concepts', () {
    test('tired finds knackered, with an explanation', () {
      final result = searcher.search(_noteWith(_snippets).note, 'tired');
      final hits = result.hits.map((h) => h.section.text).toList();

      expect(hits.any((t) => t.contains('Pretty tired')), isTrue);
      expect(hits.any((t) => t.contains('knackered')), isTrue);
      expect(result.interpretation, isNotNull);
      expect(result.interpretation, contains('tired'));
    });

    test('money finds a deposit, and ranks the literal hit first', () {
      final result = searcher.search(_noteWith(_snippets).note, 'money');
      expect(result.isNotEmpty, isTrue);
      expect(
        result.hits.any((h) => h.section.text.contains('deposit')),
        isTrue,
      );
    });

    test('a concept word is highlighted as a concept, not a typo', () {
      final result = searcher.search(_noteWith(_snippets).note, 'tired');
      final knackered = result.hits.firstWhere(
        (h) => h.section.text.contains('knackered'),
      );
      expect(knackered.spans.any((s) => s.kind == MatchKind.concept), isTrue);
      // And the highlight sits exactly on the matched word.
      for (final span in knackered.spans) {
        final word = knackered.excerpt.substring(span.start, span.end);
        expect(
          word.toLowerCase(),
          anyOf(
            contains('knackered'),
            contains('exhausted'),
            contains('tired'),
            contains('worn'),
          ),
        );
      }
    });
  });

  group('typos', () {
    test('a misspelling still finds the intended word', () {
      final result = searcher.search(
        _noteWith([
          'I was absolutely exausted after the drive.',
          'Unrelated note about a lamp.',
        ]).note,
        'exhausted',
      );
      expect(result.isNotEmpty, isTrue);
      expect(
        result.hits.first.spans.any((s) => s.kind == MatchKind.fuzzy),
        isTrue,
      );
    });

    test('a fuzzy hit never outranks a literal one', () {
      final result = searcher.search(
        _noteWith([
          'I was exhausted, genuinely exhausted.',
          'The exhaust on the car needs fixing.',
        ]).note,
        'exhausted',
      );
      expect(result.hits.first.section.text, contains('genuinely'));
    });
  });

  group('ranking', () {
    test('literal matches beat related wording', () {
      final result = searcher.search(
        _noteWith([
          'Feeling drained and worn out.',
          'Feeling tired after the drive.',
        ]).note,
        'tired',
      );
      expect(result.hits.first.section.text, contains('tired after'));
    });

    test('every term must be present', () {
      final result = searcher.search(
        _noteWith([
          'Tired.',
          'Work was long.',
          'Tired after work, straight to bed.',
        ]).note,
        'tired work',
      );
      expect(result.hits.length, 1);
      expect(result.hits.single.section.text, contains('straight to bed'));
    });

    test('terms close together beat terms far apart', () {
      final result = searcher.search(
        _noteWith([
          'Tired. ${'Filler sentence. ' * 20} Work.',
          'Tired after work.',
        ]).note,
        'tired work',
      );
      expect(result.hits.first.section.text, 'Tired after work.');
    });

    test('ties go to the more recent section', () {
      final result = searcher.search(
        _noteWith(['Walked home.', 'Walked home.']).note,
        'walked',
      );
      expect(result.hits.length, 2);
      expect(
        result.hits.first.section.createdAt.isAfter(
          result.hits.last.section.createdAt,
        ),
        isTrue,
      );
    });
  });

  group('excerpts and highlights', () {
    test('a long section is trimmed around the hit', () {
      final long =
          '${'Opening line that rambles. ' * 12}'
          'Then the dentist appointment, finally. '
          '${'Closing line that rambles. ' * 12}';
      final result = searcher.search(_noteWith([long]).note, 'dentist');

      final hit = result.hits.single;
      expect(hit.excerpt.length, lessThan(long.length));
      expect(hit.excerpt, contains('dentist'));
      expect(hit.excerpt.startsWith('…'), isTrue);
      expect(hit.excerpt.endsWith('…'), isTrue);
    });

    test('every highlight lands on the word it belongs to', () {
      final text = 'Line one.\n\nLine two mentions the river.\n\nLine three.';
      final result = searcher.search(_noteWith([text]).note, 'river');

      final span = result.hits.single.spans.single;
      expect(
        result.hits.single.excerpt.substring(span.start, span.end),
        'river',
      );
    });

    test('overlapping phrase and word spans do not overlap in output', () {
      final result = searcher.search(
        _noteWith(['We need to talk about the trip.']).note,
        'need talk',
      );
      final hit = result.hits.first;
      var previousEnd = -1;
      for (final span in hit.spans) {
        expect(span.start, greaterThanOrEqualTo(previousEnd));
        previousEnd = span.end;
      }
    });

    test('empty query returns nothing', () {
      expect(searcher.search(_noteWith(_snippets).note, '   ').isEmpty, isTrue);
    });

    test('stopwords alone return nothing', () {
      expect(
        searcher.search(_noteWith(_snippets).note, 'the of it').isEmpty,
        isTrue,
      );
    });
  });

  group('phrases', () {
    test('quoted words are matched as a run', () {
      final result = searcher.search(
        _noteWith(['We caught up with everyone.', 'I up caught the ball.'])
            .note,
        '"caught up"',
      );
      expect(result.hits.length, 1);
      expect(result.hits.single.section.text, contains('caught up with'));
    });
  });
}
