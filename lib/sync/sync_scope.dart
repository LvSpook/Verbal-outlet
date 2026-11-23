/// Makes the one [SyncController] available to the whole app.
///
/// One controller matters here: it owns the listening socket and the pairing
/// code. A second one would try to bind the same port and would show a
/// different code, so the app creates this once at launch and every screen uses
/// it. It also gives tests a single seam.
library;

import 'package:material_ui/material_ui.dart';

import 'sync_controller.dart';

class SyncScope extends InheritedWidget {
  const SyncScope({super.key, required this.controller, required super.child});

  final SyncController controller;

  static SyncController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SyncScope>()?.controller;

  /// For widgets that cannot work without sync wiring.
  static SyncController of(BuildContext context) {
    final controller = maybeOf(context);
    assert(controller != null, 'No SyncScope above this widget.');
    return controller!;
  }

  @override
  bool updateShouldNotify(SyncScope oldWidget) =>
      oldWidget.controller != controller;
}
