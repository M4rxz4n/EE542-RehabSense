/// "This session": the whole of one session on one timeline.
///
/// A port of the session viewer's first tab. It serves two sources through one
/// screen — the live session as it happens, and a saved session reopened — and
/// that is deliberate: a therapist comparing today with last Tuesday should not
/// have to learn two layouts, and a bug in one would not be found in the other.
///
/// ## Reading order
///
/// Summary tiles, then the whole session at a glance, then the two traces, then
/// per-rep bars, then the rep table. Each step narrows: what happened, roughly
/// where, exactly when, which rep, and why. Someone who only reads the tiles
/// still learns something true.
///
/// ## What is measured and what is reconstructed
///
/// Every number here came from the sleeve except the lift / hold / lower split,
/// which is timed from the rep-state stream in the app. The duration chart says
/// so in its own subtitle, and the rep table marks those three columns. That
/// distinction is not pedantry: the split is the one figure a reader might
/// otherwise cite back to the firmware team as a device measurement.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../protocol/enums.dart';
import '../session/rep_log.dart';
import '../session/session_record.dart';
import '../session/session_state.dart';
import '../session/session_store.dart';
import 'charts/bars.dart';
import 'charts/chart_kit.dart';
import 'charts/time_series.dart';
import 'theme.dart';

/// What the session screen needs, from either a live session or a saved one.
///
/// A thin view rather than a copy: the live session's lists are read in place,
/// so opening this tab mid-set costs nothing and a 2,000-sample trace is not
/// duplicated on every rebuild.
class SessionView {
  const SessionView({
    required this.reps,
    required this.trace,
    required this.faults,
    required this.config,
    required this.ratings,
    required this.title,
    required this.isLive,
    this.note = '',
    this.startedAt,
    this.fatigueStops = 0,
  });

  factory SessionView.live(SessionState s) => SessionView(
        reps: s.repRows,
        trace: s.record,
        faults: s.faults,
        ratings: s.ratings,
        config: SessionConfigSnapshot(
          targetAngleDeg: s.effectiveTargetDeg,
          peakAngleDeg: s.effectivePeakDeg,
          startAngleDeg: s.effectiveStartDeg,
          finishAngleDeg: s.effectiveFinishDeg,
          tempoMinS: s.effectiveTempoMinS,
          tempoMaxS: s.effectiveTempoMaxS,
          repTarget: s.effectiveRepTarget,
          setCount: s.effectiveSetCount,
          restSeconds: s.sleeveParams?.restSeconds ?? 60,
          muscleOnPercent: s.sleeveParams?.muscleOnPercent,
          paceOn: s.paceOn,
        ),
        title: 'This session',
        isLive: true,
        startedAt: s.sessionStartedAt,
        fatigueStops: s.fatigueStops,
      );

  factory SessionView.saved(SessionRecord r) => SessionView(
        reps: r.reps,
        trace: r.trace,
        faults: r.faults,
        ratings: r.ratings,
        config: r.config,
        title: '${r.startedAt.day}/${r.startedAt.month} '
            '${r.startedAt.hour.toString().padLeft(2, '0')}:'
            '${r.startedAt.minute.toString().padLeft(2, '0')}',
        isLive: false,
        note: r.note,
        startedAt: r.startedAt,
        fatigueStops: r.fatigueStops,
      );

  final List<RepRow> reps;
  final List<TraceSample> trace;
  final List<FaultSpan> faults;
  final List<SetRating> ratings;
  final SessionConfigSnapshot config;
  final String title;
  final bool isLive;
  final String note;
  final DateTime? startedAt;
  final int fatigueStops;

  List<RepRow> get counted => reps.where((r) => r.counted).toList();
  List<RepRow> get partials => reps.where((r) => !r.counted).toList();

  double get totalSeconds =>
      trace.isEmpty ? 0 : trace.last.tMs / 1000;

  int? get repT0Us => reps.isEmpty ? null : reps.first.atUs;

