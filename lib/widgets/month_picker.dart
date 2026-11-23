import 'package:material_ui/material_ui.dart';

import '../data/note_store.dart';
import '../utils/date_format.dart';

/// A month-picker overlay, opened by tapping the calendar's month heading.
///
/// Built to make "jump to any point in time" fast:
///
/// - A year strip along the top, with an indicator on years that have notes.
/// - A 3x4 grid of months; months with notes show a dot.
/// - Shortcuts to today and to the very first note.
///
/// Pops with the chosen [DateTime] (the first of that month), or null.
Future<DateTime?> showMonthPicker(
  BuildContext context, {
  required DateTime selectedMonth,
}) {
  return showDialog<DateTime>(
    context: context,
    builder: (_) => _MonthPickerDialog(selectedMonth: selectedMonth),
  );
}

class _MonthPickerDialog extends StatefulWidget {
  const _MonthPickerDialog({required this.selectedMonth});

  final DateTime selectedMonth;

  @override
  State<_MonthPickerDialog> createState() => _MonthPickerDialogState();
}

class _MonthPickerDialogState extends State<_MonthPickerDialog> {
  final NoteStore _store = NoteStore.instance;
  late int _year = widget.selectedMonth.year;

  static const _earliestYear = 1970;

  int get _latestYear => DateTime.now().year + 10;

  bool get _canGoBack => _year > _earliestYear;
  bool get _canGoForward => _year < _latestYear;

  void _shiftYear(int delta) {
    setState(() => _year = (_year + delta).clamp(_earliestYear, _latestYear));
  }

  void _pick(int month) {
    Navigator.of(context).pop(DateTime(_year, month));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final counts = _store.noteCountsByMonth(_year);
    final now = DateTime.now();
    final yearsWithNotes = _store.yearsWithNotes;
    final earliest = _store.earliestNoteDay;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      backgroundColor: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ---- Year strip ----
              Row(
                children: [
                  IconButton(
                    tooltip: 'Previous year',
                    onPressed: _canGoBack ? () => _shiftYear(-1) : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          '$_year',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.5,
                          ),
                        ),
                        Text(
                          _yearSummary(counts),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Next year',
                    onPressed: _canGoForward ? () => _shiftYear(1) : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),

              // ---- Years that actually have notes ----
              // Only useful as a shortcut when there is more than one year.
              if (yearsWithNotes.length > 1) ...[
                const SizedBox(height: 4),
                _YearChips(
                  years: yearsWithNotes,
                  selectedYear: _year,
                  onSelected: (year) => setState(() => _year = year),
                ),
              ],

              const SizedBox(height: 16),

              // ---- Month grid ----
              for (var row = 0; row < 4; row++) ...[
                Row(
                  children: [
                    for (var column = 0; column < 3; column++)
                      Expanded(
                        child: _buildMonthCell(
                          context,
                          row * 3 + column + 1,
                          counts,
                          now,
                        ),
                      ),
                  ],
                ),
                if (row < 3) const SizedBox(height: 8),
              ],

              const SizedBox(height: 16),
              Divider(color: scheme.outlineVariant, height: 1),
              const SizedBox(height: 12),

              // ---- Shortcuts ----
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  _ShortcutChip(
                    icon: Icons.today_outlined,
                    label: 'Today',
                    onPressed: () =>
                        Navigator.of(context).pop(_firstOfMonth(now)),
                  ),
                  if (earliest != null)
                    _ShortcutChip(
                      icon: Icons.first_page,
                      label: 'First note',
                      onPressed: () =>
                          Navigator.of(context).pop(_firstOfMonth(earliest)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMonthCell(
    BuildContext context,
    int month,
    Map<int, int> counts,
    DateTime now,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final isSelected =
        _year == widget.selectedMonth.year &&
        month == widget.selectedMonth.month;
    final isCurrentMonth = _year == now.year && month == now.month;
    final hasNote = counts.containsKey(month);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        _MonthTile(
          label: shortMonthNames[month - 1],
          isSelected: isSelected,
          isCurrent: isCurrentMonth,
          onPressed: () => _pick(month),
        ),
        // Dot in the corner signals "there are notes in here".
        if (hasNote)
          Positioned(
            top: 7,
            right: 10,
            child: IgnorePointer(
              child: Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: isSelected
                      ? scheme.onPrimary
                      : scheme.primary.withValues(alpha: 0.85),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _MonthTile extends StatelessWidget {
  const _MonthTile({
    required this.label,
    required this.isSelected,
    required this.isCurrent,
    required this.onPressed,
  });

  final String label;
  final bool isSelected;
  final bool isCurrent;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: isSelected
            ? scheme.primary
            : isCurrent
            ? scheme.primaryContainer
            : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            height: 52,
            child: Center(
              child: Text(
                label,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: isSelected
                      ? scheme.onPrimary
                      : isCurrent
                      ? scheme.onPrimaryContainer
                      : scheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _YearChips extends StatelessWidget {
  const _YearChips({
    required this.years,
    required this.selectedYear,
    required this.onSelected,
  });

  final List<int> years;
  final int selectedYear;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        shrinkWrap: true,
        itemCount: years.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final year = years[index];
          final isSelected = year == selectedYear;

          return Material(
            color: isSelected
                ? scheme.secondaryContainer
                : scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(999),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => onSelected(year),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Center(
                  child: Text(
                    '$year',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: isSelected
                          ? scheme.onSecondaryContainer
                          : scheme.onSurfaceVariant,
                      fontWeight: isSelected
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ShortcutChip extends StatelessWidget {
  const _ShortcutChip({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }
}

String _yearSummary(Map<int, int> counts) {
  if (counts.isEmpty) return 'No notes this year';
  final months = counts.length;
  final notes = counts.values.fold<int>(0, (sum, count) => sum + count);
  return '$notes ${notes == 1 ? 'note' : 'notes'} across $months '
      '${months == 1 ? 'month' : 'months'}';
}

DateTime _firstOfMonth(DateTime date) => DateTime(date.year, date.month);
