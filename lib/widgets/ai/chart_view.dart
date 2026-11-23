/// Draws the small charts the AI asks for.
///
/// The model does not send images; it sends a few numbers as JSON and the app
/// draws them. That keeps pictures sharp at any size, keeps replies tiny, and
/// means a modest local model can still produce something that looks capable.
///
/// Deliberately hand-painted instead of adding a charting package: the app only
/// needs bar, line and pie with a dozen labels at most, and the palette should
/// match the rest of the app exactly.
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../ai/ai_controller.dart';

class ChartView extends StatelessWidget {
  const ChartView({super.key, required this.data});

  final ChartData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final labelStyle =
        theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant) ??
        const TextStyle(fontSize: 11);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (data.title.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              data.title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        Semantics(
          label: _describe(),
          child: SizedBox(
            height: 180,
            width: double.infinity,
            child: CustomPaint(
              painter: switch (data.type) {
                ChartType.bar => _BarChartPainter(
                  data: data,
                  primary: scheme.primary,
                  grid: scheme.outlineVariant,
                  labelStyle: labelStyle,
                ),
                ChartType.line => _LineChartPainter(
                  data: data,
                  primary: scheme.primary,
                  tertiary: scheme.tertiary,
                  grid: scheme.outlineVariant,
                  labelStyle: labelStyle,
                ),
                ChartType.pie => _PieChartPainter(
                  data: data,
                  colors: _pieColors(scheme),
                  labelStyle: labelStyle,
                  legendStyle:
                      theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurface,
                      ) ??
                      const TextStyle(fontSize: 11),
                ),
              },
            ),
          ),
        ),
      ],
    );
  }

  /// Plain-text version of the chart, so screen readers get the numbers rather
  /// than silence.
  String _describe() {
    final units = [
      for (var i = 0; i < data.labels.length; i++)
        '${data.labels[i]}: ${_formatNumber(data.values[i])}',
    ];
    return '${data.type.name} chart'
        '${data.title.isEmpty ? '' : ' titled ${data.title}'}. '
        '${units.join(', ')}.';
  }
}

List<Color> _pieColors(ColorScheme scheme) => [
  scheme.primary,
  scheme.tertiary,
  scheme.secondary,
  scheme.primary.withValues(alpha: 0.55),
  scheme.tertiary.withValues(alpha: 0.55),
  scheme.secondary.withValues(alpha: 0.55),
  scheme.primary.withValues(alpha: 0.3),
  scheme.tertiary.withValues(alpha: 0.3),
];

String _formatNumber(double value) {
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return value.toStringAsFixed(1);
}

/// Shared helpers for the painters.
mixin _ChartPainting {
  void drawLabel(
    Canvas canvas,
    String text,
    Offset position,
    TextStyle style, {
    TextAlign align = TextAlign.center,
    double maxWidth = 80,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: align,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);

    final dx = switch (align) {
      TextAlign.right => position.dx - painter.width,
      TextAlign.left => position.dx,
      _ => position.dx - painter.width / 2,
    };
    painter.paint(canvas, Offset(dx, position.dy));
  }
}

class _BarChartPainter extends CustomPainter with _ChartPainting {
  _BarChartPainter({
    required this.data,
    required this.primary,
    required this.grid,
    required this.labelStyle,
  });

  final ChartData data;
  final Color primary;
  final Color grid;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    const labelHeight = 18.0;
    const topPadding = 6.0;
    final chartHeight = size.height - labelHeight - topPadding;
    final maxValue = data.values.reduce(math.max);
    final minValue = math.min(0.0, data.values.reduce(math.min));
    final span = (maxValue - minValue) == 0 ? 1.0 : maxValue - minValue;

    // Baseline grid: the top of the plot area, and the zero line.
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, topPadding),
      Offset(size.width, topPadding),
      gridPaint,
    );

    final slot = size.width / data.values.length;
    final barWidth = math.min(slot * 0.6, 44.0);

    final barPaint = Paint()..color = primary;
    for (var i = 0; i < data.values.length; i++) {
      final value = data.values[i];
      final height = ((value - minValue) / span) * chartHeight;
      final left = slot * i + (slot - barWidth) / 2;
      final top = topPadding + chartHeight - height;
      final rect = RRect.fromRectAndCorners(
        Rect.fromLTWH(left, top, barWidth, height),
        topLeft: const Radius.circular(6),
        topRight: const Radius.circular(6),
      );
      canvas.drawRRect(rect, barPaint);

      drawLabel(
        canvas,
        _formatNumber(value),
        Offset(left + barWidth / 2, top - 14),
        labelStyle,
        maxWidth: slot,
      );
      drawLabel(
        canvas,
        data.labels[i],
        Offset(slot * i + slot / 2, size.height - labelHeight + 3),
        labelStyle,
        maxWidth: slot,
      );
    }
  }

  @override
  bool shouldRepaint(_BarChartPainter old) =>
      old.data != data || old.primary != primary;
}

