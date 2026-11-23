/// Makes the one [UpdateController] available, so the Settings card and anything
/// else that wants to show "a new version is here" share one answer.
library;

import 'package:material_ui/material_ui.dart';

import 'update_controller.dart';

class UpdateScope extends InheritedNotifier<UpdateController> {
  const UpdateScope({
    super.key,
    required UpdateController controller,
    required super.child,
  }) : super(notifier: controller);

  /// Null when the app was built without one: previews and tests that do not
  /// touch updates simply see no card.
  static UpdateController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UpdateScope>()?.notifier;
}
