/// Time charts: the overview strip, and the angle and effort traces.
///
/// ## Why two panels and not one chart with two axes
///
/// Elbow angle is in degrees and muscle effort is a percentage of a calibrated
/// squeeze. Drawn on two y-scales in one frame they appear to cross, and the
/// crossing point is an artefact of the two scalings — it means nothing, and it
/// is the first thing anyone's eye goes to. So they are two panels sharing one
/// time axis. That makes the true comparison — *when* the muscle worked
/// relative to *when* the arm moved — the easy one to read, which is the
/// comparison that actually diagnoses a passive lift.
///
/// ## The window
///
/// A ten-minute session at 10 Hz does not fit on a phone screen, and squeezing
/// it in turns forty curls into a solid block. The overview strip shows the
/// whole session as one sparkline with a draggable window, and the two detail
/// panels show that window. Dragging either one moves both.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../protocol/enums.dart';
import '../../session/rep_log.dart';
import '../../session/session_record.dart';
import '../theme.dart';
import 'chart_kit.dart';

/// A time window into a session, in seconds from its start.
class TimeWindow {
  const TimeWindow(this.fromS, this.toS);

  final double fromS;
  final double toS;

  double get spanS => math.max(0.5, toS - fromS);

  TimeWindow shifted(double byS, {required double maxS}) {
    final span = spanS;
    var a = fromS + byS;
    if (a < 0) a = 0;
    if (a + span > maxS) a = math.max(0, maxS - span);
    return TimeWindow(a, a + span);
  }

  TimeWindow centredOn(double atS, {required double maxS}) =>
      TimeWindow(0, spanS).shifted(atS - spanS / 2, maxS: maxS);

  TimeWindow zoomed(double factor, {required double maxS}) {
    final mid = (fromS + toS) / 2;
    final span = (spanS * factor).clamp(2.0, math.max(2.0, maxS));
    var a = mid - span / 2;
    if (a < 0) a = 0;
    if (a + span > maxS) a = math.max(0, maxS - span);
    return TimeWindow(a, a + span);
  }

  bool contains(double s) => s >= fromS && s <= toS;
}

/// The whole session at a glance, with the shown window marked.
///
/// Each bump is one curl. Clicking or dragging inside moves the window, which
/// is the only navigation on this screen that lets someone find "the bit where
/// it went wrong" without scrubbing.
class OverviewStrip extends StatelessWidget {
  const OverviewStrip({
    super.key,
    required this.samples,
    required this.reps,
    required this.window,
    required this.onWindow,
    required this.peakAngleDeg,
    this.faults = const [],
    this.height = 62,
  });

  final List<TraceSample> samples;
  final List<RepRow> reps;
  final TimeWindow window;
  final ValueChanged<TimeWindow> onWindow;
  final double peakAngleDeg;
  final List<FaultSpan> faults;
  final double height;

  double get _totalS =>
      samples.isEmpty ? 1 : math.max(1, samples.last.tMs / 1000);