class _LineChartPainter extends CustomPainter with _ChartPainting {
  _LineChartPainter({
    required this.data,
    required this.primary,
    required this.tertiary,
    required this.grid,
    required this.labelStyle,
  });

  final ChartData data;
  final Color primary;
  final Color tertiary;
  final Color grid;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    const labelHeight = 18.0;
    const topPadding = 10.0;
    const sidePadding = 6.0;
    final plotHeight = size.height - labelHeight - topPadding;
    final plotWidth = size.width - sidePadding * 2;

    final maxValue = data.values.reduce(math.max);
    final minValue = data.values.reduce(math.min);
    final span = (maxValue - minValue) == 0 ? 1.0 : maxValue - minValue;

    canvas.drawLine(
      Offset(sidePadding, topPadding),
      Offset(size.width - sidePadding, topPadding),
      Paint()
        ..color = grid
        ..strokeWidth = 1,
    );

    final points = <Offset>[];
    for (var i = 0; i < data.values.length; i++) {
      final x = data.values.length == 1
          ? size.width / 2
          : sidePadding + plotWidth * (i / (data.values.length - 1));
      final y =
          topPadding +
          plotHeight -
          ((data.values[i] - minValue) / span) * plotHeight;
      points.add(Offset(x, y));
    }

    if (points.length > 1) {
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = primary
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    for (var i = 0; i < points.length; i++) {
      canvas.drawCircle(points[i], 4, Paint()..color = tertiary);
      drawLabel(
        canvas,
        _formatNumber(data.values[i]),
        Offset(points[i].dx, points[i].dy - 17),
        labelStyle,
        maxWidth: 60,
      );
      drawLabel(
        canvas,
        data.labels[i],
        Offset(points[i].dx, size.height - labelHeight + 3),
        labelStyle,
        maxWidth: 60,
      );
    }
  }

  @override
  bool shouldRepaint(_LineChartPainter old) =>
      old.data != data || old.primary != primary;
}

class _PieChartPainter extends CustomPainter with _ChartPainting {
  _PieChartPainter({
    required this.data,
    required this.colors,
    required this.labelStyle,
    required this.legendStyle,
  });

  final ChartData data;
  final List<Color> colors;
  final TextStyle labelStyle;
  final TextStyle legendStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final total = data.values.fold<double>(
      0,
      (sum, value) => sum + value.abs(),
    );
    final radius = math.min(size.height / 2 - 4, size.width * 0.26);
    final center = Offset(radius + 6, size.height / 2);

    // Legend gets the right half so labels stay readable.
    final legendLeft = center.dx + radius + 18;

    if (total <= 0) {
      canvas.drawCircle(
        center,
        radius,
        Paint()..color = colors.first.withValues(alpha: 0.25),
      );
      return;
    }

    var start = -math.pi / 2;
    for (var i = 0; i < data.values.length; i++) {
      final sweep = (data.values[i].abs() / total) * math.pi * 2;
      final paint = Paint()..color = colors[i % colors.length];
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        sweep,
        true,
        paint,
      );
      start += sweep;
    }

    var y = center.dy - (data.values.length * 16) / 2;
    for (var i = 0; i < data.values.length; i++) {
      final colour = colors[i % colors.length];
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(legendLeft, y + 3, 9, 9),
          const Radius.circular(2),
        ),
        Paint()..color = colour,
      );
      final text = '${data.labels[i]}  ${_formatNumber(data.values[i])}';
      final painter = TextPainter(
        text: TextSpan(text: text, style: legendStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: size.width - legendLeft - 8);
      painter.paint(canvas, Offset(legendLeft + 14, y));
      y += 16;
    }
  }

  @override
  bool shouldRepaint(_PieChartPainter old) =>
      old.data != data || old.colors != colors;
}
