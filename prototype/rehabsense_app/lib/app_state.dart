import 'dart:async';
import 'package:flutter/foundation.dart';
import 'device_link.dart';
import 'models.dart';

class TherapistMessage {
  TherapistMessage(this.text) : time = DateTime.now();
  final String text;
  final DateTime time;
  bool seen = false;
}

class SessionSummary {
  const SessionSummary(this.time, this.reps, this.flagged, this.meanScore, this.shoulder, this.fatigue);
  final DateTime time;
  final int reps, flagged, shoulder, fatigue;
  final double meanScore;
}

/// Single source of truth for all three dashboards. Screens listen to it and
/// call its methods; only this class talks to the [DeviceLink].
class AppState extends ChangeNotifier {
  AppState(this.link) {
    _subs = [
      link.frames.listen(_onFrame),
      link.reps.listen(_onRep),
      link.events.listen(_onEvent),
    ];
    link.connect();
  }

  final DeviceLink link;
  late final List<StreamSubscription<dynamic>> _subs;

  static const traceLength = 200;
  final angle = List<double>.filled(traceLength, 5);
  final bic = List<double>.filled(traceLength, .04);
  final tri = List<double>.filled(traceLength, .05);

  Frame? frame;
  final setReps = <RepResult>[];
  final allReps = <RepResult>[];
  final log = <String>[];
  final messages = <TherapistMessage>[];
  final history = <SessionSummary>[];
  TherapistMessage? pending;
  int fatigueEvents = 0;
  bool _calibrating = false;

  static const msg = <String, String>{
    'shoulder': 'Keep your shoulder down and relaxed.',
    'trunk': 'Stay upright, don’t lean your body.',
    'swing': 'Slow and steady, no swinging.',
    'pas': 'Use your arm muscle to lift. Don’t swing.',
    'range': 'Try to curl a little higher.',
    'slow': 'Slow down a little.',
    'fast': 'Move a bit faster.',
    'good': 'Good work, keep going.',
    'rest': 'Take a short rest.',
  };

  bool get calibrated => link.calibration.every((c) => c);
  bool get calibrating => _calibrating;
  Params get params => link.params;

  void _push(List<double> l, double v) {
    l.removeAt(0);
    l.add(v);
  }

  void _onFrame(Frame f) {
    final prev = frame;
    frame = f;
    _push(angle, f.angle);
    _push(bic, f.bic);
    _push(tri, f.tri);
    if (prev != null && prev.set != f.set) setReps.clear();
    final wasRunning = prev != null && prev.running;
    if (wasRunning && (f.state == DeviceState.idle || f.state == DeviceState.fault)) _saveSession();
    notifyListeners();
  }

  void _onRep(RepResult r) {
    setReps.add(r);
    allReps.add(r);
    notifyListeners();
  }

  void _onEvent(String e) {
    if (e.startsWith('Fatigue')) fatigueEvents++;
    final n = DateTime.now();
    log.insert(0, '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}:${n.second.toString().padLeft(2, '0')}  $e');
    if (log.length > 60) log.removeLast();
    notifyListeners();
  }

  void _saveSession() {
    if (allReps.isEmpty) return;
    final mean = allReps.map((r) => r.score).reduce((a, b) => a + b) / allReps.length;
    history.add(SessionSummary(
      DateTime.now(),
      allReps.length,
      allReps.where((r) => r.flagged).length,
      mean,
      allReps.where((r) => r.flags.contains('shoulder compensation')).length,
      fatigueEvents,
    ));
    allReps.clear();
  }

  // ---- actions ----
  Future<void> calibrateAll() async {
    _calibrating = true;
    notifyListeners();
    for (var i = 0; i < 6; i++) {
      await link.runCalibrationStep(i);
    }
    _calibrating = false;
    notifyListeners();
  }

  Future<void> start() async {
    allReps.clear();
    setReps.clear();
    fatigueEvents = 0;
    await link.startSession();
  }

  Future<void> stop() => link.stopSession();

  void updateParams(void Function(Params p) edit) {
    final p = link.params.copy();
    edit(p);
    link.setParams(p);
    notifyListeners();
  }

  void sendMessage(String text) {
    if (text.trim().isEmpty) return;
    final m = TherapistMessage(text.trim());
    messages.insert(0, m);
    pending = m;
    notifyListeners();
  }

  /// Lets screens ask for a rebuild after changing simulator-only settings.
  void refresh() => notifyListeners();

  void acknowledge() {
    pending?.seen = true;
    pending = null;
    notifyListeners();
  }

  // ---- derived text for the dashboards ----
  String? get liveCue {
    final f = frame;
    if (f == null) return null;
    if (f.shoulderLive) return msg['shoulder'];
    if (f.trunkLive) return msg['trunk'];
    if (f.swingLive) return msg['swing'];
    if (f.movingWithoutBiceps) return msg['pas'];
    return null;
  }

  String? get suggestion {
    final f = frame;
    if (f == null) return null;
    final live = liveCue;
    if (live != null) return live;
    if (f.state != DeviceState.session || allReps.isEmpty) return null;
    final flag = allReps.last.flags.isEmpty ? null : allReps.last.flags.first;
    switch (flag) {
      case 'shoulder compensation':
        return msg['shoulder'];
      case 'trunk lean':
        return msg['trunk'];
      case 'momentum':
        return msg['swing'];
      case 'range':
        return msg['range'];
      case 'tempo':
        return allReps.last.duration < params.tempoMin ? msg['slow'] : msg['fast'];
      default:
        return f.fatigueWarned ? msg['rest'] : msg['good'];
    }
  }

  (String, String) get patientText {
    final f = frame;
    if (f != null && f.state == DeviceState.fault) {
      return ('Sensor problem', 'An electrode lost contact. Press the electrodes firmly, then tap Get ready.');
    }
    if (_calibrating) return ('Getting ready', 'Follow the on-screen step. Stay as instructed.');
    if (!calibrated) return ('Let’s get set up', 'Put the sleeve on, sit comfortably, then tap Get ready.');
    if (f == null) return ('Connecting', '');
    if (f.state == DeviceState.rest) return ('Rest', 'Next set starts in ${f.restLeft.ceil()} s.');
    if (f.state == DeviceState.session) {
      switch (f.phase) {
        case Phase.ready:
          return ('Curl up slowly', 'Bend your elbow when you are ready.');
        case Phase.up:
          return ('Lifting', 'Keep going, nice and slow.');
        case Phase.down:
          return ('Lowering', 'Lower slowly all the way down.');
        case Phase.hold:
          return ('Hold still', 'Stay still for a moment.');
      }
    }
    return allReps.isEmpty && history.isEmpty
        ? ('Ready when you are', 'Tap Start when you are comfortable.')
        : ('Session finished', 'Well done.');
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    link.dispose();
    super.dispose();
  }
}