  double? get meanPeak {
    final c = counted;
    if (c.isEmpty) return null;
    return c.map((r) => r.peakAngleDeg).reduce((a, b) => a + b) / c.length;
  }

  int get atTarget =>
      counted.where((r) => r.peakAngleDeg >= config.targetAngleDeg).length;

  int get flagged => counted.where((r) => r.flagged).length;

  int get passive =>
      reps.where((r) => r.outcome == RepOutcome.passive).length;

  double? get meanScore {
    final c = counted.where((r) => r.score != null).toList();
    if (c.isEmpty) return null;
    return c.map((r) => r.score!).reduce((a, b) => a + b) / c.length;
  }

  double? get onPaceFraction {
    final c = counted;
    if (c.isEmpty) return null;
    final ok = c
        .where((r) =>
            r.durationS >= config.tempoMinS && r.durationS <= config.tempoMaxS)
        .length;
    return ok / c.length;
  }
}

class SessionScreen extends StatefulWidget {
  const SessionScreen({
    super.key,
    required this.state,
    required this.store,
    this.loaded,
    this.onCloseLoaded,
  });

  final SessionState state;
  final SessionStore store;

  /// A saved session being viewed instead of the live one.
  final SessionRecord? loaded;
  final VoidCallback? onCloseLoaded;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  TimeWindow? _window;
  int? _selectedRep;
  String? _message;

  /// The default window. Thirty seconds shows two or three curls with room to
  /// see their shape; the whole session squeezed into a phone width shows a
  /// solid block.
  static const double defaultSpanS = 30;

  SessionView get _view => widget.loaded != null
      ? SessionView.saved(widget.loaded!)
      : SessionView.live(widget.state);

  TimeWindow _windowFor(SessionView v) {
    final total = math.max(1.0, v.totalSeconds);
    final w = _window;
    if (w == null) {
      // Live: follow the end of the trace, because the interesting moment is
      // always now. Saved: start at the beginning, because the whole thing is
      // already there to read.
      if (v.isLive) {
        final from = math.max(0.0, total - defaultSpanS);
        return TimeWindow(from, math.max(from + 1, total));
      }
      return TimeWindow(0, math.min(total, defaultSpanS));
    }
    // A window that has fallen off the end of a shrinking trace.
    if (w.fromS > total) {
      return TimeWindow(math.max(0, total - w.spanS), total);
    }
    return w;
  }

