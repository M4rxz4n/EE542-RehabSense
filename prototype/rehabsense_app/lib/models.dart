/// Data types shared by every layer. They mirror what the device reports
/// (PRD 5.9: the device is authoritative; the app only displays).
enum DeviceState { idle, calibrating, session, rest, fault }

enum Phase { ready, up, down, hold }

/// The six haptic patterns of PRD 5.6.
enum HapticPattern { tick, clean, flagged, setComplete, rest, fault }

/// Exercise parameters settable from the host (PRD 5.9.1).
class Params {
  Params({
    this.holdDurationMs = 1000,
    this.repTarget = 20,
    this.setCount = 3,
    this.restSeconds = 60,
    this.targetAngle = 110,
    this.startAngle = 15,
    this.finishAngle = 10,
    this.tempoMin = 1.5,
    this.tempoMax = 3.5,
    this.shoulderDeg = 20,
  });

  int holdDurationMs, repTarget, setCount, restSeconds;
  double targetAngle, startAngle, finishAngle, tempoMin, tempoMax, shoulderDeg;

  Params copy() => Params(
        holdDurationMs: holdDurationMs,
        repTarget: repTarget,
        setCount: setCount,
        restSeconds: restSeconds,
        targetAngle: targetAngle,
        startAngle: startAngle,
        finishAngle: finishAngle,
        tempoMin: tempoMin,
        tempoMax: tempoMax,
        shoulderDeg: shoulderDeg,
      );
}

/// One live feature sample (20 Hz on air, PRD 12.3 "Live features").
class Frame {
  const Frame({
    required this.state,
    required this.phase,
    this.angle = 5,
    this.bic = 0,
    this.tri = 0,
    this.upper = 0,
    this.trunk = 0,
    this.velocity = 0,
    this.set = 0,
    this.repsInSet = 0,
    this.restLeft = 0,
    this.bicepsOn = false,
    this.medianFreq,
    this.fatigueWarned = false,
    this.shoulderLive = false,
    this.trunkLive = false,
    this.swingLive = false,
    this.movingWithoutBiceps = false,
  });

  final DeviceState state;
  final Phase phase;
  final double angle, bic, tri, upper, trunk, velocity, restLeft;
  final int set, repsInSet;
  final bool bicepsOn, fatigueWarned;
  final bool shoulderLive, trunkLive, swingLive, movingWithoutBiceps;
  final double? medianFreq;

  bool get running => state == DeviceState.session || state == DeviceState.rest;
}

/// Per-repetition result (PRD 12.3 "Results").
class RepResult {
  const RepResult({
    required this.number,
    required this.set,
    required this.score,
    required this.range,
    required this.tempo,
    required this.smooth,
    required this.coContraction,
    required this.duration,
    required this.peakAngle,
    required this.peakVelocity,
    required this.velocityPeaks,
    required this.overlap,
    required this.maxUpper,
    required this.maxTrunk,
    required this.upperSpeed,
    required this.medianFreq,
    required this.flags,
    required this.why,
    this.latency,
  });

  final int number, set, velocityPeaks;
  final double score, range, tempo, smooth, coContraction, duration, peakAngle;
  final double peakVelocity, overlap, maxUpper, maxTrunk, upperSpeed, medianFreq;
  final double? latency;
  final List<String> flags, why;

  bool get flagged => flags.isNotEmpty;
}
