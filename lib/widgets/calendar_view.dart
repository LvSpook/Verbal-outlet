import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../ai/monthly_insight_controller.dart';
import '../ai/monthly_insight_scope.dart';
import '../data/note_store.dart';
import '../screens/sync_screen.dart';
import '../utils/date_format.dart';
import '../widgets/ai/monthly_insight_card.dart';
import '../widgets/month_picker.dart';

/// The month calendar, usable either full width or as a narrow sidebar.
///
/// It owns only its own view state (which month is showing). Selecting a day is
/// reported through [onDaySelected] so the surrounding shell decides whether to
/// open a note beside it or navigate to a new screen.
class CalendarView extends StatefulWidget {
  const CalendarView({
    super.key,
    required this.onDaySelected,
    this.selectedDay,
    this.compact = false,
    this.onSearchAll,
    this.monthRequest = 0,
    this.monthRequestForward = true,
  });

  /// Called when a day cell is clicked.
  final ValueChanged<DateTime> onDaySelected;

  /// The day currently open in the note pane, highlighted in the grid.
  final DateTime? selectedDay;

  /// Hides the app title and shrinks spacing for the sidebar layout.
  final bool compact;

  /// Opens the all-notes search. Null hides the search button.
  final VoidCallback? onSearchAll;

  /// Increments when something outside the calendar (a voice command) asks for
  /// the next or previous month. A counter rather than a callback so the
  /// calendar keeps owning its month state.
  final int monthRequest;

  /// Whether [monthRequest] means forward or back.
  final bool monthRequestForward;

  @override
  State<CalendarView> createState() => _CalendarViewState();
}

class _CalendarViewState extends State<CalendarView> {
  final NoteStore _store = NoteStore.instance;

  /// First day of the month currently being shown.
  late DateTime _visibleMonth = _monthOf(DateTime.now());

