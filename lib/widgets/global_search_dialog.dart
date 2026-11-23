/// Search across every note, not only the day that happens to be open.
///
/// This is the same engine as the per-day search (`LexicalSearcher`), so it
/// understands word forms, typos and related wording the same way, and its
/// results are ranked in one list rather than grouped by day: the best answer
/// anywhere comes first. Each card says which day it came from, because the
/// point of a global search is that you no longer know.
///
/// Deliberately a dialog rather than a screen: it is a quick "where did I write
/// that", and it should close the moment you pick something.
library;

import 'package:material_ui/material_ui.dart';

import '../data/note_store.dart';
import '../search/note_search.dart';
import '../utils/date_format.dart';
import 'highlighted_text.dart';

/// Opens the all-notes search and reports the hit the user chose.
///
/// Resolves to null when it is dismissed. The caller decides what "opening" a
/// hit means, since that differs between the split layout (a pane beside the
/// calendar) and a phone (a full page).
Future<GlobalHit?> showGlobalSearch(
  BuildContext context, {
  required NoteStore store,
  NoteSearcher searcher = const LexicalSearcher(),
  String initialQuery = '',
}) {
  return showDialog<GlobalHit>(
    context: context,
    builder: (_) => GlobalSearchDialog(
      store: store,
      searcher: searcher,
      initialQuery: initialQuery,
    ),
  );
}

class GlobalSearchDialog extends StatefulWidget {
  const GlobalSearchDialog({
    super.key,
    required this.store,
    this.searcher = const LexicalSearcher(),
    this.initialQuery = '',
  });

  final NoteStore store;

  /// Lets a test (or a future smarter backend) swap the engine.
  final NoteSearcher searcher;

  /// Words to search for before the person types. A voice command ("search for
  /// the trip") opens the dialog already showing its results.
  final String initialQuery;

  @override
  State<GlobalSearchDialog> createState() => _GlobalSearchDialogState();
}

class _GlobalSearchDialogState extends State<GlobalSearchDialog> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.trim().isNotEmpty) {
      _controller.text = widget.initialQuery.trim();
    }
    _controller.addListener(_onQueryChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onQueryChanged);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final query = _controller.text.trim();

    final result = query.isEmpty
        ? null
        : widget.searcher.searchAll(widget.store.allNotes, query);

    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 48),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focus,
                      textInputAction: TextInputAction.search,
                      style: theme.textTheme.bodyLarge,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'Search every note — e.g. tired, money, walk',
                        prefixIcon: Icon(Icons.search, size: 20),
                        contentPadding: EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Close search',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _helperText(result, query),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: result == null || result.isEmpty
                  ? _EmptyState(query: query, result: result)
                  : ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                      itemCount: result.hits.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final hit = result.hits[index];
                        return _GlobalHitCard(
                          key: ValueKey(
                            'global-hit-${hit.day.toIso8601String()}-'
                            '${hit.hit.section.id}',
                          ),
                          hit: hit,
                          onOpen: () => Navigator.of(context).pop(hit),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  String _helperText(GlobalSearchResult? result, String query) {
    if (query.isEmpty) {
      final days = widget.store.allNotes.where((n) => n.isNotEmpty).length;
      return 'Searches all $days '
          '${days == 1 ? 'day' : 'days'} of notes · understands related words '
          'and typos';
    }
    if (result == null || result.isEmpty) {
      return 'No matches in ${result?.daysSearched ?? 0} days';
    }
    final hits = result.hits.length;
    final days = result.dayCount;
    return '$hits ${hits == 1 ? 'match' : 'matches'} on '
        '$days ${days == 1 ? 'day' : 'days'}, best first';
  }
}

/// What to show under the field: how the query was read, or where it missed.
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.query, required this.result});

  final String query;
  final GlobalSearchResult? result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (query.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.manage_search,
              size: 38,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 12),
            Text(
              'Find any thought you have written',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Results are ranked across every day, and the best one is '
              'first.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_off,
            size: 34,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
          const SizedBox(height: 10),
          Text(
            'Nothing matches “$query”',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          if (result?.interpretation != null)
            Text(
              result!.interpretation!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

/// One hit from any day: when it was written, which day, and the excerpt.
class _GlobalHitCard extends StatelessWidget {
  const _GlobalHitCard({
    super.key,
    required this.hit,
    required this.onOpen,
  });

  final GlobalHit hit;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      formatDayTitle(hit.day),
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                  Text(
                    '  ·  ${formatClock(hit.hit.section.createdAt)}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    Icons.north_east,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              HighlightedText(
                text: hit.hit.excerpt,
                spans: hit.hit.spans,
                style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
