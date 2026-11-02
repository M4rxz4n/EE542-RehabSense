/// Reassembling and reading the sleeve's printed lines (characteristic 000A).
///
/// ## Why parse text at all
///
/// Because three things exist only here. `EVT_FATIGUE_WARN` says *how many*
/// fatigue signs fired but not which, and the `[FT1]` line is the only source
/// of the range / effort / time percentages the therapist's fatigue trend is
/// drawn from. The `biceps=NN%` figure — the share of the lift the muscle was
/// actually working, which is what `[FC2]` rejects a passive lift on — appears
/// in no frame. And the whole calibration protocol reports itself in prose:
/// `EVT_CALIB_PHASE_DONE` gives a phase and a percentage, not the measured
/// rest level, the noise floor, or the comfortable bend it settled on.
///
/// So this is not a convenience. Without it the therapist view has no fatigue
/// chart and the calibration screen can only show a progress bar.
///
/// ## What this is not
///
/// It is not a second source of truth for anything a frame already carries.
/// Rep counts, scores, peak angles, durations and compensation flags come from
/// `EVT_REP_COMPLETE`; the matching `# REP` line is parsed only for the two
/// fields the event lacks (the tempo verdict text and `biceps=`). Where a
/// number appears in both, the **event wins** — the firmware builds the event
/// from the same variables it formats the line from, but the line is rounded
/// for people to read (`peak=%.1f`, `duration=%.1f`) and the event is not.
///
/// Parsing is deliberately total: an unrecognised line becomes a
/// [SleeveMessageKind.other] with its text intact, never an exception and
/// never a dropped line. The log view shows everything; only the structured
/// readers care about the kind.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Reassembles whole lines from the notification stream.
///
/// The sleeve packs several short lines into one notification (up to 180
/// bytes, whole lines where they fit) and splits a long line across several,
/// so neither "one notification is one line" nor "a notification ends on a
/// line boundary" holds. Buffer until a newline.
class SleeveTextAssembler {
  final StringBuffer _partial = StringBuffer();

  /// Hard cap on an unterminated fragment.
  ///
  /// Nothing the sleeve prints is near this. A buffer that only ever grows
  /// means a corrupt notification that eats its newline would consume memory
  /// for the rest of the session, so the fragment is flushed as its own line
  /// instead — visible and bounded rather than invisible and unbounded.
  static const int maxPartialChars = 2048;

  /// Feed one notification; get back the complete lines it finished.
  List<String> add(Uint8List bytes) {
    // allowMalformed: a split notification can cut a multi-byte sequence in
    // half, and one replacement character in a log line is a far better
    // outcome than an exception that discards the line.
    _partial.write(utf8.decode(bytes, allowMalformed: true));
    final buffered = _partial.toString();
    _partial.clear();

    final parts = buffered.split('\n');
    final tail = parts.removeLast();

    if (tail.length > maxPartialChars) {
      parts.add(tail);
    } else {
      _partial.write(tail);
    }

    return [
      for (final p in parts)
        if (p.trim().isNotEmpty) p.trimRight(),
    ];
  }

  /// Emit whatever is buffered without waiting for a newline. Worth calling
  /// on disconnect so the last line is not lost.
  List<String> flush() {
    final tail = _partial.toString().trim();
    _partial.clear();
    return tail.isEmpty ? const [] : [tail];
  }

  void reset() => _partial.clear();
}

enum SleeveMessageKind {
  /// `# LIVE …` — the state dump the `i` command produces.
  live,

  /// `# PARAMS …` — the thresholds in force.
  params,

  /// `# REP n …` — a counted repetition.
  rep,

  /// `# Partial rep …` or `# NOT COUNTED [FC2] …`.
  partial,

  /// `#   [FT1] vs your first reps: …` — the fatigue comparison.
  fatigueTrend,

  /// `#   Set n: k of m`.
  setProgress,

  /// A form fault with its coaching line: `[FC2]`–`[FC5]`.
  formFault,

