import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:verbal_outlet/ai/ai_controller.dart';
import 'package:verbal_outlet/ai/compose_queue.dart';
import 'package:verbal_outlet/ai/compose_scope.dart';
import 'package:verbal_outlet/data/note_repository.dart';
import 'package:verbal_outlet/data/note_store.dart';
import 'package:verbal_outlet/models/day_note.dart';
import 'package:verbal_outlet/voice/voice_controller.dart';
import 'package:verbal_outlet/voice/voice_scope.dart';
import 'package:verbal_outlet/widgets/note_editor_pane.dart';

import 'support/fake_composer_provider.dart';
import 'support/fake_voice_engine.dart';

/// The pane with the floating capture buttons, a fake model and a fake mic.
Future<Widget> _pane(
  WidgetTester tester, {
  required NoteStore store,
  required FakeComposerProvider provider,
  required VoiceController voice,
  DateTime? day,
}) async {
  tester.view.physicalSize = const Size(1000, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final ai = AiController(initialProvider: provider);
  final queue = ComposeQueue(store: store, ai: ai);
  // The queue quietly retries held entries, so it must be closed at the end of
  // the test or its timer outlives the widget tree.
  addTearDown(queue.dispose);
  return ComposeScope(
    queue: queue,
    child: VoiceScope(
      controller: voice,
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: NoteEditorPane(
            day: day ?? DateTime(2026, 4, 2),
            embedded: true,
          ),
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

  testWidgets('the floating microphone is shown and stays over the note', (
    tester,
  ) async {
    final voice = VoiceController(engine: FakeVoiceEngine());
    await tester.pumpWidget(
      await _pane(
        tester,
        store: store,
        provider: FakeComposerProvider(),
        voice: voice,
      ),
    );
    await tester.pumpAndSettle();

    final mic = find.byTooltip('Speak a thought');
    expect(mic, findsOneWidget);
    expect(find.byTooltip('Write a thought'), findsOneWidget);

    // A long note: the buttons should not scroll away with it.
    for (var i = 0; i < 12; i++) {
      store.appendToDay(DateTime(2026, 4, 2), 'Thought $i');
    }
    await tester.pumpAndSettle();
    final before = tester.getCenter(mic);
    await tester.drag(find.byType(ListView).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Speak a thought'), findsOneWidget);
    final after = tester.getCenter(mic);
    expect(after.dx, moreOrLessEquals(before.dx, epsilon: 1));
    expect(after.dy, moreOrLessEquals(before.dy, epsilon: 1));
  });

  testWidgets('speaking adds an AI-written entry, not the raw words', (
    tester,
  ) async {
    final voice = VoiceController(
      engine: FakeVoiceEngine(transcript: 'I went for a long walk.'),
    );
    await tester.pumpWidget(
      await _pane(
        tester,
        store: store,
        provider: FakeComposerProvider(),
        voice: voice,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Speak a thought'));
    await tester.pumpAndSettle();

    // Record, then stop: the transcript appears for review.
    await tester.tap(find.byKey(const ValueKey('voice-record-button')));
    // The record button pulses, so the tree never settles while recording.
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.byIcon(Icons.stop));
    // The transcript field takes focus, so a blinking cursor keeps the tree
    // from ever settling; pump a few frames instead.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('I went for a long walk.'), findsOneWidget);

    await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.text('Write it up')));
    await tester.pumpAndSettle();

    // The note shows the AI's version, with the spoken words folded away.
    expect(find.text('Written: I went for a long walk.'), findsOneWidget);
    expect(find.text('I went for a long walk.'), findsNothing);
    expect(find.text('Your words'), findsOneWidget);
  });

  testWidgets('a transcript can be corrected before it is sent', (
    tester,
  ) async {
    final voice = VoiceController(
      engine: FakeVoiceEngine(transcript: 'The wether is nice.'),
    );
    await tester.pumpWidget(
      await _pane(
        tester,
        store: store,
        provider: FakeComposerProvider(),
        voice: voice,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Speak a thought'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-record-button')));
    // The record button pulses, so the tree never settles while recording.
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.byIcon(Icons.stop));
    // The transcript field takes focus, so a blinking cursor keeps the tree
    // from ever settling; pump a few frames instead.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(
      find.byKey(const ValueKey('transcript-field')),
      'The weather is nice.',
    );
    await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.text('Write it up')));
    await tester.pumpAndSettle();

    expect(find.text('Written: The weather is nice.'), findsOneWidget);
  });

  testWidgets('cancelling a recording adds nothing', (tester) async {
    final engine = FakeVoiceEngine();
    final voice = VoiceController(engine: engine);
    await tester.pumpWidget(
      await _pane(
        tester,
        store: store,
        provider: FakeComposerProvider(),
        voice: voice,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Speak a thought'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-record-button')));
    // The record button pulses, so the tree never settles while recording.
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.text('Cancel')));
    // Still recording until cancel resolves, so the pulse keeps the tree
    // unsettled; pump through the sheet's closing animation by hand.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(engine.cancelled, isTrue);
    expect(store.pendingCompositions, isEmpty);
    expect(store.allNotes, isEmpty);
  });

  testWidgets('with no model downloaded the sheet offers setup', (
    tester,
  ) async {
    final voice = VoiceController(engine: FakeVoiceEngine(ready: false));
    await tester.pumpWidget(
      await _pane(
        tester,
        store: store,
        provider: FakeComposerProvider(),
        voice: voice,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Speak a thought'));
    await tester.pumpAndSettle();

    expect(find.text('One-time voice setup'), findsOneWidget);
    expect(find.text('Set up voice'), findsOneWidget);
    // No record button, so nothing looks broken when tapped.
    expect(find.text('Tap to start'), findsNothing);
  });

  testWidgets('the spoken entry is held while the AI is down', (tester) async {
    final voice = VoiceController(engine: FakeVoiceEngine(transcript: 'Held.'));
    final provider = FakeComposerProvider(available: false);
    await tester.pumpWidget(
      await _pane(tester, store: store, provider: provider, voice: voice),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Speak a thought'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-record-button')));
    // The record button pulses, so the tree never settles while recording.
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.byIcon(Icons.stop));
    // The transcript field takes focus, so a blinking cursor keeps the tree
    // from ever settling; pump a few frames instead.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.text('Write it up')));
    await tester.pumpAndSettle();

    // Nothing raw is written; the words wait for the AI.
    expect(find.text('Held.'), findsNothing);
    final pending = store.pendingCompositions;
    expect(pending, hasLength(1));
    expect(pending.single.$2.text, 'Held.');
    expect(pending.single.$2.state, ComposeState.pending);
  });
}