  /// The last [CalendarView.monthRequest] that was acted on, so a rebuild with
  /// the same value does not shift the month again.
  late int _handledMonthRequest = widget.monthRequest;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStoreChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _applyMonthRequest();
    // Deferred: `show()` notifies the insight scope straight away, and
    // notifying an InheritedNotifier while its descendants are building is
    // illegal. The card shows nothing until the first load anyway.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncInsight();
    });
  }

  @override
  void didUpdateWidget(CalendarView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _applyMonthRequest();
  }

  /// Honours a month change asked for from outside the calendar.
  void _applyMonthRequest() {
    if (widget.monthRequest == _handledMonthRequest) return;
    _handledMonthRequest = widget.monthRequest;
    // Deferred: the request arrives during a rebuild that may be caused by
    // something else, and shifting the month mid-build is illegal.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _shiftMonth(widget.monthRequestForward ? 1 : -1);
    });
  }

  /// Tells the insight controller which month is on screen, so it can load the
  /// cached overview or write one.
  ///
  /// Only when the month differs from what the controller already holds: `show`
  /// notifies its listeners, and this runs from a dependency change, so calling
  /// it unconditionally would rebuild the calendar, which would call it again.
  void _syncInsight() {
    final controller = MonthlyInsightScope.maybeOf(context);
    if (controller == null) return;
    if (controller.year == _visibleMonth.year &&
        controller.month == _visibleMonth.month) {
      return;
    }
    unawaited(controller.show(_visibleMonth.year, _visibleMonth.month));
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  void _shiftMonth(int delta) {
    setState(() {
      _visibleMonth = DateTime(_visibleMonth.year, _visibleMonth.month + delta);
    });
    _syncInsight();
  }

  void _goToToday() {
    setState(() => _visibleMonth = _monthOf(DateTime.now()));
    _syncInsight();
  }

  Future<void> _openMonthPicker() async {
    final picked = await showMonthPicker(context, selectedMonth: _visibleMonth);

    if (!mounted || picked == null) return;
    setState(() => _visibleMonth = _monthOf(picked));
    _syncInsight();
  }

  /// The month's overview, when the app has a controller for it.
  ///
  /// Watches the controller so a newly written overview appears without the
  /// calendar rebuilding for any other reason.
  Widget _insight(ThemeData theme) {
    final controller = MonthlyInsightScope.maybeOf(context);
    if (controller == null) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        // Only describe the month the calendar is showing; a late reply for a
        // month that has since been left would otherwise flash up.
        final state =
            (controller.year == _visibleMonth.year &&
                controller.month == _visibleMonth.month)
            ? controller.state
            : const MonthlyInsightState(loading: true);
        return MonthlyInsightCard(
          state: state,
          month: _visibleMonth,
          compact: widget.compact,
          onRegenerate: () => controller.regenerate(),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final daysWithNotes = _store.daysWithNotesIn(
      _visibleMonth.year,
      _visibleMonth.month,
    );
    final today = dateOnly(DateTime.now());
    final isViewingCurrentMonth =
        _visibleMonth.year == today.year && _visibleMonth.month == today.month;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CalendarHeader(
          compact: widget.compact,
          isViewingCurrentMonth: isViewingCurrentMonth,
          onGoToToday: _goToToday,
          onSearchAll: widget.onSearchAll,
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              widget.compact ? 12 : 16,
              widget.compact ? 0 : 4,
              widget.compact ? 12 : 16,
              24,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _MonthHeader(
                  month: _visibleMonth,
                  compact: widget.compact,
                  onPrevious: () => _shiftMonth(-1),
                  onNext: () => _shiftMonth(1),
                  onOpenPicker: _openMonthPicker,
                ),
                const SizedBox(height: 8),
                const _WeekdayRow(),
                const SizedBox(height: 4),
                _MonthGrid(
                  month: _visibleMonth,
                  daysWithNotes: daysWithNotes,
                  today: today,
                  selectedDay: widget.selectedDay,
                  onDayTapped: widget.onDaySelected,
                ),
                const SizedBox(height: 18),
                _Legend(today: today),
                const SizedBox(height: 20),
                _TodaySummary(
                  today: today,
                  compact: widget.compact,
                  onOpen: () => widget.onDaySelected(today),
                ),
                const SizedBox(height: 16),
                _insight(theme),
                if (theme.brightness == Brightness.dark)
                  const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Title row with the calendar and settings actions.
class _CalendarHeader extends StatelessWidget {
  const _CalendarHeader({
    required this.compact,
    required this.isViewingCurrentMonth,
    required this.onGoToToday,
    this.onSearchAll,
  });

  final bool compact;
  final bool isViewingCurrentMonth;
  final VoidCallback onGoToToday;
  final VoidCallback? onSearchAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (compact) {
      // In the sidebar the month heading is the visual anchor, so the app
      // title would just be noise. Keep only the actions.
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 6, 0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (onSearchAll != null)
              IconButton(
                tooltip: 'Search all notes',
                visualDensity: VisualDensity.compact,
                onPressed: onSearchAll,
                icon: const Icon(Icons.search, size: 20),
              ),
            IconButton(
              tooltip: 'This month',
              visualDensity: VisualDensity.compact,
              onPressed: isViewingCurrentMonth ? null : onGoToToday,
              icon: const Icon(Icons.today_outlined, size: 20),
            ),
            IconButton(
              tooltip: 'Settings',
              visualDensity: VisualDensity.compact,
              onPressed: () => _showSettingsPlaceholder(context),
              icon: const Icon(Icons.settings_outlined, size: 20),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 12, 0),
      child: Row(
        children: [
          Flexible(
            child: Text(
              'Verbal Outlet',
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
                color: scheme.onSurface,
              ),
            ),
          ),
          const Spacer(),
          if (onSearchAll != null)
            IconButton(
              tooltip: 'Search all notes',
              onPressed: onSearchAll,
              icon: const Icon(Icons.search),
            ),
          IconButton(
            tooltip: 'This month',
            onPressed: isViewingCurrentMonth ? null : onGoToToday,
            icon: const Icon(Icons.today_outlined),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => _showSettingsPlaceholder(context),
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

void _showSettingsPlaceholder(BuildContext context) {
  Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => const SyncScreen()),
  );
}

class _MonthHeader extends StatelessWidget {
  const _MonthHeader({
    required this.month,
    required this.compact,
    required this.onPrevious,
    required this.onNext,
    required this.onOpenPicker,
  });

  final DateTime month;
  final bool compact;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onOpenPicker;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = compact
        ? '${shortMonthNames[month.month - 1]} ${month.year}'
        : '${monthNames[month.month - 1]} ${month.year}';

    return Row(
      children: [
        // Tapping the heading opens the month picker, so any past or future
        // month is one click away. Styled as a control to make that obvious.
        Flexible(
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onOpenPicker,
              child: Padding(
                padding: EdgeInsets.fromLTRB(8, 6, 10, compact ? 4 : 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style:
                            (compact
                                    ? theme.textTheme.titleMedium
                                    : theme.textTheme.headlineSmall)
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.4,
                                ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.expand_more,
                      size: compact ? 18 : 22,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const Spacer(),
        IconButton(
          tooltip: 'Previous month',
          visualDensity: compact ? VisualDensity.compact : null,
          onPressed: onPrevious,
          icon: Icon(Icons.chevron_left, size: compact ? 20 : 24),
        ),
        IconButton(
          tooltip: 'Next month',
          visualDensity: compact ? VisualDensity.compact : null,
          onPressed: onNext,
          icon: Icon(Icons.chevron_right, size: compact ? 20 : 24),
        ),
      ],
    );
  }
}

class _WeekdayRow extends StatelessWidget {
  const _WeekdayRow();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        for (final initial in weekdayInitials)
          Expanded(
            child: Center(
              child: Text(
                initial,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.daysWithNotes,
    required this.today,
    required this.selectedDay,
    required this.onDayTapped,
  });

  final DateTime month;
  final Set<DateTime> daysWithNotes;
  final DateTime today;
  final DateTime? selectedDay;
  final ValueChanged<DateTime> onDayTapped;

  @override
  Widget build(BuildContext context) {
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    // Monday-first grid: weekday 1 is Monday, so 0 leading blanks.
    final leadingBlanks = DateTime(month.year, month.month).weekday - 1;
    final cellCount = leadingBlanks + daysInMonth;
    final rowCount = (cellCount / 7).ceil();

    return Column(
      children: [
        for (var row = 0; row < rowCount; row++)
          SizedBox(
            height: _cellHeight,
            child: Row(
              children: [
                for (var column = 0; column < 7; column++)
                  Expanded(
                    child: _buildCell(
                      context,
                      row * 7 + column - leadingBlanks + 1,
                      daysInMonth,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// Cells are wide but short: a calendar should read as a grid of rows, not a
  /// wall of squares.
  static const double _cellHeight = 52;

  Widget _buildCell(BuildContext context, int dayOfMonth, int daysInMonth) {
    if (dayOfMonth < 1 || dayOfMonth > daysInMonth) {
      return const SizedBox.shrink();
    }

    final date = DateTime(month.year, month.month, dayOfMonth);

    return _DayCell(
      day: dayOfMonth,
      isToday: isSameDay(date, today),
      hasNote: daysWithNotes.contains(date),
      isSelected: selectedDay != null && isSameDay(date, selectedDay!),
      onTap: () => onDayTapped(date),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.isToday,
    required this.hasNote,
    required this.isSelected,
    required this.onTap,
  });

  final int day;
  final bool isToday;
  final bool hasNote;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Selected wins over the "has a note" tint so the open day is unmistakable.
    final Color? circleColor;
    final Color labelColor;
    if (isSelected) {
      circleColor = scheme.primary;
      labelColor = scheme.onPrimary;
    } else if (hasNote) {
      circleColor = scheme.primaryContainer;
      labelColor = scheme.onPrimaryContainer;
    } else {
      circleColor = null;
      labelColor = scheme.onSurface;
    }

    final showRing = isToday && !isSelected;

    return Semantics(
      button: true,
      selected: isSelected,
      label:
          '$day${hasNote ? ', has a note' : ''}'
          '${isToday ? ', today' : ''}'
          '${isSelected ? ', open' : ''}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: circleColor,
                  border: showRing
                      ? Border.all(color: scheme.primary, width: 1.5)
                      : null,
                ),
                child: Text(
                  '$day',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: isToday || hasNote || isSelected
                        ? FontWeight.w700
                        : FontWeight.w400,
                    color: labelColor,
                  ),
                ),
              ),
              const SizedBox(height: 3),
              // Small underline marks today.
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: isToday ? 14 : 0,
                height: 3,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.today});

  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Wrap(
      spacing: 20,
      runSpacing: 8,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text('Has a note', style: labelStyle),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '1',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 1),
                Container(
                  width: 12,
                  height: 2,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 8),
            Text('Today', style: labelStyle),
          ],
        ),
      ],
    );
  }
}

/// A shortcut card under the calendar so today's note is one click away.
class _TodaySummary extends StatelessWidget {
  const _TodaySummary({
    required this.today,
    required this.compact,
    required this.onOpen,
  });

  final DateTime today;
  final bool compact;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final note = NoteStore.instance.noteOrEmpty(today);
    final count = note.sectionCount;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: EdgeInsets.all(compact ? 14 : 18),
          child: Row(
            children: [
              Container(
                width: compact ? 38 : 44,
                height: compact ? 38 : 44,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.mic,
                  color: scheme.onPrimary,
                  size: compact ? 18 : 20,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Today',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      switch (count) {
                        0 => 'No note yet. Click to start one.',
                        1 => 'Open today\'s note.',
                        _ => '$count additions today. Click to open.',
                      },
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

DateTime _monthOf(DateTime date) => DateTime(date.year, date.month);
