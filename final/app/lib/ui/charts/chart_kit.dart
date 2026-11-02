/// Shared chart machinery: palette, scales, axes, legend, tooltips, tiles.
///
/// ## The series palette is not the UI palette
///
/// [RehabColors.actual] and [RehabColors.muscle] are UI accents, chosen bright
/// because the patient view is read at arm's length mid-exercise. They are not
/// a categorical chart palette and do not pass as one: both sit at OKLCH
/// L ≈ 0.77, outside the 0.48–0.67 band a dark chart surface needs, so two
/// series in those colours fight each other and the surface.
///
/// [ChartPalette.series] is a validated set of darker siblings of the same
/// three hues, so a chart still reads as part of this app while the series
/// actually separate. Checked with the dataviz validator against surface
/// `#181D23`: lightness band, chroma floor, CVD separation (worst adjacent
/// pair ΔE 20.4 protan / 13.6 tritan), normal-vision floor (ΔE 21.2) and
/// contrast all pass.
///
/// **Three slots, assigned in fixed order, never cycled.** Nothing here needs
/// a fourth categorical series; if something ever does, it folds into "other"
/// or becomes a second chart rather than getting a generated hue.
///
/// ## Two rules these charts do not break
///
/// **No dual axes.** Elbow angle and muscle effort are different quantities in
/// different units, and putting them on two y-scales in one frame invents a
/// crossing point that means nothing. They are drawn as two stacked panels
/// sharing one time axis, which is the comparison that is actually true.
///
/// **Status colours stay status.** Green, amber and red mean on target, needs
/// attention and problem. They are never pressed into service as "series 4",
/// and they always carry a label or a shape as well, because a colourblind
/// patient is not an edge case in a rehabilitation device.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

abstract final class ChartPalette {
  /// Categorical series, in fixed assignment order. Darker siblings of the
  /// app's blue, orange and purple. Validated — see the library comment.
  static const List<Color> series = [
    Color(0xFF2F9FD4),
    Color(0xFFDE6A45),
    Color(0xFFA855B8),
  ];

  static Color seriesAt(int i) => series[i % series.length];

  /// Recessive. A grid that competes with the data is worse than no grid.
  static const Color grid = Color(0xFF232A32);
  static const Color axis = Color(0xFF39434E);
  static const Color surface = RehabColors.surface;

  /// A band showing an acceptable range — the tempo window, the fatigue
  /// thresholds. Low alpha so marks stay legible over it.
  static Color band(Color of) => of.withValues(alpha: 0.12);

  /// A stretch where a sensor stopped answering. Hatched rather than tinted:
  /// a flat tint reads as a highlight, and this is the opposite — it marks
  /// readings that should not be trusted.
  static const Color faultInk = RehabColors.bad;
}

/// A linear mapping from data to pixels, with the inverse for hit-testing.
class Scale {
  const Scale({
    required this.domainMin,
    required this.domainMax,
    required this.rangeMin,
    required this.rangeMax,
  });

  final double domainMin;
  final double domainMax;
  final double rangeMin;
  final double rangeMax;

  double get span =>
      (domainMax - domainMin).abs() < 1e-9 ? 1.0 : domainMax - domainMin;

  double px(double value) =>
      rangeMin + (value - domainMin) / span * (rangeMax - rangeMin);

  double value(double pixel) =>
      domainMin + (pixel - rangeMin) / (rangeMax - rangeMin) * span;

  double clampPx(double value) {
    final lo = math.min(rangeMin, rangeMax);
    final hi = math.max(rangeMin, rangeMax);
    return px(value).clamp(lo, hi);
  }
}

/// "Nice" tick values for an axis: 1, 2 or 5 times a power of ten.
///
/// Worth doing properly rather than dividing the range into five: ticks at
/// 0, 23.4, 46.8 are read as noise, and an axis nobody reads is an axis that
/// is not doing its job.
List<double> niceTicks(double min, double max, {int target = 5}) {
  if (!(max > min)) return [min];
  final raw = (max - min) / target;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  final step = (norm < 1.5 ? 1 : norm < 3 ? 2 : norm < 7 ? 5 : 10) * mag;
  final first = (min / step).ceil() * step;
  final out = <double>[];
  for (var v = first; v <= max + step * 1e-6; v += step) {
    out.add(double.parse(v.toStringAsFixed(6)));
  }
  return out;
}

/// Axis and grid painting, shared so every chart's furniture matches.
class ChartFrame {
  const ChartFrame({
    required this.plot,
    required this.x,
    required this.y,
  });

  /// The drawing area, inside the labels.
  final Rect plot;
  final Scale x;
  final Scale y;

