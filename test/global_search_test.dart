import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:verbal_outlet/data/note_repository.dart';
import 'package:verbal_outlet/data/note_store.dart';
import 'package:verbal_outlet/models/day_note.dart';
import 'package:verbal_outlet/search/note_search.dart';
import 'package:verbal_outlet/widgets/global_search_dialog.dart';
import 'package:verbal_outlet/widgets/highlighted_text.dart';

/// A store holding [notes], built without touching the app-wide singleton.
NoteStore _storeWith(List<DayNote> notes) {
  final store = NoteStore.forTesting(MemoryNoteRepository());
  for (final note in notes) {
    for (final section in note.sections) {
      store.applyRemoteSection(note.day, section);
    }
  }
  return store;
}

/// A note on [day] with one section per line, timestamped in order.
DayNote _noteOn(DateTime day, List<String> lines) => DayNote(
  day: DateTime(day.year, day.month, day.day),
  sections: [
    for (var i = 0; i < lines.length; i++)
      NoteSection(
        id: '${day.toIso8601String()}-$i',
        createdAt: DateTime(day.year, day.month, day.day, 8 + i),
        text: lines[i],
        updatedAt: DateTime(day.year, day.month, day.day, 8 + i),
      ),
  ],
);

void main() {
  const searcher = LexicalSearcher();

  group('searching every note', () {
    test('finds a word written on a day that is not today', () {
      final notes = [
        _noteOn(DateTime(2025, 3, 1), ['Bought some milk.']),
        _noteOn(DateTime(2025, 4, 9), ['Walked the long route by the river.']),
      ];

      final result = searcher.searchAll(notes, 'walk');

      expect(result.hits, hasLength(1));
      expect(result.hits.single.day, DateTime(2025, 4, 9));
      expect(result.hits.single.hit.section.text, contains('route'));
      expect(result.dayCount, 1);
      expect(result.daysSearched, 2);
    });

    test('ranks across days in one list, not day by day', () {
      final notes = [
        // Older, but says exactly what was typed.
        _noteOn(DateTime(2025, 1, 2), ['A gentle walk before breakfast.']),
        // Newer, and only related wording.
        _noteOn(DateTime(2025, 6, 20), ['Went for a stroll after lunch.']),
      ];

      final result = searcher.searchAll(notes, 'walk');

      // The literal match should win even though the other day is more recent.
      expect(result.hits.first.day, DateTime(2025, 1, 2));
      expect(result.hits.length, greaterThan(1));
      // Both days are represented, and scores are descending.
      expect(result.hits.map((h) => h.day).toSet(), hasLength(2));
      for (var i = 1; i < result.hits.length; i++) {
        expect(
          result.hits[i - 1].hit.score,
          greaterThanOrEqualTo(result.hits[i].hit.score),
        );
      }
    });

    test('a hit carries the day it was filed under, not when it was typed', () {
      // A thought added today to a note from last week should still report the
      // old day, because that is the note the calendar will open.
      final note = DayNote(
        day: DateTime(2025, 2, 3),
        sections: [
          NoteSection(
            id: 'late',
            createdAt: DateTime(2025, 9, 1, 12),
            text: 'Remembered something about the walk.',
          ),
        ],
      );

      final result = searcher.searchAll([note], 'walk');

      expect(result.hits.single.day, DateTime(2025, 2, 3));
    });

    test('empty notes are not counted as searched', () {
      final result = searcher.searchAll([
        _noteOn(DateTime(2025, 1, 1), ['One thing.']),
        DayNote(day: DateTime(2025, 1, 2), sections: const []),
      ], 'thing');

      expect(result.daysSearched, 1);
    });

    test('an empty query finds nothing and reports nothing searched', () {
      final result = searcher.searchAll([
        _noteOn(DateTime(2025, 1, 1), ['Anything.']),
      ], '   ');

      expect(result.isEmpty, isTrue);
      expect(result.daysSearched, 0);
      expect(result.interpretation, isNull);
    });

    test('the same expansions as a day search are explained once', () {
      final result = searcher.searchAll([
        _noteOn(DateTime(2025, 1, 1), ['Absolutely knackered.']),
      ], 'tired');

      expect(result.isNotEmpty, isTrue);
      expect(result.interpretation, contains('related wording'));
      expect(result.hits.single.hit.reasons, isNotEmpty);
    });

    test('deleted sections are not found', () {
      final note = DayNote(
        day: DateTime(2025, 1, 1),
        sections: [
          NoteSection(
            id: 'gone',
            createdAt: DateTime(2025, 1, 1, 9),
            text: 'A walk that was deleted.',
            deleted: true,
          ),
        ],
      );

      // The day has no visible text, so it is not searched at all.
      final result = searcher.searchAll([note], 'walk');
      expect(result.isEmpty, isTrue);
      expect(result.daysSearched, 0);
    });
  });

  group('the all-notes dialog', () {
    Future<void> pumpDialog(
      WidgetTester tester, {
      required List<DayNote> notes,
      Size size = const Size(900, 900),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showDialog<GlobalHit>(
                    context: context,
                    builder: (_) => GlobalSearchDialog(
                      store: _storeWith(notes),
                      searcher: searcher,
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('says how many days it will search before a query', (
      tester,
    ) async {
      await pumpDialog(
        tester,
        notes: [
          _noteOn(DateTime(2025, 1, 1), ['One.']),
          _noteOn(DateTime(2025, 1, 2), ['Two.']),
        ],
      );

      expect(find.textContaining('Searches all 2 days'), findsOneWidget);
      expect(find.textContaining('Find any thought'), findsOneWidget);
    });

    testWidgets('lists hits from several days with their dates', (
      tester,
    ) async {
      await pumpDialog(
        tester,
        notes: [
          _noteOn(DateTime(2025, 1, 2), ['A walk before breakfast.']),
          _noteOn(DateTime(2025, 6, 20), ['The walk home was cold.']),
        ],
      );

      await tester.enterText(find.byType(TextField), 'walk');
      await tester.pumpAndSettle();

      // Two matches, on two days, and each card names its day.
      expect(find.textContaining('2 matches on 2 days'), findsOneWidget);
      expect(find.text('2 January 2025'), findsOneWidget);
      expect(find.text('20 June 2025'), findsOneWidget);
      expect(find.byType(HighlightedText), findsNWidgets(2));
    });

    testWidgets('choosing a hit returns it to the caller', (tester) async {
      GlobalHit? chosen;
      tester.view.physicalSize = const Size(900, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    chosen = await showDialog<GlobalHit>(
                      context: context,
                      builder: (_) => GlobalSearchDialog(
                        store: _storeWith([
                          _noteOn(DateTime(2025, 3, 4), ['A walk by the sea.']),
                        ]),
                        searcher: searcher,
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'walk');
      await tester.pumpAndSettle();
      // The excerpt is drawn as a RichText so the match can be highlighted,
      // which a text finder cannot see; tap the card by its type instead.
      await tester.tap(find.byType(InkWell).last);
      await tester.pumpAndSettle();

      expect(chosen, isNotNull);
      expect(chosen!.day, DateTime(2025, 3, 4));
      expect(chosen!.hit.section.text, contains('sea'));
    });

    testWidgets('a query with no hits says so instead of showing nothing', (
      tester,
    ) async {
      await pumpDialog(
        tester,
        notes: [_noteOn(DateTime(2025, 1, 2), ['A walk before breakfast.'])],
      );

      await tester.enterText(find.byType(TextField), 'helicopter');
      await tester.pumpAndSettle();

      expect(find.textContaining('Nothing matches'), findsOneWidget);
      expect(find.textContaining('No matches in 1 days'), findsOneWidget);
    });

    for (final size in const [
      Size(700, 520),
      Size(1000, 700),
      Size(1400, 900),
    ]) {
      testWidgets('fits $size without overflowing', (tester) async {
        await pumpDialog(
          tester,
          notes: [
            _noteOn(DateTime(2025, 1, 2), [
              'A long walk before breakfast, along the whole river path and '
                  'back again before the rain came.',
            ]),
            _noteOn(DateTime(2025, 6, 20), ['The walk home was cold.']),
          ],
          size: size,
        );

        await tester.enterText(find.byType(TextField), 'walk');
        await tester.pumpAndSettle();

        // A RenderFlex overflow is reported as a framework exception, so
        // nothing to assert beyond a clean build at each size.
        expect(tester.takeException(), isNull);
      });
    }
  });
}
