import 'dart:typed_data';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:rehabsense_app/ble_link.dart';
import 'package:rehabsense_app/grading.dart';
import 'package:rehabsense_app/models.dart';

List<List<double>> trace() => [
      for (var i = 0; i < 60; i++)
        [i * .05, 95 * sin(pi * i / 59), 95 * pi / 3 * cos(pi * i / 59)],
    ];

RepResult grade({double upper = 3, double trunk = 2, double swing = 0}) => gradeRep(
      p: Params(),
      trace: trace(),
      number: 1,
      set: 1,
      maxUpper: upper,
      maxTrunk: trunk,
      swingSeconds: swing,
      upperSpeed: 10,
      overlapNum: 1,
      overlapDen: 5,
      latency: .2,
      medianFreq: 90,
    );

void main() {
  test('a smooth rep has two velocity peaks', () {
    expect(velocityPeaks(trace().map((r) => r[2]).toList()), 2);
  });

  test('shoulder rotation over the limit is flagged and costs 20 points', () {
    final clean = grade(), bad = grade(upper: 26);
    expect(bad.flags, contains('shoulder compensation'));
    expect(clean.score - bad.score, 20);
  });

  test('trunk lean and momentum are flagged', () {
    expect(grade(trunk: 15).flags, contains('trunk lean'));
    expect(grade(swing: .4).flags, contains('momentum'));
  });

  test('live frame survives an encode/decode round trip', () {
    const f = Frame(state: DeviceState.session, phase: Phase.up, angle: 47.3, bic: .62, tri: .11, set: 2, repsInSet: 7, bicepsOn: true, shoulderLive: true);
    final g = FrameCodec.decode(FrameCodec.encode(f, 1234))!;
    expect(g.angle, closeTo(47.3, .05));
    expect(g.state, DeviceState.session);
    expect(g.repsInSet, 7);
    expect(g.shoulderLive, isTrue);
    expect(g.trunkLive, isFalse);
  });

  test('a short packet is rejected, not thrown', () {
    expect(FrameCodec.decode(Uint8List(3)), isNull);
  });
}