  static const double leftGutter = 42;
  static const double bottomGutter = 22;
  static const double topPad = 10;
  static const double rightPad = 10;

  static ChartFrame of(
    Size size, {
    required double xMin,
    required double xMax,
    required double yMin,
    required double yMax,
    double left = leftGutter,
    double bottom = bottomGutter,
  }) {
    final plot = Rect.fromLTRB(
      left,
      topPad,
      math.max(left + 1, size.width - rightPad),
      math.max(topPad + 1, size.height - bottom),
    );
    return ChartFrame(
      plot: plot,
      x: Scale(
        domainMin: xMin,
        domainMax: xMax,
        rangeMin: plot.left,
        rangeMax: plot.right,
      ),
      // Inverted: data grows upward, pixels grow downward.
      y: Scale(
        domainMin: yMin,
        domainMax: yMax,
        rangeMin: plot.bottom,
        rangeMax: plot.top,
      ),
    );
  }

  Offset at(double dx, double dy) => Offset(x.px(dx), y.px(dy));

  void paintGrid(
    Canvas canvas, {
    List<double>? yTicks,
    List<double>? xTicks,
    String Function(double)? yLabel,
    String Function(double)? xLabel,
  }) {
    final gridPaint = Paint()
      ..color = ChartPalette.grid
      ..strokeWidth = 1;

    for (final t in yTicks ?? niceTicks(y.domainMin, y.domainMax)) {
      final py = y.px(t);
      if (py < plot.top - 0.5 || py > plot.bottom + 0.5) continue;
      canvas.drawLine(Offset(plot.left, py), Offset(plot.right, py), gridPaint);
      if (yLabel != null) {
        _text(canvas, yLabel(t), Offset(plot.left - 6, py),
            align: TextAlign.right, anchorRight: true);
      }
    }

    for (final t in xTicks ?? niceTicks(x.domainMin, x.domainMax)) {
      final px = x.px(t);
      if (px < plot.left - 0.5 || px > plot.right + 0.5) continue;
      canvas.drawLine(
        Offset(px, plot.top),
        Offset(px, plot.bottom),
        gridPaint..color = ChartPalette.grid.withValues(alpha: 0.6),
      );
      if (xLabel != null) {
        _text(canvas, xLabel(t), Offset(px, plot.bottom + 4), centre: true);
      }
    }

    // The baseline is the one line worth more than the grid.
    canvas.drawLine(
      Offset(plot.left, plot.bottom),
      Offset(plot.right, plot.bottom),
      Paint()
        ..color = ChartPalette.axis
        ..strokeWidth = 1,
    );
  }

  /// A horizontal reference line — a threshold, a target, a criterion.
  ///
  /// Labelled at the right, because an unlabelled dashed line is a puzzle.
  void paintThreshold(
    Canvas canvas,
    double value, {
    required Color color,
    String? label,
    bool dashed = true,
    double width = 1.5,
  }) {
    final py = y.px(value);
    if (py < plot.top - 1 || py > plot.bottom + 1) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = width;
    if (dashed) {
      dashedLine(canvas, Offset(plot.left, py), Offset(plot.right, py), paint);
    } else {
      canvas.drawLine(Offset(plot.left, py), Offset(plot.right, py), paint);
    }
    if (label != null) {
      _text(canvas, label, Offset(plot.right - 4, py - 13),
          align: TextAlign.right, anchorRight: true, color: color);
    }
  }

  /// A shaded horizontal band — an acceptable range.
  void paintBand(Canvas canvas, double lo, double hi, Color color,
      {String? label}) {
    final a = y.px(lo);
    final b = y.px(hi);
    final rect = Rect.fromLTRB(
      plot.left,
      math.min(a, b).clamp(plot.top, plot.bottom),
      plot.right,
      math.max(a, b).clamp(plot.top, plot.bottom),
    );
    if (rect.height <= 0) return;
    canvas.drawRect(rect, Paint()..color = ChartPalette.band(color));
    if (label != null) {
      _text(canvas, label, Offset(plot.left + 6, rect.top + 2), color: color);
    }
  }

  /// A stretch where readings are unreliable, hatched so it cannot be mistaken
  /// for a highlight.
  void paintFault(Canvas canvas, double fromX, double toX) {
    final a = x.clampPx(fromX);
    final b = x.clampPx(toX);
    if (b - a < 0.5) {
      // A momentary fault still has to be visible, so it gets a minimum width.
      final mid = (a + b) / 2;
      canvas.drawRect(
        Rect.fromLTRB(mid - 1.5, plot.top, mid + 1.5, plot.bottom),
        Paint()..color = ChartPalette.faultInk.withValues(alpha: 0.45),
      );
      return;
    }
    final rect = Rect.fromLTRB(a, plot.top, b, plot.bottom);
    canvas.save();
    canvas.clipRect(rect);
    final hatch = Paint()
      ..color = ChartPalette.faultInk.withValues(alpha: 0.30)
      ..strokeWidth = 1.2;
    for (var o = -rect.height; o < rect.width + rect.height; o += 7) {
      canvas.drawLine(
        Offset(rect.left + o, rect.bottom),
        Offset(rect.left + o + rect.height, rect.top),
        hatch,
      );
    }
    canvas.restore();
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = ChartPalette.faultInk.withValues(alpha: 0.5),
    );
  }
}