  void _focusRep(SessionView v, int index) {
    setState(() => _selectedRep = index);
    final t0 = v.repT0Us;
    if (t0 == null || index >= v.reps.length) return;
    final at = (v.reps[index].atUs - t0) / 1e6;
    setState(() => _window =
        _windowFor(v).centredOn(at, maxS: math.max(1, v.totalSeconds)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final v = _view;
        final window = _windowFor(v);

        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 28),
            children: [
              _Header(
                view: v,
                onClose: widget.onCloseLoaded,
                onSave: v.isLive ? () => _save(v) : null,
                onCsv: () => _copyCsv(v),
                message: _message,
              ),
              _SummaryTiles(view: v),
              ChartCard(
                title: 'Whole session at a glance',
                subtitle: 'Each bump is one curl. The box marks the stretch '
                    'shown below — tap or drag the strip to move it.',
                legend: const [
                  LegendItem('Counted', RehabColors.good),
                  LegendItem('Flagged', RehabColors.warn),
                  LegendItem('Partial', RehabColors.inkFaint),
                  LegendItem('Not counted', RehabColors.bad),
                ],
                child: OverviewStrip(
                  samples: v.trace,
                  reps: v.reps,
                  window: window,
                  peakAngleDeg: v.config.peakAngleDeg,
                  faults: v.faults,
                  onWindow: (w) => setState(() => _window = w),
                ),
              ),
              ChartCard(
                title: 'Elbow angle over time',
                subtitle: 'A full curl rises from near 0° past the dashed '
                    'criterion and comes back down. Drag sideways to move '
                    'through time; press and hold for exact values.',
                legend: [
                  const LegendItem('Elbow angle', Color(0xFF2F9FD4)),
                  LegendItem(
                      'Counts above ${v.config.peakAngleDeg.round()}°',
                      RehabColors.good,
                      dashed: true),
                  LegendItem('Full target ${v.config.targetAngleDeg.round()}°',
                      RehabColors.inkFaint,
                      dashed: true),
                ],
                child: TraceChart(
                  samples: v.trace,
                  window: window,
                  onWindow: (w) => setState(() => _window = w),
                  value: (s) => s.angleDeg,
                  color: ChartPalette.series[0],
                  yMax: math.max(
                      v.config.targetAngleDeg * 1.25,
                      v.trace.isEmpty
                          ? 120
                          : v.trace
                              .map((s) => s.angleDeg)
                              .reduce(math.max)
                              .clamp(60, 180)),
                  yLabel: (x) => '${x.toStringAsFixed(0)}°',
                  tooltipUnit: '°',
                  reps: v.reps,
                  repT0Us: v.repT0Us,
                  faults: v.faults,
                  selectedRepIndex: _selectedRep,
                  thresholds: [
                    (v.config.peakAngleDeg, RehabColors.good, 'counts above'),
                    (
                      v.config.targetAngleDeg,
                      RehabColors.inkFaint,
                      'full target'
                    ),
                    (v.config.startAngleDeg, RehabColors.inkFaint, 'rep starts'),
                  ],
                  showTimeAxis: false,
                  height: 190,
                ),
              ),
              ChartCard(
                title: 'Biceps effort over time',
                subtitle: 'The same time axis as the angle above — separate '
                    'panels, because degrees and percent on one pair of axes '
                    'would invent a crossing point that means nothing.',
                legend: [
                  const LegendItem('Biceps effort', Color(0xFFDE6A45)),
                  const LegendItem('Muscle working', RehabColors.muscle),
                  if (v.config.muscleOnPercent != null)
                    LegendItem(
                        'Counts as working above '
                        '${v.config.muscleOnPercent!.round()}%',
                        RehabColors.warn,
                        dashed: true),
                ],
                child: TraceChart(
                  samples: v.trace,
                  window: window,
                  onWindow: (w) => setState(() => _window = w),
                  value: (s) => s.envelopePercent,
                  color: ChartPalette.series[1],
                  yMax: 150,
                  yLabel: (x) => '${x.toStringAsFixed(0)}%',
                  tooltipUnit: '%',
                  reps: v.reps,
                  repT0Us: v.repT0Us,
                  faults: v.faults,
                  selectedRepIndex: _selectedRep,
                  shadeActivation: true,
                  thresholds: [
                    if (v.config.muscleOnPercent != null)
                      (
                        v.config.muscleOnPercent!,
                        RehabColors.warn,
                        'muscle on'
                      ),
                    (100, RehabColors.inkFaint, 'calibration squeeze'),
                  ],
                  height: 170,
                ),
              ),
              ChartCard(
                title: 'Highest angle reached in each rep',
                subtitle: 'One bar per counted rep, in order. Tap a bar to '
                    'find it on the charts above.',
                legend: const [
                  LegendItem('Reached the full target', RehabColors.good),
                  LegendItem('Counted, below the target', RehabColors.warn),
                ],
                child: PeakAngleBars(
                  reps: v.counted,
                  peakAngleDeg: v.config.peakAngleDeg,
                  targetAngleDeg: v.config.targetAngleDeg,
                  selected: _countedIndexOf(v, _selectedRep),
                  onSelect: (i) =>
                      _focusRep(v, v.reps.indexOf(v.counted[i])),
                ),
              ),
              ChartCard(
                title: 'How long each rep took',
                subtitle: v.counted.any((r) => r.phases != null)
                    ? 'Split into lift, hold and lower. The sleeve reports one '
                        'total; the split is timed in the app from the rep '
                        'state it streams, so treat it as indicative.'
                    : 'Slow and controlled is good. Bars far above the band '
                        'usually mean a pause mid-rep.',
                legend: const [
                  LegendItem('Lift', Color(0xFF2F9FD4)),
                  LegendItem('Hold', Color(0xFFA855B8)),
                  LegendItem('Lower', Color(0xFFDE6A45)),
                  LegendItem('Outside the ideal pace', RehabColors.warn),
                ],
                child: RepDurationBars(
                  reps: v.counted,
                  tempoMinS: v.config.tempoMinS,
                  tempoMaxS: v.config.tempoMaxS,
                  selected: _countedIndexOf(v, _selectedRep),
                  onSelect: (i) =>
                      _focusRep(v, v.reps.indexOf(v.counted[i])),
                ),
              ),
              _RepTable(
                view: v,
                selected: _selectedRep,
                onSelect: (i) => _focusRep(v, i),
              ),
            ],
          ),
        );
      },
    );
  }

  int? _countedIndexOf(SessionView v, int? repIndex) {
    if (repIndex == null || repIndex >= v.reps.length) return null;
    final i = v.counted.indexOf(v.reps[repIndex]);
    return i < 0 ? null : i;
  }

  Future<void> _save(SessionView v) async {
    if (v.reps.isEmpty) {
      setState(() => _message = 'Nothing to save yet — no reps recorded.');
      return;
    }
    final note = await _askNote();
    if (note == null) return;
    final record = widget.state.buildRecord(
      patientId: widget.store.currentPatientId,
      note: note,
    );
    final ok = await widget.store.save(record);
    if (!mounted) return;
    setState(() => _message = ok
        ? 'Saved to ${widget.store.currentPatient.name}\'s progress.'
        : widget.store.lastError ?? 'Could not save.');
  }

  Future<String?> _askNote() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: RehabColors.surfaceHigh,
        title: const Text('Save to progress'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Saving for ${widget.store.currentPatient.name}. A short note '
              'is what makes this session findable in six weeks.',
              style: RehabText.body,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              maxLength: 80,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Note (optional)',
                hintText: 'e.g. new electrode spot',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _copyCsv(SessionView v) async {
    if (v.reps.isEmpty) {
      setState(() => _message = 'No reps to export yet.');
      return;
    }
    final record = widget.loaded ??
        widget.state.buildRecord(patientId: widget.store.currentPatientId);
    await Clipboard.setData(ClipboardData(text: record.toCsv()));
    if (!mounted) return;
    setState(() => _message =
        'Rep log copied as CSV — ${v.reps.length} rows, ready to paste.');
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.view,
    required this.onClose,
    required this.onSave,
    required this.onCsv,
    required this.message,
  });

  final SessionView view;
  final VoidCallback? onClose;
  final VoidCallback? onSave;
  final VoidCallback onCsv;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      view.isLive ? 'This session' : 'Saved session',
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w600,
                        color: RehabColors.ink,
                      ),
                    ),
                    Text(
                      [
                        if (!view.isLive) view.title,
                        if (view.note.isNotEmpty) view.note,
                        '${view.counted.length} counted',
                        if (view.partials.isNotEmpty)
                          '${view.partials.length} partial',
                      ].join(' · '),
                      style: RehabText.body.copyWith(fontSize: 12.5),
                    ),
                  ],
                ),
              ),
              if (onClose != null)
                IconButton(
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 20),
                  tooltip: 'Back to the live session',
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (onSave != null)
                OutlinedButton.icon(
                  onPressed: onSave,
                  icon: const Icon(Icons.bookmark_add_outlined, size: 17),
                  label: const Text('Save to progress'),
                ),
              if (onSave != null) const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: onCsv,
                icon: const Icon(Icons.copy_all_outlined, size: 17),
                label: const Text('Copy CSV'),
              ),
            ],
          ),
          if (message != null) ...[
            const SizedBox(height: 8),
            Text(message!,
                style: RehabText.body
                    .copyWith(fontSize: 12.5, color: RehabColors.good)),
          ],
        ],
      ),
    );
  }
}

