import 'dart:math';
import 'package:flutter/material.dart';
import '../models.dart';

/// Three stacked live traces: angle, biceps envelope, triceps envelope.
class TracePainter extends CustomPainter {
  TracePainter(this.angle, this.bic, this.tri, this.target, this.cs);
  final List<double> angle, bic, tri;
  final double target;
  final ColorScheme cs;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height, w = size.width;
    void lane(List<double> d, double max, Color c, double y, double lh, {double? mark}) {
      canvas.drawRect(Rect.fromLTWH(0, y, w, lh), Paint()..style = PaintingStyle.stroke..color = cs.outlineVariant);
      if (mark != null) {
        final my = y + lh - (mark / max) * lh;
        canvas.drawLine(Offset(0, my), Offset(w, my), Paint()..color = cs.outline.withOpacity(.5));
      }
      final path = Path();
      for (var i = 0; i < d.length; i++) {
        final px = i / (d.length - 1) * w;
        final py = y + lh - (d[i] / max).clamp(0.0, 1.0) * (lh - 4) - 2;
        i == 0 ? path.moveTo(px, py) : path.lineTo(px, py);
      }
      canvas.drawPath(path, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = c);
    }

    lane(angle, 130, cs.onSurface, 0, h * .4, mark: target);
    lane(bic, 1.1, cs.primary, h * .42, h * .28);
    lane(tri, 1.1, cs.tertiary, h * .72, h * .28);
  }

  @override
  bool shouldRepaint(covariant TracePainter old) => true;
}

/// Half-circle elbow-angle gauge with the target marked.
class GaugePainter extends CustomPainter {
  GaugePainter(this.angle, this.target, this.cs);
  final double angle, target;
  final ColorScheme cs;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height * .9), r = size.width * .38;
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), pi, pi, false,
        Paint()..style = PaintingStyle.stroke..strokeWidth = 12..strokeCap = StrokeCap.round..color = cs.outlineVariant);
    Offset at(double deg, double rad) {
      final t = deg.clamp(0, 150) / 150 * pi;
      return Offset(c.dx - rad * cos(t), c.dy - rad * sin(t));
    }

    canvas.drawLine(at(target, r * .8), at(target, r * 1.15), Paint()..strokeWidth = 3..color = Colors.green);
    canvas.drawLine(c, at(angle, r), Paint()..strokeWidth = 5..strokeCap = StrokeCap.round..color = cs.onSurface);
    canvas.drawCircle(c, 6, Paint()..color = cs.onSurface);
  }

  @override
  bool shouldRepaint(covariant GaugePainter old) => true;
}

class FlagChip extends StatelessWidget {
  const FlagChip(this.label, this.bad, {super.key});
  final String label;
  final bool bad;
  @override
  Widget build(BuildContext context) {
    final c = bad ? Theme.of(context).colorScheme.error : Colors.green.shade700;
    return Chip(label: Text(label, style: TextStyle(color: c, fontWeight: bad ? FontWeight.bold : null)), side: BorderSide(color: c), visualDensity: VisualDensity.compact);
  }
}

List<Widget> liveChips(Frame? f) => [
      FlagChip('Biceps ${f != null && f.bicepsOn ? 'active' : 'quiet'}', false),
      FlagChip('Shoulder ${f != null && f.shoulderLive ? '${f.upper.abs().round()}° up' : 'steady'}', f?.shoulderLive ?? false),
      FlagChip('Trunk ${f != null && f.trunkLive ? '${f.trunk.abs().round()}° lean' : 'upright'}', f?.trunkLive ?? false),
      FlagChip('Swing ${f != null && f.swingLive ? 'detected' : 'none'}', f?.swingLive ?? false),
      if (f != null && f.movingWithoutBiceps) const FlagChip('Moving without biceps', true),
    ];

class Tile extends StatelessWidget {
  const Tile(this.label, this.value, {this.bad = false, super.key});
  final String label, value;
  final bool bad;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 150,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(border: Border.all(color: bad ? cs.error : cs.outlineVariant), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        Text(value, style: Theme.of(context).textTheme.titleSmall),
      ]),
    );
  }
}