void dashedLine(Canvas canvas, Offset a, Offset b, Paint paint,
    {double dash = 6, double gap = 5}) {
  final total = (b - a).distance;
  if (total <= 0) return;
  final unit = (b - a) / total;
  var travelled = 0.0;
  while (travelled < total) {
    final end = math.min(travelled + dash, total);
    canvas.drawLine(a + unit * travelled, a + unit * end, paint);
    travelled = end + gap;
  }
}

void _text(
  Canvas canvas,
  String s,
  Offset at, {
  TextAlign align = TextAlign.left,
  bool centre = false,
  bool anchorRight = false,
  Color color = RehabColors.inkFaint,
  double size = 10,
  FontWeight weight = FontWeight.w500,
}) {
  final tp = TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(fontSize: size, color: color, fontWeight: weight),
    ),
    textAlign: align,
    textDirection: TextDirection.ltr,
  )..layout();
  var dx = at.dx;
  if (centre) dx -= tp.width / 2;
  if (anchorRight) dx -= tp.width;
  tp.paint(canvas, Offset(dx, at.dy - (centre ? 0 : tp.height / 2)));
}

/// Label text, for charts that want to place their own.
void paintChartLabel(
  Canvas canvas,
  String s,
  Offset at, {
  bool centre = false,
  bool anchorRight = false,
  Color color = RehabColors.inkFaint,
  double size = 10,
  FontWeight weight = FontWeight.w500,
}) =>
    _text(canvas, s, at,
        centre: centre,
        anchorRight: anchorRight,
        color: color,
        size: size,
        weight: weight);

/// Rounded-top bar, anchored to the baseline.
///
/// Rounded at the data end only. A bar rounded at both ends floats off its
/// axis and stops being a length you can compare.
void paintBar(Canvas canvas, Rect bar, Color color, {double radius = 4}) {
  if (bar.height <= 0.5) {
    // A zero-height bar still needs to say "measured, and it was zero",
    // which is different from "no bar here".
    canvas.drawRect(
      Rect.fromLTWH(bar.left, bar.bottom - 1.5, bar.width, 1.5),
      Paint()..color = color.withValues(alpha: 0.5),
    );
    return;
  }
  final r = math.min(radius, bar.width / 2);
  canvas.drawRRect(
    RRect.fromRectAndCorners(
      bar,
      topLeft: Radius.circular(r),
      topRight: Radius.circular(r),
    ),
    Paint()..color = color,
  );
}

/// One legend entry: a mark and a label, so identity never rests on colour.
class LegendItem {
  const LegendItem(this.label, this.color, {this.dashed = false, this.hint});

  final String label;
  final Color color;
  final bool dashed;

  /// An optional second line, for a legend that has to explain itself.
  final String? hint;
}

/// A legend. Always present for two or more series; a single-series chart is
/// named by its own title instead.
class ChartLegend extends StatelessWidget {
  const ChartLegend({super.key, required this.items, this.dense = false});

  final List<LegendItem> items;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: dense ? 12 : 16,
      runSpacing: 6,
      children: [
        for (final it in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CustomPaint(
                size: const Size(16, 10),
                painter: _MarkPainter(it.color, it.dashed),
              ),
              const SizedBox(width: 6),
              Text(
                it.label,
                style: RehabText.label.copyWith(
                  color: RehabColors.inkSoft,
                  fontSize: dense ? 10.5 : 11.5,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.color, this.dashed);
  final Color color;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    if (dashed) {
      dashedLine(canvas, Offset(0, y), Offset(size.width, y), paint,
          dash: 4, gap: 3);
    } else {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) =>
      old.color != color || old.dashed != dashed;
}

/// The frame every chart sits in: a title, a one-line explanation, the plot,
/// and a legend.
///
/// The explanation is not decoration. Every chart in the session viewer had
/// one, and that is a large part of why the viewer could be handed to someone
/// who had never seen it.
class ChartCard extends StatelessWidget {
  const ChartCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.legend = const [],
    this.height,
    this.trailing,
    this.footer,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final List<LegendItem> legend;
  final double? height;
  final Widget? trailing;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        color: RehabColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RehabColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: RehabColors.ink,
                        )),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(subtitle!,
                          style: RehabText.body.copyWith(fontSize: 12.5)),
                    ],
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 10),
          if (height != null)
            SizedBox(height: height, child: RepaintBoundary(child: child))
          else
            RepaintBoundary(child: child),
          if (legend.isNotEmpty) ...[
            const SizedBox(height: 10),
            ChartLegend(items: legend),
          ],
          if (footer != null) ...[
            const SizedBox(height: 8),
            footer!,
          ],
        ],
      ),
    );
  }
}

