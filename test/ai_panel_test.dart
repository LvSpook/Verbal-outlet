import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:verbal_outlet/ai/ai_controller.dart';
import 'package:verbal_outlet/ai/ai_provider.dart';
import 'package:verbal_outlet/ai/ai_scope.dart';
import 'package:verbal_outlet/models/day_note.dart';
import 'package:verbal_outlet/theme.dart';
import 'package:verbal_outlet/widgets/ai/ai_panel.dart';
import 'package:verbal_outlet/widgets/ai/chart_view.dart';
import 'package:verbal_outlet/widgets/ai/diagram_view.dart';

/// Answers with a fixed reply, a few characters at a time.
class _FakeProvider implements AiProvider {
  _FakeProvider(this.reply);

  final String reply;
  final List<List<AiMessage>> received = [];

  @override
  String get name => 'Fake';

  @override
  String get model => 'fake-1';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<AiChunk> chat(List<AiMessage> messages) async* {
    received.add(messages);
    yield const AiChunk.first();
    for (var i = 0; i < reply.length; i += 8) {
      yield AiChunk.token(reply.substring(i, (i + 8).clamp(0, reply.length)));
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    yield const AiChunk.finished();
  }

  @override
  Future<void> dispose() async {}
}

DayNote _note() => DayNote(
  day: DateTime(2026, 11, 22),
  sections: [
    NoteSection(
      id: 'a',
      createdAt: DateTime(2026, 11, 22, 9, 30),
      text: 'Slept badly, then had a long day at work.',
    ),
  ],
);

Widget _app(AiController controller) {
  return AiScope(
    controller: controller,
    child: MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(body: AiPanel(note: _note())),
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shows an empty state before anything is asked', (tester) async {
    final controller = AiController(initialProvider: _FakeProvider('hi'));
    await tester.pumpWidget(_app(controller));

    expect(find.text('Think it back over'), findsOneWidget);
    expect(find.text('Reflect on this'), findsOneWidget);
  });

  testWidgets('streams an answer and sends the note to the provider', (
    tester,
  ) async {
    final provider = _FakeProvider('You slept badly. Be gentle with yourself.');
    final controller = AiController(initialProvider: provider);
    await tester.pumpWidget(_app(controller));

    await tester.tap(find.text('Reflect on this'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Be gentle'), findsOneWidget);
    expect(provider.received, hasLength(1));
    final messages = provider.received.single;
    expect(messages.first.role, AiRole.system);
    expect(messages.last.text, contains('long day at work'));
  });

  testWidgets('renders a chart instead of printing the JSON', (tester) async {
    const reply =
        '```chart\n'
        '{"type":"bar","title":"Hours slept","labels":["Mon"],"values":[6]}\n'
        '```';
    final controller = AiController(initialProvider: _FakeProvider(reply));
    await tester.pumpWidget(_app(controller));

    await tester.tap(find.text('Chart my numbers'));
    await tester.pumpAndSettle();

    expect(find.byType(ChartView), findsOneWidget);
    expect(find.text('Hours slept'), findsOneWidget);
    expect(find.textContaining('"type"'), findsNothing);
  });

  testWidgets('renders a diagram from dot', (tester) async {
    const reply =
        '```dot\n'
        'digraph g { a [label="Sleep"]; b [label="Focus"]; a -> b; }\n'
        '```';
    final controller = AiController(initialProvider: _FakeProvider(reply));
    await tester.pumpWidget(_app(controller));

    await tester.tap(find.text('Draw a diagram'));
    await tester.pumpAndSettle();

    expect(find.byType(DiagramView), findsOneWidget);
    expect(find.textContaining('digraph'), findsNothing);
  });

  testWidgets('asks a typed question', (tester) async {
    final provider = _FakeProvider('A short answer.');
    final controller = AiController(initialProvider: provider);
    await tester.pumpWidget(_app(controller));

    await tester.enterText(find.byType(TextField), 'What was I worried about?');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(find.text('A short answer.'), findsOneWidget);
    expect(
      provider.received.single.last.text,
      contains('What was I worried about?'),
    );
  });
}