  /// `# [GP1] >> UP/HOLD/DOWN/RELAX` — the guided pace phase.
  paceePhase,

  /// `#   [GP3] …` — the per-cycle pace verdict.
  paceVerdict,

  /// `[AP1]`/`[AP2]` — auto-pause and resume.
  pause,

  /// `[AT1]`–`[AT4]` — the adaptive target.
  target,

  /// Calibration: headers, prompts, step results.
  calibration,

  /// A line from the EMG signal-quality test.
  emgTest,

  /// Set and session boundaries, and the rest countdown.
  sessionFlow,

  /// `# HAPTIC …` — which of the two DRV2605Ls answered, and which motor a
  /// cue was just played on. The only report of a motor that failed to come
  /// up: a sleeve that quietly lost one otherwise just feels wrong.
  haptics,

  /// `# IMUs: …` and `# Haptics: …` — the boot banner's bus map. Worth
  /// catching because "flashed for the wrong wiring" is the first thing to
  /// rule out on a bench, and these lines settle it.
  busMap,

  /// Anything else, kept verbatim.
  other,
}

/// One printed line, classified, with whatever fields it carried.
class SleeveMessage {
  SleeveMessage(this.raw, this.kind, {this.fields = const {}})
      : at = DateTime.now();

  /// The line as printed, with the leading `#` and indentation stripped only
  /// for display — [raw] keeps it, because the indentation is how the sleeve
  /// marks a line as subordinate to the one above.
  final String raw;
  final SleeveMessageKind kind;

  /// Parsed values. Numbers are `double` even where the sleeve prints an
  /// integer, so a reader never has to care which format string produced it.
  final Map<String, Object> fields;

  final DateTime at;

  double? num_(String k) {
    final v = fields[k];
    if (v is double) return v;
    if (v is int) return v.toDouble();
    return null;
  }

  int? int_(String k) => num_(k)?.round();
  String? str(String k) => fields[k] as String?;
  bool flag(String k) => fields[k] == true;

  /// What to show in a log. Drops the comment marker but keeps the indent, so
  /// the sleeve's own grouping survives into the UI.
  String get display {
    var s = raw;
    if (s.startsWith('#')) {
      s = s.substring(1);
      // One space after '#' is the marker's own padding; more is deliberate
      // indentation and is kept.
      if (s.startsWith(' ')) s = s.substring(1);
    }
    return s;
  }

  /// True for a line a clinician should notice: a fault, a fatigue sign, a
  /// rejected rep, or a calibration failure.
  ///
  /// A fatigue line is only concerning when a sign actually fired — the
  /// sleeve prints one after every rep once the baseline is set, and marking
  /// all of them would make the filter useless. The parentheses are explicit
  /// rather than relying on `&&` binding tighter than `||`.
  bool get isConcerning =>
      kind == SleeveMessageKind.formFault ||
      kind == SleeveMessageKind.partial ||
      (kind == SleeveMessageKind.fatigueTrend && flag('anySign')) ||
      raw.contains('FAIL') ||
      raw.contains('WARNING') ||
      raw.contains('Calibration stopped');

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'kind': kind.name,
        'text': raw,
        if (fields.isNotEmpty) 'fields': fields,
      };

  @override
  String toString() => '[${kind.name}] $raw';
}

// ── Patterns ─────────────────────────────────────────────────────────────
//
// One per line shape the firmware prints, anchored on the literal text of its
// format string in the matching module. Each is written to survive the
// rounding the firmware applies (`%.0f` and `%.1f` both appear for the same
// quantity in different places) and the optional segments it appends.

final _numPattern = r'(-?\d+(?:\.\d+)?)';

final _live = RegExp(
    r'^#\s*LIVE\s+calibrated=(\d+)\s+set=(\d+)/(\d+)\s+reps=(\d+)\s+'
    r'partials=(\d+)\s+resting=(\d+)\s+done=(\d+)\s+paused=(\d+)'
    r'(?:\s+pace=(\d+))?');

