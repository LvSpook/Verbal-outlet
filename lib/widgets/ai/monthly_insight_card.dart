/// The month, looked back on, shown under the calendar.
///
/// It is deliberately quiet: a heading, a few lines, and whatever diagram the
/// model drew, rendered by the same [EntryView] that draws an entry. There is
/// no "generate" button on first view - the controller writes the overview the
/// first time a month is seen, and reuses it until the month changes. The only
/// button is a retry, and only after a failure.
library;

import 'package:material_ui/material_ui.dart';

import '../../ai/monthly_insight_controller.dart';
import '../../utils/date_format.dart';
import 'entry_view.dart';

class MonthlyInsightCard extends StatelessWidget {
  const MonthlyInsightCard({
    super.key,
    required this.state,
    required this.month,
    required this.compact,
    required this.onRegenerate,
  });

  final MonthlyInsightState state;

  /// First day of the month being described.
  final DateTime month;

  /// Tightens spacing for the sidebar layout.
  final bool compact;

  /// Asks for the overview again, e.g. after the model was unreachable.
  final VoidCallback onRegenerate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // A month with nothing in it gets no card at all: an empty overview would
    // be a promise the app cannot keep.
    if (state.empty) return const SizedBox.shrink();
    if (state.loading && state.insight == null) return const SizedBox.shrink();

    final label = compact
        ? shortMonthNames[month.month - 1]
        : monthNames[month.month - 1];

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(compact ? 14 : 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.auto_awesome_outlined,
                  size: compact ? 18 : 20,
                  color: scheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '$label in review',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (state.generating)
                  // A static mark, not a spinner: an indeterminate
                  // CircularProgressIndicator keeps the whole app animating,
                  // and "Reading…" below already says what is happening.
                  Icon(
                    Icons.hourglass_top_rounded,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  )
                else if (state.insight != null)
                  IconButton(
                    tooltip: 'Write the overview again',
                    visualDensity: VisualDensity.compact,
                    onPressed: onRegenerate,
                    icon: const Icon(Icons.refresh, size: 18),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (state.insight != null) ...[
              EntryView(source: state.insight!.body, compact: compact),
              if (state.generating || state.stale)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    state.generating
                        ? 'Updating this overview…'
                        : 'The notes have changed since this was written.',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ] else if (state.generating)
              Text(
                'Reading the month…',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else if (state.error != null)
              _error(theme, scheme)
            else
              Text(
                'No overview yet.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _error(ThemeData theme, ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          state.error!,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: onRegenerate,
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('Try again'),
        ),
      ],
    );
  }
}