  @override
  Widget build(BuildContext context) {
    if (samples.length < 2) {
      return SizedBox(
        height: height,
        child: const ChartEmpty(
            message: 'No trace yet — start a set and the session appears here.'),
      );
    }
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, box) {
          void moveTo(double dx) {
            final s = dx / box.maxWidth * _totalS;
            onWindow(window.centredOn(s, maxS: _totalS));
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => moveTo(d.localPosition.dx),
            onHorizontalDragUpdate: (d) => moveTo(d.localPosition.dx),
            child: CustomPaint(
              painter: _OverviewPainter(
                samples: samples,
                reps: reps,
                window: window,
                totalS: _totalS,
                peakAngleDeg: peakAngleDeg,
                faults: faults,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _OverviewPainter extends CustomPainter {
  _OverviewPainter({
    required this.samples,
    required this.reps,
    required this.window,
    required this.totalS,
    required this.peakAngleDeg,
    required this.faults,
  });

  final List<TraceSample> samples;
  final List<RepRow> reps;
  final TimeWindow window;
  final double totalS;
  final double peakAngleDeg;
  final List<FaultSpan> faults;

  @override
  void paint(Canvas canvas, Size size) {
    var maxAngle = peakAngleDeg * 1.25;
    for (final s in samples) {
      if (s.angleDeg > maxAngle) maxAngle = s.angleDeg;
    }

    final frame = ChartFrame.of(
      size,
      xMin: 0,
      xMax: totalS,
      yMin: 0,
      yMax: maxAngle,
      left: 2,
      bottom: 2,
    );

    for (final f in faults) {
      frame.paintFault(canvas, f.fromMs / 1000, f.toMs / 1000);
    }

    // The trace, as a filled area: at this scale individual curls are a few
    // pixels wide and a 1px line disappears, whereas a filled bump does not.
    final path = Path()..moveTo(frame.plot.left, frame.plot.bottom);
    for (final s in samples) {
      path.lineTo(frame.x.px(s.tMs / 1000), frame.y.px(s.angleDeg));
    }
    path.lineTo(frame.plot.right, frame.plot.bottom);
    path.close();
    canvas.drawPath(
        path, Paint()..color = ChartPalette.series[0].withValues(alpha: 0.42));

    // Rep marks along the baseline, so the strip says which bumps counted.
    for (final r in reps) {
      final x = frame.x.px(_repSeconds(r));
      final colour = switch (r.outcome) {
        RepOutcome.onTarget => RehabColors.good,
        RepOutcome.countedPaceOff => RehabColors.good,
        RepOutcome.flagged => RehabColors.warn,
        RepOutcome.partial => RehabColors.inkFaint,
        RepOutcome.passive => RehabColors.bad,
      };
      canvas.drawCircle(
          Offset(x, frame.plot.bottom - 2.5), 2.2, Paint()..color = colour);
    }

    // The shown window.
    final a = frame.x.px(window.fromS);
    final b = frame.x.px(window.toS);
    final rect = Rect.fromLTRB(
        math.min(a, b), frame.plot.top, math.max(a, b) + 1, frame.plot.bottom);
    canvas.drawRect(
      rect,
      Paint()..color = RehabColors.actual.withValues(alpha: 0.14),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = RehabColors.actual.withValues(alpha: 0.9),
    );
  }

  double _repSeconds(RepRow r) {
    if (reps.isEmpty) return 0;
    final t0 = reps.first.atUs;
    return (r.atUs - t0) / 1e6;
  }

  @override
  bool shouldRepaint(_OverviewPainter old) =>
      old.samples.length != samples.length ||
      old.reps.length != reps.length ||
      old.window.fromS != window.fromS ||
      old.window.toS != window.toS;
}

/// One trace over time. Used twice — angle, then effort — on a shared axis.
class TraceChart extends StatefulWidget {
  const TraceChart({
    super.key,
    required this.samples,
    required this.window,
    required this.onWindow,
    required this.value,
    required this.color,
    required this.yMax,
    this.yMin = 0,
    this.thresholds = const [],
    this.bands = const [],
    this.reps = const [],
    this.faults = const [],
    this.repT0Us,
    this.yLabel,
    this.showTimeAxis = true,
    this.height = 180,
    this.shadeActivation = false,
    this.selectedRepIndex,
    this.tooltipUnit = '',
  });

  final List<TraceSample> samples;
  final TimeWindow window;
  final ValueChanged<TimeWindow> onWindow;

  /// Which number of a sample this chart draws.
  final double Function(TraceSample) value;

  final Color color;
  final double yMax;
  final double yMin;

  /// Reference lines: value, colour, label.
  final List<(double, Color, String)> thresholds;

  /// Shaded ranges: low, high, colour, label.
  final List<(double, double, Color, String)> bands;

  final List<RepRow> reps;
  final List<FaultSpan> faults;

  /// Device time of the first rep, so rep marks land on the same axis as the
  /// samples. Without it, rep marks are placed relative to the first rep
  /// rather than to the session start.
  final int? repT0Us;

  final String Function(double)? yLabel;
  final bool showTimeAxis;
  final double height;

  /// Tint the stretches where the sleeve says the muscle was working. Only
  /// worth it on the effort trace, where it explains the activation gate.
  final bool shadeActivation;

  final int? selectedRepIndex;
  final String tooltipUnit;

  @override
  State<TraceChart> createState() => _TraceChartState();
}

class _TraceChartState extends State<TraceChart> {
  Offset? _touch;
  TraceSample? _hit;

  double get _totalS => widget.samples.isEmpty
      ? 1
      : math.max(1, widget.samples.last.tMs / 1000);

  @override
  Widget build(BuildContext context) {
    if (widget.samples.length < 2) {
      return SizedBox(
        height: widget.height,
        child: const ChartEmpty(message: 'Nothing recorded for this stretch.'),
      );
    }

    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, box) {
          final size = Size(box.maxWidth, widget.height);

          void probe(Offset p) {
            final frame = _frame(size);
            final s = frame.x.value(p.dx);
            TraceSample? best;
            var bestD = double.infinity;
            for (final x in widget.samples) {
              final d = (x.tMs / 1000 - s).abs();
              if (d < bestD) {
                bestD = d;
                best = x;
              }
            }
            setState(() {
              _touch = p;
              // Only within half a second: past that the tooltip would name a
              // sample the finger is nowhere near.
              _hit = bestD < 0.5 ? best : null;
            });
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => probe(d.localPosition),
            onLongPressStart: (d) => probe(d.localPosition),
            onLongPressMoveUpdate: (d) => probe(d.localPosition),
            onLongPressEnd: (_) => setState(() {
              _touch = null;
              _hit = null;
            }),
            // Dragging sideways moves through time, which is how anyone
            // expects to navigate a trace on a touch screen.
            onHorizontalDragUpdate: (d) {
              final perPx = widget.window.spanS / box.maxWidth;
              widget.onWindow(widget.window
                  .shifted(-d.delta.dx * perPx, maxS: _totalS));
              if (_touch != null) setState(() => _touch = null);
            },
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _TracePainter(
                      samples: widget.samples,
                      window: widget.window,
                      value: widget.value,
                      color: widget.color,
                      yMin: widget.yMin,
                      yMax: widget.yMax,
                      thresholds: widget.thresholds,
                      bands: widget.bands,
                      reps: widget.reps,
                      faults: widget.faults,
                      repT0Us: widget.repT0Us,
                      yLabel: widget.yLabel,
                      showTimeAxis: widget.showTimeAxis,
                      shadeActivation: widget.shadeActivation,
                      selectedRepIndex: widget.selectedRepIndex,
                      cursor: _touch,
                    ),
                  ),
                ),
                if (_hit != null && _touch != null)
                  ChartTooltip(
                    at: _touch!,
                    bounds: size,
                    lines: [
                      mmss(_hit!.tMs / 1000),
                      '${widget.value(_hit!).toStringAsFixed(1)}'
                          '${widget.tooltipUnit}',
                      if (_hit!.activationOn) 'muscle working',
                      if (_hit!.repState != 0)
                        RepState.fromWire(_hit!.repState).label.toLowerCase(),
                    ],
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  ChartFrame _frame(Size size) => ChartFrame.of(
        size,
        xMin: widget.window.fromS,
        xMax: widget.window.toS,
        yMin: widget.yMin,
        yMax: widget.yMax,
        bottom: widget.showTimeAxis ? ChartFrame.bottomGutter : 6,
      );
}

class _TracePainter extends CustomPainter {
  _TracePainter({
    required this.samples,
    required this.window,
    required this.value,
    required this.color,
    required this.yMin,
    required this.yMax,
    required this.thresholds,
    required this.bands,
    required this.reps,
    required this.faults,
    required this.repT0Us,
    required this.yLabel,
    required this.showTimeAxis,
    required this.shadeActivation,
    required this.selectedRepIndex,
    required this.cursor,
  });

  final List<TraceSample> samples;
  final TimeWindow window;
  final double Function(TraceSample) value;
  final Color color;
  final double yMin;
  final double yMax;
  final List<(double, Color, String)> thresholds;
  final List<(double, double, Color, String)> bands;
  final List<RepRow> reps;
  final List<FaultSpan> faults;
  final int? repT0Us;
  final String Function(double)? yLabel;
  final bool showTimeAxis;
  final bool shadeActivation;
  final int? selectedRepIndex;
  final Offset? cursor;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = ChartFrame.of(
      size,
      xMin: window.fromS,
      xMax: window.toS,
      yMin: yMin,
      yMax: yMax,
      bottom: showTimeAxis ? ChartFrame.bottomGutter : 6,
    );

    canvas.save();
    canvas.clipRect(frame.plot.inflate(1));

    for (final b in bands) {
      frame.paintBand(canvas, b.$1, b.$2, b.$3, label: b.$4);
    }

    frame.paintGrid(
      canvas,
      yLabel: yLabel ?? (v) => v.toStringAsFixed(0),
      xLabel: showTimeAxis ? mmss : null,
      xTicks: niceTicks(window.fromS, window.toS, target: 4),
    );

    for (final f in faults) {
      frame.paintFault(canvas, f.fromMs / 1000, f.toMs / 1000);
    }

    if (shadeActivation) _paintActivation(canvas, frame);

    for (final t in thresholds) {
      frame.paintThreshold(canvas, t.$1, color: t.$2, label: t.$3);
    }

    _paintTrace(canvas, frame);
    _paintRepMarks(canvas, frame);

    if (cursor != null) {
      canvas.drawLine(
        Offset(cursor!.dx, frame.plot.top),
        Offset(cursor!.dx, frame.plot.bottom),
        Paint()
          ..color = RehabColors.ink.withValues(alpha: 0.35)
          ..strokeWidth = 1,
      );
    }

    canvas.restore();
  }

  /// Where the sleeve says the muscle was on. Drawn as low bars along the
  /// baseline rather than as a full-height tint: a tint behind the trace
  /// changes how the trace itself reads, and this is a separate fact about the
  /// same instant.
  void _paintActivation(Canvas canvas, ChartFrame frame) {
    final paint = Paint()..color = RehabColors.muscle.withValues(alpha: 0.22);
    double? runStart;
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      final t = s.tMs / 1000;
      if (s.activationOn && runStart == null) runStart = t;
      final ends = !s.activationOn || i == samples.length - 1;
      if (ends && runStart != null) {
        final a = frame.x.clampPx(runStart);
        final b = frame.x.clampPx(t);
        if (b > a) {
          canvas.drawRect(
            Rect.fromLTRB(a, frame.plot.bottom - 7, b, frame.plot.bottom),
            paint,
          );
        }
        runStart = null;
      }
    }
  }

  void _paintTrace(Canvas canvas, ChartFrame frame) {
    final visible = samples
        .where((s) => window.contains(s.tMs / 1000))
        .toList(growable: false);
    if (visible.length < 2) return;

    final line = Path();
    final area = Path()
      ..moveTo(frame.x.px(visible.first.tMs / 1000), frame.plot.bottom);
    for (var i = 0; i < visible.length; i++) {
      final p = frame.at(visible[i].tMs / 1000, value(visible[i]));
      if (i == 0) {
        line.moveTo(p.dx, p.dy);
      } else {
        line.lineTo(p.dx, p.dy);
      }
      area.lineTo(p.dx, p.dy);
    }
    area
      ..lineTo(frame.x.px(visible.last.tMs / 1000), frame.plot.bottom)
      ..close();

    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0.26),
            color.withValues(alpha: 0.02),
          ],
        ).createShader(frame.plot),
    );

    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  /// Rep markers, at the moment each attempt resolved.
  void _paintRepMarks(Canvas canvas, ChartFrame frame) {
    if (reps.isEmpty) return;
    final t0 = repT0Us ?? reps.first.atUs;

    for (var i = 0; i < reps.length; i++) {
      final r = reps[i];
      final t = (r.atUs - t0) / 1e6;
      if (!window.contains(t)) continue;
      final x = frame.x.px(t);
      final selected = selectedRepIndex == i;

      final (colour, filled) = switch (r.outcome) {
        RepOutcome.onTarget => (RehabColors.good, true),
        RepOutcome.countedPaceOff => (RehabColors.good, true),
        RepOutcome.flagged => (RehabColors.warn, true),
        RepOutcome.partial => (RehabColors.inkFaint, false),
        RepOutcome.passive => (RehabColors.bad, false),
      };

      canvas.drawLine(
        Offset(x, frame.plot.top),
        Offset(x, frame.plot.bottom),
        Paint()
          ..color = colour.withValues(alpha: selected ? 0.75 : 0.30)
          ..strokeWidth = selected ? 2.5 : 1.2,
      );

      // A 9px marker, which is the floor for something meant to be tapped,
      // with a surface ring so overlapping markers stay countable.
      final c = Offset(x, frame.plot.top + 9);
      canvas.drawCircle(c, 5.5, Paint()..color = RehabColors.surface);
      canvas.drawCircle(
        c,
        4.5,
        Paint()
          ..color = colour
          ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke
          ..strokeWidth = 2,
      );

      // Rep numbers, but only when there is room: a number on every marker at
      // forty reps in a 30-second window is a smear.
      if (r.index != null && frame.plot.width / math.max(1, reps.length) > 26) {
        paintChartLabel(canvas, '${r.index}', Offset(x, frame.plot.top + 20),
            centre: true, color: colour, size: 9.5);
      }
    }
  }

  @override
  bool shouldRepaint(_TracePainter old) =>
      old.samples.length != samples.length ||
      old.window.fromS != window.fromS ||
      old.window.toS != window.toS ||
      old.yMax != yMax ||
      old.reps.length != reps.length ||
      old.selectedRepIndex != selectedRepIndex ||
      old.cursor != cursor ||
      old.thresholds.length != thresholds.length;
}

/// A rolling live trace, for the therapist's "last 30 seconds".
///
/// Fed from the live window rather than the session recording, and redrawn off
/// a [ValueNotifier] so a 20 Hz update does not rebuild the screen around it.
class LiveTraceChart extends StatelessWidget {
  const LiveTraceChart({
    super.key,
    required this.revision,
    required this.samples,
    required this.value,
    required this.color,
    required this.yMax,
    this.yMin = 0,
    this.thresholds = const [],
    this.yLabel,
    this.height = 150,
    this.windowSeconds = 30,
    this.shadeActivation = false,
  });