final _params = RegExp(
    '^#\\s*PARAMS\\s+target=$_numPattern\\s+peak=$_numPattern\\s+'
    'start=$_numPattern\\s+hyst=$_numPattern\\s+'
    'tempo=$_numPattern-$_numPattern\\s+muscle=$_numPattern\\s+'
    r'sets=(\d+)x(\d+)\s+rest=(\d+)');

final _rep = RegExp(
    '^#\\s*REP\\s+(\\d+)\\s+peak=$_numPattern\\s*deg\\s+'
    'duration=$_numPattern\\s*s\\s+rom=(\\d+)\\s+'
    r'tempo=(\d+)\s*\(([^)]*)\)\s+score=(\d+)');

final _repFlags = RegExp(r'flags=(\S+)');
final _repBiceps = RegExp('biceps=$_numPattern%');

final _partial = RegExp(
    '^#\\s*Partial rep\\s*\\(peak\\s*$_numPattern\\s*deg,\\s*'
    'needed\\s*$_numPattern');

final _passive = RegExp(
    '^#\\s*NOT COUNTED\\s*\\[FC2\\]:\\s*peak\\s*$_numPattern\\s*deg,.*?'
    'only\\s*$_numPattern%.*?needs\\s*$_numPattern%');

final _fatigue = RegExp(
    '\\[FT1\\].*?range\\s*$_numPattern%,\\s*effort\\s*$_numPattern%,\\s*'
    'time\\s*$_numPattern%');

final _setProgress = RegExp(r'^#\s*Set\s+(\d+):\s*(\d+)\s+of\s+(\d+)');

final _shoulderFault =
    RegExp('\\[FC4\\].*?upper arm moved\\s*$_numPattern\\s*deg');
final _dropFault = RegExp('\\[FC5\\].*?Lowered at\\s*$_numPattern\\s*deg/s');

final _pacePhase = RegExp(r'\[GP1\]\s*>>\s*([A-Z]+)');

final _emgRest = RegExp(
    '^#\\s*REST\\s+mean\\s*$_numPattern\\s*mV\\s+noise\\s*\\(SD\\)\\s*'
    '$_numPattern\\s*mV');
final _emgSqueeze = RegExp(
    '^#\\s*SQUEEZE\\s+mean\\s*$_numPattern\\s*mV\\s+peak\\s*'
    '$_numPattern\\s*mV\\s+rise above rest\\s*$_numPattern\\s*mV');
final _emgSnr = RegExp('^#\\s*SNR\\s+$_numPattern\\s*dB');
final _emgVerdict = RegExp(r'^#\s*(PASS|WEAK|FAIL|WARN|NOTE)\s+(.*)$');

final _comfortableBend = RegExp(
    'Comfortable bend\\s*(?:only\\s*)?$_numPattern\\s*deg.*?'
    'target\\s*$_numPattern\\s*deg');

final _stepDone = RegExp(r'^Step\s+(\d+)\s+done');
final _restCountdown = RegExp(r'^(?:Ready!\s*)?(\d+)$');

// ---- the two-motor haptic reports ---------------------------------------
//
// Two shapes, from two places. `hm` asks what came up; a haptic test reports
// where it just played. `found` is a bitmask: bit 0 upper arm, bit 1 forearm.
final _hapticPlayed = RegExp(
    r'^#\s*HAPTIC\s+pattern=(\d+)\s+motor=(\S+)\s+motors=(\d+)\s+found=(\d+)');
final _hapticReport = RegExp(
    r'^#\s*HAPTIC\s+motors=(\d+)\s+found=(\d+)\s+upper=(\S+)\s+forearm=(.*)$');

// One DRV2605L answered and the other did not. The sleeve keeps running on
// the one it has, so this is a warning rather than a fault, and it is the
// reason a cue can feel like it is in the wrong place.
final _hapticOneOnly = RegExp(
    r'^#?\s*Haptics:\s*only the (\S+) DRV2605L answered');
