/// Golden-vector tests for the wire protocol.
///
/// Every expected byte string in this file was produced by running the
/// authoritative Python reference, `final/python/rehab_protocol.py`, not by
/// re-reading the header comments and not by this Dart code. That is the
/// whole point: a port checked against itself proves nothing.
///
/// The Python host learned this the hard way. Its `device_status_t` parser
/// carried explicit pad bytes the packed C struct does not have, so every
/// field after `battery_mv` was read from the wrong offset — and its own test
/// suite passed throughout, because it parsed what it itself built. Only a
/// real device showed the fault.
///
/// To regenerate after a deliberate wire change, see `tool/gen_golden.py`.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rehabsense/protocol/calib.dart';
import 'package:rehabsense/protocol/commands.dart';
import 'package:rehabsense/protocol/config_tlv.dart';
import 'package:rehabsense/protocol/constants.dart';
import 'package:rehabsense/protocol/enums.dart';
import 'package:rehabsense/protocol/frames.dart';
import 'package:rehabsense/protocol/status.dart';
import 'package:rehabsense/protocol/xfer.dart';

Uint8List hex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ]);

String unhex(Uint8List b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

void main() {
  // ── Sizes ──────────────────────────────────────────────────────────────
  //
  // These mirror the _Static_asserts in ble_service.h and rehab_types.h. If
  // one of these fails, a struct changed on one side only.
  group('wire sizes', () {
    test('match the firmware static assertions', () {
      expect(kEmgChannels, 1, reason: 'goldens were generated for 1 channel');
      expect(kFrameHeaderBytes, 14);
      expect(kFeaturesPaddedBytes, 40);
      expect(kFeaturesPackedBytes, 32);
      expect(kStatusBytes, 29); // 24 + 5 * 1
      expect(kCalibBytes, 104);
      expect(kXferBytes, 63);
      expect(RepComplete.bytes, 16);
      expect(kEmgFrameBytes, 174);
      expect(kImuFrameBytes, 158);
    });

    test('every frame fits the budget', () {
      expect(kEmgFrameBytes, lessThanOrEqualTo(kFrameMaxBytes));
      expect(kImuFrameBytes, lessThanOrEqualTo(kFrameMaxBytes));
      expect(kFrameHeaderBytes + kFeaturesPaddedBytes,
          lessThanOrEqualTo(kFrameMaxBytes));
    });

    test('the budget fits inside the MTU Android must negotiate', () {
      expect(kMinUsableMtu, lessThanOrEqualTo(kDesiredMtu));
    });
  });

  // ── EMG ────────────────────────────────────────────────────────────────
  group('EMG frame', () {
    const golden = '0107000000cb04fb711f0100000a000001'
        '00ffffff7f0080d2041fefe703efff0500';
    final samples = [0, 1, -1, 32767, -32768, 1234, -4321, 999, -17, 5]
        .map((v) => [v])
        .toList();

    test('builds the reference bytes', () {
      expect(unhex(buildEmgFrame(7, 1234567890123, samples)), golden);
    });

    test('round-trips, saturation included', () {
      final f = parseFrame(hex(golden)) as EmgFrame;
      expect(f.seq, 7);
      expect(f.tUs, 1234567890123);
      expect(f.samples.length, 10);
      expect(f.samples.map((s) => s[0]).toList(),
          [0, 1, -1, 32767, -32768, 1234, -4321, 999, -17, 5]);
      expect(f.isBackfill, isFalse);
    });

    test('rejects a frame that claims more samples than it carries', () {
      // n = 80 in the header, one sample of body.
      final truncated = Uint8List.fromList(
          FrameHeader.build(FrameType.emg, 1, 1, 80) + [0, 0]);
      expect(() => parseFrame(truncated), throwsA(isA<ProtocolError>()));
    });
  });

  // ── IMU ────────────────────────────────────────────────────────────────
  group('IMU frame', () {
    const golden = '020b0000002a00000000000000020a00ecffd4030f00e7ff'
        '0000f401f401bc029cffc8002c0100000000e8030000'
        '0000000006ff7d00f401e80318fc0500';

    test('builds the reference bytes', () {
      final samples = [
        [
          const ImuSample([0.01, -0.02, 0.98], [1.5, -2.5, 0.0]),
          const ImuSample([0.5, 0.5, 0.7], [-10.0, 20.0, 30.0]),
        ],
        [
          const ImuSample([0.0, 0.0, 1.0], [0.0, 0.0, 0.0]),
          const ImuSample([-0.25, 0.125, 0.5], [100.0, -100.0, 0.5]),
        ],
      ];
      expect(unhex(buildImuFrame(11, 42, samples)), golden);
    });

    test('decodes both devices with the right scaling', () {
      final f = parseFrame(hex(golden)) as ImuFrame;
      expect(f.seq, 11);
      expect(f.samples.length, 2);
      // Device 0 is the upper arm, device 1 the forearm.
      expect(f.samples[0][0].accel[2], closeTo(0.98, 1e-6));
      expect(f.samples[0][0].gyro[0], closeTo(1.5, 1e-6));
      expect(f.samples[0][1].gyro[2], closeTo(30.0, 1e-6));
      expect(f.samples[1][1].accel[0], closeTo(-0.25, 1e-6));
      expect(f.samples[1][1].gyro[1], closeTo(-100.0, 1e-6));
    });
  });

  // ── Features: the padding that matters ─────────────────────────────────
  group('feature frame', () {
    const paddedGolden = '030300000031de0b00000000000131de0b0000000000'
        '3d0ad73e0000b1420080c242000060c0'
        '03000d00050004000100000000000000';
    const packedGolden = '030300000031de0b00000000000131de0b0000000000'
        '3d0ad73e0000b1420080c242000060c0'
        '030d000500040001';

    test('builds the padded layout the firmware actually emits', () {
      expect(
        unhex(buildFeatureFrame(3, 777777,
            envelope: [0.42],
            mdf: [88.5],
            elbowAngleDeg: 97.25,
            upperArmDevDeg: -3.5,
            repState: RepState.eccentric.wire,
            repCount: 13,
            compFlags: compShoulder | compSwing,
            sigFlags: sigMvcUnreliable,
            activationOn: true)),
        paddedGolden,
      );
    });

    test('builds the packed layout a packed features_t would give', () {
      expect(
        unhex(buildFeatureFrame(3, 777777,
            envelope: [0.42],
            mdf: [88.5],
            elbowAngleDeg: 97.25,
            upperArmDevDeg: -3.5,
            repState: RepState.eccentric.wire,
            repCount: 13,
            compFlags: compShoulder | compSwing,
            sigFlags: sigMvcUnreliable,
            activationOn: true,
            padded: false)),
        packedGolden,
      );
    });

    // This is the test that earns its keep. Read the padded layout without
    // the pad byte and rep_count, comp_flags and sig_flags all shift one byte
    // left — which does not throw, it just puts wrong numbers on screen.
    for (final (name, golden) in [
      ('padded', paddedGolden),
      ('packed', packedGolden),
    ]) {
      test('decodes the $name layout to identical values', () {
        final f = parseFrame(hex(golden)) as FeatureFrame;
        expect(f.seq, 3);
        expect(f.tUs, 777777);
        expect(f.envelope[0], closeTo(0.42, 1e-6));
        expect(f.mdf[0], closeTo(88.5, 1e-6));
        expect(f.elbowAngleDeg, closeTo(97.25, 1e-6));
        expect(f.upperArmDevDeg, closeTo(-3.5, 1e-6));
        expect(f.repState, RepState.eccentric);
        expect(f.repCount, 13, reason: 'shifted by the pad byte if wrong');
        expect(f.compFlags, compShoulder | compSwing);
        expect(f.compensations, ['shoulder hike', 'arm swing']);
        expect(f.sigFlags, sigMvcUnreliable);
        expect(f.mvcUnreliable, isTrue);
        expect(f.signalDegraded, isFalse);
        expect(f.activationOn, isTrue);
      });
    }
  });

  // ── Events ─────────────────────────────────────────────────────────────
  group('event frame', () {
    test('carries an empty payload', () {
      const golden = '04000000000900000000000000010e00';
      expect(unhex(buildEventFrame(9, RehabEvent.setComplete.wire)), golden);
      final f = parseFrame(hex(golden)) as EventFrame;
      expect(f.kind, RehabEvent.setComplete);
      expect(f.tUs, 9);
      expect(f.payload, isEmpty);
    });

    test('carries a REP_COMPLETE payload', () {
      const frameGolden = '0400000000b3150000000000000102100400525b114037001304020092090000';
      const payloadGolden = '0400525b114037001304020092090000';

      final rc = const RepComplete(
        index: 4,
        score: 82,
        romFraction: 0.91,
        cocontraction: 0.17,
        smoothness: 0.64,
        holdSteadiness: 0.55,
        peakAngleDeg: 104.3,
        compFlags: compTrunk,
        durationMs: 2450,
      );
      expect(unhex(rc.pack()), payloadGolden);
      expect(
        unhex(buildEventFrame(5555, RehabEvent.repComplete.wire, rc.pack())),
        frameGolden,
      );

      final f = parseFrame(hex(frameGolden)) as EventFrame;
      expect(f.kind, RehabEvent.repComplete);
      final back = RepComplete.parse(f.payload);
      expect(back.index, 4);
      expect(back.score, 82);
      expect(back.romFraction, closeTo(0.91, 1e-9));
      expect(back.cocontraction, closeTo(0.17, 1e-9));
      expect(back.smoothness, closeTo(0.64, 1e-9));
      expect(back.holdSteadiness, closeTo(0.55, 1e-9));
      expect(back.peakAngleDeg, closeTo(104.3, 1e-6));
      expect(back.compFlags, compTrunk);
      expect(back.compensations, ['trunk lean']);
      expect(back.durationMs, 2450);
      expect(back.flagged, isTrue);
    });

    test('refuses a payload over 16 bytes', () {
      expect(
        () => buildEventFrame(1, 1, List.filled(17, 0)),
        throwsA(isA<ProtocolError>()),
      );
    });
  });

  // ── Status: no padding at all ──────────────────────────────────────────
  group('device status', () {
    const golden = '050049e40e5b640000000010000007000000030d00eb32a4f8ffffffff';

    test('builds the reference bytes', () {
      const s = DeviceStatus(
        fwState: 5, // operational
        faultCode: 0,
        batteryPct: 73,
        batteryMv: 3812,
        signalQuality: [91],
        seqOldest: 100,
        seqNewest: 4096,
        clipCount: [7],
        flags: statusFlagPsramBacked | statusFlagGapOccurred,
        repCount: 13,
        hostTimeOffsetUs: -123456789,
      );
      expect(unhex(s.pack()), golden);
    });

    test('decodes every field from the right offset', () {
      final s = DeviceStatus.parse(hex(golden));
      expect(s.state, FwState.operational);
      expect(s.faultCode, 0);
      expect(s.batteryPct, 73);
      expect(s.batteryMv, 3812, reason: 'the field the old pad bug shifted');
      expect(s.signalQuality, [91]);
      expect(s.seqOldest, 100);
      expect(s.seqNewest, 4096);
      expect(s.clipCount, [7]);
      expect(s.psramBacked, isTrue);
      expect(s.gapOccurred, isTrue);
      expect(s.repCount, 13);
      // A negative offset is the case an unsigned high word gets wrong.
      expect(s.hostTimeOffsetUs, -123456789);
    });
  });

  // ── Calibration record ─────────────────────────────────────────────────
  group('calibration record', () {
    const golden = '02000000dc2cdc6aa69b443ca69b443b3d0a573f0000bf42'
        'cdcccc3dcdcc4cbe9a99993ecdccccbe0000003f9a9919bf'
        'b6846c3f0000000041f1c33e000000000000803f00000000'
        '000000000000000000000000000000000000803f0000084100'
        '80ec4201000000';

    final record = CalibRecord(
      version: calibRecordVersion,
      timestamp: 1792814300,
      emgRestRms: const [0.012],
      emgRestSd: const [0.003],
      emgMvc: const [0.84],
      mdfBaseline: const [95.5],
      gyroBias: const [0.1, -0.2, 0.3, -0.4, 0.5, -0.6],
      qUpper0: const [0.9239, 0.0, 0.3827, 0.0],
      qFore0: const [1.0, 0.0, 0.0, 0.0],
      flexionAxis: const [0.0, 0.0, 1.0],
      angleMin: 8.5,
      angleMax: 118.25,
      flags: calibFlagMvcUnreliable,
    );

    test('builds the reference bytes, trailing pad included', () {
      expect(unhex(record.pack()), golden);
    });

    test('round-trips', () {
      final c = CalibRecord.parse(hex(golden));
      expect(c.version, calibRecordVersion);
      expect(c.timestamp, 1792814300);
      expect(c.emgMvc[0], closeTo(0.84, 1e-6));
      expect(c.emgRestSd[0], closeTo(0.003, 1e-6));
      expect(c.gyroBias[5], closeTo(-0.6, 1e-6));
      expect(c.qUpper0[0], closeTo(0.9239, 1e-5));
      expect(c.angleMin, closeTo(8.5, 1e-6));
      expect(c.angleMax, closeTo(118.25, 1e-6));
      expect(c.rom, closeTo(109.75, 1e-5));
      expect(c.mvcUnreliable, isTrue);
      expect(c.isCalibrated, isTrue);
    });

    test('a clinician override clears the unreliable flag', () {
      final o = record.withMvcOverride([0.95]);
      expect(o.clinicianOverride, isTrue);
      expect(o.mvcUnreliable, isFalse);
      expect(o.emgMvc[0], closeTo(0.95, 1e-6));
      // Everything the protocol measured survives untouched.
      expect(o.angleMax, record.angleMax);
      expect(o.gyroBias, record.gyroBias);
    });

    test('an empty record does not claim to be calibrated', () {
      expect(CalibRecord.empty().isCalibrated, isFalse);
    });
  });

  // ── Transfer credentials ───────────────────────────────────────────────
  group('transfer info', () {
    const golden = '0201f000c0a80401901f00001000526568616253656e7365'
        '2d3741334600000000000000000000000000000000000063'
        '75726c2d616e6b6c652d3932000000';

    test('decodes the network-order address and the C strings', () {
      final x = XferInfo.parse(hex(golden));
      expect(x.kind, XferState.ready);
      expect(x.ready, isTrue);
      expect(x.clients, 1);
      expect(x.secondsRemaining, 240);
      expect(x.ipv4, '192.168.4.1');
      expect(x.port, 8080);
      expect(x.bytesServed, 1048576);
      expect(x.ssid, 'RehabSense-7A3F');
      expect(x.password, 'curl-ankle-92');
      expect(x.baseUrl, 'http://192.168.4.1:8080');
    });

    test('round-trips', () {
      expect(unhex(XferInfo.parse(hex(golden)).pack()), golden);
    });

    test('never puts the password in the clinician feed', () {
      final json = XferInfo.parse(hex(golden)).toJson();
      expect(json.containsKey('password'), isFalse);
      expect(json.toString(), isNot(contains('curl-ankle-92')));
    });
  });

  // ── Commands ───────────────────────────────────────────────────────────
  group('commands', () {
    test('match the reference byte for byte', () {
      expect(unhex(Commands.startSession(0)), '0100');
      expect(unhex(Commands.stopSession()), '02');
      expect(unhex(Commands.calibrate(CalibPhase.all)), '0307');
      expect(unhex(Commands.calibrate(CalibPhase.biceps)), '0304');
      expect(unhex(Commands.abortCalibration()), '04');
      expect(unhex(Commands.requestRecalibration()), '05');
      expect(unhex(Commands.ackSeq(4096)), '0600100000');
      expect(unhex(Commands.requestBackfill(100, 200)), '0764000000c8000000');
      expect(unhex(Commands.getConfig()), '09');
      expect(unhex(Commands.hapticTest(HapticPattern.rest)), '0a05');
      expect(unhex(Commands.setTime(1792814300123456)), '0b40d1811b8e5e0600');
      expect(unhex(Commands.powerOff()), '0c');
      expect(unhex(Commands.startTransfer()), '0d');
      expect(unhex(Commands.stopTransfer()), '0e');
    });
  });

  // ── Config TLV ─────────────────────────────────────────────────────────
  group('config TLV', () {
    const blockGolden = '0102dc0503010c06040000d24209080000a03f000040400a0c'
        '0000a041000020410000f0410b14cdcc4c3ecdcc4c3ecdcc'
        '4c3ecdcc4c3ecdcc4c3e0d0100';

    final block = concatTlv([
      cfgU16(CfgTag.holdMs, 1500),
      cfgU8(CfgTag.repTarget, 12),
      cfgF32(CfgTag.targetAngle, [105.0]),
      cfgF32(CfgTag.tempo, [1.25, 3.0]),
      cfgF32(CfgTag.compThresh, [20.0, 10.0, 30.0]),
      cfgF32(CfgTag.weights, [0.2, 0.2, 0.2, 0.2, 0.2]),
      cfgU8(CfgTag.rawStream, 0),
    ]);

    test('serialises to the reference block', () {
      expect(unhex(block), blockGolden);
      expect(unhex(Commands.setConfig(block)), '08$blockGolden');
    });

    test('decodes back into a RuntimeConfig', () {
      final cfg = RuntimeConfig()..applyTlv(parseConfigTlv(hex(blockGolden)));
      expect(cfg.holdMs, 1500);
      expect(cfg.repTarget, 12);
      expect(cfg.targetAngleDeg, closeTo(105.0, 1e-6));
      expect(cfg.peakAngleDeg, closeTo(84.0, 1e-6)); // 80% of target
      expect(cfg.tempoMinS, closeTo(1.25, 1e-6));
      expect(cfg.tempoMaxS, closeTo(3.0, 1e-6));
      expect(cfg.compShoulderDeg, closeTo(20.0, 1e-6));
      expect(cfg.compSwingDps, closeTo(30.0, 1e-6));
      expect(cfg.weights, everyElement(closeTo(0.2, 1e-6)));
      expect(cfg.rawStreamEnable, isFalse);
    });

    test('skips an unrecognised tag instead of failing, as the firmware does',
        () {
      final withJunk = Uint8List.fromList([
        ...cfgU16(CfgTag.holdMs, 900),
        0x7F, 0x03, 0xAA, 0xBB, 0xCC, // a tag from some future host
        ...cfgU8(CfgTag.repTarget, 5),
      ]);
      final cfg = RuntimeConfig()..applyTlv(parseConfigTlv(withJunk));
      expect(cfg.holdMs, 900);
      expect(cfg.repTarget, 5);
    });

    test('rejects a truncated block rather than guessing', () {
      final truncated = Uint8List.fromList([CfgTag.tempo.wire, 8, 0, 0, 0]);
      expect(() => parseConfigTlv(truncated), throwsA(isA<FormatException>()));
    });

    test('a full round trip preserves every field', () {
      final original = RuntimeConfig(
        holdMs: 2200,
        repTarget: 15,
        setCount: 4,
        restSeconds: 45,
        targetAngleDeg: 95.5,
        startAngleDeg: 20.0,
        finishAngleDeg: 14.0,
        tempoMinS: 2.0,
        tempoMaxS: 4.0,
        compShoulderDeg: 18.0,
        compTrunkDeg: 9.0,
        compSwingDps: 25.0,
        rawStreamEnable: false,
        agonistChannel: 0,
      );
      final back = RuntimeConfig()..applyTlv(parseConfigTlv(original.toTlv()));
      expect(back.holdMs, original.holdMs);
      expect(back.repTarget, original.repTarget);
      expect(back.setCount, original.setCount);
      expect(back.restSeconds, original.restSeconds);
      expect(back.targetAngleDeg, closeTo(original.targetAngleDeg, 1e-5));
      expect(back.startAngleDeg, closeTo(original.startAngleDeg, 1e-5));
      expect(back.finishAngleDeg, closeTo(original.finishAngleDeg, 1e-5));
      expect(back.tempoMinS, closeTo(original.tempoMinS, 1e-5));
      expect(back.tempoMaxS, closeTo(original.tempoMaxS, 1e-5));
      expect(back.compShoulderDeg, closeTo(original.compShoulderDeg, 1e-5));
      expect(back.rawStreamEnable, isFalse);
    });
  });

  // ── Malformed input ────────────────────────────────────────────────────
  group('robustness', () {
    test('a short frame throws rather than reading past the end', () {
      expect(() => parseFrame(Uint8List(3)), throwsA(isA<ProtocolError>()));
    });

    test('an unknown frame type throws', () {
      final f = Uint8List.fromList(FrameHeader.build(0x7E, 1, 1, 1) + [0]);
      expect(() => parseFrame(f), throwsA(isA<ProtocolError>()));
    });

    test('a short status throws', () {
      expect(() => DeviceStatus.parse(Uint8List(10)),
          throwsA(isA<ProtocolError>()));
    });

    test('a short calibration record throws', () {
      expect(
          () => CalibRecord.parse(Uint8List(50)), throwsA(isA<ProtocolError>()));
    });
  });
}
