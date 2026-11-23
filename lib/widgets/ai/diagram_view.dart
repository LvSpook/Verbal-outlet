/// Draws the simple Graphviz diagrams the AI produces.
///
/// A full DOT engine is far too much app for what this needs. The prompts ask
/// the model for a small, plain digraph — nodes with quoted labels and a handful
/// of labelled edges — so a small parser and a layered layout are enough, and
/// they match the app's palette exactly.
///
/// Anything it cannot read is reported as a plain message rather than a crash;
/// the raw DOT is still available to the user in that case.
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// A parsed diagram: nodes in declaration order, and the edges between them.
class DotGraph {
  DotGraph({required this.nodes, required this.edges});

  final List<DotNode> nodes;
  final List<DotEdge> edges;

  bool get isEmpty => nodes.isEmpty;
}

class DotNode {
  DotNode(this.id, this.label);

  final String id;
  String label;

  /// Position after layout, used by the painter.
  Rect bounds = Rect.zero;
}

class DotEdge {
  DotEdge(this.from, this.to, this.label);

  final String from;
  final String to;
  final String? label;
}

/// Parses the subset of DOT the prompts ask for.
///
/// Handles:
/// * `digraph name { ... }` / `graph { ... }` wrappers
/// * `a [label="Text"];` and bare `a;`
/// * `a -> b [label="why"];` and `a -- b;`
/// * global `node [shape=box]` / `rankdir=LR` lines, which are ignored
///
/// Returns null when the text does not look like a graph at all.
DotGraph? parseDot(String source) {
  final body = _stripWrapper(source);
  if (body == null) return null;

  final nodes = <String, DotNode>{};
  final edges = <DotEdge>[];

  // Statements are separated by ; or newlines. Splitting on ; is enough because
  // attributes are always inside [ ] in the format we ask for.
  final statements = body
      .split(RegExp(r';|\n'))
      .map((statement) => statement.trim())
      .where((statement) => statement.isNotEmpty);

  final nodeDeclaration = RegExp(r'^([A-Za-z0-9_"\-\.]+)\s*(?:\[(.*)\])?$');
  final edgeDeclaration = RegExp(
    r'^([A-Za-z0-9_"\-\.]+)\s*(->|--)\s*([A-Za-z0-9_"\-\.]+)\s*(?:\[(.*)\])?$',
  );

  for (final statement in statements) {
    // Skip graph-level settings and stray braces.
    if (statement.startsWith('rankdir') ||
        statement.startsWith('node ') ||
        statement.startsWith('edge ') ||
        statement.startsWith('graph ') ||
        statement == '{' ||
        statement == '}') {
      continue;
    }

    final edgeMatch = edgeDeclaration.firstMatch(statement);
    if (edgeMatch != null) {
      final from = _cleanId(edgeMatch.group(1)!);
      final to = _cleanId(edgeMatch.group(3)!);
      final label = _attributeLabel(edgeMatch.group(4));
      nodes.putIfAbsent(from, () => DotNode(from, from));
      nodes.putIfAbsent(to, () => DotNode(to, to));
      edges.add(DotEdge(from, to, label));
      continue;
    }

    final nodeMatch = nodeDeclaration.firstMatch(statement);
    if (nodeMatch != null) {
      final id = _cleanId(nodeMatch.group(1)!);
      if (id.isEmpty) continue;
      final label = _attributeLabel(nodeMatch.group(2)) ?? id;
      final existing = nodes[id];
      if (existing != null) {
        existing.label = label;
      } else {
        nodes[id] = DotNode(id, label);
      }
    }
  }

  if (nodes.isEmpty) return null;
  return DotGraph(nodes: nodes.values.toList(), edges: edges);
}

/// Strips `digraph name {` … `}`. Returns null if there's no graph wrapper,
/// which also filters out prose that happens to contain braces.
String? _stripWrapper(String source) {
  final match = RegExp(
    r'(?:strict\s+)?(?:di)?graph\b[^{]*\{([\s\S]*)\}',
    caseSensitive: false,
  ).firstMatch(source);
  if (match == null) return null;
  // Drop any trailing text after the final brace.
  return match.group(1);
}

String _cleanId(String raw) =>
    raw.replaceAll('"', '').replaceAll("'", '').trim();

/// Pulls `label="..."` out of an attribute list.
String? _attributeLabel(String? attributes) {
  if (attributes == null) return null;
  final match = RegExp(
    r'label\s*=\s*(?:"([^"]*)"|([A-Za-z0-9_\-\. ]+))',
    caseSensitive: false,
  ).firstMatch(attributes);
  if (match == null) return null;
  final value = (match.group(1) ?? match.group(2) ?? '').trim();
  return value.isEmpty ? null : value;
}

