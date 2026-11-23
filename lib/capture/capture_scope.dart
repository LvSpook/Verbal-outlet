/// Makes the one [CaptureRequest] available to the whole app.
///
/// One request, because there is one pending action to act on; a second would
/// mean two things could be waiting and the UI could act twice. widget tests
/// can supply their own to simulate a hotkey press without a desktop.
library;

import 'package:material_ui/material_ui.dart';

import 'capture_request.dart';

class CaptureScope extends InheritedWidget {
  const CaptureScope({super.key, required this.request, required super.child});

  final CaptureRequest request;

  static CaptureRequest? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CaptureScope>()?.request;

  /// For widgets that cannot work without a capture request wired up.
  static CaptureRequest of(BuildContext context) {
    final request = maybeOf(context);
    assert(request != null, 'No CaptureScope above this widget.');
    return request!;
  }

  @override
  bool updateShouldNotify(CaptureScope oldWidget) =>
      oldWidget.request != request;
}