class _SummaryTiles extends StatelessWidget {
  const _SummaryTiles({required this.view});

  final SessionView view;

  @override
  Widget build(BuildContext context) {
    final v = view;
    final atTargetPct = v.counted.isEmpty
        ? null
        : v.atTarget / v.counted.length * 100;
    final onPacePct =
        v.onPaceFraction == null ? null : v.onPaceFraction! * 100;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          StatTile(
            label: 'Counted reps',
            value: '${v.counted.length}',
            detail: 'target ${v.config.repTarget} per set',
            grade: v.counted.length >= v.config.repTarget
                ? TileGrade.good
                : TileGrade.neutral,
          ),
          StatTile(
            label: 'At full target',
            value: atTargetPct == null ? '–' : atTargetPct.toStringAsFixed(0),
            unit: atTargetPct == null ? null : '%',
            detail: '${v.atTarget} of ${v.counted.length} past '
                '${v.config.targetAngleDeg.round()}°',
            grade: atTargetPct == null
                ? TileGrade.neutral
                : atTargetPct >= 80
                    ? TileGrade.good
                    : atTargetPct >= 50
                        ? TileGrade.warn
                        : TileGrade.bad,
          ),
          StatTile(
            label: 'Mean peak',
            value: v.meanPeak == null ? '–' : v.meanPeak!.toStringAsFixed(0),
            unit: v.meanPeak == null ? null : '°',
            detail: 'criterion ${v.config.peakAngleDeg.round()}°',
          ),
          StatTile(
            label: 'On pace',
            value: onPacePct == null ? '–' : onPacePct.toStringAsFixed(0),
            unit: onPacePct == null ? null : '%',
            detail: '${v.config.tempoMinS.toStringAsFixed(0)}'
                '–${v.config.tempoMaxS.toStringAsFixed(0)} s per rep',
            grade: onPacePct == null
                ? TileGrade.neutral
                : onPacePct >= 70
                    ? TileGrade.good
                    : TileGrade.warn,
          ),
          StatTile(
            label: 'Mean score',
            value: v.meanScore == null ? '–' : v.meanScore!.toStringAsFixed(0),
            detail: 'as the sleeve graded them',
          ),
          StatTile(
            label: 'Form flags',
            value: '${v.flagged}',
            detail: v.flagged == 0
                ? 'no compensation detected'
                : 'reps counted but marked',
            grade: v.flagged == 0
                ? TileGrade.good
                : v.flagged <= 2
                    ? TileGrade.warn
                    : TileGrade.bad,
          ),
          StatTile(
            label: 'Partial',
            value: '${v.partials.length}',
            detail: v.passive > 0
                ? '${v.passive} with the biceps quiet'
                : 'started, stopped short',
            grade: v.partials.isEmpty ? TileGrade.good : TileGrade.warn,
          ),
          StatTile(
            label: 'Sensor faults',
            value: '${v.faults.length}',
            detail: v.faults.isEmpty
                ? 'both IMUs answered throughout'
                : 'readings unreliable in those stretches',
            grade: v.faults.isEmpty ? TileGrade.good : TileGrade.bad,
          ),
          if (v.fatigueStops > 0)
            StatTile(
              label: 'Fatigue stops',
              value: '${v.fatigueStops}',
              detail: 'a set ended early',
              grade: TileGrade.warn,
            ),
        ],
      ),
    );
  }
}

