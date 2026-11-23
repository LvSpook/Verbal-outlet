/// Makes the one [MonthlyInsightController] available to the whole app.
///
/// The calendar asks for a month's overview; the settings and voice layers can
/// ask it to regenerate. One controller means one model call at a time and a
/// cache that never disagrees with itself.
library;

import 'package:material_ui/material_ui.dart';

import 'monthly_insight_controller.dart';

class MonthlyInsightScope extends InheritedNotifier<MonthlyInsightController> {
  const MonthlyInsightScope({
    super.key,
    required MonthlyInsightController controller,
    required super.child,
  }) : super(notifier: controller);

  /// Null when the app was built without one (previews, older tests), in which
  /// case the calendar simply shows no overview.
  static MonthlyInsightController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MonthlyInsightScope>()?.notifier;
}
