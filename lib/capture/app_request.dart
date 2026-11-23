/// A tiny mailbox for "show me this" requests from outside the UI.
///
/// Voice commands can arrive while a note pane is open, while the calendar has
/// focus, or on a phone where a dialog is on top. Rather than each caller
/// holding keys to widgets it does not own, they post a request here and the
/// screens that can honour it listen.
///
/// Deliberately plain values: an action plus an optional date or query. The
/// screens decide how to carry it out on their layout (a pane beside the
/// calendar, or a full page on a phone).
library;

import 'package:flutter/foundation.dart';

/// What the app should show.
enum AppAction { openDay, searchAll, nextMonth, previousMonth, openSettings }

/// One request, as taken from the mailbox.
@immutable
class AppRequest {
  const AppRequest({
    required this.action,
    this.day,
    this.query,
    this.settingsSection = '',
  });

  final AppAction action;
  final DateTime? day;
  final String? query;
  final String settingsSection;
}

/// Holds at most one pending [AppRequest].
///
/// Consumed once: a screen takes it, then it is cleared, so the same request
/// cannot fire twice on a rebuild.
class AppRequestMailbox extends ChangeNotifier {
  AppRequest? _pending;

  AppRequest? get pending => _pending;

  bool get isPending => _pending != null;

  void openDay(DateTime day) =>
      _post(AppRequest(action: AppAction.openDay, day: day));

  void search(String query) =>
      _post(AppRequest(action: AppAction.searchAll, query: query));

  void changeMonth({required bool forward}) => _post(
    AppRequest(action: forward ? AppAction.nextMonth : AppAction.previousMonth),
  );

  void openSettings({String section = ''}) => _post(
    AppRequest(action: AppAction.openSettings, settingsSection: section),
  );

  void _post(AppRequest request) {
    _pending = request;
    notifyListeners();
  }

  /// Takes the pending request, if any, and clears it.
  AppRequest? take() {
    final request = _pending;
    if (request == null) return null;
    _pending = null;
    notifyListeners();
    return request;
  }

  void clear() {
    if (_pending == null) return;
    _pending = null;
    notifyListeners();
  }
}
