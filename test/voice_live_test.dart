import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:verbal_outlet/ai/ai_controller.dart';
import 'package:verbal_outlet/ai/ai_provider.dart';
import 'package:verbal_outlet/ai/ai_scope.dart';
import 'package:verbal_outlet/ai/compose_queue.dart';
import 'package:verbal_outlet/ai/compose_scope.dart';
import 'package:verbal_outlet/capture/app_request.dart';
import 'package:verbal_outlet/capture/app_request_scope.dart';
import 'package:verbal_outlet/data/note_repository.dart';
import 'package:verbal_outlet/data/note_store.dart';
import 'package:verbal_outlet/voice/pause_trace.dart';
import 'package:verbal_outlet/voice/speech_service.dart';
import 'package:verbal_outlet/voice/voice_controller.dart';
import 'package:verbal_outlet/voice/voice_engine.dart';
import 'package:verbal_outlet/voice/voice_settings.dart';
import 'package:verbal_outlet/voice/voice_scope.dart';
import 'package:verbal_outlet/widgets/note_editor_pane.dart';

import 'support/fake_voice_engine.dart';

/// A model that answers each kind of one-shot request differently.
///
/// The sheet now asks three different questions of the same controller -
/// compose this entry, classify this sentence, ask a follow-up - so a single
/// canned reply would prove nothing. This inspects the system prompt and
/// answers in character.
class _RoleProvider implements AiProvider {
  _RoleProvider({
    this.commandReply = '{"intent":"none","value":""}',
    this.questionReply = 'NOTHING',
  });

  /// What the command classifier answers.
  String commandReply;

  /// What the follow-up asker answers.
  String questionReply;

  final List<List<AiMessage>> received = [];

  @override
  String get name => 'Role';

  @override
  String get model => 'role-1';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<AiChunk> chat(List<AiMessage> messages) async* {
    received.add(messages);
    final system = messages.first.text;
    final reply = system.contains('turn what someone says into one')
        ? commandReply
        : system.contains('listening to someone')
        ? questionReply
        : 'Written: ${messages.last.text}';

    yield const AiChunk.first();
    yield AiChunk.token(reply);
    yield const AiChunk.finished();
  }

  @override
  Future<void> dispose() async {}
}

/// Records what would have been spoken instead of talking to SAPI.
class _RecordingSpeech extends SpeechService {
  _RecordingSpeech() : super(channel: null);

  final List<String> spoken = [];

  @override
  Future<bool> speak(String text) async {
    spoken.add(text);
    return true;
  }
}

/// Keeps the behaviour switches in memory.
///
/// The real store writes to shared preferences, whose platform channel never
/// answers in a widget test, so awaiting a save there hangs the test.
class _MemoryBehaviourStore extends VoiceBehaviourStore {
  VoiceSettings saved = const VoiceSettings();

  @override
  Future<VoiceSettings> load() async => saved;

  @override
  Future<void> save(VoiceSettings settings) async => saved = settings;
}

