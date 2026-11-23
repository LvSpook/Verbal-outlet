import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../capture/app_request.dart';
import '../capture/app_request_scope.dart';
import '../capture/capture_request.dart';
import '../capture/capture_scope.dart';
import '../data/note_store.dart';
import '../screens/sync_screen.dart';
import '../voice/speech_service.dart';
import '../widgets/calendar_view.dart';
import '../widgets/global_search_dialog.dart';
import '../widgets/note_editor_pane.dart';
import 'note_page.dart';

/// The app's home.
///
/// On a wide window (desktop) it is a two-pane split: the calendar sits on the
/// left and shrinks, and the selected day's note opens on the right. That makes
/// switching days cheap — the calendar stays put and you just click another
/// date.
///
/// On a narrow window (a phone, or a small window) there is no room for two
/// panes, so selecting a day navigates to a full-screen note instead.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.initialDay});

  /// Below this width the split layout is dropped in favour of navigation.
  static const double splitBreakpoint = 900;

  /// Opens straight onto this day's note when the split layout is available.
  /// Useful for deep links later, and for previews.
  final DateTime? initialDay;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final NoteStore _store = NoteStore.instance;

  /// One speech service for the pane, so a question and a confirmation share
  /// the same platform channel rather than each opening their own.
  final SpeechService _speech = SpeechService();

  /// Increments when a window-level Ctrl+F asks the open note to search.
  ///
  /// A counter rather than a global key: the open pane is keyed by day so that
  /// switching dates animates, and a key that changes identity would break
  /// that. The pane watches the counter instead.
  int _searchRequests = 0;

  /// Same idea as [_searchRequests], for "put the cursor in the composer".
  int _captureRequests = 0;

  /// The section a chosen all-notes search result wants opened. Null otherwise.
  String? _focusSectionId;

  /// The day whose note is open in the right pane, or null when it is closed.
  DateTime? _openDay;

  /// Whether the current frame is using the wide split layout.
  bool _isSplitLayout = false;

  /// Whether the previous frame used the split layout. Used to tell "the window
  /// shrank, so the pane no longer exists" apart from "the window grew and the
  /// pane is available again".
  bool _wasSplitLayout = false;

  /// The capture request this screen is listening to, if any.
  CaptureRequest? _capture;

  /// The voice-command mailbox this screen is listening to, if any.
  AppRequestMailbox? _requests;

  /// Increments when a voice command asks for the next or previous month, so the
  /// calendar shifts without the home screen owning its month state.
  int _monthRequests = 0;
  bool _monthForward = true;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStoreChanged);
    _openDay = widget.initialDay == null ? null : dateOnly(widget.initialDay!);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final request = CaptureScope.maybeOf(context);
    if (!identical(request, _capture)) {
      _capture?.removeListener(_onCapture);
      _capture = request?..addListener(_onCapture);
      // A hotkey press can land before this screen exists (Android shortcuts
      // start the app cold), so take anything already waiting. Deferred a
      // frame: layout has not run yet, so [_isSplitLayout] is not yet known,
      // and navigating during a build is illegal.
      if (request != null && request.isPending) {
        final pending = request;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final waiting = pending.consume();
          if (waiting == CaptureTrigger.quick) _openTodayForCapture();
        });
      }
    }

    final mailbox = AppRequestScope.maybeOf(context);
    if (!identical(mailbox, _requests)) {
      _requests?.removeListener(_onAppRequest);
      _requests = mailbox?..addListener(_onAppRequest);
    }
  }

  @override
  void dispose() {
    _capture?.removeListener(_onCapture);
    _requests?.removeListener(_onAppRequest);
    _store.removeListener(_onStoreChanged);
    super.dispose();
  }

  /// Acts on a "show me this" request from a voice command.
  void _onAppRequest() {
    final mailbox = _requests;
    if (mailbox == null) return;
    final request = mailbox.take();
    if (request == null || !mounted) return;

    switch (request.action) {
      case AppAction.openDay:
        final day = request.day;
        if (day != null) unawaited(_selectDay(dateOnly(day)));
      case AppAction.searchAll:
        unawaited(_openGlobalSearch(initialQuery: request.query ?? ''));
      case AppAction.nextMonth:
      case AppAction.previousMonth:
        setState(() {
          _monthRequests++;
          _monthForward = request.action == AppAction.nextMonth;
        });
      case AppAction.openSettings:
        _openSettings();
    }
  }

  void _openSettings() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const SyncScreen()),
    );
  }

  /// Acts on a pending quick capture: today's note, cursor in the composer.
  void _onCapture() {
    final request = _capture;
    if (request == null || !request.isPending) return;
    if (request.consume() != CaptureTrigger.quick) return;
    _openTodayForCapture();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _selectDay(DateTime day) async {
    if (_isSplitLayout) {
      setState(() {
        _openDay = dateOnly(day);
        _focusSectionId = null;
      });
      return;
    }

    await Navigator.of(context)
        .push<void>(MaterialPageRoute(builder: (_) => NotePage(day: day)));
  }

  void _closeNote() => setState(() {
    _openDay = null;
    _focusSectionId = null;
  });

  /// Searches every note and opens whatever is chosen.
  ///
  /// On the split layout the chosen day opens in the pane beside the calendar
  /// with the matched section already in its editor. On a phone the same day
  /// opens as a page, since there is no pane to put it in.
  Future<void> _openGlobalSearch({String initialQuery = ''}) async {
    final chosen = await showGlobalSearch(
      context,
      store: _store,
      initialQuery: initialQuery,
    );
    if (chosen == null || !mounted) return;

    final day = dateOnly(chosen.day);
    final sectionId = chosen.hit.section.id;

    if (_isSplitLayout) {
      setState(() {
        _openDay = day;
        _focusSectionId = sectionId;
      });
      return;
    }

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => NotePage(day: day, focusSectionId: sectionId),
      ),
    );
  }

  /// Opens today's note with the cursor ready: the "New thought" button, and
  /// what a quick capture does.
  ///
  /// On a narrow window the note is a page rather than a pane, so it opens as
  /// one and asks that page to focus instead.
  void _openTodayForCapture() {
    final today = dateOnly(DateTime.now());
    if (!_isSplitLayout) {
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => NotePage(day: today, focusComposer: true),
        ),
      );
      return;
    }

    setState(() {
      _openDay = today;
      _focusSectionId = null;
      // The pane watches this counter instead of being driven through a key,
      // so it works whether today's note was closed or already open.
      _captureRequests++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isSplit = constraints.maxWidth >= HomeScreen.splitBreakpoint;

        // If the window shrank while a note was open, the split has gone; drop
        // the pane rather than leave a dangling selection. Doing this only on a
        // genuine split -> narrow transition stops the initial layout pass (which
        // looks like a transition from "narrow") from discarding a note that was
        // opened via [HomeScreen.initialDay].
        if (_wasSplitLayout && !isSplit && _openDay != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _openDay = null);
          });
        }

        _isSplitLayout = isSplit;
        _wasSplitLayout = isSplit;

        return isSplit ? _buildSplit(context, constraints) : _buildSingle();
      },
    );
  }

  Widget _buildSingle() {
    return Scaffold(
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: CalendarView(
              onDaySelected: _selectDay,
              onSearchAll: () => unawaited(_openGlobalSearch()),
              monthRequest: _monthRequests,
              monthRequestForward: _monthForward,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSplit(BuildContext context, BoxConstraints constraints) {
    final scheme = Theme.of(context).colorScheme;
    final noteOpen = _openDay != null;

    // The calendar narrows to a fixed sidebar once a note is open. Clamp
    // against the available width so a mid-size window still leaves the note
    // usable.
    const sidebarWidth = 360.0;
    final maxSidebar = constraints.maxWidth * 0.45;
    final sidebar = sidebarWidth.clamp(280.0, maxSidebar);
    final calendarWidth = noteOpen
        ? sidebar
        : (constraints.maxWidth > 900 ? 560.0 : constraints.maxWidth);

    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): _CloseNoteIntent(),
        SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _OpenSearchIntent(),
        // Ctrl+K for "find anywhere", the shortcut people already reach for in
        // editors and chat apps.
        SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _OpenGlobalSearchIntent(),
      },
      child: Actions(
        actions: {
          _CloseNoteIntent: CallbackAction<_CloseNoteIntent>(
            onInvoke: (_) {
              if (noteOpen) _closeNote();
              return null;
            },
          ),
          _OpenSearchIntent: CallbackAction<_OpenSearchIntent>(
            onInvoke: (_) {
              if (noteOpen) setState(() => _searchRequests++);
              return null;
            },
          ),
          _OpenGlobalSearchIntent: CallbackAction<_OpenGlobalSearchIntent>(
            onInvoke: (_) {
              unawaited(_openGlobalSearch());
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            body: SafeArea(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ---- Calendar pane: slides left and narrows ----
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    width: calendarWidth,
                    decoration: BoxDecoration(
                      color: noteOpen
                          ? scheme.surfaceContainerLowest.withValues(
                              alpha: 0.45,
                            )
                          : null,
                      border: Border(
                        right: BorderSide(
                          color: noteOpen
                              ? scheme.outlineVariant
                              : Colors.transparent,
                        ),
                      ),
                    ),
                    child: CalendarView(
                      compact: noteOpen,
                      selectedDay: _openDay,
                      onDaySelected: _selectDay,
                      onSearchAll: () => unawaited(_openGlobalSearch()),
                      monthRequest: _monthRequests,
                      monthRequestForward: _monthForward,
                    ),
                  ),

                  // ---- Note pane: slides in from the right ----
                  Expanded(
                    child: ClipRect(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 260),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) {
                          final slide = Tween<Offset>(
                            begin: const Offset(0.04, 0),
                            end: Offset.zero,
                          ).animate(animation);
                          return FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: slide,
                              child: child,
                            ),
                          );
                        },
                        child: noteOpen
                            ? NoteEditorPane(
                                // Keyed by day so switching dates animates
                                // rather than silently swapping text.
                                key: ValueKey(_openDay),
                                day: _openDay!,
                                embedded: true,
                                onClose: _closeNote,
                                searchRequest: _searchRequests,
                                captureRequest: _captureRequests,
                                focusSectionId: _focusSectionId,
                                speech: _speech,
                              )
                            : _EmptyNotePane(
                                key: const ValueKey('empty'),
                                onOpenToday: () =>
                                    _selectDay(dateOnly(DateTime.now())),
                                onCapture: _openTodayForCapture,
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown in the right pane before a day is chosen.
class _EmptyNotePane extends StatelessWidget {
  const _EmptyNotePane({
    super.key,
    required this.onOpenToday,
    required this.onCapture,
  });

  final VoidCallback onOpenToday;

  /// Opens today's note with the cursor ready, so a thought can be typed
  /// without first finding the day.
  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.menu_book_outlined,
              size: 44,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 16),
            Text(
              'Pick a day',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Choose a date on the left to open its note here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            // Stacked, not side by side: the empty pane is a narrow sidebar
            // when a note is open elsewhere, and two icon buttons overflow it.
            FilledButton.icon(
              onPressed: onCapture,
              icon: const Icon(Icons.add_comment_outlined, size: 18),
              label: const Text('New thought'),
            ),
            TextButton.icon(
              onPressed: onOpenToday,
              icon: const Icon(Icons.today_outlined, size: 18),
              label: const Text('Open today'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CloseNoteIntent extends Intent {
  const _CloseNoteIntent();
}

class _OpenSearchIntent extends Intent {
  const _OpenSearchIntent();
}

class _OpenGlobalSearchIntent extends Intent {
  const _OpenGlobalSearchIntent();
}


