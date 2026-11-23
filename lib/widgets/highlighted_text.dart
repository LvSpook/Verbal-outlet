/// Draws text with some character ranges emphasised.
///
/// Shared by the day search and the all-notes search so a match looks the same
/// wherever it is shown. The spans are already offsets into this exact string —
/// the search engine builds them that way — so highlighting cannot land on the
/// wrong letters.
library;

import 'package:material_ui/material_ui.dart';

import '../search/note_search.dart';

class HighlightedText extends StatelessWidget {
  const HighlightedText({
    super.key,
    required this.text,
    required this.spans,
    this.style,
  });

  final String text;
  final List<MatchSpan> spans;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (spans.isEmpty) return Text(text, style: style);

    Color backgroundFor(MatchKind kind) => switch (kind) {
      MatchKind.direct => scheme.primary.withValues(alpha: 0.34),
      MatchKind.stem => scheme.primary.withValues(alpha: 0.22),
      MatchKind.concept => scheme.tertiary.withValues(alpha: 0.30),
      MatchKind.fuzzy => scheme.tertiary.withValues(alpha: 0.16),
    };

    final base = style ?? theme.textTheme.bodyLarge;
    final children = <TextSpan>[];
    var cursor = 0;
    for (final span in spans) {
      final start = span.start.clamp(0, text.length);
      final end = span.end.clamp(0, text.length);
      if (end <= start || start < cursor) continue;
      if (start > cursor) {
        children.add(TextSpan(text: text.substring(cursor, start)));
      }
      children.add(
        TextSpan(
          text: text.substring(start, end),
          style: base?.copyWith(
            backgroundColor: backgroundFor(span.kind),
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      cursor = end;
    }
    if (cursor < text.length) {
      children.add(TextSpan(text: text.substring(cursor)));
    }

    return RichText(text: TextSpan(style: base, children: children));
  }
}
