/// Per-repetition bar charts: peak angle reached, and how long each took.
///
/// One bar per attempt, in order, which makes the session's shape visible in a
/// way the rep table cannot: a steady decline across twenty bars is obvious at
/// a glance and invisible in a list of numbers.
///
/// ## Why the colour is status and not series
///
/// These bars are not categories. Each one is a single measurement that either
/// met a criterion or did not, so the colour carries state — reached the
/// target, below it, flagged — from the reserved status palette. Every state
/// also carries a shape or a label, because colour alone is not an acceptable
/// encoding in a device a stroke patient uses.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../session/rep_log.dart';
import '../theme.dart';
import 'chart_kit.dart';

/// Highest angle reached in each counted rep.
class PeakAngleBars extends StatelessWidget {
  const PeakAngleBars({
    super.key,
    required this.reps,
    required this.peakAngleDeg,
    required this.targetAngleDeg,
    this.selected,
    this.onSelect,
    this.height = 190,
  });

  /// Counted reps only. A partial has no bar — it reached no countable peak,
  /// and giving it one would say it did.
  final List<RepRow> reps;

  /// The criterion a rep had to pass, which is 80% of the target.
  final double peakAngleDeg;

  /// The therapist's target, which is further out and is not the criterion.
  final double targetAngleDeg;

  final int? selected;
  final ValueChanged<int>? onSelect;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (reps.isEmpty) {
      return SizedBox(
        height: height,
        child: const ChartEmpty(
          message: 'No counted reps yet. Partial reps get no bar — they '
              'reached no countable peak.',
          icon: Icons.bar_chart,
        ),
      );
    }
    return _BarPlot(
      height: height,
      count: reps.length,
      selected: selected,
      onSelect: onSelect,
      painter: (size, sel) => _PeakBarsPainter(
        reps: reps,
        peakAngleDeg: peakAngleDeg,
        targetAngleDeg: targetAngleDeg,
        selected: sel,
      ),
      tooltipFor: (i) {
        final r = reps[i];
        return [
          'Rep ${r.index ?? i + 1}',
          '${r.peakAngleDeg.toStringAsFixed(0)}° peak',
          if (r.romPercent != null) '${r.romPercent}% of target',
          r.outcome.label,
        ];
      },
    );
  }
}

class _PeakBarsPainter extends CustomPainter {
  _PeakBarsPainter({
    required this.reps,
    required this.peakAngleDeg,
    required this.targetAngleDeg,
    required this.selected,
  });

  final List<RepRow> reps;
  final double peakAngleDeg;
  final double targetAngleDeg;
  final int? selected;

  @override
  void paint(Canvas canvas, Size size) {
    var top = math.max(targetAngleDeg, peakAngleDeg) * 1.15;
    for (final r in reps) {
      if (r.peakAngleDeg > top) top = r.peakAngleDeg * 1.08;
    }

    final frame = ChartFrame.of(size,
        xMin: 0, xMax: reps.length.toDouble(), yMin: 0, yMax: top);

    frame.paintGrid(canvas, yLabel: (v) => '${v.toStringAsFixed(0)}°');

    frame.paintThreshold(canvas, peakAngleDeg,
        color: RehabColors.good, label: 'counts above');
    if (targetAngleDeg > peakAngleDeg + 1) {
      frame.paintThreshold(canvas, targetAngleDeg,
          color: RehabColors.inkFaint, label: 'full target');
    }

    final slot = frame.plot.width / reps.length;
    // A 2px surface gap between adjacent bars, so two equal bars read as two.
    final barW = math.max(2.0, math.min(slot - 2, 26.0));

    for (var i = 0; i < reps.length; i++) {
      final r = reps[i];
      final cx = frame.plot.left + slot * (i + 0.5);
      final yTop = frame.y.px(r.peakAngleDeg.clamp(0, top));

      final colour = r.flagged
          ? RehabColors.warn
          : r.peakAngleDeg >= targetAngleDeg
              ? RehabColors.good
              : r.peakAngleDeg >= peakAngleDeg
                  ? RehabColors.good.withValues(alpha: 0.62)
                  : RehabColors.warn.withValues(alpha: 0.7);

      final rect =
          Rect.fromLTRB(cx - barW / 2, yTop, cx + barW / 2, frame.plot.bottom);
      paintBar(canvas, rect, colour);

      if (selected == i) {
        canvas.drawRect(
          rect.inflate(2),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = RehabColors.actual,
        );
      }

      // A flagged rep gets a mark as well as a colour.
      if (r.flagged) {
        canvas.drawCircle(Offset(cx, yTop - 7), 2.6,
            Paint()..color = RehabColors.warn);
      }

      if (slot > 20) {
        paintChartLabel(
            canvas, '${r.index ?? i + 1}', Offset(cx, frame.plot.bottom + 4),
            centre: true, size: 9.5);
      }
    }
  }

