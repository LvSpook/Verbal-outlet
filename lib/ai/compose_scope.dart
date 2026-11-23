/// Makes the one [ComposeQueue] available to the whole app.
///
/// The composer adds an entry and asks this queue to write it up; the note pane
/// asks it to retry a failed one. One instance app-wide means a single pass is
/// in flight no matter which screen asked, and a switch of day cannot start a
/// second concurrent pass over the same entries.
library;

import 'package:material_ui/material_ui.dart';

import 'compose_queue.dart';

class ComposeScope extends InheritedNotifier<ComposeQueue> {
  const ComposeScope({
    super.key,
    required ComposeQueue queue,
    required super.child,
  }) : super(notifier: queue);

  /// Null when the app was built without one (some widget tests, previews), so
  /// callers can fall back to writing plainly rather than crash.
  static ComposeQueue? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ComposeScope>()?.notifier;

  static ComposeQueue of(BuildContext context) {
    final queue = maybeOf(context);
    assert(queue != null, 'No ComposeScope above this widget.');
    return queue!;
  }
}
