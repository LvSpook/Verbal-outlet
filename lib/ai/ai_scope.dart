/// Makes the one [AiController] available to the whole app.
///
/// One controller means one conversation and one provider, so switching to the
/// AI panel on another day continues the same thread rather than rebuilding a
/// client each time. It also gives tests a single seam: wrap a widget in
/// [AiScope] with a controller built for the test.
library;

import 'package:material_ui/material_ui.dart';

import 'ai_controller.dart';

class AiScope extends InheritedWidget {
  const AiScope({super.key, required this.controller, required super.child});

  final AiController controller;

  static AiController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AiScope>()?.controller;

  /// Convenience for widgets that cannot work without AI wiring.
  static AiController of(BuildContext context) {
    final controller = maybeOf(context);
    assert(controller != null, 'No AiScope above this widget.');
    return controller!;
  }

  @override
  bool updateShouldNotify(AiScope oldWidget) =>
      oldWidget.controller != controller;
}