void main() {
  late NoteStore store;
  late AppRequestMailbox mailbox;

  final day = DateTime(2026, 4, 2);

  setUp(() async {
    store = NoteStore.instance;
    await store.attachRepository(MemoryNoteRepository(), seedSamples: false);
    mailbox = AppRequestMailbox();
  });

  Future<Widget> pane({
    required WidgetTester tester,
    required VoiceController voice,
    required AiController ai,
    SpeechService? speech,
  }) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final queue = ComposeQueue(store: store, ai: ai);
    // Retried held entries use a timer, so the queue is closed with the test.
    addTearDown(queue.dispose);

    return AiScope(
      controller: ai,
      child: ComposeScope(
        queue: queue,
        child: AppRequestScope(
          mailbox: mailbox,
          child: VoiceScope(
            controller: voice,
            child: MaterialApp(
              theme: ThemeData.dark(),
              home: Scaffold(
                body: NoteEditorPane(day: day, embedded: true, speech: speech),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('the transcript grows while the person is still talking', (
    tester,
  ) async {
    final voice = VoiceController(
      behaviour: _MemoryBehaviourStore(),
      engine: FakeVoiceEngine(
        transcript: 'And then I went home.',
        liveChunks: const ['I walked', 'I walked down to the river'],
      ),
    );
    final ai = AiController(initialProvider: _RoleProvider());

    await tester.pumpWidget(
      await pane(tester: tester, voice: voice, ai: ai),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Speak a thought'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-record-button')));
    // Let the chunk arrive and the model answer it: the question is an
    // asynchronous round-trip behind the recording.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 100));

    // The words arrive before the recording ends.
    expect(find.text('I walked down to the river'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('voice-stop-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The final pass replaces them with the complete transcript.
    expect(find.text('And then I went home.'), findsOneWidget);
  });

  testWidgets('words already settled read in full ink, the newest in a softer one', (
    tester,
  ) async {
    final voice = VoiceController(
      behaviour: _MemoryBehaviourStore(),
      engine: FakeVoiceEngine(
        transcript: 'Then I went home.',
        liveChunks: const ['I walked down', 'I walked down to the river'],
        liveSettled: 1,
      ),
    );
    final ai = AiController(initialProvider: _RoleProvider());

    await tester.pumpWidget(
      await pane(tester: tester, voice: voice, ai: ai),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Speak a thought'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-record-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 100));

    // The transcript box is one rich span: the settled part, then the sentence
    // still being spoken, which is painted with some transparency. Flattened,
    // because Text.rich wraps the span it is given in another.
    final live = tester.widget<RichText>(
      find.descendant(
        of: find.byKey(const ValueKey('live-transcript')),
        matching: find.byType(RichText),
      ),
    );
    final spans = <TextSpan>[];
    void walk(InlineSpan span) {
      if (span is! TextSpan) return;
      if (span.text != null) spans.add(span);
      for (final child in span.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }

    walk(live.text);

    expect(spans, hasLength(2));
    expect(spans[0].text, 'I walked down ');
    expect(spans[1].text, 'to the river');

    final settledColor = spans[0].style?.color;
    final formingColor = spans[1].style?.color;
    expect(settledColor, isNotNull);
    expect(
      formingColor!.a,
      lessThan(settledColor!.a),
      reason: 'the newest words are softer until a pause settles them',
    );

    await tester.tap(find.byKey(const ValueKey('voice-stop-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('a follow-up question is shown, and answering extends the same entry', (
    tester,
  ) async {
    final voice = VoiceController(
      behaviour: _MemoryBehaviourStore(),
      engine: FakeVoiceEngine(
        transcript: 'I met someone by the river.',
        liveChunks: const ['I met someone by the river again today'],
      ),
    );
    final provider = _RoleProvider(questionReply: 'Who was that?');
    final ai = AiController(initialProvider: provider);

    await tester.pumpWidget(
      await pane(tester: tester, voice: voice, ai: ai),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Speak a thought'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-record-button')));
    // Let the chunk arrive and the model answer it: the question is an
    // asynchronous round-trip behind the recording.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 100));


    expect(find.byKey(const ValueKey('follow-up-question')), findsOneWidget);
    expect(find.text('Who was that?'), findsOneWidget);

    // Skipping it is harmless.
    await tester.tap(find.byTooltip('Skip the question'));
    await tester.pump();
    expect(find.byKey(const ValueKey('follow-up-question')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('voice-stop-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('with questions switched off the AI is never asked', (
    tester,
  ) async {
    final voice = VoiceController(
      behaviour: _MemoryBehaviourStore(),
      engine: FakeVoiceEngine(
        transcript: 'I met someone by the river.',
        liveChunks: const ['I met someone by the river again today'],
      ),
    );
    await voice.updateVoiceSettings(
      voice.voiceSettings.copyWith(followUpsEnabled: false),
    );
    final provider = _RoleProvider(questionReply: 'Who was that?');
    final ai = AiController(initialProvider: provider);

    await tester.pumpWidget(
      await pane(tester: tester, voice: voice, ai: ai),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Speak a thought'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-record-button')));
    // Let the chunk arrive and the model answer it: the question is an
    // asynchronous round-trip behind the recording.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('follow-up-question')), findsNothing);
    expect(
      provider.received.any(
        (m) => m.first.text.contains('listening to someone'),
      ),
      isFalse,
    );

    await tester.tap(find.byKey(const ValueKey('voice-stop-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('a command is carried out instead of becoming a note', (
    tester,
  ) async {
    final voice = VoiceController(
      behaviour: _MemoryBehaviourStore(),
      engine: FakeVoiceEngine(transcript: 'Search my notes for the trip.'),
    );
    final provider = _RoleProvider(
      commandReply: '{"intent":"search","value":"the trip"}',
    );
    final ai = AiController(initialProvider: provider);

    await tester.pumpWidget(
      await pane(tester: tester, voice: voice, ai: ai),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Speak a thought'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-record-button')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('voice-stop-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The sheet closed itself and asked the app to search.
    expect(find.text('Search my notes for the trip.'), findsNothing);
    final request = mailbox.take();
    expect(request?.action, AppAction.searchAll);
    expect(request?.query, 'the trip');
    expect(store.allNotes, isEmpty, reason: 'nothing was written down');
  });

  testWidgets('a delete waits for confirmation, and speaks when asked to', (
    tester,
  ) async {
    store.appendToDay(day, 'I went for a long walk by the river.');

    final voice = VoiceController(
      behaviour: _MemoryBehaviourStore(),
      engine: FakeVoiceEngine(transcript: 'Delete the walk one.'),
    );
    await voice.updateVoiceSettings(
      voice.voiceSettings.copyWith(speakQuestions: true),
    );
    final provider = _RoleProvider(
      commandReply: '{"intent":"delete_entry","value":"walk"}',
    );
    final ai = AiController(initialProvider: provider);
    final speech = _RecordingSpeech();

    await tester.pumpWidget(
      await pane(tester: tester, voice: voice, ai: ai, speech: speech),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Speak a thought'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-record-button')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('voice-stop-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Nothing deleted yet; the sheet is asking.
    expect(find.byKey(const ValueKey('confirm-command-button')), findsOneWidget);
    expect(store.noteOrEmpty(day).sectionCount, 1);
    expect(speech.spoken, isNotEmpty, reason: 'read aloud, as asked');
    expect(speech.spoken.last, contains('Delete'));

    // Saying no leaves the entry alone.
    await tester.tap(find.text('No, leave it'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(store.noteOrEmpty(day).sectionCount, 1);
  });

  testWidgets('confirming the delete actually deletes it', (tester) async {
    store.appendToDay(day, 'I went for a long walk by the river.');

    final voice = VoiceController(
      behaviour: _MemoryBehaviourStore(),
      engine: FakeVoiceEngine(transcript: 'Delete the walk one.'),
    );
    final provider = _RoleProvider(
      commandReply: '{"intent":"delete_entry","value":"walk"}',
    );
    final ai = AiController(initialProvider: provider);

    await tester.pumpWidget(
      await pane(tester: tester, voice: voice, ai: ai),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Speak a thought'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-record-button')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('voice-stop-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byKey(const ValueKey('confirm-command-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(store.noteOrEmpty(day).isEmpty, isTrue);
  });

  testWidgets('with commands switched off the words become a note', (
    tester,
  ) async {
    final voice = VoiceController(
      behaviour: _MemoryBehaviourStore(),
      engine: FakeVoiceEngine(transcript: 'Search my notes for the trip.'),
    );
    await voice.updateVoiceSettings(
      voice.voiceSettings.copyWith(commandsEnabled: false),
    );
    final provider = _RoleProvider(
      commandReply: '{"intent":"search","value":"the trip"}',
    );
    final ai = AiController(initialProvider: provider);

    await tester.pumpWidget(
      await pane(tester: tester, voice: voice, ai: ai),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Speak a thought'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-record-button')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('voice-stop-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // It is offered for review, not acted on.
    expect(find.byKey(const ValueKey('transcript-field')), findsOneWidget);
    expect(mailbox.pending, isNull);
    expect(
      provider.received.any(
        (m) => m.first.text.contains('turn what someone says into one'),
      ),
      isFalse,
    );
  });
  testWidgets('a pause during capture is recorded for tuning the pause length', (
    tester,
  ) async {
    final traces = _MemoryTraceStore();
    final voice = VoiceController(
      behaviour: _MemoryBehaviourStore(),
      trace: traces,
      engine: FakeVoiceEngine(
        transcript: 'I wanted to ask you about the job.',
        liveChunks: const ['I wanted to ask you about'],
        liveSettled: 1,
        liveCuts: const [
          ChunkCut(
            pause: Duration(milliseconds: 700),
            before: 'We got there late',
            after: 'and the place was shut',
          ),
        ],
      ),
    );
    final ai = AiController(initialProvider: _RoleProvider());

    await tester.pumpWidget(
      await pane(tester: tester, voice: voice, ai: ai),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Speak a thought'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-record-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The join looks cut mid-sentence, so it is kept as evidence.
    expect(voice.pauseTrace.boundaries, 1);
    expect(voice.pauseTrace.evidence, hasLength(1));
    expect(voice.pauseTrace.evidence.single.pause, const Duration(milliseconds: 700));

    await tester.tap(find.byKey(const ValueKey('voice-stop-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  });
  testWidgets('leaving the app stops the recording but keeps the words', (
    tester,
  ) async {
    final engine = FakeVoiceEngine(
      transcript: 'Half a thought',
      liveChunks: const ['Half a thought'],
    );
    final voice = VoiceController(
      behaviour: _MemoryBehaviourStore(),
      engine: engine,
    );
    final ai = AiController(initialProvider: _RoleProvider());

    await tester.pumpWidget(
      await pane(tester: tester, voice: voice, ai: ai),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Speak a thought'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-record-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(engine.recording, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The microphone is released, and what was heard is offered for review
    // rather than thrown away or written down on its own.
    expect(engine.recording, isFalse);
    expect(store.allNotes, isEmpty);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });
}

/// Keeps the pause evidence in memory, since preferences never answer here.
class _MemoryTraceStore extends PauseTraceStore {
  PauseTrace saved = const PauseTrace();

  @override
  Future<PauseTrace> load() async => saved;

  @override
  Future<void> save(PauseTrace trace) async => saved = trace;
}



