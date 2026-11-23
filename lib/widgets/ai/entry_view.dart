/// Reading the AI's entry back as a note, not as a chat message.
///
/// The model writes Markdown plus, occasionally, a `dot` or `chart` block. This
/// turns that into widgets: paragraphs, bullets, checklists, quotes, and the
/// real [DiagramView] and [ChartView]. It is deliberately small — a subset of
/// Markdown, chosen because a diary entry needs emphasis and lists, not tables
/// of contents — and it degrades to plain text when it meets something it does
/// not know, so a model being clever cannot break the note.
library;

import 'package:material_ui/material_ui.dart';

import '../../ai/ai_controller.dart'
    show ChartData, RenderedBlock, RenderedBlockKind, parseBlocks;
import 'chart_view.dart';
import 'diagram_view.dart';

/// One piece of a composed entry.
sealed class EntryBlock {
  const EntryBlock();
}

class ParagraphBlock extends EntryBlock {
  const ParagraphBlock(this.text);
  final String text;
}

class HeadingBlock extends EntryBlock {
  const HeadingBlock(this.text, this.level);
  final String text;
  final int level;
}

/// A bullet, or a checklist item when [checked] is not null.
class BulletBlock extends EntryBlock {
  const BulletBlock(this.text, {this.checked, this.indent = 0});
  final String text;
  final bool? checked;

  /// Nesting depth from leading spaces, capped so a deeply-indented list does
  /// not walk off the side of a phone.
  final int indent;
}

class QuoteBlock extends EntryBlock {
  const QuoteBlock(this.text);
  final String text;
}

class DiagramBlock extends EntryBlock {
  const DiagramBlock(this.source);
  final String source;
}

class ChartBlock extends EntryBlock {
  const ChartBlock(this.data);
  final ChartData data;
}

/// Splits a composed entry into blocks.
///
/// Block-level structures are found first (fences, headings, lists, quotes);
/// everything else accumulates into a paragraph until a blank line or a new
/// block starts.
List<EntryBlock> parseEntry(String source) {
  final blocks = <EntryBlock>[];
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  final paragraph = <String>[];

  void flushParagraph() {
    if (paragraph.isEmpty) return;
    final text = paragraph.join(' ').trim();
    paragraph.clear();
    if (text.isNotEmpty) blocks.add(ParagraphBlock(text));
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trim();

    // Fenced blocks: read to the closing fence, then let the same readers the
    // assistant panel uses decide what it is. Sharing them means a diagram
    // looks identical in a note and in the chat.
    if (trimmed.startsWith('```')) {
      flushParagraph();
      final body = <String>[];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        body.add(lines[i]);
        i++;
      }
      _addFenced(blocks, body.join('\n'));
      continue;
    }

    if (trimmed.isEmpty) {
      flushParagraph();
      continue;
    }

    final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(trimmed);
    if (heading != null) {
      flushParagraph();
      blocks.add(
        HeadingBlock(heading.group(2)!.trim(), heading.group(1)!.length),
      );
      continue;
    }

    final quote = RegExp(r'^>\s?(.*)$').firstMatch(trimmed);
    if (quote != null) {
      flushParagraph();
      // Consecutive quote lines read as one quote, like a paragraph.
      final buffer = <String>[quote.group(1)!.trim()];
      while (i + 1 < lines.length) {
        final next = RegExp(r'^>\s?(.*)$').firstMatch(lines[i + 1].trim());
        if (next == null) break;
        buffer.add(next.group(1)!.trim());
        i++;
      }
      blocks.add(QuoteBlock(buffer.join(' ').trim()));
      continue;
    }

    final bullet = _bulletPattern.firstMatch(line);
    if (bullet != null) {
      flushParagraph();
      final indent = (bullet.group(1)!.length / 2).floor().clamp(0, 3);
      final box = bullet.group(2);
      // group 2 is the literal `[ ]` or `[x]`, so an x anywhere inside means
      // ticked.
      final checked = box?.toLowerCase().contains('x');
      blocks.add(
        BulletBlock(
          bullet.group(3)!.trim(),
          checked: checked,
          indent: indent,
        ),
      );
      continue;
    }

    // A horizontal rule is a pause; it does not need drawing.
    if (RegExp(r'^([-*_])\1{2,}$').hasMatch(trimmed)) {
      flushParagraph();
      continue;
    }

    paragraph.add(trimmed);
  }

  flushParagraph();
  return blocks;
}