/// A diagram drawn with rounded boxes and arrows.
class DiagramView extends StatelessWidget {
  const DiagramView({super.key, required this.source});

  /// The DOT text exactly as the model wrote it.
  final String source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final graph = parseDot(source);

    if (graph == null || graph.isEmpty) {
      return Text(
        'That diagram could not be read.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      );
    }

    // Short labels keep boxes small and the whole picture readable in a narrow
    // panel; the model is asked to keep them short, but clamp anyway.
    final labelStyle =
        theme.textTheme.labelMedium?.copyWith(color: scheme.onSurface) ??
        const TextStyle(fontSize: 12);

    return Semantics(
      label: _describe(graph),
      child: SizedBox(
        height: 240,
        width: double.infinity,
        child: CustomPaint(
          painter: _DiagramPainter(
            graph: graph,
            nodeFill: scheme.surfaceContainerHigh,
            nodeBorder: scheme.primary.withValues(alpha: 0.65),
            edgeColor: scheme.outline,
            labelStyle: labelStyle,
            edgeLabelStyle:
                theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ) ??
                const TextStyle(fontSize: 10),
          ),
        ),
      ),
    );
  }

  String _describe(DotGraph graph) {
    final parts = [
      for (final edge in graph.edges)
        '${_nodeLabel(graph, edge.from)} to ${_nodeLabel(graph, edge.to)}'
            '${edge.label == null ? '' : ' (${edge.label})'}',
    ];
    if (parts.isEmpty) {
      return 'Diagram of ${graph.nodes.map((node) => node.label).join(', ')}.';
    }
    return 'Diagram: ${parts.join('; ')}.';
  }

  String _nodeLabel(DotGraph graph, String id) =>
      graph.nodes.firstWhere((node) => node.id == id).label;
}

class _DiagramPainter extends CustomPainter {
  _DiagramPainter({
    required this.graph,
    required this.nodeFill,
    required this.nodeBorder,
    required this.edgeColor,
    required this.labelStyle,
    required this.edgeLabelStyle,
  });

  final DotGraph graph;
  final Color nodeFill;
  final Color nodeBorder;
  final Color edgeColor;
  final TextStyle labelStyle;
  final TextStyle edgeLabelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    _layout(size);

    final edgePaint = Paint()
      ..color = edgeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;

    for (final edge in graph.edges) {
      final from = graph.nodes.firstWhere((node) => node.id == edge.from);
      final to = graph.nodes.firstWhere((node) => node.id == edge.to);
      _drawEdge(canvas, from.bounds, to.bounds, edge.label, edgePaint);
    }