  final ValueListenable<int> revision;

  /// Called at paint time, so the chart always draws the newest window
  /// without this widget holding a copy.
  final List<TraceSample> Function() samples;

  final double Function(TraceSample) value;
  final Color color;
  final double yMax;
  final double yMin;
  final List<(double, Color, String)> thresholds;
  final String Function(double)? yLabel;
  final double height;
  final int windowSeconds;
  final bool shadeActivation;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: RepaintBoundary(
        child: ValueListenableBuilder<int>(
          valueListenable: revision,
          builder: (context, _, __) {
            final data = samples();
            if (data.length < 2) {
              return const ChartEmpty(
                  message: 'Waiting for the sleeve to send live data.');
            }
            final lastS = data.last.tMs / 1000;
            final from = math.max(0.0, lastS - windowSeconds);
            return CustomPaint(
              painter: _TracePainter(
                samples: data,
                window: TimeWindow(from, math.max(from + 1, lastS)),
                value: value,
                color: color,
                yMin: yMin,
                yMax: yMax,
                thresholds: thresholds,
                bands: const [],
                reps: const [],
                faults: const [],
                repT0Us: null,
                yLabel: yLabel,
                showTimeAxis: false,
                shadeActivation: shadeActivation,
                selectedRepIndex: null,
                cursor: null,
              ),
            );
          },
        ),
      ),
    );
  }
}