/// How a number compares with where it should be.
enum TileGrade {
  good(RehabColors.good),
  warn(RehabColors.warn),
  bad(RehabColors.bad),
  neutral(RehabColors.inkSoft);

  const TileGrade(this.color);
  final Color color;
}

/// A single headline number.
///
/// Used where a chart would be worse: one number with a label and a comparison
/// is read instantly, and a bar chart of one bar is a bar chart of one bar.
///
/// The grade is carried by an icon **and** the colour, never colour alone.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.detail,
    this.grade = TileGrade.neutral,
    this.onTap,
  });

  final String label;
  final String value;
  final String? unit;
  final String? detail;
  final TileGrade grade;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final body = Container(
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
      decoration: BoxDecoration(
        color: RehabColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: grade == TileGrade.neutral
              ? RehabColors.divider
              : grade.color.withValues(alpha: 0.42),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (grade != TileGrade.neutral) ...[
                Icon(
                  switch (grade) {
                    TileGrade.good => Icons.check_circle_outline,
                    TileGrade.warn => Icons.error_outline,
                    TileGrade.bad => Icons.report_problem_outlined,
                    TileGrade.neutral => Icons.remove,
                  },
                  size: 13,
                  color: grade.color,
                ),
                const SizedBox(width: 5),
              ],
              Expanded(
                child: Text(label.toUpperCase(),
                    style: RehabText.label, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value,
                  style: RehabText.big.copyWith(
                    fontSize: 27,
                    color: grade == TileGrade.neutral
                        ? RehabColors.ink
                        : grade.color,
                  )),
              if (unit != null) ...[
                const SizedBox(width: 3),
                Text(unit!,
                    style: RehabText.label.copyWith(color: RehabColors.inkFaint)),
              ],
            ],
          ),
          if (detail != null) ...[
            const SizedBox(height: 3),
            Text(detail!,
                style: RehabText.body.copyWith(fontSize: 11.5),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ],
        ],
      ),
    );

    if (onTap == null) return body;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: body,
    );
  }
}

/// A tooltip anchored near a point in a chart.
///
/// Charts here are touched, not hovered, so the tooltip is positioned to stay
/// inside the plot and out from under a finger: offset upward, and flipped to
/// the other side when it would run past the right edge.
class ChartTooltip extends StatelessWidget {
  const ChartTooltip({
    super.key,
    required this.lines,
    required this.at,
    required this.bounds,
  });

  /// First line is the heading.
  final List<String> lines;
  final Offset at;
  final Size bounds;

  @override
  Widget build(BuildContext context) {
    const w = 168.0;
    final flip = at.dx + w + 14 > bounds.width;
    final left = (flip ? at.dx - w - 10 : at.dx + 10).clamp(0.0, bounds.width - w);
    final top = (at.dy - 14 - 20 * lines.length).clamp(0.0, bounds.height - 40);

    return Positioned(
      left: left,
      top: top,
      child: IgnorePointer(
        child: Container(
          width: w,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: RehabColors.surfaceHigh,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: RehabColors.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < lines.length; i++)
                Padding(
                  padding: EdgeInsets.only(bottom: i == 0 ? 3 : 1),
                  child: Text(
                    lines[i],
                    style: i == 0
                        ? RehabText.label.copyWith(color: RehabColors.ink)
                        : RehabText.body.copyWith(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown where a chart has nothing to draw.
///
/// Says *why* there is no data, not merely that there is none: "no reps yet"
/// and "this needs the printed lines the sleeve only sends once subscribed"
/// are different problems with different fixes.
class ChartEmpty extends StatelessWidget {
  const ChartEmpty({super.key, required this.message, this.icon});

  final String message;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon ?? Icons.show_chart,
                size: 22, color: RehabColors.inkFaint),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: RehabText.body.copyWith(fontSize: 12.5)),
          ],
        ),
      ),
    );
  }
}

/// Seconds as m:ss, for a time axis.
String mmss(double seconds) {
  final s = seconds.round();
  final m = s ~/ 60;
  return '$m:${(s % 60).toString().padLeft(2, '0')}';
}
