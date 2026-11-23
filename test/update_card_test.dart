import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:verbal_outlet/update/update_controller.dart';
import 'package:verbal_outlet/update/update_installer.dart';
import 'package:verbal_outlet/update/update_scope.dart';
import 'package:verbal_outlet/update/updates.dart';
import 'package:verbal_outlet/widgets/update_card.dart';

/// Stands in for the network; answers with whatever the test set.
class _ScriptedService extends UpdateService {
  _ScriptedService(this.answer) : super(owner: 'me', repo: 'app');

  final String? answer;
  final List<String> seen = [];

  @override
  Future<ReleaseInfo?> latest() async {
    if (answer == null) return null;
    return ReleaseInfo(
      version: '1.3.0',
      notes: answer!,
      downloadUrl: 'https://example.com/app.zip',
      publishedAt: null,
    );
  }
}

class _QuietInstaller implements UpdateInstaller {
  final List<String> installed = [];

  @override
  Future<void> install(
    ReleaseInfo release, {
    void Function(double fraction)? progress,
  }) async {
    progress?.call(0.25);
    progress?.call(1);
    installed.add(release.version);
  }
}

Future<void> _pump(
  WidgetTester tester,
  UpdateController controller,
) async {
  tester.view.physicalSize = const Size(700, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UpdateScope(
      controller: controller,
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: const Scaffold(
          body: SingleChildScrollView(child: UpdateCard()),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('with nothing found it says you are up to date', (tester) async {
    final controller = UpdateController(
      service: _ScriptedService(null),
      installer: _QuietInstaller(),
      currentVersionOverride: '1.3.0',
    );

    await _pump(tester, controller);
    await tester.tap(find.text('Check for updates'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('You are up to date.'), findsOneWidget);
    expect(find.text('Update now'), findsNothing);
  });

  testWidgets('a newer version shows its notes and an update button', (
    tester,
  ) async {
    final installer = _QuietInstaller();
    final controller = UpdateController(
      service: _ScriptedService('Faster notes, and charts.'),
      installer: installer,
      currentVersionOverride: '1.2.0',
    );

    await _pump(tester, controller);
    await tester.tap(find.text('Check for updates'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('New'), findsOneWidget);
    expect(find.text('Faster notes, and charts.'), findsOneWidget);
    expect(find.text('Your notes are kept.'), findsOneWidget);

    await tester.tap(find.text('Update now'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(installer.installed, ['1.3.0']);
  });

  testWidgets('the version in the blurb is the running one', (tester) async {
    final controller = UpdateController(
      service: _ScriptedService(null),
      installer: _QuietInstaller(),
      currentVersionOverride: '2.4.1',
    );

    await _pump(tester, controller);

    expect(find.textContaining('You are on version 2.4.1'), findsOneWidget);
  });

  testWidgets('without a controller there is no card at all', (tester) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: const Scaffold(
          body: SingleChildScrollView(child: UpdateCard()),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Card), findsNothing);
  });
}