    final fillPaint = Paint()..color = nodeFill;
    final borderPaint = Paint()
      ..color = nodeBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    for (final node in graph.nodes) {
      final rect = RRect.fromRectAndRadius(
        node.bounds,
        const Radius.circular(10),
      );
      canvas.drawRRect(rect, fillPaint);
      canvas.drawRRect(rect, borderPaint);

      final painter = TextPainter(
        text: TextSpan(text: node.label, style: labelStyle),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        maxLines: 2,
        ellipsis: '…',
      )..layout(maxWidth: node.bounds.width - 12);
      painter.paint(
        canvas,
        Offset(
          node.bounds.center.dx - painter.width / 2,
          node.bounds.center.dy - painter.height / 2,
        ),
      );
    }
  }

  /// Lays the graph out in columns, roots first.
  ///
  /// Nodes with no incoming edges form the first column; each edge pushes the
  /// target one column further right. That is enough for the small,
  /// mostly-acyclic graphs the prompts ask for, and cycles simply land in
  /// whichever column they were reached from.
  void _layout(Size size) {
    const nodeWidth = 96.0;
    const nodeHeight = 40.0;
    const columnGap = 44.0;
    const rowGap = 18.0;

    final inbound = {for (final node in graph.nodes) node.id: 0};
    for (final edge in graph.edges) {
      inbound[edge.to] = (inbound[edge.to] ?? 0) + 1;
    }

    // Breadth-first from the roots, recording a depth for each node.
    final depth = <String, int>{};
    final queue = <String>[
      for (final node in graph.nodes)
        if ((inbound[node.id] ?? 0) == 0) node.id,
    ];
    if (queue.isEmpty) queue.add(graph.nodes.first.id);

    for (final id in queue) {
      depth.putIfAbsent(id, () => 0);
    }
    var head = 0;
    while (head < queue.length) {
      final id = queue[head++];
      final current = depth[id] ?? 0;
      for (final edge in graph.edges.where((edge) => edge.from == id)) {
        final next = current + 1;
        if ((depth[edge.to] ?? -1) < next) {
          depth[edge.to] = next;
          queue.add(edge.to);
        }
      }
    }
    for (final node in graph.nodes) {
      depth.putIfAbsent(node.id, () => 0);
    }

    // Group into columns, preserving declaration order within a column.
    final columns = <int, List<DotNode>>{};
    for (final node in graph.nodes) {
      columns.putIfAbsent(depth[node.id] ?? 0, () => []).add(node);
    }

    final columnCount = columns.length;
    final maxRows = columns.values
        .map((column) => column.length)
        .reduce(math.max);

    final totalWidth =
        columnCount * nodeWidth + math.max(0, columnCount - 1) * columnGap;
    final totalHeight =
        maxRows * nodeHeight + math.max(0, maxRows - 1) * rowGap;

    final originX = math.max(0.0, (size.width - totalWidth) / 2);
    final originY = math.max(0.0, (size.height - totalHeight) / 2);

    final sortedDepths = columns.keys.toList()..sort();
    for (
      var columnIndex = 0;
      columnIndex < sortedDepths.length;
      columnIndex++
    ) {
      final column = columns[sortedDepths[columnIndex]]!;
      final columnHeight =
          column.length * nodeHeight + (column.length - 1) * rowGap;
      final startY = originY + (totalHeight - columnHeight) / 2;
      final x = originX + columnIndex * (nodeWidth + columnGap);

      for (var row = 0; row < column.length; row++) {
        column[row].bounds = Rect.fromLTWH(
          x,
          startY + row * (nodeHeight + rowGap),
          nodeWidth,
          nodeHeight,
        );
      }
    }

    // Shrink to fit if the layout overflowed a narrow panel.
    var overflowX = 0.0;
    var overflowY = 0.0;
    for (final node in graph.nodes) {
      overflowX = math.max(overflowX, node.bounds.right - size.width + 4);
      overflowY = math.max(overflowY, node.bounds.bottom - size.height + 4);
    }
    if (overflowX > 0 || overflowY > 0) {
      final scaleX = overflowX > 0 ? size.width / (totalWidth + 8) : 1.0;
      final scaleY = overflowY > 0 ? size.height / (totalHeight + 8) : 1.0;
      final scale = math.min(scaleX, scaleY).clamp(0.45, 1.0);
      for (final node in graph.nodes) {
        node.bounds = Rect.fromLTWH(
          node.bounds.left * scale,
          node.bounds.top * scale,
          node.bounds.width * scale,
          node.bounds.height * scale,
        );
      }
    }
  }

  void _drawEdge(
    Canvas canvas,
    Rect from,
    Rect to,
    String? label,
    Paint paint,
  ) {
    // Leave from the right of the source and arrive at the left of the target,
    // which matches the left-to-right reading order.
    final start = Offset(from.right, from.center.dy);
    final end = Offset(to.left, to.center.dy);
    final midX = (start.dx + end.dx) / 2;

    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..cubicTo(midX, start.dy, midX, end.dy, end.dx, end.dy);
    canvas.drawPath(path, paint);

    // Arrowhead. The curve arrives horizontally, so it points right.
    const arrowSize = 6.0;
    const angle = 0.0;
    final tip = Offset(end.dx, end.dy);
    final left = tip.translate(
      -arrowSize * math.cos(angle - 0.4),
      -arrowSize * math.sin(angle - 0.4),
    );
    final right = tip.translate(
      -arrowSize * math.cos(angle + 0.4),
      -arrowSize * math.sin(angle + 0.4),
    );
    final arrow = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(left.dx, left.dy)
      ..lineTo(right.dx, right.dy)
      ..close();
    canvas.drawPath(arrow, Paint()..color = edgeColor);

    if (label == null || label.isEmpty) return;
    final painter = TextPainter(
      text: TextSpan(text: label, style: edgeLabelStyle),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: math.max(0, end.dx - start.dx - 8));
    painter.paint(
      canvas,
      Offset(
        (start.dx + end.dx) / 2 - painter.width / 2,
        (start.dy + end.dy) / 2 - painter.height - 3,
      ),
    );
  }

  @override
  bool shouldRepaint(_DiagramPainter old) =>
      old.graph != graph || old.nodeFill != nodeFill;
}
