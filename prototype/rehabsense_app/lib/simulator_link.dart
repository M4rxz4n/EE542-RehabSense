import 'dart:async';
import 'dart:math';
import 'device_link.dart';
import 'grading.dart';
import 'models.dart';

enum Scenario { normal, shoulder, trunk, momentum, passive, fatigue }

class _Rep {
  _Rep({required this.dur, required this.peak, required this.shT, required this.tlT, required this.mom, required this.fat});
  final double dur, peak, shT, tlT, mom;
  final bool fat;
  double t = 0, holdT = 0, maxU = 0, maxC = 0, swingMax = 0, uvMax = 0, ovN = 0, ovD = 0, mfSum = 0;
  int mfN = 0;
  double? lat;
  final List<List<double>> trace = [];
}

/// Stand-in for the sleeve. It produces the same *outputs* the firmware will
/// (features, rep results, events). The real sEMG DSP lives in firmware.
class SimulatorLink extends DeviceLink {
  SimulatorLink({this.speed = 3});

  int speed;
  Scenario scenario = Scenario.normal;

  final _frames = StreamController<Frame>.broadcast();
  final _reps = StreamController<RepResult>.broadcast();
  final _events = StreamController<String>.broadcast();
  @override
  Stream<Frame> get frames => _frames.stream;
  @override
  Stream<RepResult> get reps => _reps.stream;
  @override
  Stream<String> get events => _events.stream;

  Params _p = Params(), _a = Params();
  @override
  Params get params => _p;
  @override
  final List<bool> calibration = List.filled(6, false);

  DeviceState _state = DeviceState.idle;
  Phase _phase = Phase.ready;
  int _set = 0, _repsInSet = 0, _fatCnt = 0;
  double _wait = 1.2, _rest = 0, _swingT = 0;
  double _angle = 5, _upper = 0, _trunk = 0, _pa = 5, _pu = 0, _v = 0, _uv = 0, _sw = 0;
  double _bEnv = .04, _tEnv = .05, _mf = 95;
  bool _on = false, _fatigueWarned = false, _busy = false;
  _Rep? _rep;
  Timer? _timer;
  final _rng = Random();
  final List<RepResult> _setReps = [];

  double _r(double a, double b) => a + _rng.nextDouble() * (b - a);

  @override
  Future<void> connect() async {
    _timer ??= Timer.periodic(const Duration(milliseconds: 50), (_) {
      for (var i = 0; i < speed; i++) {
        _step();
      }
      _emit();
    });
    _events.add('Simulator connected');
  }

  @override
  Future<void> runCalibrationStep(int i) async {
    if (_busy) return;
    _busy = true;
    calibration[i] = false;
    _state = DeviceState.calibrating;
    _emit();
    await Future<void>.delayed(Duration(milliseconds: (calibrationSteps[i].$3 * 1000 / speed).round()));
    calibration[i] = true;
    _state = DeviceState.idle;
    _busy = false;
    _events.add('Calibration step $i passed');
    _emit();
  }

  @override
  Future<void> startSession() async {
    if (!calibration.every((c) => c)) return;
    _set = 1;
    _repsInSet = 0;
    _setReps.clear();
    _fatigueWarned = false;
    _fatCnt = 0;
    _phase = Phase.ready;
    _wait = 1.2;
    _state = DeviceState.session;
    _a = _p.copy();
    _events.add('Session started');
  }

  @override
  Future<void> stopSession() async => _end('Session stopped');

  void _end(String why) {
    _state = DeviceState.idle;
    _rep = null;
    _phase = Phase.ready;
    _events.add('$why (saved)');
  }

  @override
  void setParams(Params p) {
    _p = p.copy();
    _events.add('Parameters set (effective next repetition)');
  }

  @override
  Future<void> firePattern(HapticPattern pattern) async => _events.add('Pattern fired: ${pattern.name}');

  @override
  void injectFault() {
    if (!(_state == DeviceState.session || _state == DeviceState.rest)) return;
    _state = DeviceState.fault;
    _rep = null;
    _phase = Phase.ready;
    for (var i = 0; i < 6; i++) {
      calibration[i] = false;
    }
    _events.add('Fault: contact lost on biceps channel. Session paused and saved.');
  }

  void _newRep() {
    _a = _p.copy();
    final s = scenario;
    _rep = _Rep(
      dur: s == Scenario.shoulder ? _r(2.8, 4.2) : _r(2.2, 4.2),
      peak: _r(90, 100),
      shT: s == Scenario.shoulder ? _r(22, 26) : _r(1, 6),
      tlT: s == Scenario.trunk ? _r(13, 18) : _r(1, 4),
      mom: s == Scenario.momentum ? _r(10, 14) : 0,
      fat: s == Scenario.fatigue,
    );
    _phase = Phase.up;
  }

