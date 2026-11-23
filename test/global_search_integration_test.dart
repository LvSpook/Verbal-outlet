import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:verbal_outlet/data/note_repository.dart';
import 'package:verbal_outlet/data/note_store.dart';
import 'package:verbal_outlet/main.dart';
import 'package:verbal_outlet/screens/note_page.dart';
import 'package:verbal_outlet/widgets/note_editor_pane.dart';

/// Puts the app on a desktop-sized surface, where the split layout applies.
Future<void> _pumpDesktop(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(const VerbalOutletApp());
  await tester.pumpAndSettle();
}

/// A store with one note on a past day, so a global search has somewhere to
/// find something that is not today.
Future<DateTime> _seedPastNote() async {
  await NoteStore.instance.attachRepository(
    MemoryNoteRepository(),
    seedSamples: false,
  );
  final day = DateTime(DateTime.now().year, 3, 4);
  NoteStore.instance.appendToDay(day, 'Walked to the lighthouse at dawn.');
  return day;
}

void main() {
  setUp(() async {
    await NoteStore.instance.attachRepository(
      MemoryNoteRepository(),
      seedSamples: false,
    );
  });

  testWidgets('Ctrl+K opens the all-notes search', (tester) async {
    await _pumpDesktop(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.textContaining('Search every note'), findsOneWidget);
  });

  testWidgets('the calendar search button opens it too', (tester) async {
    await _pumpDesktop(tester);

    await tester.tap(find.byTooltip('Search all notes').first);
    await tester.pumpAndSettle();

    expect(find.textContaining('Search every note'), findsOneWidget);
  });

  testWidgets('a hit from another day opens that day with the section editing', (
    tester,
  ) async {
    final day = await _seedPastNote();
    await _pumpDesktop(tester);

    await tester.tap(find.byTooltip('Search all notes').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'lighthouse');
    await tester.pumpAndSettle();

    // The result names the day it came from.
    expect(find.text('4 March ${day.year}'), findsOneWidget);

    await tester.tap(find.byType(InkWell).last);
    await tester.pumpAndSettle();

    // The pane now shows that day, with the matched section in its editor.
    expect(find.byType(NoteEditorPane), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'Walked to the lighthouse at dawn.'),
      findsOneWidget,
    );
  });

  testWidgets('closing without choosing leaves the screen as it was', (
    tester,
  ) async {
    await _seedPastNote();
    await _pumpDesktop(tester);

    await tester.tap(find.byTooltip('Search all notes').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'lighthouse');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();

    expect(find.text('Pick a day'), findsOneWidget);
    expect(find.byType(NoteEditorPane), findsNothing);
  });

  testWidgets('on a narrow window a hit opens as a full note page', (
    tester,
  ) async {
    final day = await _seedPastNote();
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const VerbalOutletApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Search all notes').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'lighthouse');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(InkWell).last);
    await tester.pumpAndSettle();

    expect(find.byType(NotePage), findsOneWidget);
    expect(find.byType(NoteEditorPane), findsOneWidget);
    expect(find.text('4 March ${day.year}'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'Walked to the lighthouse at dawn.'),
      findsOneWidget,
    );
  });
}