/// Every rep, in order, with the reason for its result.
///
/// Partials are rows. A patient who sees nothing after a hard attempt
/// concludes the device is broken, which is worse than a dash in a table.
class _RepTable extends StatelessWidget {
  const _RepTable({
    required this.view,
    required this.selected,
    required this.onSelect,
  });

  final SessionView view;
  final int? selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    if (view.reps.isEmpty) {
      return const ChartCard(
        title: 'Every rep, in order',
        child: ChartEmpty(
          message: 'No attempts yet. Counted and partial reps both appear '
              'here as they happen.',
          icon: Icons.list_alt,
        ),
      );
    }

    final anyPhases = view.reps.any((r) => r.phases != null);
    final t0 = view.repT0Us ?? 0;

    const tapHint = 'Tap a row to find it on the charts above and see why it '
        'got its result.';
    const phaseHint = ' Lift, hold and lower are timed in the app, not '
        'reported by the sleeve.';

    return ChartCard(
      title: 'Every rep, in order',
      subtitle: anyPhases ? '$tapHint$phaseHint' : tapHint,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: RehabColors.divider)),
            ),
            child: Row(
              children: [
                _cell('#', 30),
                _cell('TIME', 48),
                _cell('PEAK', 46),
                _cell('SECS', 44),
                if (anyPhases) _cell('L·H·L', 74),
                _cell('SCORE', 46),
                const Expanded(child: Text('RESULT', style: RehabText.label)),
              ],
            ),
          ),
          for (var i = 0; i < view.reps.length; i++)
            _RepRowTile(
              row: view.reps[i],
              elapsedS: (view.reps[i].atUs - t0) / 1e6,
              showPhases: anyPhases,
              selected: selected == i,
              onTap: () => onSelect(i),
            ),
        ],
      ),
    );
  }

  static Widget _cell(String s, double w) =>
      SizedBox(width: w, child: Text(s, style: RehabText.label));
}