  @override
  bool shouldRepaint(_PeakBarsPainter old) =>
      old.reps.length != reps.length ||
      old.selected != selected ||
      old.peakAngleDeg != peakAngleDeg ||
      old.targetAngleDeg != targetAngleDeg;
}

/// How long each rep took, against the pace window.
///
/// Stacked into lift, hold and lower where the split could be reconstructed,
/// which turns "that one was slow" into "that one paused at the top".
class RepDurationBars extends StatelessWidget {
  const RepDurationBars({
    super.key,
    required this.reps,
    required this.tempoMinS,
    required this.tempoMaxS,
    this.selected,
    this.onSelect,
    this.height = 190,
  });

  final List<RepRow> reps;
  final double tempoMinS;
  final double tempoMaxS;
  final int? selected;
  final ValueChanged<int>? onSelect;
  final double height;

  bool get _anyPhases => reps.any((r) => r.phases != null);

  @override
  Widget build(BuildContext context) {
    if (reps.isEmpty) {
      return SizedBox(
        height: height,
        child: const ChartEmpty(
            message: 'No counted reps yet.', icon: Icons.timer_outlined),
      );
    }
    return _BarPlot(
      height: height,
      count: reps.length,
      selected: selected,
      onSelect: onSelect,
      painter: (size, sel) => _DurationBarsPainter(
        reps: reps,
        tempoMinS: tempoMinS,
        tempoMaxS: tempoMaxS,
        selected: sel,
        stacked: _anyPhases,
      ),
      tooltipFor: (i) {
        final r = reps[i];
        final p = r.phases;
        return [
          'Rep ${r.index ?? i + 1}',
          '${r.durationS.toStringAsFixed(1)} s total',
          if (p != null)
            'lift ${p.liftS.toStringAsFixed(1)} · hold '
                '${p.holdS.toStringAsFixed(1)} · lower '
                '${p.lowerS.toStringAsFixed(1)}',
          if (r.tempoText != null) 'pace: ${r.tempoText}',
        ];
      },
    );
  }
}

class _DurationBarsPainter extends CustomPainter {
  _DurationBarsPainter({
    required this.reps,
    required this.tempoMinS,
    required this.tempoMaxS,
    required this.selected,
    required this.stacked,
  });

  final List<RepRow> reps;
  final double tempoMinS;
  final double tempoMaxS;
  final int? selected;
  final bool stacked;