  void _step() {
    const dt = .05;
    var a = 5 + _r(-.3, .3), u = _r(-.2, .2), c = _r(-.1, .1), actB = .04, actT = .04;
    _Rep? r;
    if (_state == DeviceState.session) {
      if (scenario == Scenario.passive) {
        _swingT += dt;
        final cc = _swingT % 4.5;
        if (cc < 2.4) {
          a = 60 * sin(pi * cc / 2.4);
          u = 2;
        }
        if (_swingT > dt && cc < dt) _events.add('Passive swing: biceps inactive, no repetition started');
        _phase = Phase.ready;
      } else {
        if (_phase == Phase.ready) {
          _wait -= dt;
          if (_wait <= 0) _newRep();
        }
        r = _rep;
        if (r != null && (_phase == Phase.up || _phase == Phase.down)) {
          r.t += dt;
          final f = min(1.0, r.t / r.dur), s = sin(pi * f);
          _phase = f < .5 ? Phase.up : Phase.down;
          a = r.peak * s + (r.mom > 0 ? .9 * r.mom * sin(2 * pi * 2.2 * r.t) * s : 0.0) + _r(-.15, .15);
          final ff = r.fat ? max(.55, 1 - .02 * _repsInSet) : 1.0;
          actB = (f < .5 ? .78 : .34) * ff * s + .05;
          actT = .06 + (r.fat ? .1 : .05) * s;
          u = r.shT * s + r.mom * sin(2 * pi * 1.2 * r.t) + _r(-.15, .15);
          c = r.tlT * s + _r(-.1, .1);
          if (f >= 1) {
            _phase = Phase.hold;
            r.holdT = 0;
          }
        } else if (r != null && _phase == Phase.hold) {
          r.holdT += dt;
          actB = .05;
          actT = .05;
        }
      }
    } else if (_state == DeviceState.rest) {
      _rest -= dt;
      if (_rest <= 0) {
        _set++;
        _repsInSet = 0;
        _setReps.clear();
        _fatigueWarned = false;
        _state = DeviceState.session;
        _phase = Phase.ready;
        _wait = 1.2;
        _events.add('Set $_set started');
      }
    }
    // Envelope: first-order stand-in for the 150 ms RMS window of the firmware.
    _bEnv += (actB - _bEnv) * .5;
    _tEnv += (actT - _tEnv) * .5;
    _on = _on ? _bEnv > .065 : _bEnv > .08;
    final fc = (r != null && r.fat) ? max(45.0, 92 - 7.0 * _repsInSet) : 92.0;
    if (_on) _mf = _mf * .85 + (fc + 5 + _r(-6, 6)) * .15;
    _v += ((a - _pa) / dt - _v) * .6;
    _pa = a;
    _uv += ((u - _pu) / dt - _uv) * .6;
    _pu = u;
    final moving = _phase == Phase.up || _phase == Phase.down;
    _sw = (_phase == Phase.up && _uv.abs() > 30) ? _sw + dt : 0;
    _angle = a;
    _upper = u;
    _trunk = c;
    if (r != null && moving) {
      r.trace.add([r.t, a, _v]);
      r.maxU = max(r.maxU, u.abs());
      r.maxC = max(r.maxC, c.abs());
      r.swingMax = max(r.swingMax, _sw);
      r.uvMax = max(r.uvMax, _uv.abs());
      if (_on) {
        r.ovN += min(_bEnv, _tEnv);
        r.ovD += _bEnv;
        r.lat ??= r.t;
        r.mfSum += _mf;
        r.mfN++;
      }
    }
    if (r != null && _phase == Phase.hold && r.holdT * 1000 >= _a.holdDurationMs) _finish(r);
  }

  void _finish(_Rep r) {
    final g = gradeRep(
      p: _a,
      trace: r.trace,
      number: _repsInSet + 1,
      set: _set,
      maxUpper: r.maxU,
      maxTrunk: r.maxC,
      swingSeconds: r.swingMax,
      upperSpeed: r.uvMax,
      overlapNum: r.ovN,
      overlapDen: r.ovD,
      latency: r.lat,
      medianFreq: r.mfN > 0 ? r.mfSum / r.mfN : _mf,
    );
    _repsInSet++;
    _setReps.add(g);
    _reps.add(g);
    _events.add('Haptic: ${g.flagged ? 'flagged' : 'clean'} (rep ${g.number}, score ${g.score.round()})');
    if (_repsInSet >= _a.repTarget) {
      _events.add('Set $_set complete');
      if (_set >= _a.setCount) {
        _end('Session complete');
      } else {
        _state = DeviceState.rest;
        _rest = _a.restSeconds.toDouble();
      }
    }
    if (_setReps.length < 4) _fatCnt = 0;
    if (_setReps.length >= 4) {
      final w = _setReps.sublist(_setReps.length - 4).map((x) => x.medianFreq).toList();
      final slope = (-1.5 * w[0] - .5 * w[1] + .5 * w[2] + 1.5 * w[3]) / 5;
      _fatCnt = slope < -3 ? _fatCnt + 1 : 0;
      if (!_fatigueWarned && _fatCnt >= 3) {
        _fatigueWarned = true;
        _events.add('Fatigue warning: median frequency falling ${slope.toStringAsFixed(1)} Hz per rep. Rest advised.');
      }
    }
    _rep = null;
    if (_state == DeviceState.session) _phase = Phase.ready;
    _wait = _r(.8, 1.4);
  }

  void _emit() {
    final run = _state == DeviceState.session;
    final moving = run && (_phase == Phase.up || _phase == Phase.down);
    _frames.add(Frame(
      state: _state,
      phase: _phase,
      angle: _angle,
      bic: _bEnv,
      tri: _tEnv,
      upper: _upper,
      trunk: _trunk,
      velocity: _v,
      set: _set,
      repsInSet: _repsInSet,
      restLeft: _rest,
      bicepsOn: _on,
      medianFreq: _on || _repsInSet > 0 ? _mf : null,
      fatigueWarned: _fatigueWarned,
      shoulderLive: moving && _upper.abs() > _p.shoulderDeg,
      trunkLive: moving && _trunk.abs() > 10,
      swingLive: moving && _sw >= .2,
      movingWithoutBiceps: run && _phase == Phase.ready && _angle > 25 && !_on,
    ));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _frames.close();
    _reps.close();
    _events.close();
  }
}
