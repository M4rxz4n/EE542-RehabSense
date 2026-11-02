/// Saved sessions on the phone, and the progress series built from them.
///
/// The viewer kept these in browser local storage. A phone has a filesystem,
/// so each session is its own JSON file under the app's documents directory
/// and the index is rebuilt by reading the directory. That choice is about
/// failure modes, not tidiness: one corrupt file costs one session rather
/// than the whole history, and a session is written once and then only read.
///
/// Two further consequences worth stating. A session is saved whole and never
/// edited, so there is no update path to get wrong. And export is just the
/// files concatenated into one JSON document, which means an export can be
/// re-imported by a different phone, or read by hand, without this class.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'session_record.dart';

/// A person the sleeve is used on.
///
/// Several exist because one sleeve and one phone get shared between patients
/// in a clinic, and merging two people's reps into one progress chart is worse
/// than having no chart.
class Patient {
  const Patient({required this.id, required this.name});

  final String id;
  final String name;

  static const Patient unassigned =
      Patient(id: 'default', name: 'Unnamed patient');

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  static Patient fromJson(Map<String, dynamic> j) => Patient(
        id: j['id'] as String? ?? 'default',
        name: j['name'] as String? ?? 'Unnamed patient',
      );
}

/// What a saved session contributes to the progress charts.
///
/// A summary, not the session: the charts plot one point per session and
/// loading every trace to draw four dots would make the tab unusable after a
/// few weeks of daily use.
class SessionSummary {
  const SessionSummary({
    required this.id,
    required this.patientId,
    required this.startedAt,
    required this.note,
    required this.source,
    required this.countedCount,
    required this.partialCount,
    required this.flaggedCount,
    required this.targetAngleDeg,
    this.meanPeakDeg,
    this.bestPeakDeg,
    this.worstPeakDeg,
    this.meanScore,
    this.atTargetFraction,
    this.controlledPaceFraction,
    this.medianLiftS,
    this.medianHoldS,
    this.medianLowerS,
    this.restEnvelopePercent,
    this.curlEnvelopePercent,
    this.meanPain,
    this.meanEffort,
    required this.faultCount,
  });

  final String id;
  final String patientId;
  final DateTime startedAt;
  final String note;
  final SessionSource source;

  final int countedCount;
  final int partialCount;
  final int flaggedCount;
  final double targetAngleDeg;

  final double? meanPeakDeg;
  final double? bestPeakDeg;
  final double? worstPeakDeg;
  final double? meanScore;
  final double? atTargetFraction;
  final double? controlledPaceFraction;
  final double? medianLiftS;
  final double? medianHoldS;
  final double? medianLowerS;
  final double? restEnvelopePercent;
  final double? curlEnvelopePercent;
  final double? meanPain;
  final double? meanEffort;
  final int faultCount;

  factory SessionSummary.of(SessionRecord s) => SessionSummary(
        id: s.id,
        patientId: s.patientId,
        startedAt: s.startedAt,
        note: s.note,
        source: s.source,
        countedCount: s.countedCount,
        partialCount: s.partialCount,
        flaggedCount: s.flaggedCount,
        targetAngleDeg: s.config.targetAngleDeg,
        meanPeakDeg: s.meanPeakDeg,
        bestPeakDeg: s.bestPeakDeg,
        worstPeakDeg: s.worstPeakDeg,
        meanScore: s.meanScore,
        atTargetFraction: s.atTargetFraction,
        controlledPaceFraction: s.controlledPaceFraction,
        medianLiftS: s.medianLiftS,
        medianHoldS: s.medianHoldS,
        medianLowerS: s.medianLowerS,
        restEnvelopePercent: s.restEnvelopePercent,
        curlEnvelopePercent: s.curlEnvelopePercent,
        meanPain: s.meanPain,
        meanEffort: s.meanEffort,
        faultCount: s.faults.length,
      );

  String get dateLabel =>
      '${startedAt.year}-${_two(startedAt.month)}-${_two(startedAt.day)}';

  String get timeLabel => '${_two(startedAt.hour)}:${_two(startedAt.minute)}';

  static String _two(int v) => v.toString().padLeft(2, '0');

  Map<String, dynamic> toJson() => {
        'id': id,
        'patient_id': patientId,
        'started_at': startedAt.toIso8601String(),
        'note': note,
        'source': source.name,
        'counted': countedCount,
        'partial': partialCount,
        'flagged': flaggedCount,
        'target_angle_deg': targetAngleDeg,
        'mean_peak_deg': meanPeakDeg,
        'best_peak_deg': bestPeakDeg,
        'worst_peak_deg': worstPeakDeg,
        'mean_score': meanScore,
        'at_target_fraction': atTargetFraction,
        'controlled_pace_fraction': controlledPaceFraction,
        'median_lift_s': medianLiftS,
        'median_hold_s': medianHoldS,
        'median_lower_s': medianLowerS,
        'rest_envelope_percent': restEnvelopePercent,
        'curl_envelope_percent': curlEnvelopePercent,
        'mean_pain': meanPain,
        'mean_effort': meanEffort,
        'faults': faultCount,
      };

