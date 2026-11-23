import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:verbal_outlet/data/note_export.dart';
import 'package:verbal_outlet/data/note_import.dart';
import 'package:verbal_outlet/data/note_repository.dart';
import 'package:verbal_outlet/data/note_store.dart';
import 'package:verbal_outlet/data/storage_tools.dart';
import 'package:verbal_outlet/models/day_note.dart';
import 'package:verbal_outlet/screens/sync_screen.dart';
import 'package:verbal_outlet/sync/lan_transport.dart';
import 'package:verbal_outlet/sync/sync_controller.dart';
import 'package:verbal_outlet/sync/sync_crypto.dart';
import 'package:verbal_outlet/sync/sync_models.dart';
import 'package:verbal_outlet/voice/pause_trace.dart';
import 'package:verbal_outlet/voice/voice_controller.dart';
import 'package:verbal_outlet/voice/voice_scope.dart';
import 'package:verbal_outlet/voice/voice_settings.dart';

import 'support/fake_voice_engine.dart';

/// A controller that never opens a socket, so tests are fast and repeatable.
Future<SyncController> _controller() async {
  SharedPreferences.setMockInitialValues({});
  final store = NoteStore.forTesting(MemoryNoteRepository());
  await store.attachRepository(MemoryNoteRepository());
  final controller = SyncController(
    noteStore: store,
    listen: false,
    addressesOverride: const [LocalAddress('192.168.1.10', 'Wi-Fi')],
  );
  await controller.init();
  return controller;
}

