import 'dart:math';
import 'models.dart';

/// Counts prominent velocity peaks (PRD 5.5 smoothness). A clean rep has two:
/// one for the lift, one for the lowering.
int velocityPeaks(List<double> v) {
  var m = 0.0;
  for (final x in v) {
    m = max(m, x.abs());
  }
  if (m == 0) return 0;
  final th = .15 * m;
  var n = 0, up = false;
  var hi = 0.0, lo = 0.0;
  for (final raw in v) {
    final x = raw.abs();
    if (!up) {
      if (x < lo) lo = x;
      if (x > lo + th) {
        up = true;
        hi = x;
      }
    } else {
      if (x > hi) hi = x;
      if (x < hi - th) {
        n++;
        up = false;
        lo = x;
      }
    }
  }
  if (up) n++;
  return n;
}

/// Scores one repetition: four equal-weight components, then deductions
/// (PRD 5.5). [trace] rows are [time s, angle deg, velocity deg/s].
RepResult gradeRep({
  required Params p,
  required List<List<double>> trace,
  required int number,
  required int set,
  required double maxUpper,
  required double maxTrunk,
  required double swingSeconds,
  required double upperSpeed,
  required double overlapNum,
  required double overlapDen,
  required double? latency,
  required double medianFreq,
}) {
  var peak = 0.0, peakV = 0.0, tF = 0.0;
  double? tS;
  final v = <double>[];
  for (final q in trace) {
    peak = max(peak, q[1]);
    peakV = max(peakV, q[2].abs());
    if (tS == null && q[1] > p.startAngle) tS = q[0];
    if (q[1] > p.finishAngle) tF = q[0];
    v.add(q[2]);
  }
  final dur = tS == null ? 0.0 : max(.1, tF - tS);
  final vp = velocityPeaks(v);
  final rom = min(1.0, peak / p.targetAngle) * 100;
  var tempo = 100.0;
  if (dur < p.tempoMin) tempo = max(40.0, 100 - 60 * (p.tempoMin - dur) / p.tempoMin);
  if (dur > p.tempoMax) tempo = max(40.0, 100 - 60 * (dur - p.tempoMax) / p.tempoMax);
  final smooth = max(40, 100 - 12 * max(0, vp - 2)).toDouble();
  final ov = overlapDen > 0 ? overlapNum / overlapDen : 0.0;
  final co = max(0.0, 100 * (1 - ov));
  final sh = maxUpper > p.shoulderDeg, tl = maxTrunk > 10, mo = swingSeconds >= .2;
  final ded = (sh ? 20 : 0) + (tl ? 15 : 0) + (mo ? 15 : 0);
  final score = ((rom + tempo + smooth + co) / 4 - ded).clamp(0, 100).roundToDouble();
  final flags = <String>[
    if (peak < .8 * p.targetAngle) 'range',
    if (dur < p.tempoMin || dur > p.tempoMax) 'tempo',
    if (sh) 'shoulder compensation',
    if (tl) 'trunk lean',
    if (mo) 'momentum',
  ];
  final why = <String>[
    'Range ${rom.round()}: peak ${peak.round()}° against a ${p.targetAngle.round()}° target',
    'Tempo ${tempo.round()}: ${dur.toStringAsFixed(1)} s against a ${p.tempoMin}–${p.tempoMax} s window',
    'Smoothness ${smooth.round()}: $vp velocity peaks (2 is ideal)',
    'Co-contraction ${co.round()}: triceps overlapped biceps by ${(ov * 100).round()}%',
    if (sh) 'Shoulder compensation −20: upper arm rotated ${maxUpper.round()}° (limit ${p.shoulderDeg.round()}°)',
    if (tl) 'Trunk lean −15: both sensors rotated together by ${maxTrunk.round()}°',
    if (mo) 'Momentum −15: upper arm faster than 30 °/s for ${(swingSeconds * 1000).round()} ms',
  ];
  return RepResult(
    number: number,
    set: set,
    score: score,
    range: rom,
    tempo: tempo,
    smooth: smooth,
    coContraction: co,
    duration: dur,
    peakAngle: peak,
    peakVelocity: peakV,
    velocityPeaks: vp,
    overlap: ov,
    maxUpper: maxUpper,
    maxTrunk: maxTrunk,
    upperSpeed: upperSpeed,
    medianFreq: medianFreq,
    flags: flags,
    why: why,
    latency: latency,
  );
}
