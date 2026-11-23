import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:verbal_outlet/capture/capture_request.dart';
import 'package:verbal_outlet/capture/capture_scope.dart';
import 'package:verbal_outlet/ai/ai_controller.dart';
import 'package:verbal_outlet/ai/compose_queue.dart';
import 'package:verbal_outlet/ai/compose_scope.dart';
import 'package:verbal_outlet/data/note_repository.dart';
import 'package:verbal_outlet/data/note_store.dart';
import 'package:verbal_outlet/screens/home_screen.dart';
import 'package:verbal_outlet/widgets/note_editor_pane.dart';

import 'support/fake_composer_provider.dart';

/// The app shell with a fake model, so a capture can actually be written up.
Widget _shell(CaptureRequest request, Widget child) {
  final ai = AiController(initialProvider: FakeComposerProvider());
  final queue = ComposeQueue(store: NoteStore.instance, ai: ai);
  // The queue retries held entries on a timer, which must not outlive the test.
  addTearDown(queue.dispose);
  return ComposeScope(
    queue: queue,
    child: CaptureScope(request: request, child: child),
  );
}

/// A wide window, so the home screen takes the split layout with a note pane.
Future<void> _pumpSplit(WidgetTester tester, CaptureRequest request) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: _shell(request, const HomeScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

/// A narrow window, where the note is a page instead of a pane.
Future<void> _pumpNarrow(WidgetTester tester, CaptureRequest request) async {
  tester.view.physicalSize = const Size(500, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: _shell(request, const HomeScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    await NoteStore.instance.attachRepository(
      MemoryNoteRepository(),
      seedSamples: false,
    );
  });

  group('the request', () {
    test('starts with nothing pending', () {
      final request = CaptureRequest();
      expect(request.isPending, isFalse);
      expect(request.consume(), CaptureTrigger.normal);
    });

    test('capture waits until it is consumed', () {
      final request = CaptureRequest();
      request.capture();
      expect(request.isPending, isTrue);
      expect(request.consume(), CaptureTrigger.quick);
      // Consuming twice must not fire twice.
      expect(request.consume(), CaptureTrigger.normal);
    });

    test('notifies listeners, so a live screen reacts', () {
      final request = CaptureRequest();
      var calls = 0;
      request.addListener(() => calls++);
      request.capture();
      expect(calls, 1);
    });
  });

  group('quick capture', () {
    testWidgets('pressing the header button opens today with the cursor ready', (
      tester,
    ) async {
      await _pumpSplit(tester, CaptureRequest());

      // Nothing open yet.
      expect(find.text('Pick a day'), findsOneWidget);

      await tester.tap(find.text('New thought').first);
      await tester.pumpAndSettle();

      // Today's note is now open in the pane.
      expect(find.byType(NoteEditorPane), findsOneWidget);
      expect(find.text('Pick a day'), findsNothing);

      // The composer has focus: typing goes straight into it.
      final composer = find.byKey(composerFieldKey);
      expect(tester.widget<TextField>(composer).focusNode?.hasFocus, isTrue);
    });

    testWidgets('a pending capture is acted on when the screen appears', (
      tester,
    ) async {
      // The state a cold start from a home-screen shortcut produces: the
      // request is already waiting before any UI exists.
      final request = CaptureRequest()..capture();
      await _pumpSplit(tester, request);

      expect(request.isPending, isFalse);
      expect(find.byType(NoteEditorPane), findsOneWidget);
    });

    testWidgets('a capture arrives while a note is already open', (
      tester,
    ) async {
      final request = CaptureRequest();
      await _pumpSplit(tester, request);

      // Open a different day first.
      final today = DateTime.now().day.toString();
      await tester.tap(find.text(today).last);
      await tester.pumpAndSettle();
      expect(find.byType(NoteEditorPane), findsOneWidget);

      // Now a hotkey press.
      request.capture();
      await tester.pumpAndSettle();

      expect(find.byType(NoteEditorPane), findsOneWidget);
      final composer = find.byKey(composerFieldKey);
      expect(tester.widget<TextField>(composer).focusNode?.hasFocus, isTrue);
    });

    testWidgets('on a narrow window a capture opens the full note page', (
      tester,
    ) async {
      final request = CaptureRequest();
      await _pumpNarrow(tester, request);

      request.capture();
      await tester.pumpAndSettle();

      expect(find.byType(NoteEditorPane), findsOneWidget);
      expect(find.byTooltip('Back to calendar'), findsOneWidget);
    });

    testWidgets('typing into a capture lands in today\'s note', (tester) async {
      await _pumpSplit(tester, CaptureRequest());

      await tester.tap(find.text('New thought').first);
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(composerFieldKey), 'Captured quickly.');
      await tester.tap(find.text('Write it up'));
      await tester.pumpAndSettle();

      final note = NoteStore.instance.noteFor(DateTime.now());
      expect(note, isNotNull);
      expect(note!.body, 'Written: Captured quickly.');
    });
  });
}
