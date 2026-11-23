import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:verbal_outlet/data/note_repository.dart';
import 'package:verbal_outlet/data/note_store.dart';
import 'package:verbal_outlet/widgets/note_editor_pane.dart';

/// The pane on its own, with a note to work on.
Future<void> _pumpPane(WidgetTester tester, DateTime day) async {
  tester.view.physicalSize = const Size(1000, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: NoteEditorPane(day: day)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    // A clean store per test, with no sample notes.
    await NoteStore.instance.attachRepository(
      MemoryNoteRepository(),
      seedSamples: false,
    );
  });

  testWidgets('the header menu offers copy and both export formats', (
    tester,
  ) async {
    final day = DateTime(2026, 3, 4);
    NoteStore.instance.appendToDay(day, 'A thought worth keeping.');
    await _pumpPane(tester, day);

    await tester.tap(find.byTooltip('Note options'));
    await tester.pumpAndSettle();

    expect(find.text('Copy note'), findsOneWidget);
    expect(find.text('Export as Markdown'), findsOneWidget);
    expect(find.text('Export as JSON'), findsOneWidget);
  });

  testWidgets('copy puts the note text on the clipboard', (tester) async {
    final day = DateTime(2026, 3, 4);
    NoteStore.instance.appendToDay(day, 'First.');
    NoteStore.instance.appendToDay(day, 'Second.');
    await _pumpPane(tester, day);

    // Capture what the app writes to the clipboard.
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.tap(find.byTooltip('Note options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy note'));
    await tester.pumpAndSettle();

    expect(copied, 'First.\n\nSecond.');
    expect(find.text('Note copied.'), findsOneWidget);
  });

  testWidgets('the menu is disabled with nothing to export', (tester) async {
    final day = DateTime(2026, 3, 5);
    await _pumpPane(tester, day);

    await tester.tap(find.byTooltip('Note options'));
    await tester.pumpAndSettle();

    // The items are visible but cannot be chosen: there is nothing in the note.
    final copy = tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, 'Copy note'),
    );
    expect(copy.enabled, isFalse);

    final markdown = tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, 'Export as Markdown'),
    );
    expect(markdown.enabled, isFalse);
  });

  testWidgets('a day with a note enables the export items', (tester) async {
    final day = DateTime(2026, 3, 6);
    NoteStore.instance.appendToDay(day, 'Something.');
    await _pumpPane(tester, day);

    await tester.tap(find.byTooltip('Note options'));
    await tester.pumpAndSettle();

    final markdown = tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, 'Export as Markdown'),
    );
    expect(markdown.enabled, isTrue);
  });

  testWidgets('a deleted-only note counts as empty', (tester) async {
    final day = DateTime(2026, 3, 7);
    final note = NoteStore.instance.appendToDay(day, 'Gone soon.');
    NoteStore.instance.removeSection(day, note.sections.single.id);
    await _pumpPane(tester, day);

    await tester.tap(find.byTooltip('Note options'));
    await tester.pumpAndSettle();

    final copy = tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, 'Copy note'),
    );
    expect(copy.enabled, isFalse);
    expect(NoteStore.instance.noteFor(day)!.visible, isEmpty);
  });
}
