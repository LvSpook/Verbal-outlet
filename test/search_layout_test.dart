import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:verbal_outlet/main.dart';

/// Search has to look right at the window sizes people actually use, not just
/// the wide one the widget tests default to. A RenderFlex overflow is reported
/// as a test failure by the framework, so simply opening search and typing is
/// enough to catch clipped or overflowing layout.
void main() {
  for (final size in const [
    Size(1000, 700),
    Size(1100, 800),
    Size(1400, 900),
  ]) {
    testWidgets('search fits without overflowing at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const VerbalOutletApp());
      await tester.pumpAndSettle();

      await tester.tap(find.text(DateTime.now().day.toString()).first);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Search this note'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'walk');
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('match'), findsWidgets);
    });
  }
}
