import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:verbal_outlet/ai/monthly_insight.dart';
import 'package:verbal_outlet/ai/monthly_insight_controller.dart';
import 'package:verbal_outlet/widgets/ai/monthly_insight_card.dart';

MonthlyInsight _insight({
  String body = '## In short\nA quiet month of walks.',
  String revision = 'r1',
}) {
  return MonthlyInsight(
    year: 2026,
    month: 4,
    body: body,
    generatedAt: DateTime(2026, 5, 1),
    revision: revision,
  );
}

Future<void> _pumpCard(
  WidgetTester tester,
  MonthlyInsightState state, {
  DateTime? month,
  bool compact = false,
  VoidCallback? onRegenerate,
}) async {
  tester.view.physicalSize = const Size(700, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: MonthlyInsightCard(
            state: state,
            month: month ?? DateTime(2026, 4),
            compact: compact,
            onRegenerate: onRegenerate ?? () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an overview is shown under its month heading', (tester) async {
    await _pumpCard(
      tester,
      MonthlyInsightState(insight: _insight(), revision: 'r1'),
    );

    expect(find.text('April in review'), findsOneWidget);
    expect(find.text('In short'), findsOneWidget);
    expect(find.text('A quiet month of walks.'), findsOneWidget);
    // The refresh affordance exists once there is something to refresh.
    expect(find.byTooltip('Write the overview again'), findsOneWidget);
  });

  testWidgets('the sidebar uses the short month name', (tester) async {
    await _pumpCard(
      tester,
      MonthlyInsightState(insight: _insight(), revision: 'r1'),
      compact: true,
    );

    expect(find.text('Apr in review'), findsOneWidget);
  });

  testWidgets('a month with no notes shows no card at all', (tester) async {
    await _pumpCard(tester, const MonthlyInsightState(empty: true));

    expect(find.byType(Card), findsNothing);
    expect(find.textContaining('in review'), findsNothing);
  });

  testWidgets('nothing is shown while the first overview is being written', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      const MonthlyInsightState(loading: true, generating: true),
    );

    expect(find.byType(Card), findsNothing);
  });

  testWidgets('an old overview stays visible while a rewrite is in flight', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      MonthlyInsightState(
        insight: _insight(),
        revision: 'r1',
        generating: true,
      ),
    );

    expect(find.text('A quiet month of walks.'), findsOneWidget);
    expect(find.text('Updating this overview…'), findsOneWidget);
  });

  testWidgets('an overview written from older notes says it is out of date', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      MonthlyInsightState(insight: _insight(revision: 'old'), revision: 'new'),
    );

    expect(find.text('The notes have changed since this was written.'), findsOneWidget);
  });

  testWidgets('a failure shows the reason and offers a retry', (tester) async {
    var retried = 0;
    await _pumpCard(
      tester,
      const MonthlyInsightState(
        error: 'The AI is not reachable, so no overview was written yet.',
      ),
      onRegenerate: () => retried++,
    );

    expect(
      find.text('The AI is not reachable, so no overview was written yet.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(retried, 1);
  });

  testWidgets('a failure beside an old overview keeps the old text', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      MonthlyInsightState(
        insight: _insight(),
        revision: 'r1',
        error: 'The AI is not reachable right now.',
      ),
    );

    expect(find.text('A quiet month of walks.'), findsOneWidget);
    expect(find.text('The AI is not reachable right now.'), findsNothing);
  });
}