  static SessionSummary fromJson(Map<String, dynamic> j) => SessionSummary(
        id: j['id'] as String? ?? '',
        patientId: j['patient_id'] as String? ?? 'default',
        startedAt: DateTime.tryParse(j['started_at'] as String? ?? '') ??
            DateTime.now(),
        note: j['note'] as String? ?? '',
        source: SessionSource.values.firstWhere(
          (s) => s.name == j['source'],
          orElse: () => SessionSource.live,
        ),
        countedCount: (j['counted'] as num?)?.toInt() ?? 0,
        partialCount: (j['partial'] as num?)?.toInt() ?? 0,
        flaggedCount: (j['flagged'] as num?)?.toInt() ?? 0,
        targetAngleDeg: (j['target_angle_deg'] as num?)?.toDouble() ?? 90,
        meanPeakDeg: (j['mean_peak_deg'] as num?)?.toDouble(),
        bestPeakDeg: (j['best_peak_deg'] as num?)?.toDouble(),
        worstPeakDeg: (j['worst_peak_deg'] as num?)?.toDouble(),
        meanScore: (j['mean_score'] as num?)?.toDouble(),
        atTargetFraction: (j['at_target_fraction'] as num?)?.toDouble(),
        controlledPaceFraction:
            (j['controlled_pace_fraction'] as num?)?.toDouble(),
        medianLiftS: (j['median_lift_s'] as num?)?.toDouble(),
        medianHoldS: (j['median_hold_s'] as num?)?.toDouble(),
        medianLowerS: (j['median_lower_s'] as num?)?.toDouble(),
        restEnvelopePercent: (j['rest_envelope_percent'] as num?)?.toDouble(),
        curlEnvelopePercent: (j['curl_envelope_percent'] as num?)?.toDouble(),
        meanPain: (j['mean_pain'] as num?)?.toDouble(),
        meanEffort: (j['mean_effort'] as num?)?.toDouble(),
        faultCount: (j['faults'] as num?)?.toInt() ?? 0,
      );
}

class SessionStore extends ChangeNotifier {
  SessionStore();

  Directory? _dir;
  bool _loaded = false;
  bool get isLoaded => _loaded;

  String? lastError;

  final List<SessionSummary> _summaries = [];
  final List<Patient> _patients = [Patient.unassigned];

  /// Newest first, which is the order both the saved list and the "open a
  /// session" pickers want.
  List<SessionSummary> get all =>
      List.unmodifiable(_summaries.reversed.toList());

  /// Oldest first — the order the progress charts plot in.
  List<SessionSummary> get chronological => List.unmodifiable(_summaries);

  List<Patient> get patients => List.unmodifiable(_patients);

  String currentPatientId = Patient.unassigned.id;

  Patient get currentPatient => _patients.firstWhere(
        (p) => p.id == currentPatientId,
        orElse: () => Patient.unassigned,
      );

  List<SessionSummary> forPatient(String patientId) =>
      _summaries.where((s) => s.patientId == patientId).toList();

  /// Oldest first, for the current patient. What every progress chart plots.
  List<SessionSummary> get series => forPatient(currentPatientId);

  Future<Directory> _directory() async {
    final existing = _dir;
    if (existing != null) return existing;
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/rehabsense/sessions');
    if (!await d.exists()) await d.create(recursive: true);
    _dir = d;
    return d;
  }

  File _file(Directory d, String id) => File('${d.path}/$id.json');

  /// The patient list sits beside the sessions directory, not inside it, so
  /// the directory scan that rebuilds the index never has to skip it.
  File _patientsFile(Directory d) =>
      File('${d.parent.path}/patients.json');