class _RepRowTile extends StatelessWidget {
  const _RepRowTile({
    required this.row,
    required this.elapsedS,
    required this.showPhases,
    required this.selected,
    required this.onTap,
  });

  final RepRow row;
  final double elapsedS;
  final bool showPhases;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colour = switch (row.outcome) {
      RepOutcome.onTarget => RehabColors.good,
      RepOutcome.countedPaceOff => RehabColors.warn,
      RepOutcome.flagged => RehabColors.warn,
      RepOutcome.partial => RehabColors.inkFaint,
      RepOutcome.passive => RehabColors.bad,
    };
    final p = row.phases;

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? RehabColors.actual.withValues(alpha: 0.08)
              : Colors.transparent,
          border: const Border(
              bottom: BorderSide(color: RehabColors.divider, width: 0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 30,
                  child: Text(row.index?.toString() ?? '–',
                      style: RehabText.numeric.copyWith(fontSize: 14)),
                ),
                SizedBox(
                  width: 48,
                  child: Text(mmss(elapsedS),
                      style: RehabText.body.copyWith(fontSize: 12.5)),
                ),
                SizedBox(
                  width: 46,
                  child: Text('${row.peakAngleDeg.toStringAsFixed(0)}°',
                      style: RehabText.numeric.copyWith(fontSize: 13.5)),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                      row.durationS > 0
                          ? row.durationS.toStringAsFixed(1)
                          : '–',
                      style: RehabText.body.copyWith(fontSize: 12.5)),
                ),
                if (showPhases)
                  SizedBox(
                    width: 74,
                    child: Text(
                      p == null
                          ? '–'
                          : '${p.liftS.toStringAsFixed(1)}·'
                              '${p.holdS.toStringAsFixed(1)}·'
                              '${p.lowerS.toStringAsFixed(1)}',
                      style: RehabText.body
                          .copyWith(fontSize: 11.5, color: RehabColors.inkFaint),
                    ),
                  ),
                SizedBox(
                  width: 46,
                  child: Text(row.score?.toString() ?? '–',
                      style: RehabText.numeric
                          .copyWith(fontSize: 13.5, color: colour)),
                ),
                Expanded(
                  child: Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle, color: colour),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(row.outcome.shortLabel,
                            style: RehabText.body
                                .copyWith(fontSize: 12, color: colour),
                            overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (selected) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: RehabColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('WHY', style: RehabText.label),
                    const SizedBox(height: 5),
                    for (final line in row.why)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text('· $line',
                            style: RehabText.body.copyWith(fontSize: 12.5)),
                      ),
                    if (row.bicepsPercent != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          'Biceps working for '
                          '${row.bicepsPercent!.toStringAsFixed(0)}% of the '
                          'lift.',
                          style: RehabText.body.copyWith(
                              fontSize: 12.5, color: RehabColors.muscle),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