final _hapticNone = RegExp(r'^#?\s*Haptics:\s*no DRV2605L answering');

// The PCB puts both motors behind a TCA9543A I2C switch, so a missing switch
// means no haptics at all - a different fault from a missing driver, and
// worth saying so rather than reporting two dead motors.
final _hapticMuxNone =
    RegExp(r'^#?\s*Haptics:\s*no TCA9543A answering at (0x[0-9A-Fa-f]+)');
final _hapticMuxFound = RegExp(
    r'^#?\s*Haptics:\s*TCA9543A found at (0x[0-9A-Fa-f]+), '
    r'not the expected (0x[0-9A-Fa-f]+)');

// ---- the boot banner's bus map ------------------------------------------
final _imuBus = RegExp(r'^#\s*IMUs:\s*(I2C|SPI)\b(.*)$');
final _hapticBus = RegExp(r'^#\s*Haptics:\s*(\d+)\s*x\s*DRV2605L');

double _d(String? s) => s == null ? 0 : (double.tryParse(s) ?? 0);

/// Classify one line.
///
/// Order matters: the most specific shapes are tested first, and the bare
/// countdown number is tested near-last because `60` on its own would
/// otherwise be claimed by anything looser.
SleeveMessage parseSleeveLine(String line) {
  final s = line.trimRight();

  // ---- the two status dumps ------------------------------------------
  final live = _live.firstMatch(s);
  if (live != null) {
    return SleeveMessage(s, SleeveMessageKind.live, fields: {
      'calibrated': live.group(1) == '1',
      'set': _d(live.group(2)),
      'sets': _d(live.group(3)),
      'reps': _d(live.group(4)),
      'partials': _d(live.group(5)),
      'resting': live.group(6) == '1',
      'done': live.group(7) == '1',
      'paused': live.group(8) == '1',
      // Absent on firmware before the 28 Oct update, hence the default
      // rather than a required group.
      'paceOn': live.group(9) == '1',
    });
  }

  final params = _params.firstMatch(s);
  if (params != null) {
    final target = _d(params.group(1));
    final peakFraction = _d(params.group(2));
    return SleeveMessage(s, SleeveMessageKind.params, fields: {
      'targetDeg': target,
      'peakFraction': peakFraction,
      // The angle a rep must actually pass, which is the product and not the
      // target. Precomputed because every reader wants it and getting it
      // wrong silently moves the criterion line on the charts.
      'peakDeg': target * peakFraction,
      'startDeg': _d(params.group(3)),
      'hystDeg': _d(params.group(4)),
      'tempoMinS': _d(params.group(5)),
      'tempoMaxS': _d(params.group(6)),
      'muscleOnPct': _d(params.group(7)),
      'sets': _d(params.group(8)),
      'repsPerSet': _d(params.group(9)),
      'restS': _d(params.group(10)),
    });
  }

  // ---- the two motors, and the bus map --------------------------------
  //
  // Tested here, early, because every shape below is looser and `# Haptics:`
  // would otherwise be swallowed by one of them.
  final played = _hapticPlayed.firstMatch(s);
  if (played != null) {
    final found = int.tryParse(played.group(4) ?? '') ?? 0;
    return SleeveMessage(s, SleeveMessageKind.haptics, fields: {
      'pattern': _d(played.group(1)),
      'motor': played.group(2) ?? '',
      'channels': _d(played.group(3)),
      'found': found.toDouble(),
      'upperOk': (found & 0x1) != 0,
      'forearmOk': (found & 0x2) != 0,
    });
  }

  final hapReport = _hapticReport.firstMatch(s);
  if (hapReport != null) {
    final found = int.tryParse(hapReport.group(2) ?? '') ?? 0;
    return SleeveMessage(s, SleeveMessageKind.haptics, fields: {
      'channels': _d(hapReport.group(1)),
      'found': found.toDouble(),
      'upperOk': (hapReport.group(3) ?? '') == 'ok',
      'forearmOk': (hapReport.group(4) ?? '').trim() == 'ok',
    });
  }

  final oneOnly = _hapticOneOnly.firstMatch(s);
  if (oneOnly != null) {
    final which = oneOnly.group(1) ?? '';
    return SleeveMessage(s, SleeveMessageKind.haptics, fields: {
      'channels': 2.0,
      'upperOk': which.startsWith('upper'),
      'forearmOk': which == 'forearm',
      'degraded': true,
    });
  }

  final muxNone = _hapticMuxNone.firstMatch(s);
  if (muxNone != null) {
    return SleeveMessage(s, SleeveMessageKind.haptics, fields: {
      'upperOk': false,
      'forearmOk': false,
      'degraded': true,
      'muxMissing': true,
      'muxScanFrom': muxNone.group(1) ?? '',
    });
  }

  final muxFound = _hapticMuxFound.firstMatch(s);
  if (muxFound != null) {
    return SleeveMessage(s, SleeveMessageKind.haptics, fields: {
      'muxAddr': muxFound.group(1) ?? '',
      'muxExpected': muxFound.group(2) ?? '',
    });
  }

  if (_hapticNone.hasMatch(s)) {
    return SleeveMessage(s, SleeveMessageKind.haptics, fields: {
      'upperOk': false,
      'forearmOk': false,
      'degraded': true,
    });
  }

  final imuBus = _imuBus.firstMatch(s);
  if (imuBus != null) {
    return SleeveMessage(s, SleeveMessageKind.busMap, fields: {
      'bus': imuBus.group(1) ?? '',
      'detail': (imuBus.group(2) ?? '').trim(),
    });
  }

  final hapBus = _hapticBus.firstMatch(s);
  if (hapBus != null) {
    return SleeveMessage(s, SleeveMessageKind.busMap, fields: {
      'channels': _d(hapBus.group(1)),
    });
  }

  // ---- repetitions ----------------------------------------------------
  final rep = _rep.firstMatch(s);
  if (rep != null) {
    final biceps = _repBiceps.firstMatch(s);
    final flags = _repFlags.firstMatch(s);
    return SleeveMessage(s, SleeveMessageKind.rep, fields: {
      'index': _d(rep.group(1)),
      'peakDeg': _d(rep.group(2)),
      'durationS': _d(rep.group(3)),
      'rom': _d(rep.group(4)),
      'tempoScore': _d(rep.group(5)),
      // "ok", "too fast" or "slow" — the verdict in the sleeve's own words.
      // Not in EVT_REP_COMPLETE, and the reason the rep table can say why a
      // pace was marked rather than only that it was.
      'tempoText': rep.group(6)?.trim() ?? '',
      'score': _d(rep.group(7)),
      'flagged': s.contains('FLAGGED'),
      if (flags != null) 'flagText': flags.group(1)!,
      // Share of the lift the biceps was actually working. The [FC2]
      // criterion, and available nowhere else.
      if (biceps != null) 'bicepsPct': _d(biceps.group(1)),
    });
  }

  final partial = _partial.firstMatch(s);
  if (partial != null) {
    return SleeveMessage(s, SleeveMessageKind.partial, fields: {
      'peakDeg': _d(partial.group(1)),
      'neededDeg': _d(partial.group(2)),
      'passive': false,
    });
  }

  final passive = _passive.firstMatch(s);
  if (passive != null) {
    return SleeveMessage(s, SleeveMessageKind.partial, fields: {
      'peakDeg': _d(passive.group(1)),
      'bicepsPct': _d(passive.group(2)),
      'neededBicepsPct': _d(passive.group(3)),
      'passive': true,
    });
  }

  // ---- fatigue --------------------------------------------------------
  final fatigue = _fatigue.firstMatch(s);
  if (fatigue != null) {
    final range = s.contains('RANGE');
    final effort = s.contains('EFFORT');
    final slow = s.contains('SLOW');
    return SleeveMessage(s, SleeveMessageKind.fatigueTrend, fields: {
      'rangePct': _d(fatigue.group(1)),
      'effortPct': _d(fatigue.group(2)),
      'timePct': _d(fatigue.group(3)),
      'range': range,
      'effort': effort,
      'slow': slow,
      'signs': (range ? 1 : 0) + (effort ? 1 : 0) + (slow ? 1 : 0),
      'anySign': range || effort || slow,
    });
  }

  final setProgress = _setProgress.firstMatch(s);
  if (setProgress != null) {
    return SleeveMessage(s, SleeveMessageKind.setProgress, fields: {
      'set': _d(setProgress.group(1)),
      'done': _d(setProgress.group(2)),
      'target': _d(setProgress.group(3)),
    });
  }

  // ---- form faults ----------------------------------------------------
  final shoulder = _shoulderFault.firstMatch(s);
  if (shoulder != null) {
    return SleeveMessage(s, SleeveMessageKind.formFault, fields: {
      'code': 'FC4',
      'tiltDeg': _d(shoulder.group(1)),
    });
  }
  final drop = _dropFault.firstMatch(s);
  if (drop != null) {
    return SleeveMessage(s, SleeveMessageKind.formFault, fields: {
      'code': 'FC5',
      'dropDps': _d(drop.group(1)),
    });
  }
  if (s.contains('[FC3]')) {
    return SleeveMessage(s, SleeveMessageKind.formFault,
        fields: {'code': 'FC3'});
  }
  if (s.contains('[FC6]')) {
    return SleeveMessage(s, SleeveMessageKind.formFault,
        fields: {'code': 'FC6'});
  }
  if (s.contains('[FC1]')) {
    // The adaptive activation threshold, reported during calibration.
    return SleeveMessage(s, SleeveMessageKind.calibration,
        fields: {'code': 'FC1'});
  }

  // ---- guided pace ----------------------------------------------------
  final pace = _pacePhase.firstMatch(s);
  if (pace != null) {
    return SleeveMessage(s, SleeveMessageKind.paceePhase, fields: {
      'phase': pace.group(1)!,
    });
  }
  if (s.contains('[GP3]')) {
    return SleeveMessage(s, SleeveMessageKind.paceVerdict, fields: {
      'onBeat': s.contains('Right on the beat'),
    });
  }
  if (s.contains('[GP2]')) {
    return SleeveMessage(s, SleeveMessageKind.paceePhase,
        fields: const {'phase': 'WAIT'});
  }

  // ---- auto-pause -----------------------------------------------------
  if (s.contains('[AP1]')) {
    return SleeveMessage(s, SleeveMessageKind.pause,
        fields: const {'paused': true});
  }
  if (s.contains('[AP2]')) {
    return SleeveMessage(s, SleeveMessageKind.pause,
        fields: const {'paused': false});
  }

  // ---- adaptive target ------------------------------------------------
  if (s.contains('[AT1]') ||
      s.contains('[AT2]') ||
      s.contains('[AT3]') ||
      s.contains('[AT4]')) {
    final bend = _comfortableBend.firstMatch(s);
    return SleeveMessage(s, SleeveMessageKind.target, fields: {
      'locked': s.contains('locked'),
      if (bend != null) 'bendDeg': _d(bend.group(1)),
      if (bend != null) 'targetDeg': _d(bend.group(2)),
    });
  }

  // ---- the EMG signal test --------------------------------------------
  // Tested before the generic calibration shapes: several of its lines also
  // start with '# ' and would otherwise be swallowed.
  final emgRest = _emgRest.firstMatch(s);
  if (emgRest != null) {
    return SleeveMessage(s, SleeveMessageKind.emgTest, fields: {
      'part': 'rest',
      'meanMv': _d(emgRest.group(1)),
      'noiseSdMv': _d(emgRest.group(2)),
    });
  }
  final emgSqueeze = _emgSqueeze.firstMatch(s);
  if (emgSqueeze != null) {
    return SleeveMessage(s, SleeveMessageKind.emgTest, fields: {
      'part': 'squeeze',
      'meanMv': _d(emgSqueeze.group(1)),
      'peakMv': _d(emgSqueeze.group(2)),
      'riseMv': _d(emgSqueeze.group(3)),
    });
  }
  final emgSnr = _emgSnr.firstMatch(s);
  if (emgSnr != null) {
    return SleeveMessage(s, SleeveMessageKind.emgTest, fields: {
      'part': 'snr',
      'snrDb': _d(emgSnr.group(1)),
    });
  }
  final verdict = _emgVerdict.firstMatch(s);
  if (verdict != null) {
    return SleeveMessage(s, SleeveMessageKind.emgTest, fields: {
      'part': 'verdict',
      'verdict': verdict.group(1)!,
      'detail': verdict.group(2)!.trim(),
    });
  }
  if (s.contains('EMG signal-quality test') || s.contains('End of EMG test')) {
    return SleeveMessage(s, SleeveMessageKind.emgTest,
        fields: {'part': s.contains('End of') ? 'end' : 'begin'});
  }
  if (s.contains('mains hum')) {
    return SleeveMessage(s, SleeveMessageKind.emgTest,
        fields: const {'part': 'mains'});
  }

  // ---- calibration ----------------------------------------------------
  final stepDone = _stepDone.firstMatch(s);
  if (stepDone != null) {
    return SleeveMessage(s, SleeveMessageKind.calibration, fields: {
      'step': _d(stepDone.group(1)),
      'stepDone': true,
    });
  }
  if (s.startsWith('=== Calibration')) {
    return SleeveMessage(s, SleeveMessageKind.calibration, fields: {
      'begin': s.contains('=== Calibration ==='),
      'done': s.contains('done'),
      'stopped': s.contains('stopped'),
    });
  }
  if (s.startsWith('>>')) {
    // A prompt, or the "in 3... 2... 1..." that precedes a step. The prompt is
    // what belongs in front of a patient.
    return SleeveMessage(s, SleeveMessageKind.calibration, fields: {
      'prompt': s.replaceFirst('>>', '').trim(),
      'countdown': s.contains('...'),
    });
  }
  final bendOnly = _comfortableBend.firstMatch(s);
  if (bendOnly != null) {
    return SleeveMessage(s, SleeveMessageKind.calibration, fields: {
      'bendDeg': _d(bendOnly.group(1)),
      'targetDeg': _d(bendOnly.group(2)),
    });
  }
  if (s.startsWith('Rest EMG') ||
      s.startsWith('Max contraction EMG') ||
      s.startsWith('Straight-arm reference') ||
      s.startsWith('Try ') ||
      s.startsWith("Couldn't get") ||
      s.startsWith('WARNING')) {
    return SleeveMessage(s, SleeveMessageKind.calibration);
  }

  // ---- session flow ---------------------------------------------------
  if (s.contains('SESSION COMPLETE') ||
      s.contains('SESSION STOPPED') ||
      s.contains('complete. Well done') ||
      s.startsWith('Rep start!') ||
      s.contains('New session') ||
      s.contains('Rest ended early')) {
    return SleeveMessage(s, SleeveMessageKind.sessionFlow, fields: {
      'sessionComplete': s.contains('SESSION COMPLETE'),
      'sessionStopped': s.contains('SESSION STOPPED'),
      'repStart': s.startsWith('Rep start!'),
    });
  }
  // The rest countdown prints bare seconds, and "Ready! 10" at ten left.
  final countdown = _restCountdown.firstMatch(s);
  if (countdown != null) {
    return SleeveMessage(s, SleeveMessageKind.sessionFlow, fields: {
      'restSecondsLeft': _d(countdown.group(1)),
      'ready': s.startsWith('Ready!'),
    });
  }

  return SleeveMessage(s, SleeveMessageKind.other);
}
