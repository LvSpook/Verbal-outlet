import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:verbal_outlet/ai/ai_controller.dart';
import 'package:verbal_outlet/ai/compose_queue.dart';
import 'package:verbal_outlet/ai/compose_scope.dart';
import 'package:verbal_outlet/data/note_repository.dart';
import 'package:verbal_outlet/data/note_export.dart';
import 'package:verbal_outlet/data/note_store.dart';
import 'package:verbal_outlet/models/day_note.dart';
import 'package:verbal_outlet/widgets/note_editor_pane.dart';

import 'support/fake_composer_provider.dart';

/// The pane on its own, with a fake model writing entries.
Future<Widget> _pane(
  WidgetTester tester, {
  required NoteStore store,
  required FakeComposerProvider provider,
  DateTime? day,
}) async {
  tester.view.physicalSize = const Size(1000, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final ai = AiController(initialProvider: provider);
  final queue = ComposeQueue(store: store, ai: ai);
  // Held entries are retried on a timer, which must not outlive the test.
  addTearDown(queue.dispose);
  return ComposeScope(
    queue: queue,
    child: MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: NoteEditorPane(
          day: day ?? DateTime(2026, 4, 2),
          embedded: true,
        ),
      ),
    ),
  );
}

void main() {
  late NoteStore store;

  setUp(() async {
    await NoteStore.instance.attachRepository(
      MemoryNoteRepository(),
      seedSamples: false,
    );
    store = NoteStore.instance;
  });

  testWidgets('typing and pressing Write it up shows the AI version', (
    tester,
  ) async {
    final provider = FakeComposerProvider();
    await tester.pumpWidget(await _pane(tester, store: store, provider: provider));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(composerFieldKey), 'Long day at work.');
    await tester.tap(find.text('Write it up'));
    await tester.pumpAndSettle();

    // The note shows what the AI wrote, not the raw words.
    expect(find.text('Written: Long day at work.'), findsOneWidget);
    // And the original is available, folded away.
    expect(find.text('Your words'), findsOneWidget);
    expect(find.text('Long day at work.'), findsNothing);

    await tester.tap(find.text('Your words'));
    await tester.pumpAndSettle();
    expect(find.text('Long day at work.'), findsOneWidget);
  });

  testWidgets('an instruction field is passed to the model', (tester) async {
    final provider = FakeComposerProvider();
    await tester.pumpWidget(await _pane(tester, store: store, provider: provider));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(composerFieldKey), 'Milk, eggs, bread');
    await tester.enterText(
      find.widgetWithText(
        TextField,
        'Ask the AI for something specific (optional)',
      ),
      'make it a checklist',
    );
    await tester.tap(find.text('Write it up'));
    await tester.pumpAndSettle();

    expect(
      provider.received.single.last.text,
      contains('make it a checklist'),
    );
  });

  testWidgets('when the AI is offline the entry is held, not lost', (
    tester,
  ) async {
    final provider = FakeComposerProvider(available: false);
    await tester.pumpWidget(await _pane(tester, store: store, provider: provider));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(composerFieldKey), 'Keep this safe.');
    await tester.tap(find.text('Write it up'));
    await tester.pumpAndSettle();

    // Still waiting, with the words still there.
    expect(find.textContaining('Waiting for the AI'), findsOneWidget);
    expect(store.noteFor(DateTime(2026, 4, 2))!.sections.single.text,
        'Keep this safe.');
    // And the composer stops promising a write it cannot do.
    expect(find.textContaining('AI offline'), findsOneWidget);
  });

  testWidgets('a failed entry can be retried from the card', (tester) async {
    final provider = FakeComposerProvider(
      failMessage: 'The model returned nothing. Try rephrasing.',
    );
    await tester.pumpWidget(await _pane(tester, store: store, provider: provider));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(composerFieldKey), 'Odd entry.');
    await tester.tap(find.text('Write it up'));
    await tester.pumpAndSettle();

    expect(find.textContaining('could not write this one'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('edited words are written up again', (tester) async {
    final provider = FakeComposerProvider();
    await tester.pumpWidget(await _pane(tester, store: store, provider: provider));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(composerFieldKey), 'First version.');
    await tester.tap(find.text('Write it up'));
    await tester.pumpAndSettle();
    expect(find.text('Written: First version.'), findsOneWidget);

    // Open the inline editor and change the words.
    await tester.tap(find.text('Written: First version.'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Second version.');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Written: Second version.'), findsOneWidget);
    expect(find.text('Written: First version.'), findsNothing);
  });

  group('export', () {
    test('the AI version leads, with the words beneath', () {
      final note = DayNote(
        day: DateTime(2026, 4, 2),
        sections: [
          NoteSection(
            id: 'a',
            createdAt: DateTime(2026, 4, 2, 9),
            text: 'Raw thoughts about the day',
            body: 'A **short** summary.\n\n- one\n- two',
          ),
        ],
      );

      final markdown = renderDayMarkdown(note);

      expect(markdown, contains('A **short** summary.'));
      expect(markdown, contains('- one'));
      expect(markdown, contains('Your words'));
      expect(markdown, contains('> Raw thoughts about the day'));
    });

    test('an uncomposted section exports its words directly', () {
      final note = DayNote(
        day: DateTime(2026, 4, 2),
        sections: [
          NoteSection(
            id: 'a',
            createdAt: DateTime(2026, 4, 2, 9),
            text: 'Just the words',
          ),
        ],
      );

      final markdown = renderDayMarkdown(note);

      expect(markdown, contains('Just the words'));
      expect(markdown, isNot(contains('Your words')));
    });
  });
}