/// Leading spaces, a marker (`-`, `*`, `+`, `1.`), then an optional `[ ]`/`[x]`
/// and the text. One pattern for both kinds of bullet, so grouping stays simple:
/// group 1 is indent, 2 is the optional box, 3 is the text.
final RegExp _bulletPattern = RegExp(
  r'^(\s*)(?:[-*+]|\d+[.)])\s+(?:(\[[ xX]\])\s+)?(.*)$',
);

/// The fenced-block reader, expressed once for both the panel and notes.
List<RenderedBlock> blocksFromFence(String body) => parseBlocks('```\n$body\n```');

void _addFenced(List<EntryBlock> blocks, String body) {
  final parsed = blocksFromFence(body);
  if (parsed.isEmpty) {
    // Not a diagram or chart: keep the text rather than silently dropping it,
    // so a model that padded its answer with code is still readable.
    final text = body.trim();
    if (text.isNotEmpty) blocks.add(ParagraphBlock(text));
    return;
  }
  for (final block in parsed) {
    if (block.chart != null) {
      blocks.add(ChartBlock(block.chart!));
    } else if (block.kind == RenderedBlockKind.diagram) {
      blocks.add(DiagramBlock(block.source));
    }
  }
}

/// Draws a composed entry.
class EntryView extends StatelessWidget {
  const EntryView({super.key, required this.source, this.compact = false});

  final String source;

  /// Tightens spacing, for the narrow pane beside a calendar.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final blocks = parseEntry(source);
    final gap = compact ? 8.0 : 12.0;

    final children = <Widget>[];
    for (final block in blocks) {
      if (children.isNotEmpty) children.add(SizedBox(height: gap));
      children.add(
        switch (block) {
          ParagraphBlock(:final text) => Text(
            _inline(text),
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.55),
          ),
          HeadingBlock(:final text, :final level) => Text(
            _inline(text),
            style: (level <= 2
                    ? theme.textTheme.titleMedium
                    : theme.textTheme.titleSmall)
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          BulletBlock(:final text, :final checked, :final indent) => _bullet(
            context,
            text,
            checked: checked,
            indent: indent,
          ),
          QuoteBlock(:final text) => Container(
            padding: const EdgeInsets.fromLTRB(12, 2, 0, 2),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: scheme.primary.withValues(alpha: 0.5)),
              ),
            ),
            child: Text(
              _inline(text),
              style: theme.textTheme.bodyMedium?.copyWith(
                height: 1.5,
                color: scheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
          DiagramBlock(:final source) => DiagramView(source: source),
          ChartBlock(:final data) => ChartView(data: data),
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  /// A bullet or a checklist row. A checklist shows a real box, read-only: the
  /// entry is a record of what was said, not a live task list.
  Widget _bullet(
    BuildContext context,
    String text, {
    required bool? checked,
    required int indent,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.bodyLarge?.copyWith(height: 1.5);

    final marker = checked == null
        ? Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
              ),
            ),
          )
        : Icon(
            checked ? Icons.check_box : Icons.check_box_outline_blank,
            size: 18,
            color: checked ? scheme.primary : scheme.onSurfaceVariant,
          );

    return Padding(
      padding: EdgeInsets.only(left: indent * 16.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 18, child: Center(child: marker)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _inline(text),
              style: checked == true
                  ? style?.copyWith(color: scheme.onSurfaceVariant)
                  : style,
            ),
          ),
        ],
      ),
    );
  }

  /// Strips the emphasis markers this view does not style, so they never leak
  /// as literal punctuation. Bold is left in place: it is rare, and a reader
  /// would rather see `**` than lose the emphasis.
  static String _inline(String text) => text
      .replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m.group(1)!)
      .replaceAllMapped(RegExp(r'(?<!\*)\*([^*\n]+)\*(?!\*)'), (m) => m.group(1)!)
      .replaceAllMapped(RegExp(r'~~([^~]+)~~'), (m) => m.group(1)!);
}
