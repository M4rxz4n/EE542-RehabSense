/// Multi-series line charts: progress across sessions, the fatigue trend
/// within one, and the pain and effort ratings.
///
/// One shape, three uses, because they ask the same question — how does this
/// number move across an ordered sequence — and giving each its own chart type
/// would make three things to learn instead of one.
///
/// ## Series, legends and labels
///
/// Up to three series, assigned from [ChartPalette.series] in fixed order and
/// never cycled. A legend is always drawn for two or more; a single series is
/// named by the chart's own title. Points are 8px, which is the floor for
/// something tappable, and the last point of each series is labelled directly
/// so the reader does not have to count back from the legend.
///
/// ## The band behind the fatigue trend
///
/// The fatigue chart's dashed lines are the sleeve's **own** thresholds —
/// range below 85%, effort above 125%, time above 140% — not lines of this
/// app's invention. A chart that drew its own thresholds would disagree with
/// the device about when fatigue had been detected, which is the one thing it
/// must never do.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../session/rep_log.dart';
import '../theme.dart';
import 'chart_kit.dart';

/// One series on a trend chart.
class TrendSeries {
  const TrendSeries({
    required this.label,
    required this.values,
    required this.color,
    this.dashed = false,
    this.band,
    this.unit = '',
  });

  final String label;

  /// One entry per x position, null where that session or rep has no value.
  /// Null is a gap, drawn as a gap: joining across it would invent data.
  final List<double?> values;

  final Color color;
  final bool dashed;

  /// An optional per-point range, drawn as a shaded ribbon. Used for the
  /// lowest-to-highest spread of a session's reps.
  final List<(double, double)?>? band;

  final String unit;
}

class TrendChart extends StatefulWidget {
  const TrendChart({
    super.key,
    required this.series,
    required this.xLabels,
    this.thresholds = const [],
    this.yMin,
    this.yMax,
    this.yLabel,
    this.height = 200,
    this.onSelect,
    this.selected,
    this.pointLabels = true,
  });

  final List<TrendSeries> series;

  /// One per x position, shown on the axis. Thinned automatically when they
  /// would collide.
  final List<String> xLabels;

  /// Reference lines: value, colour, label.
  final List<(double, Color, String)> thresholds;

  final double? yMin;
  final double? yMax;
  final String Function(double)? yLabel;
  final double height;
  final ValueChanged<int>? onSelect;
  final int? selected;

  /// Label the final point of each series. Off for charts where the series
  /// end at the same place and the labels would overlap.
  final bool pointLabels;

  @override
  State<TrendChart> createState() => _TrendChartState();
}

class _TrendChartState extends State<TrendChart> {
  Offset? _touch;
  int? _hit;

  int get _n => widget.xLabels.length;

