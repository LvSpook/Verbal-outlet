/// Makes the one [AppRequestMailbox] available to the whole app.
///
/// Voice commands post "open this day", "search for that" into the mailbox, and
/// the home screen and calendar listen. One instance app-wide means a request
/// is never duplicated or lost between screens.
library;

import 'package:material_ui/material_ui.dart';

import 'app_request.dart';

class AppRequestScope extends InheritedNotifier<AppRequestMailbox> {
  const AppRequestScope({
    super.key,
    required AppRequestMailbox mailbox,
    required super.child,
  }) : super(notifier: mailbox);

  /// Null when the app was built without one (previews, older tests), so callers
  /// can simply skip posting a request rather than crash.
  static AppRequestMailbox? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppRequestScope>()?.notifier;
}