  @override
  void paint(Canvas canvas, Size size) {
    var top = tempoMaxS * 1.4;
    for (final r in reps) {
      if (r.durationS > top) top = r.durationS * 1.1;
    }

    final frame =
        ChartFrame.of(size, xMin: 0, xMax: reps.length.toDouble(), yMin: 0, yMax: top);

    frame.paintGrid(canvas, yLabel: (v) => '${v.toStringAsFixed(0)}s');
    frame.paintBand(canvas, tempoMinS, tempoMaxS, RehabColors.good,
        label: 'ideal ${tempoMinS.toStringAsFixed(0)}'
            '–${tempoMaxS.toStringAsFixed(0)} s');

    final slot = frame.plot.width / reps.length;
    final barW = math.max(2.0, math.min(slot - 2, 26.0));

    for (var i = 0; i < reps.length; i++) {
      final r = reps[i];
      final cx = frame.plot.left + slot * (i + 0.5);
      final inBand = r.durationS >= tempoMinS && r.durationS <= tempoMaxS;
      final base = inBand ? RehabColors.good : RehabColors.warn;

      final phases = r.phases;
      if (stacked && phases != null && phases.totalS > 0.05) {
        // Stacked by phase, with a 2px surface gap between segments so the
        // three parts stay countable.
        var acc = 0.0;
        final segs = <(double, Color)>[
          (phases.liftS, ChartPalette.series[0]),
          (phases.holdS, ChartPalette.series[2]),
          (phases.lowerS, ChartPalette.series[1]),
        ];
        for (final (len, colour) in segs) {
          if (len <= 0) continue;
          final y0 = frame.y.px((acc + len).clamp(0, top));
          final y1 = frame.y.px(acc.clamp(0, top));
          final rect = Rect.fromLTRB(cx - barW / 2, y0, cx + barW / 2,
              math.max(y0 + 1, y1 - 2));
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(2)),
            Paint()..color = colour.withValues(alpha: inBand ? 1.0 : 0.65),
          );
          acc += len;
        }
        // An outline in the status colour, so the pace verdict survives the
        // phase colouring.
        final totalTop = frame.y.px(phases.totalS.clamp(0, top));
        canvas.drawRect(
          Rect.fromLTRB(
              cx - barW / 2, totalTop, cx + barW / 2, frame.plot.bottom),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = inBand ? 1.0 : 1.8
            ..color = base.withValues(alpha: inBand ? 0.35 : 0.95),
        );
      } else {
        final rect = Rect.fromLTRB(cx - barW / 2,
            frame.y.px(r.durationS.clamp(0, top)), cx + barW / 2, frame.plot.bottom);
        paintBar(canvas, rect, base);
      }

      if (selected == i) {
        canvas.drawRect(
          Rect.fromLTRB(cx - barW / 2 - 2, frame.plot.top,
              cx + barW / 2 + 2, frame.plot.bottom),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = RehabColors.actual,
        );
      }

      if (slot > 20) {
        paintChartLabel(
            canvas, '${r.index ?? i + 1}', Offset(cx, frame.plot.bottom + 4),
            centre: true, size: 9.5);
      }
    }
  }

  @override
  bool shouldRepaint(_DurationBarsPainter old) =>
      old.reps.length != reps.length ||
      old.selected != selected ||
      old.stacked != stacked ||
      old.tempoMinS != tempoMinS ||
      old.tempoMaxS != tempoMaxS;
}

/// Tap handling and tooltips, shared by both bar charts.
class _BarPlot extends StatefulWidget {
  const _BarPlot({
    required this.height,
    required this.count,
    required this.painter,
    required this.tooltipFor,
    this.selected,
    this.onSelect,
  });

  final double height;
  final int count;
  final CustomPainter Function(Size size, int? selected) painter;
  final List<String> Function(int index) tooltipFor;
  final int? selected;
  final ValueChanged<int>? onSelect;

  @override
  State<_BarPlot> createState() => _BarPlotState();
}

class _BarPlotState extends State<_BarPlot> {
  Offset? _touch;
  int? _hit;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, box) {
          final size = Size(box.maxWidth, widget.height);
          final plotLeft = ChartFrame.leftGutter;
          final plotWidth =
              math.max(1.0, box.maxWidth - plotLeft - ChartFrame.rightPad);

          int? indexAt(Offset p) {
            if (p.dx < plotLeft) return null;
            final i = ((p.dx - plotLeft) / plotWidth * widget.count).floor();
            return i >= 0 && i < widget.count ? i : null;
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
                    painter: widget.painter(size, widget.selected ?? _hit),
                  ),
                ),
                if (_hit != null && _touch != null)
                  ChartTooltip(
                    at: _touch!,
                    bounds: size,
                    lines: widget.tooltipFor(_hit!),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