  @override
  Widget build(BuildContext context) {
    if (_n == 0 || widget.series.every((s) => s.values.every((v) => v == null))) {
      return SizedBox(
        height: widget.height,
        child: const ChartEmpty(message: 'Nothing to plot yet.'),
      );
    }

    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, box) {
          final size = Size(box.maxWidth, widget.height);
          final plotLeft = ChartFrame.leftGutter;
          final plotWidth =
              math.max(1.0, box.maxWidth - plotLeft - ChartFrame.rightPad);

          int? indexAt(Offset p) {
            if (_n == 1) return 0;
            final step = plotWidth / math.max(1, _n - 1);
            final i = ((p.dx - plotLeft) / step).round();
            return i >= 0 && i < _n ? i : null;
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              final i = indexAt(d.localPosition);
              if (i == null) return;
              setState(() {
                _touch = d.localPosition;
                _hit = i;
              });
              widget.onSelect?.call(i);
            },
            onLongPressMoveUpdate: (d) {
              final i = indexAt(d.localPosition);
              if (i == null) return;
              setState(() {
                _touch = d.localPosition;
                _hit = i;
              });
            },
            onLongPressEnd: (_) => setState(() {
              _touch = null;
              _hit = null;
            }),
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _TrendPainter(
                      series: widget.series,
                      xLabels: widget.xLabels,
                      thresholds: widget.thresholds,
                      yMinOverride: widget.yMin,
                      yMaxOverride: widget.yMax,
                      yLabel: widget.yLabel,
                      selected: widget.selected ?? _hit,
                      pointLabels: widget.pointLabels,
                    ),
                  ),
                ),
                if (_hit != null && _touch != null)
                  ChartTooltip(
                    at: _touch!,
                    bounds: size,
                    lines: [
                      widget.xLabels[_hit!],
                      for (final s in widget.series)
                        if (_hit! < s.values.length && s.values[_hit!] != null)
                          '${s.label}: '
                              '${s.values[_hit!]!.toStringAsFixed(1)}${s.unit}',
                    ],
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter({
    required this.series,
    required this.xLabels,
    required this.thresholds,
    required this.yMinOverride,
    required this.yMaxOverride,
    required this.yLabel,
    required this.selected,
    required this.pointLabels,
  });

  final List<TrendSeries> series;
  final List<String> xLabels;
  final List<(double, Color, String)> thresholds;
  final double? yMinOverride;
  final double? yMaxOverride;
  final String Function(double)? yLabel;
  final int? selected;
  final bool pointLabels;

  @override
  void paint(Canvas canvas, Size size) {
    final n = xLabels.length;
    if (n == 0) return;

    var lo = double.infinity;
    var hi = -double.infinity;
    for (final s in series) {
      for (var i = 0; i < s.values.length; i++) {
        final v = s.values[i];
        if (v == null) continue;
        lo = math.min(lo, v);
        hi = math.max(hi, v);
        final b = s.band != null && i < s.band!.length ? s.band![i] : null;
        if (b != null) {
          lo = math.min(lo, b.$1);
          hi = math.max(hi, b.$2);
        }
      }
    }
    for (final t in thresholds) {
      lo = math.min(lo, t.$1);
      hi = math.max(hi, t.$1);
    }
    if (!lo.isFinite || !hi.isFinite) return;

    // A little headroom, and never a zero-height domain.
    final pad = math.max(1.0, (hi - lo) * 0.14);
    final yMin = yMinOverride ?? (lo - pad);
    final yMax = yMaxOverride ?? (hi + pad);

    final frame = ChartFrame.of(
      size,
      xMin: 0,
      xMax: (n - 1).toDouble(),
      yMin: yMin,
      yMax: yMax == yMin ? yMin + 1 : yMax,
    );

    frame.paintGrid(
      canvas,
      yLabel: yLabel ?? (v) => v.toStringAsFixed(0),
    );

    for (final t in thresholds) {
      frame.paintThreshold(canvas, t.$1, color: t.$2, label: t.$3);
    }

    // x labels, thinned so they never collide.
    final step = n > 1 ? frame.plot.width / (n - 1) : frame.plot.width;
    final every = math.max(1, (56 / math.max(1, step)).ceil());
    for (var i = 0; i < n; i++) {
      if (i % every != 0 && i != n - 1) continue;
      paintChartLabel(canvas, xLabels[i],
          Offset(frame.x.px(i.toDouble()), frame.plot.bottom + 4),
          centre: true, size: 9.5);
    }

    if (selected != null && selected! < n) {
      final x = frame.x.px(selected!.toDouble());
      canvas.drawLine(
        Offset(x, frame.plot.top),
        Offset(x, frame.plot.bottom),
        Paint()
          ..color = RehabColors.actual.withValues(alpha: 0.5)
          ..strokeWidth = 1.5,
      );
    }

    canvas.save();
    canvas.clipRect(frame.plot.inflate(6));

    // Bands first, under every line.
    for (final s in series) {
      final band = s.band;
      if (band == null) continue;
      final path = Path();
      var started = false;
      for (var i = 0; i < n && i < band.length; i++) {
        final b = band[i];
        if (b == null) continue;
        final p = frame.at(i.toDouble(), b.$2);
        if (!started) {
          path.moveTo(p.dx, p.dy);
          started = true;
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      for (var i = math.min(n, band.length) - 1; i >= 0; i--) {
        final b = band[i];
        if (b == null) continue;
        final p = frame.at(i.toDouble(), b.$1);
        path.lineTo(p.dx, p.dy);
      }
      if (started) {
        path.close();
        canvas.drawPath(
            path, Paint()..color = s.color.withValues(alpha: 0.13));
      }
    }

    for (final s in series) {
      _paintSeries(canvas, frame, s, n);
    }

    canvas.restore();
  }

  void _paintSeries(Canvas canvas, ChartFrame frame, TrendSeries s, int n) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..color = s.color;

    // Each run of consecutive non-null values is its own segment. A gap is
    // drawn as a gap: joining across one would invent a measurement.
    Offset? prev;
    for (var i = 0; i < n && i < s.values.length; i++) {
      final v = s.values[i];
      if (v == null) {
        prev = null;
        continue;
      }
      final p = frame.at(i.toDouble(), v);
      if (prev != null) {
        if (s.dashed) {
          dashedLine(canvas, prev, p, paint);
        } else {
          canvas.drawLine(prev, p, paint);
        }
      }
      prev = p;
    }

    // Points, with a surface ring so overlapping series stay countable.
    // Suppressed when they would merge into the line anyway.
    final step = n > 1 ? frame.plot.width / (n - 1) : frame.plot.width;
    if (step > 9) {
      for (var i = 0; i < n && i < s.values.length; i++) {
        final v = s.values[i];
        if (v == null) continue;
        final p = frame.at(i.toDouble(), v);
        canvas.drawCircle(p, 4.6, Paint()..color = RehabColors.surface);
        canvas.drawCircle(p, 3.4, Paint()..color = s.color);
      }
    }

    // Direct label on the last real point, so identity never rests on the
    // legend alone.
    if (pointLabels) {
      for (var i = math.min(n, s.values.length) - 1; i >= 0; i--) {
        final v = s.values[i];
        if (v == null) continue;
        final p = frame.at(i.toDouble(), v);
        paintChartLabel(canvas, s.label, Offset(p.dx - 7, p.dy - 9),
            anchorRight: true, color: s.color, size: 9.5);
        break;
      }
    }
  }

  @override
  bool shouldRepaint(_TrendPainter old) =>
      old.series.length != series.length ||
      old.xLabels.length != xLabels.length ||
      old.selected != selected ||
      old.thresholds.length != thresholds.length;
}

/// The fatigue trend: the sleeve's own `[FT1]` comparison, rep by rep.
///
/// 100% means no change against the session's first reps. The dashed lines are
/// the sleeve's thresholds, so this chart and the device always agree about
/// when a sign was counted.
class FatigueTrendChart extends StatelessWidget {
  const FatigueTrendChart({
    super.key,
    required this.snapshots,
    this.height = 200,
  });

  final List<FatigueSnapshot> snapshots;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (snapshots.isEmpty) {
      return SizedBox(
        height: height,
        child: const ChartEmpty(
          message: 'The sleeve compares each rep with the session\'s first '
              'three. Nothing to compare until the fourth rep.',
          icon: Icons.battery_alert_outlined,
        ),
      );
    }

    return TrendChart(
      height: height,
      pointLabels: false,
      xLabels: [for (var i = 0; i < snapshots.length; i++) 'rep ${i + 4}'],
      yLabel: (v) => '${v.toStringAsFixed(0)}%',
      thresholds: [
        (
          FatigueSnapshot.rangeThresholdPercent,
          ChartPalette.series[0],
          'range sign below'
        ),
        (
          FatigueSnapshot.effortThresholdPercent,
          ChartPalette.series[1],
          'effort sign above'
        ),
        (
          FatigueSnapshot.timeThresholdPercent,
          ChartPalette.series[2],
          'time sign above'
        ),
      ],
      series: [
        TrendSeries(
          label: 'Range',
          unit: '%',
          color: ChartPalette.series[0],
          values: [for (final s in snapshots) s.rangePercent],
        ),
        TrendSeries(
          label: 'Effort',
          unit: '%',
          color: ChartPalette.series[1],
          values: [for (final s in snapshots) s.effortPercent],
        ),
        TrendSeries(
          label: 'Rep time',
          unit: '%',
          color: ChartPalette.series[2],
          values: [for (final s in snapshots) s.timePercent],
        ),
      ],
    );
  }
}

/// Legend items for the fatigue chart. Kept beside the chart so the three
/// series are named in text, not by colour alone.
List<LegendItem> fatigueLegend() => const [
      LegendItem('Range', Color(0xFF2F9FD4)),
      LegendItem('Effort', Color(0xFFDE6A45)),
      LegendItem('Rep time', Color(0xFFA855B8)),
    ];