  /// Read the directory and rebuild the index.
  ///
  /// A file that will not parse is skipped and counted, never fatal: a half
  /// written session (a crash mid-save) must not cost the other forty.
  Future<void> load() async {
    try {
      final d = await _directory();

      final pf = _patientsFile(d);
      if (await pf.exists()) {
        final raw = jsonDecode(await pf.readAsString());
        if (raw is List) {
          _patients
            ..clear()
            ..addAll([
              for (final p in raw)
                Patient.fromJson((p as Map).cast<String, dynamic>()),
            ]);
          if (_patients.isEmpty) _patients.add(Patient.unassigned);
        }
      }

      final out = <SessionSummary>[];
      var skipped = 0;
      await for (final e in d.list()) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        try {
          final j = (jsonDecode(await e.readAsString()) as Map)
              .cast<String, dynamic>();
          // A summary block is written alongside the record so the index does
          // not have to parse every trace point on every launch.
          final s = j['summary'];
          out.add(s is Map
              ? SessionSummary.fromJson(s.cast<String, dynamic>())
              : SessionSummary.of(SessionRecord.fromJson(j)));
        } catch (_) {
          skipped++;
        }
      }
      out.sort((a, b) => a.startedAt.compareTo(b.startedAt));
      _summaries
        ..clear()
        ..addAll(out);

      lastError = skipped == 0
          ? null
          : '$skipped saved session${skipped == 1 ? '' : 's'} could not be '
              'read and were skipped.';
      _loaded = true;
    } catch (e) {
      lastError = 'Could not read saved sessions: $e';
      _loaded = true;
    }
    notifyListeners();
  }

  Future<bool> save(SessionRecord record) async {
    try {
      final d = await _directory();
      final payload = record.toJson()
        ..['summary'] = SessionSummary.of(record).toJson();
      await _file(d, record.id).writeAsString(jsonEncode(payload), flush: true);

      _summaries
        ..removeWhere((s) => s.id == record.id)
        ..add(SessionSummary.of(record))
        ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
      lastError = null;
      notifyListeners();
      return true;
    } catch (e) {
      lastError = 'Could not save: $e';
      notifyListeners();
      return false;
    }
  }

  Future<SessionRecord?> open(String id) async {
    try {
      final d = await _directory();
      final f = _file(d, id);
      if (!await f.exists()) return null;
      final j = (jsonDecode(await f.readAsString()) as Map)
          .cast<String, dynamic>();
      return SessionRecord.fromJson(j);
    } catch (e) {
      lastError = 'Could not open that session: $e';
      notifyListeners();
      return null;
    }
  }

  Future<bool> delete(String id) async {
    try {
      final d = await _directory();
      final f = _file(d, id);
      if (await f.exists()) await f.delete();
      _summaries.removeWhere((s) => s.id == id);
      notifyListeners();
      return true;
    } catch (e) {
      lastError = 'Could not delete that session: $e';
      notifyListeners();
      return false;
    }
  }

  // ── Patients ─────────────────────────────────────────────────────────

  Future<void> _savePatients() async {
    try {
      final d = await _directory();
      await _patientsFile(d).writeAsString(
          jsonEncode(_patients.map((p) => p.toJson()).toList()),
          flush: true);
    } catch (e) {
      lastError = 'Could not save the patient list: $e';
    }
  }

  Future<Patient> addPatient(String name) async {
    final id = 'p${DateTime.now().microsecondsSinceEpoch}';
    final p = Patient(id: id, name: name.trim().isEmpty ? 'Unnamed' : name.trim());
    _patients.add(p);
    await _savePatients();
    notifyListeners();
    return p;
  }

  Future<void> renamePatient(String id, String name) async {
    final i = _patients.indexWhere((p) => p.id == id);
    if (i < 0) return;
    _patients[i] = Patient(id: id, name: name);
    await _savePatients();
    notifyListeners();
  }

  void selectPatient(String id) {
    currentPatientId = id;
    notifyListeners();
  }

  // ── Export and import ────────────────────────────────────────────────

  /// Everything, as one JSON document.
  ///
  /// Whole records rather than summaries: an export is a backup and a way to
  /// move a history between phones, and a summary-only export would arrive
  /// with no charts to draw.
  Future<String> exportAll({String? patientId}) async {
    final out = <Map<String, dynamic>>[];
    for (final s in _summaries) {
      if (patientId != null && s.patientId != patientId) continue;
      final r = await open(s.id);
      if (r != null) out.add(r.toJson());
    }
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'rehabsense-progress',
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'patients': _patients.map((p) => p.toJson()).toList(),
      'sessions': out,
    });
  }

  /// Merge an exported document in.
  ///
  /// Additive, and keyed on session id: re-importing the same export changes
  /// nothing. That is the behaviour a therapist who imports twice by accident
  /// needs, and the opposite of what a replace-all import would do.
  Future<ImportResult> importJson(String text) async {
    try {
      final j = (jsonDecode(text) as Map).cast<String, dynamic>();
      if (j['format'] != 'rehabsense-progress') {
        return ImportResult.failed(
            'That file is not a RehabSense progress export.');
      }

      for (final p in (j['patients'] as List? ?? const [])) {
        final patient = Patient.fromJson((p as Map).cast<String, dynamic>());
        if (!_patients.any((x) => x.id == patient.id)) _patients.add(patient);
      }
      await _savePatients();

      var added = 0;
      var alreadyHad = 0;
      var failed = 0;
      for (final s in (j['sessions'] as List? ?? const [])) {
        try {
          final record =
              SessionRecord.fromJson((s as Map).cast<String, dynamic>());
          if (_summaries.any((x) => x.id == record.id)) {
            alreadyHad++;
            continue;
          }
          if (await save(record)) {
            added++;
          } else {
            failed++;
          }
        } catch (_) {
          failed++;
        }
      }
      notifyListeners();
      return ImportResult(added: added, alreadyHad: alreadyHad, failed: failed);
    } catch (e) {
      return ImportResult.failed('Could not read that file: $e');
    }
  }
}

class ImportResult {
  const ImportResult({
    this.added = 0,
    this.alreadyHad = 0,
    this.failed = 0,
    this.error,
  });

  factory ImportResult.failed(String message) =>
      ImportResult(error: message);

  final int added;
  final int alreadyHad;
  final int failed;
  final String? error;

  bool get ok => error == null;

  String get message {
    if (error != null) return error!;
    final parts = [
      if (added > 0) '$added added',
      if (alreadyHad > 0) '$alreadyHad already saved',
      if (failed > 0) '$failed could not be read',
    ];
    return parts.isEmpty ? 'Nothing to import.' : parts.join(', ');
  }
}
