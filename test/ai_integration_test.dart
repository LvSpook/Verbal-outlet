import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:verbal_outlet/ai/ai_controller.dart';
import 'package:verbal_outlet/ai/ai_provider.dart';
import 'package:verbal_outlet/ai/ai_scope.dart';
import 'package:verbal_outlet/data/note_store.dart';
import 'package:verbal_outlet/screens/ai_settings_screen.dart';
import 'package:verbal_outlet/theme.dart';
import 'package:verbal_outlet/widgets/ai/ai_panel.dart';
import 'package:verbal_outlet/widgets/note_editor_pane.dart';

class _SilentProvider implements AiProvider {
  @override
  String get name => 'Fake';

  @override
  String get model => 'fake-1';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<AiChunk> chat(List<AiMessage> messages) async* {
    yield const AiChunk.first();
    yield const AiChunk.token('ok');
    yield const AiChunk.finished();
  }

  @override
  Future<void> dispose() async {}
}

Widget _wrap(Widget child, AiController controller) => AiScope(
  controller: controller,
  child: MaterialApp(theme: AppTheme.dark(), home: child),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the header button opens and closes the assistant', (
    tester,
  ) async {
    final controller = AiController(initialProvider: _SilentProvider());
    final day = dateOnly(DateTime.now());

    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrap(
        Scaffold(body: NoteEditorPane(day: day, embedded: true)),
        controller,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AiPanel), findsNothing);

    await tester.tap(find.byTooltip('Ask the assistant'));
    await tester.pumpAndSettle();

    expect(find.byType(AiPanel), findsOneWidget);
    // The note stays visible beside it in a wide pane.
    expect(find.textContaining('Quiet day'), findsOneWidget);

    await tester.tap(find.byTooltip('Close assistant'));
    await tester.pumpAndSettle();
    expect(find.byType(AiPanel), findsNothing);
  });

  testWidgets('a narrow pane shows the assistant instead of the note', (
    tester,
  ) async {
    final controller = AiController(initialProvider: _SilentProvider());
    final day = dateOnly(DateTime.now());

    await tester.binding.setSurfaceSize(const Size(420, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrap(Scaffold(body: NoteEditorPane(day: day)), controller),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Ask the assistant'));
    await tester.pumpAndSettle();

    expect(find.byType(AiPanel), findsOneWidget);
    expect(find.textContaining('Quiet day'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings shows both engines and the model list', (tester) async {
    final controller = AiController(initialProvider: _SilentProvider());

    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_wrap(const AiSettingsScreen(), controller));
    // The screen paints immediately; this just lets the settings load and the
    // key-store timeout elapse so no timers outlive the test.
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));

    expect(find.text('AI settings'), findsOneWidget);
    expect(find.text('On this device'), findsWidgets);
    expect(find.text('API key'), findsOneWidget);
    expect(find.text('qwen3:4b'), findsOneWidget);
    expect(find.text('Local model'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The cloud tab shows the API key field and provider presets.
    await tester.tap(find.text('API key'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Cloud model'), findsOneWidget);
    expect(find.text('OpenAI'), findsWidgets);
    expect(find.text('Base URL'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty note still opens the assistant', (tester) async {
    final controller = AiController(initialProvider: _SilentProvider());
    final emptyDay = dateOnly(DateTime.now())
        .subtract(const Duration(days: 40));

    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrap(
        Scaffold(body: NoteEditorPane(day: emptyDay, embedded: true)),
        controller,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Ask the assistant'));
    await tester.pumpAndSettle();

    expect(find.byType(AiPanel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