Future<void> _pump(WidgetTester tester, SyncController controller) async {
  tester.view.physicalSize = const Size(900, 1100);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: SyncScreen(controller: controller),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('shows the pairing code and the Wi-Fi limitation', (
    tester,
  ) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Pair a device'), findsOneWidget);
    expect(find.text('Scan a code instead'), findsOneWidget);
    expect(
      find.textContaining('same Wi-Fi at the same time'),
      findsOneWidget,
    );
    expect(find.text('Export'), findsOneWidget);
  });

  testWidgets('with no devices, says so and hides Sync now', (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    expect(find.textContaining('Nothing paired yet'), findsOneWidget);
    expect(find.text('Sync now'), findsNothing);
  });

  testWidgets('a paired device is listed with its own sync button', (
    tester,
  ) async {
    final controller = await _controller();
    addTearDown(controller.dispose);

    final code = PairingCode(
      deviceId: 'phone-1',
      deviceName: "Luke's phone",
      host: '192.168.1.20',
      port: 47821,
      secret: SyncCrypto.newKey(),
    );
    await controller.beginPairing(code);
    await _pump(tester, controller);

    expect(find.text("Luke's phone"), findsOneWidget);
    expect(find.textContaining('Paired, not synced yet'), findsOneWidget);
    expect(find.text('Sync now'), findsOneWidget);
    expect(find.textContaining('Nothing paired yet'), findsNothing);
  });

  testWidgets('forgetting the last device returns to the empty state', (
    tester,
  ) async {
    final controller = await _controller();
    addTearDown(controller.dispose);

    await controller.beginPairing(
      PairingCode(
        deviceId: 'phone-1',
        deviceName: "Luke's phone",
        host: '192.168.1.20',
        port: 47821,
        secret: SyncCrypto.newKey(),
      ),
    );
    await _pump(tester, controller);

    await tester.tap(find.byTooltip('Forget this device'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('Nothing paired yet'), findsOneWidget);
    expect(find.text("Luke's phone"), findsNothing);
  });

  testWidgets('the auto-sync switch is saved', (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);

    await controller.beginPairing(
      PairingCode(
        deviceId: 'phone-1',
        deviceName: "Luke's phone",
        host: '192.168.1.20',
        port: 47821,
        secret: SyncCrypto.newKey(),
      ),
    );
    await _pump(tester, controller);

    expect(controller.autoSync, isTrue);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(controller.autoSync, isFalse);
  });

  testWidgets('export buttons are disabled when there is nothing to export', (
    tester,
  ) async {
    // A store with no notes, so the export section has nothing to offer.
    await NoteStore.instance.attachRepository(
      MemoryNoteRepository(),
      seedSamples: false,
    );

    final controller = await _controller();
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    final markdown = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Export all as Markdown'),
    );
    expect(markdown.onPressed, isNull);
  });

  testWidgets('exporting everything writes a file and says where', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('vo-settings-export-');
    addTearDown(() => temp.deleteSync(recursive: true));

    await NoteStore.instance.attachRepository(
      MemoryNoteRepository(),
      seedSamples: false,
    );
    NoteStore.instance.appendToDay(DateTime(2026, 4, 1), 'A note to export.');

    final controller = await _controller();
    addTearDown(controller.dispose);

    // A fake exporter rather than a real one: this test is about the button
    // asking for the right notes and reporting the result, and real disk I/O
    // under the fake clock is what made the earlier version hang.
    final exporter = _FakeExporter(temp);
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: SyncScreen(controller: controller, exporter: exporter),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Export all as Markdown'));
    await tester.pumpAndSettle();

    expect(exporter.formats, [ExportFormat.markdown]);
    expect(exporter.exportedTexts, [['A note to export.']]);
    expect(find.textContaining('Saved Verbal Outlet'), findsOneWidget);
  });

  testWidgets('importing a file merges it and says what changed', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('vo-settings-import-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final file = File('${temp.path}/notes.json')..writeAsStringSync('{}');

    await NoteStore.instance.attachRepository(
      MemoryNoteRepository(),
      seedSamples: false,
    );

    final controller = await _controller();
    addTearDown(controller.dispose);

    // Reads the picked file itself, without the disk I/O a real read does.
    final importer = _FakeImporter(
      '{"notes":[{"day":"2026-5-6","sections":[{"id":"x",'
      '"createdAt":"2026-05-06T10:00:00.000","text":"Imported thought."}]}]}',
    );

    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: SyncScreen(
          controller: controller,
          // The picker is a test seam: no file dialog in a unit test.
          pickFile: () async => XFile(file.path),
          importer: importer,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Import from a JSON file'));
    // Not pumpAndSettle: the button shows an indeterminate spinner while the
    // import runs, which would never settle.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(
      NoteStore.instance.noteFor(DateTime(2026, 5, 6))!.body,
      'Imported thought.',
    );
    expect(find.textContaining('1 entry added'), findsOneWidget);
  });

  testWidgets('storage card shows usage and can clean up', (tester) async {
    await NoteStore.instance.attachRepository(
      MemoryNoteRepository(),
      seedSamples: false,
    );
    NoteStore.instance.appendToDay(DateTime(2026, 3, 1), 'A thought.');
    NoteStore.instance.applyRemoteSection(
      DateTime(2026, 3, 1),
      NoteSection(
        id: 'old-delete',
        createdAt: DateTime.now().subtract(const Duration(days: 200)),
        updatedAt: DateTime.now().subtract(const Duration(days: 200)),
        text: '',
        deleted: true,
      ),
    );

    final controller = await _controller();
    addTearDown(controller.dispose);

    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: SyncScreen(controller: controller, storage: const StorageTools()),
      ),
    );
    await tester.pump();
    // The measurement touches the disk, so let its future complete.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Storage'), findsOneWidget);
    expect(find.text('On disk'), findsOneWidget);
    expect(find.textContaining('1 day'), findsOneWidget);
    expect(find.textContaining('being kept for 90 days'), findsOneWidget);

    await tester.tap(find.text('Clean up old deleted entries'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.textContaining('Removed 1 old deleted entry'), findsOneWidget);
    expect(find.textContaining('being kept for 90 days'), findsNothing);
  });

  testWidgets('cancelling the picker does nothing at all', (tester) async {
    await NoteStore.instance.attachRepository(
      MemoryNoteRepository(),
      seedSamples: false,
    );

    final controller = await _controller();
    addTearDown(controller.dispose);

    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: SyncScreen(
          controller: controller,
          pickFile: () async => null,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Import from a JSON file'));
    await tester.pumpAndSettle();

    // No snack bar, no notes, no error: a cancel is not a failure.
    expect(NoteStore.instance.allNotes, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('the voice card offers a download when no model is present', (
    tester,
  ) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    final voice = VoiceController(engine: FakeVoiceEngine(ready: false));
    await voice.refresh();

    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      VoiceScope(
        controller: voice,
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: SyncScreen(controller: controller),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Voice'), findsOneWidget);
    expect(find.text('Not set up'), findsOneWidget);
    expect(find.text('Download voice model'), findsOneWidget);
    expect(find.text('Delete'), findsNothing);
  });

  testWidgets('the voice card says a downloaded model is ready', (
    tester,
  ) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    final voice = VoiceController(engine: FakeVoiceEngine(ready: true));
    await voice.refresh();

    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      VoiceScope(
        controller: voice,
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: SyncScreen(controller: controller),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Ready'), findsOneWidget);
    expect(find.textContaining('is downloaded'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
  });

  testWidgets('the behaviour switches flip and are saved', (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);

    final behaviour = _MemoryBehaviourStore();
    final voice = VoiceController(
      engine: FakeVoiceEngine(ready: true),
      behaviour: behaviour,
    );
    await voice.load();

    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      VoiceScope(
        controller: voice,
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: SyncScreen(controller: controller),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.scrollUntilVisible(
      find.text('Voice commands'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    SwitchListTile tileFor(String title) => tester.widget<SwitchListTile>(
      find.ancestor(
        of: find.text(title),
        matching: find.byType(SwitchListTile),
      ),
    );

    // The defaults: both behaviours on, speaking off.
    expect(tileFor('Voice commands').value, isTrue);
    expect(tileFor('Ask a question mid-thought').value, isTrue);
    expect(tileFor('Read questions out loud').value, isFalse);

    await tester.tap(find.text('Voice commands'));
    await tester.pump();
    expect(voice.voiceSettings.commandsEnabled, isFalse);
    expect(behaviour.saved.commandsEnabled, isFalse);

    await tester.tap(find.text('Ask a question mid-thought'));
    await tester.pump();
    expect(voice.voiceSettings.followUpsEnabled, isFalse);
    expect(tileFor('Read questions out loud').onChanged, isNull);

    // With questions off, speaking them is meaningless, so it stays off.
    expect(tileFor('Read questions out loud').value, isFalse);
  });

  testWidgets('speaking questions can be switched on independently', (
    tester,
  ) async {
    final controller = await _controller();
    addTearDown(controller.dispose);

    final behaviour = _MemoryBehaviourStore();
    final voice = VoiceController(
      engine: FakeVoiceEngine(ready: true),
      behaviour: behaviour,
    );
    await voice.load();

    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      VoiceScope(
        controller: voice,
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: SyncScreen(controller: controller),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.scrollUntilVisible(
      find.text('Read questions out loud'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    await tester.tap(find.text('Read questions out loud'));
    await tester.pump();

    expect(voice.voiceSettings.speakQuestions, isTrue);
    expect(behaviour.saved.speakQuestions, isTrue);
  });
  testWidgets('the pause slider changes the setting and saves it', (
    tester,
  ) async {
    final controller = await _controller();
    addTearDown(controller.dispose);

    final behaviour = _MemoryBehaviourStore();
    final voice = VoiceController(
      engine: FakeVoiceEngine(ready: true),
      behaviour: behaviour,
    );
    await voice.load();

    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      VoiceScope(
        controller: voice,
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: SyncScreen(controller: controller),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.scrollUntilVisible(
      find.text('Pause before a sentence ends'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    // The default reads as a plain number of seconds.
    expect(find.text('0.70 s'), findsOneWidget);
    expect(voice.voiceSettings.pauseAfterSpeech.inMilliseconds, 700);

    // Dragging the slider to its end gives the longest pause on offer.
    await tester.drag(find.byType(Slider), const Offset(500, 0));
    await tester.pumpAndSettle();

    expect(
      voice.voiceSettings.pauseAfterSpeech,
      VoiceSettings.maxPauseAfterSpeech,
    );
    expect(behaviour.saved.pauseAfterSpeech, VoiceSettings.maxPauseAfterSpeech);

    await tester.drag(find.byType(Slider), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(
      voice.voiceSettings.pauseAfterSpeech,
      VoiceSettings.minPauseAfterSpeech,
    );
  });

  testWidgets('a suggestion can be taken or waved away', (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);

    final behaviour = _MemoryBehaviourStore();
    final traces = _MemoryTraceStore(
      PauseTrace(
        boundaries: 20,
        suggested: const Duration(milliseconds: 1150),
      ),
    );
    final voice = VoiceController(
      engine: FakeVoiceEngine(ready: true),
      behaviour: behaviour,
      trace: traces,
    );
    await voice.load();

    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      VoiceScope(
        controller: voice,
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: SyncScreen(controller: controller),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.scrollUntilVisible(
      find.text('Use it'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    expect(find.textContaining('split mid-thought'), findsOneWidget);

    await tester.tap(find.text('Use it'));
    await tester.pumpAndSettle();

    expect(
      voice.voiceSettings.pauseAfterSpeech,
      const Duration(milliseconds: 1150),
    );
    expect(behaviour.saved.pauseAfterSpeech, const Duration(milliseconds: 1150));
    expect(find.text('Use it'), findsNothing, reason: 'advice was taken');
  });

  testWidgets('saying no keeps the setting and stops the offer', (
    tester,
  ) async {
    final controller = await _controller();
    addTearDown(controller.dispose);

    final traces = _MemoryTraceStore(
      PauseTrace(
        boundaries: 20,
        suggested: const Duration(milliseconds: 1150),
      ),
    );
    final voice = VoiceController(
      engine: FakeVoiceEngine(ready: true),
      behaviour: _MemoryBehaviourStore(),
      trace: traces,
    );
    await voice.load();

    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      VoiceScope(
        controller: voice,
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: SyncScreen(controller: controller),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.scrollUntilVisible(
      find.text('No thanks'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(find.text('No thanks'));
    await tester.pumpAndSettle();

    expect(voice.voiceSettings.pauseAfterSpeech.inMilliseconds, 700);
    expect(voice.pauseSuggestion, isNull);
    expect(find.text('No thanks'), findsNothing);
    expect(traces.saved.dismissed, isTrue);
  });
}

/// Keeps the pause evidence in memory instead of in shared preferences.
class _MemoryTraceStore extends PauseTraceStore {
  _MemoryTraceStore(this.initial);

  final PauseTrace initial;
  PauseTrace saved = const PauseTrace();

  @override
  Future<PauseTrace> load() async => initial;

  @override
  Future<void> save(PauseTrace trace) async => saved = trace;
}
/// whose platform channel never answers under the test clock.
class _MemoryBehaviourStore extends VoiceBehaviourStore {
  VoiceSettings saved = const VoiceSettings();

  @override
  Future<VoiceSettings> load() async => saved;

  @override
  Future<void> save(VoiceSettings settings) async => saved = settings;
}

/// Records what it was asked to export and pretends to write a file.
class _FakeExporter extends NoteExporter {
  _FakeExporter(this.directory) : super(directory: directory);

  final Directory directory;
  final List<ExportFormat> formats = [];
  final List<List<String>> exportedTexts = [];

  @override
  Future<File> exportAll(
    Iterable<DayNote> notes, {
    ExportFormat format = ExportFormat.markdown,
  }) async {
    formats.add(format);
    exportedTexts.add([
      for (final note in notes)
        for (final section in note.visible) section.text,
    ]);
    return File('${directory.path}/Verbal Outlet - all notes.md');
  }
}

/// Merges a fixed string instead of reading the file, so the test does not
/// depend on real disk I/O under the fake clock.
class _FakeImporter extends NoteImporter {
  const _FakeImporter(this.json);

  final String json;

  @override
  Future<ImportReport> importFile(File file, {NoteStore? store}) =>
      importText(json, fileName: 'notes.json', store: store);
}

