import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:verbal_outlet/main.dart';
import 'package:verbal_outlet/ai/ai_controller.dart';
import 'package:verbal_outlet/widgets/note_editor_pane.dart';

import 'support/fake_composer_provider.dart';

/// Puts the app on a desktop-sized surface, where the split layout applies.
Future<void> _pumpDesktop(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(_app());
  await tester.pumpAndSettle();
}

/// Puts the app on a narrow surface, where notes open as a full page.
Future<void> _pumpNarrow(WidgetTester tester) async {
  tester.view.physicalSize = const Size(600, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(_app());
  await tester.pumpAndSettle();
}

/// The real app with a fake model behind it.
///
/// Composing is the app's write path, so a test that types into the composer
/// must supply a model; otherwise the entry waits for an Ollama that is not
/// there.
VerbalOutletApp _app() => VerbalOutletApp(
  ai: AiController(initialProvider: FakeComposerProvider()),
);

void main() {
  testWidgets('app opens to the calendar with an empty note pane', (
    tester,
  ) async {
    await _pumpDesktop(tester);

    expect(find.text('Verbal Outlet'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.data != null &&
            RegExp(r'^[A-Z][a-z]+ \d{4}$').hasMatch(widget.data!),
      ),
      findsOneWidget,
    );

    // The right-hand pane invites you to pick a day.
    expect(find.text('Pick a day'), findsOneWidget);
  });

  testWidgets('selecting a date keeps the calendar and opens the note beside', (
    tester,
  ) async {
    await _pumpDesktop(tester);

    final today = DateTime.now().day.toString();
    await tester.tap(find.text(today).first);
    await tester.pumpAndSettle();

    // Both panes are present at once: no navigation happened.
    expect(find.text('Today'), findsWidgets);
    expect(find.text('Add another thought to this day…'), findsOneWidget);
    expect(find.text('Pick a day'), findsNothing);

    // The calendar is still there, so another day is one click away.
    expect(find.byTooltip('Next month'), findsOneWidget);
  });

  testWidgets('switching days swaps the note without leaving the screen', (
    tester,
  ) async {
    await _pumpDesktop(tester);

    final now = DateTime.now();
    final blankDay = _findBlankDayInMonth(now);

    await tester.tap(find.text(now.day.toString()).first);
    await tester.pumpAndSettle();
    expect(find.text('Add another thought to this day…'), findsOneWidget);

    await tester.tap(find.text(blankDay.toString()).first);
    await tester.pumpAndSettle();

    // Now showing the blank day's empty state, with the calendar still up.
    expect(find.text('Nothing here yet'), findsOneWidget);
    expect(find.byTooltip('Next month'), findsOneWidget);
  });

  testWidgets('the close button returns to the empty pane', (tester) async {
    await _pumpDesktop(tester);

    await tester.tap(find.text(DateTime.now().day.toString()).first);
    await tester.pumpAndSettle();
    expect(find.text('Pick a day'), findsNothing);

    await tester.tap(find.byTooltip('Close note'));
    await tester.pumpAndSettle();

    expect(find.text('Pick a day'), findsOneWidget);
  });

  testWidgets('narrow windows open notes as a full page', (tester) async {
    await _pumpNarrow(tester);

    expect(find.text('Pick a day'), findsNothing);

    await tester.tap(find.text(DateTime.now().day.toString()).first);
    await tester.pumpAndSettle();

    expect(find.text('Add another thought to this day…'), findsOneWidget);
    // Full-page note has a back button and no calendar.
    expect(find.byTooltip('Back to calendar'), findsOneWidget);
    expect(find.byTooltip('Next month'), findsNothing);
  });

  testWidgets('adding to a day appends a section to the same note', (
    tester,
  ) async {
    await _pumpDesktop(tester);

    final today = DateTime.now().day;
    await tester.tap(find.text(today.toString()).first);
    await tester.pumpAndSettle();

    // Today is seeded with two sections, shown in the pane subtitle.
    expect(find.textContaining('2 additions'), findsWidgets);

    await tester.enterText(
      find.widgetWithText(TextField, 'Add another thought to this day…'),
      'One more thought',
    );
    await tester.tap(find.text('Write it up'));
    await tester.pumpAndSettle();

    // Same note, now with three sections. The AI's version is what shows.
    expect(find.textContaining('3 additions'), findsWidgets);
    expect(find.text('Written: One more thought'), findsOneWidget);
  });

  testWidgets('a new day starts empty and creates exactly one note', (
    tester,
  ) async {
    await _pumpDesktop(tester);

    final blankDay = _findBlankDayInMonth(DateTime.now());
    await tester.tap(find.text(blankDay.toString()).first);
    await tester.pumpAndSettle();

    expect(find.text('Nothing here yet'), findsOneWidget);
    expect(find.text('Write the first note for this day…'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Write the first note for this day…'),
      'First thought',
    );
    await tester.tap(find.text('Write it up'));
    await tester.pumpAndSettle();

    expect(find.text('Nothing here yet'), findsNothing);
    expect(find.text('Written: First thought'), findsOneWidget);
    expect(find.textContaining('1 addition'), findsOneWidget);
  });

  testWidgets('tapping the month heading opens the month picker', (
    tester,
  ) async {
    await _pumpDesktop(tester);

    final now = DateTime.now();
    await tester.tap(find.text('${_monthName(now.month)} ${now.year}'));
    await tester.pumpAndSettle();

    expect(find.text('${now.year}'), findsWidgets);
    expect(find.text('First note'), findsOneWidget);
  });

  testWidgets('picking a month changes the visible month', (tester) async {
    await _pumpDesktop(tester);

    final now = DateTime.now();
    await tester.tap(find.text('${_monthName(now.month)} ${now.year}'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Previous year'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jan'));
    await tester.pumpAndSettle();

    expect(find.text('January ${now.year - 1}'), findsOneWidget);
  });

  group('searching a day', () {
    Future<void> openToday(WidgetTester tester) async {
      await _pumpDesktop(tester);
      await tester.tap(find.text(DateTime.now().day.toString()).first);
      await tester.pumpAndSettle();
    }

    testWidgets('the search button opens a field and finds a match', (
      tester,
    ) async {
      await openToday(tester);

      await tester.tap(find.byTooltip('Search this note'));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(
          TextField,
          'Search this day — e.g. tired, money, walk',
        ),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextField).first, 'walk');
      await tester.pumpAndSettle();

      // Today's note mentions a walk after dinner, and "walk" also matches the
      // "walk" concept, so the count line appears with results underneath.
      expect(find.textContaining('match'), findsWidgets);
      expect(
        find.descendant(
          of: find.byType(NoteEditorPane),
          matching: find.byType(Card),
        ),
        findsWidgets,
      );
    });

    testWidgets('search understands related wording and says so', (
      tester,
    ) async {
      await openToday(tester);

      await tester.tap(find.byTooltip('Search this note'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'walk');
      await tester.pumpAndSettle();

      // The explanation names the concept that was expanded.
      expect(find.textContaining('related wording'), findsOneWidget);
    });

    testWidgets('a misspelled query still finds the note', (tester) async {
      await openToday(tester);

      await tester.tap(find.byTooltip('Search this note'));
      await tester.pumpAndSettle();
      // Today's note mentions dinner, so a nearby misspelling must still land.
      await tester.enterText(find.byType(TextField).first, 'diner');
      await tester.pumpAndSettle();

      expect(find.text('No matches on this day'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(NoteEditorPane),
          matching: find.byType(Card),
        ),
        findsWidgets,
      );
    });

    testWidgets('no matches explains itself instead of showing a blank pane', (
      tester,
    ) async {
      await openToday(tester);

      await tester.tap(find.byTooltip('Search this note'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'helicopter');
      await tester.pumpAndSettle();

      expect(find.text('No matches on this day'), findsWidgets);
      expect(find.textContaining('Try a different word'), findsOneWidget);
    });

    testWidgets('closing search restores the whole note', (tester) async {
      await openToday(tester);
      final before = find.textContaining('additions').evaluate().length;

      await tester.tap(find.byTooltip('Search this note'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'helicopter');
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();

      // Back to the note itself, composer included.
      expect(find.textContaining('additions').evaluate().length, before);
      expect(find.text('Add another thought to this day…'), findsOneWidget);
    });

    testWidgets('tapping a hit opens that section for editing', (tester) async {
      await openToday(tester);

      await tester.tap(find.byTooltip('Search this note'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'walk');
      await tester.pumpAndSettle();

      // Tap a result inside the note pane; the calendar has its own cards.
      final hit = find.descendant(
        of: find.byType(NoteEditorPane),
        matching: find.byType(Card),
      );
      expect(hit, findsWidgets);
      await tester.tap(hit.first);
      await tester.pumpAndSettle();

      // Editing shows Save and Cancel.
      expect(find.text('Save'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('Ctrl+F opens search', (tester) async {
      await openToday(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(
          TextField,
          'Search this day — e.g. tired, money, walk',
        ),
        findsOneWidget,
      );
    });

    testWidgets('switching days clears the query', (tester) async {
      await openToday(tester);

      await tester.tap(find.byTooltip('Search this note'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'walk');
      await tester.pumpAndSettle();
      expect(find.textContaining('Search this day'), findsOneWidget);

      // Move to any other day in the month.
      final now = DateTime.now();
      final other = now.day == 1 ? 2 : 1;
      await tester.tap(find.text(other.toString()).first);
      await tester.pumpAndSettle();

      // Search is closed on the new day, so the query cannot leak across.
      expect(find.textContaining('Search this day'), findsNothing);
      expect(find.textContaining('match'), findsNothing);
    });
  });
}

/// Returns a day in the current month that the sample data does not use.
int _findBlankDayInMonth(DateTime now) {
  final today = now.day;
  final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
  // Seeded days are today, and 1, 3 and 6 days ago.
  final seeded = {for (var back = 0; back <= 6; back++) today - back};

  for (var day = today + 1; day <= daysInMonth; day++) {
    if (!seeded.contains(day)) return day;
  }
  for (var day = today - 7; day >= 1; day--) {
    if (!seeded.contains(day)) return day;
  }
  throw StateError('No blank day available in this month');
}

const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String _monthName(int month) => _monthNames[month - 1];
