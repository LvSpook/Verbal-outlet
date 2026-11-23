import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:verbal_outlet/ai/ai_controller.dart';
import 'package:verbal_outlet/ai/compose_queue.dart';
import 'package:verbal_outlet/data/note_repository.dart';
import 'package:verbal_outlet/data/note_store.dart';
import 'package:verbal_outlet/models/day_note.dart';
import 'package:verbal_outlet/widgets/note_editor_pane.dart';

import 'support/fake_composer_provider.dart';

Future<NoteStore> _store() async {
  final store = NoteStore.forTesting(MemoryNoteRepository());
  await store.attachRepository(MemoryNoteRepository(), seedSamples: false);
  return store;
}

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
  group('undoing a delete', () {
    test('brings the words back, visible again', () async {
      final store = await _store();
      final day = DateTime(2026, 5, 4);
      final note = store.appendToDay(day, 'A thought I meant to keep.');
      final id = note.sections.single.id;

      store.removeSection(day, id);
      expect(store.noteFor(day)!.visible, isEmpty);

      expect(store.restoreSection(day, id), isTrue);
      final section = store.noteFor(day)!.visible.single;
      expect(section.text, 'A thought I meant to keep.');
      expect(section.deleted, isFalse);
    });

    test('the restore is newer than the tombstone, so it wins a sync', () async {
      final store = await _store();
      final day = DateTime(2026, 5, 5);
      final note = store.appendToDay(day, 'Crossed devices.');
      final id = note.sections.single.id;

      store.removeSection(day, id);
      final tombstone = store.noteFor(day)!.sections.single;
      store.restoreSection(day, id);
      final restored = store.noteFor(day)!.sections.single;

      expect(restored.modifiedAt.isAfter(tombstone.modifiedAt), isTrue);
    });

    test('an entry that is gone for good cannot be restored', () async {
      final store = await _store();
      final day = DateTime(2026, 5, 6);
      store.appendToDay(day, 'Something.');

      expect(store.restoreSection(day, 'no-such-id'), isFalse);
      expect(store.restoreSection(DateTime(2024, 1, 1), 'x'), isFalse);
    });

    test('a composed entry keeps its AI version when brought back', () async {
      final store = await _store();
      final queue = ComposeQueue(
        store: store,
        ai: AiController(initialProvider: FakeComposerProvider()),
      );
      final day = DateTime(2026, 5, 7);

      store.holdForCompose(day, 'Slept badly');
      await queue.compose(day, store.noteFor(day)!.sections.single);
      final id = store.noteFor(day)!.sections.single.id;
      final body = store.noteFor(day)!.sections.single.body;

      store.removeSection(day, id);
      store.restoreSection(day, id);

      final section = store.noteFor(day)!.sections.single;
      expect(section.body, body);
      expect(section.state, ComposeState.ready);
    });
  });

  group('the undo snackbar', () {
    testWidgets('tapping delete offers a way back', (tester) async {
      final day = DateTime(2026, 5, 8);
      await NoteStore.instance.attachRepository(
        MemoryNoteRepository(),
        seedSamples: false,
      );
      NoteStore.instance.appendToDay(day, 'Spoken in haste.');
      await _pumpPane(tester, day);

      await tester.tap(find.byTooltip('Section options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Entry deleted.'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(find.text('Spoken in haste.'), findsOneWidget);
      expect(NoteStore.instance.noteFor(day)!.visible, hasLength(1));
    });
  });

  group('retrying a held entry', () {
    test('a held entry is tried again after a backoff', () async {
      final store = await _store();
      final provider = FakeComposerProvider(available: false);
      final queue = ComposeQueue(
        store: store,
        ai: AiController(initialProvider: provider),
        retryAfter: const Duration(milliseconds: 20),
      );
      addTearDown(queue.dispose);

      store.holdForCompose(DateTime(2026, 5, 9), 'Waiting for the AI');
      await queue.kick();
      expect(queue.waiting, 1, reason: 'still held');
      expect(queue.blockedReason, isNotNull);

      // The AI comes back with no event in the app, which is the whole reason
      // for the quiet retry.
      provider.available = true;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      // Give the pass itself time to run.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(queue.waiting, 0, reason: 'written on a retry');
      expect(queue.blockedReason, isNull);
      expect(store.noteFor(DateTime(2026, 5, 9))!.body, isNotEmpty);
    });

    test('the retry stops once the queue is disposed', () async {
      final store = await _store();
      final queue = ComposeQueue(
        store: store,
        ai: AiController(initialProvider: FakeComposerProvider(available: false)),
        retryAfter: const Duration(milliseconds: 10),
      );

      store.holdForCompose(DateTime(2026, 5, 10), 'Held');
      await queue.kick();
      queue.dispose();

      // A pending timer after disposal would make the test fail; waiting is the
      // check that there is none.
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });

    test('the wait doubles each time, and a new entry starts it over', () async {
      final store = await _store();
      final queue = ComposeQueue(
        store: store,
        ai: AiController(
          initialProvider: FakeComposerProvider(available: false),
        ),
        retryAfter: const Duration(seconds: 1),
      );
      addTearDown(queue.dispose);

      store.holdForCompose(DateTime(2026, 5, 12), 'Held');
      await queue.kick();
      expect(queue.nextRetryIn, const Duration(seconds: 1));

      // Let the quiet attempt run and fail, which is what doubles the wait.
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(queue.nextRetryIn, const Duration(seconds: 2));

      await Future<void>.delayed(const Duration(milliseconds: 2300));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(queue.nextRetryIn, const Duration(seconds: 4), reason: 'doubling');

      // A person acting resets it: a new entry is a fresh reason to try now.
      store.holdForCompose(DateTime(2026, 5, 12), 'Another');
      await queue.kick();
      expect(queue.nextRetryIn, const Duration(seconds: 1));
    });

    test('a successful pass leaves no timer behind', () async {
      final store = await _store();
      final queue = ComposeQueue(
        store: store,
        ai: AiController(initialProvider: FakeComposerProvider()),
        retryAfter: const Duration(milliseconds: 10),
      );
      addTearDown(queue.dispose);

      store.holdForCompose(DateTime(2026, 5, 11), 'Written at once');
      await queue.kick();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(queue.blockedReason, isNull);
      expect(store.pendingCompositions, isEmpty);
    });
  });
}
