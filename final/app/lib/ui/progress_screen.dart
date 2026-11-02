/// "Progress over time": every saved session as one point on four charts.
///
/// This is the tab that answers the only question the project is really for —
/// is this person getting better. A single session cannot answer it, and a
/// table of forty sessions does not either.
///
/// ## Why the charts are these four
///
/// Ported from the session viewer, and each one is a different *kind* of
/// improvement, so a patient who is plateauing on one may still be moving on
/// another:
///
/// 1. **Highest angle per session** — range of motion. The headline.
/// 2. **Rep timing per session** — control. A patient whose range has stalled
///    but whose lift and lower are converging on the prescribed tempo is
///    improving in a way the first chart cannot show.
/// 3. **Reps at a controlled pace** — consistency, as a single percentage.
/// 4. **Biceps effort at rest and during curls** — signal quality and
///    efficiency together. Rest creeping up means the arm is not relaxing, or
///    the electrodes have moved; curls creeping down for the same range means
///    the movement is costing less.
///
/// ## Per patient, always
///
/// One sleeve and one phone get shared between people, and merging two
/// patients' reps into one trend line is worse than having no trend line — it
/// produces a chart that looks like data and is not. Every chart here is
/// filtered to the selected patient, and the selector is at the top where it
/// cannot be missed.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../session/session_record.dart';
import '../session/session_store.dart';
import 'charts/chart_kit.dart';
import 'charts/trends.dart';
import 'theme.dart';

class ProgressScreen extends StatefulWidget {
  const ProgressScreen({
    super.key,
    required this.store,
    required this.onOpenSession,
  });

  final SessionStore store;
  final void Function(SessionRecord) onOpenSession;

  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  int? _selected;
  String? _message;
  String? _compareA;
  String? _compareB;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (!widget.store.isLoaded) widget.store.load();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final series = widget.store.series;

        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 28),
            children: [
              _PatientBar(
                store: widget.store,
                onMessage: (m) => setState(() => _message = m),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Text(_message!,
                      style: RehabText.body
                          .copyWith(fontSize: 12.5, color: RehabColors.good)),
                ),
              if (series.isEmpty)
                _EmptyProgress(store: widget.store)
              else ...[
                _ProgressSummary(series: series),
                _AngleTrend(
                  series: series,
                  selected: _selected,
                  onSelect: (i) => setState(() => _selected = i),
                ),
                _TimingTrend(
                  series: series,
                  selected: _selected,
                  onSelect: (i) => setState(() => _selected = i),
                ),
                _PaceTrend(
                  series: series,
                  selected: _selected,
                  onSelect: (i) => setState(() => _selected = i),
                ),
                _EffortTrend(
                  series: series,
                  selected: _selected,
                  onSelect: (i) => setState(() => _selected = i),
                ),
                _Compare(
                  series: series,
                  idA: _compareA,
                  idB: _compareB,
                  onA: (v) => setState(() => _compareA = v),
                  onB: (v) => setState(() => _compareB = v),
                ),
                _SavedList(
                  store: widget.store,
                  onOpen: _open,
                  onDelete: _delete,
                ),
              ],
              _ExportImport(
                store: widget.store,
                busy: _busy,
                onMessage: (m) => setState(() => _message = m),
                onBusy: (b) => setState(() => _busy = b),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _open(SessionSummary s) async {
    final record = await widget.store.open(s.id);
    if (!mounted) return;
    if (record == null) {
      setState(() =>
          _message = widget.store.lastError ?? 'Could not open that session.');
      return;
    }
    widget.onOpenSession(record);
  }

  Future<void> _delete(SessionSummary s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: RehabColors.surfaceHigh,
        title: const Text('Delete this session?'),
        content: Text(
          'The session from ${s.dateLabel}'
          '${s.note.isEmpty ? '' : ' (${s.note})'} will be removed. This '
          'cannot be undone, and an export is the only copy.',
          style: RehabText.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: RehabColors.bad),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.store.delete(s.id);
    if (!mounted) return;
    setState(() => _message = 'Deleted the session from ${s.dateLabel}.');
  }
}

class _PatientBar extends StatelessWidget {
  const _PatientBar({required this.store, required this.onMessage});

  final SessionStore store;
  final ValueChanged<String> onMessage;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Text('PATIENT', style: RehabText.label),
          const SizedBox(width: 10),
          Expanded(
            child: DropdownButton<String>(
              value: store.currentPatientId,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              dropdownColor: RehabColors.surfaceHigh,
              items: [
                for (final p in store.patients)
                  DropdownMenuItem(
                    value: p.id,
                    child: Text(
                      '${p.name}  ·  ${store.forPatient(p.id).length} '
                      'session${store.forPatient(p.id).length == 1 ? '' : 's'}',
                      style: RehabText.body.copyWith(color: RehabColors.ink),
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) store.selectPatient(v);
              },
            ),
          ),
          IconButton(
            tooltip: 'Add a patient',
            icon: const Icon(Icons.person_add_alt, size: 20),
            onPressed: () => _addPatient(context),
          ),
        ],
      ),
    );
  }

  Future<void> _addPatient(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: RehabColors.surfaceHigh,
        title: const Text('Add a patient'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Sessions are kept separately per patient. Use whatever name or '
              'code your notes use — this stays on the phone.',
              style: RehabText.body,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 40,
              decoration: const InputDecoration(labelText: 'Name or code'),
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
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    final p = await store.addPatient(name);
    store.selectPatient(p.id);
    onMessage('Added ${p.name}, and selected them.');
  }
}

class _EmptyProgress extends StatelessWidget {
  const _EmptyProgress({required this.store});

  final SessionStore store;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: RehabColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RehabColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('No saved sessions for ${store.currentPatient.name}',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: RehabColors.ink,
              )),
          const SizedBox(height: 8),
          Text(
            'Finish a set, then use Save to progress on the Session tab. Every '
            'saved session becomes one point on the charts here, so the second '
            'one is where this tab starts being useful.',
            style: RehabText.body,
          ),
          if (store.lastError != null) ...[
            const SizedBox(height: 12),
            Text(store.lastError!,
                style: RehabText.body.copyWith(color: RehabColors.warn)),
          ],
        ],
      ),
    );
  }
}

class _ProgressSummary extends StatelessWidget {
  const _ProgressSummary({required this.series});

  final List<SessionSummary> series;

  @override
  Widget build(BuildContext context) {
    final first = series.first;
    final last = series.last;
    final days = last.startedAt.difference(first.startedAt).inDays;

    String delta(double? a, double? b, String unit) {
      if (a == null || b == null) return '–';
      final d = b - a;
      final sign = d >= 0 ? '+' : '';
      return '$sign${d.toStringAsFixed(1)}$unit';
    }

    final peakDelta = (last.meanPeakDeg ?? 0) - (first.meanPeakDeg ?? 0);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          StatTile(
            label: 'Sessions',
            value: '${series.length}',
            detail: days == 0 ? 'all today' : 'over $days days',
          ),
          StatTile(
            label: 'Mean peak, first → last',
            value: delta(first.meanPeakDeg, last.meanPeakDeg, '°'),
            detail: '${first.meanPeakDeg?.toStringAsFixed(0) ?? '–'}° → '
                '${last.meanPeakDeg?.toStringAsFixed(0) ?? '–'}°',
            grade: peakDelta > 2
                ? TileGrade.good
                : peakDelta < -2
                    ? TileGrade.warn
                    : TileGrade.neutral,
          ),
          StatTile(
            label: 'Total counted reps',
            value: '${series.fold<int>(0, (a, s) => a + s.countedCount)}',
            detail: 'across every saved session',
          ),
          StatTile(
            label: 'Latest at target',
            value: last.atTargetFraction == null
                ? '–'
                : (last.atTargetFraction! * 100).toStringAsFixed(0),
            unit: last.atTargetFraction == null ? null : '%',
            detail: 'target ${last.targetAngleDeg.round()}°',
            grade: last.atTargetFraction == null
                ? TileGrade.neutral
                : last.atTargetFraction! >= 0.8
                    ? TileGrade.good
                    : TileGrade.warn,
          ),
        ],
      ),
    );
  }
}

List<String> _labels(List<SessionSummary> s) =>
    [for (final x in s) '${x.startedAt.day}/${x.startedAt.month}'];

class _AngleTrend extends StatelessWidget {
  const _AngleTrend(
      {required this.series, required this.selected, required this.onSelect});

  final List<SessionSummary> series;
  final int? selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return ChartCard(
      title: 'Highest angle per session',
      subtitle: 'The average of each session\'s counted reps. The shaded band '
          'spans that session\'s lowest to highest rep, so a rising average '
          'with a widening band means less consistency, not more range.',
      legend: const [
        LegendItem('Mean peak angle', Color(0xFF2F9FD4)),
        LegendItem('Therapist target', RehabColors.inkFaint, dashed: true),
      ],
      child: TrendChart(
        selected: selected,
        onSelect: onSelect,
        xLabels: _labels(series),
        yLabel: (v) => '${v.toStringAsFixed(0)}°',
        pointLabels: false,
        thresholds: [
          (series.last.targetAngleDeg, RehabColors.inkFaint, 'target'),
        ],
        series: [
          TrendSeries(
            label: 'Mean peak',
            unit: '°',
            color: ChartPalette.series[0],
            values: [for (final s in series) s.meanPeakDeg],
            band: [
              for (final s in series)
                (s.worstPeakDeg != null && s.bestPeakDeg != null)
                    ? (s.worstPeakDeg!, s.bestPeakDeg!)
                    : null,
            ],
          ),
        ],
      ),
    );
  }
}

class _TimingTrend extends StatelessWidget {
  const _TimingTrend(
      {required this.series, required this.selected, required this.onSelect});

  final List<SessionSummary> series;
  final int? selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final any = series.any((s) => s.medianLiftS != null);
    return ChartCard(
      title: 'Rep timing per session',
      subtitle: any
          ? 'The typical seconds spent lifting, holding and lowering. Timed in '
              'the app from the sleeve\'s rep state, not measured by the '
              'sleeve, so read the trend rather than the absolute values.'
          : 'Needs the live feature stream to time the phases, which a session '
              'saved without one does not carry.',
      legend: const [
        LegendItem('Lift', Color(0xFF2F9FD4)),
        LegendItem('Hold', Color(0xFFA855B8)),
        LegendItem('Lower', Color(0xFFDE6A45)),
      ],
      child: any
          ? TrendChart(
              selected: selected,
              onSelect: onSelect,
              xLabels: _labels(series),
              yMin: 0,
              yLabel: (v) => '${v.toStringAsFixed(1)}s',
              pointLabels: false,
              series: [
                TrendSeries(
                  label: 'Lift',
                  unit: ' s',
                  color: ChartPalette.series[0],
                  values: [for (final s in series) s.medianLiftS],
                ),
                TrendSeries(
                  label: 'Hold',
                  unit: ' s',
                  color: ChartPalette.series[2],
                  values: [for (final s in series) s.medianHoldS],
                ),
                TrendSeries(
                  label: 'Lower',
                  unit: ' s',
                  color: ChartPalette.series[1],
                  values: [for (final s in series) s.medianLowerS],
                ),
              ],
            )
          : const ChartEmpty(
              message: 'No phase timings in these sessions.',
              icon: Icons.timer_outlined),
    );
  }
}

class _PaceTrend extends StatelessWidget {
  const _PaceTrend(
      {required this.series, required this.selected, required this.onSelect});

  final List<SessionSummary> series;
  final int? selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return ChartCard(
      title: 'Reps at a controlled pace',
      subtitle: 'The share of counted reps whose lift, hold and lower together '
          'took 4–9 s. A wider band than the sleeve\'s own tempo score, '
          'because this asks whether the movement was deliberate rather than '
          'whether it scored well.',
      legend: const [
        LegendItem('At a controlled pace', Color(0xFF2F9FD4)),
      ],
      child: TrendChart(
        selected: selected,
        onSelect: onSelect,
        xLabels: _labels(series),
        yMin: 0,
        yMax: 100,
        yLabel: (v) => '${v.toStringAsFixed(0)}%',
        pointLabels: false,
        thresholds: const [(70, RehabColors.good, 'good')],
        series: [
          TrendSeries(
            label: 'On pace',
            unit: '%',
            color: ChartPalette.series[0],
            values: [
              for (final s in series)
                s.controlledPaceFraction == null
                    ? null
                    : s.controlledPaceFraction! * 100,
            ],
          ),
        ],
      ),
    );
  }
}

class _EffortTrend extends StatelessWidget {
  const _EffortTrend(
      {required this.series, required this.selected, required this.onSelect});

  final List<SessionSummary> series;
  final int? selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return ChartCard(
      title: 'Biceps effort at rest and during curls',
      subtitle: 'Rest should stay near zero — a rising rest level means the arm '
          'is not relaxing, or an electrode has moved. Readings pinned near '
          '150% mean the calibration squeeze was too gentle, so the whole '
          'session\'s percentages are compressed.',
      legend: const [
        LegendItem('While curling', Color(0xFFDE6A45)),
        LegendItem('At rest', Color(0xFF2F9FD4)),
      ],
      child: TrendChart(
        selected: selected,
        onSelect: onSelect,
        xLabels: _labels(series),
        yMin: 0,
        yLabel: (v) => '${v.toStringAsFixed(0)}%',
        pointLabels: false,
        thresholds: const [
          (100, RehabColors.inkFaint, 'calibration squeeze'),
        ],
        series: [
          TrendSeries(
            label: 'Curling',
            unit: '%',
            color: ChartPalette.series[1],
            values: [for (final s in series) s.curlEnvelopePercent],
          ),
          TrendSeries(
            label: 'Rest',
            unit: '%',
            color: ChartPalette.series[0],
            values: [for (final s in series) s.restEnvelopePercent],
          ),
        ],
      ),
    );
  }
}

/// Two sessions side by side, with a verdict on each measure.
///
/// Better and worse are judged against the targets on this page, not against
/// each other — so "worse" never means "slightly lower but still fine".
class _Compare extends StatelessWidget {
  const _Compare({
    required this.series,
    required this.idA,
    required this.idB,
    required this.onA,
    required this.onB,
  });

  final List<SessionSummary> series;
  final String? idA;
  final String? idB;
  final ValueChanged<String?> onA;
  final ValueChanged<String?> onB;

  @override
  Widget build(BuildContext context) {
    if (series.length < 2) return const SizedBox.shrink();

    final a = series.firstWhere((s) => s.id == idA, orElse: () => series.first);
    final b = series.firstWhere((s) => s.id == idB, orElse: () => series.last);

    return ChartCard(
      title: 'Compare two sessions',
      subtitle: 'Pick an earlier and a later session to see what changed.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _picker('Earlier', series, a.id, onA)),
              const SizedBox(width: 10),
              Expanded(child: _picker('Later', series, b.id, onB)),
            ],
          ),
          const SizedBox(height: 12),
          _row('Counted reps', a.countedCount.toDouble(),
              b.countedCount.toDouble(), '', higherIsBetter: true),
          _row('Mean peak angle', a.meanPeakDeg, b.meanPeakDeg, '°',
              higherIsBetter: true),
          _row(
            'At full target',
            a.atTargetFraction == null ? null : a.atTargetFraction! * 100,
            b.atTargetFraction == null ? null : b.atTargetFraction! * 100,
            '%',
            higherIsBetter: true,
          ),
          _row(
            'On a controlled pace',
            a.controlledPaceFraction == null
                ? null
                : a.controlledPaceFraction! * 100,
            b.controlledPaceFraction == null
                ? null
                : b.controlledPaceFraction! * 100,
            '%',
            higherIsBetter: true,
          ),
          _row('Partial reps', a.partialCount.toDouble(),
              b.partialCount.toDouble(), '', higherIsBetter: false),
          _row('Form flags', a.flaggedCount.toDouble(),
              b.flaggedCount.toDouble(), '', higherIsBetter: false),
          _row('Effort at rest', a.restEnvelopePercent, b.restEnvelopePercent,
              '%', higherIsBetter: false),
          _row('Sensor faults', a.faultCount.toDouble(),
              b.faultCount.toDouble(), '', higherIsBetter: false),
        ],
      ),
    );
  }

  Widget _picker(String label, List<SessionSummary> items, String value,
          ValueChanged<String?> onChanged) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: RehabText.label),
          DropdownButton<String>(
            value: value,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            dropdownColor: RehabColors.surfaceHigh,
            items: [
              for (final s in items)
                DropdownMenuItem(
                  value: s.id,
                  child: Text(
                    s.note.isEmpty ? s.dateLabel : '${s.dateLabel} · ${s.note}',
                    style: RehabText.body.copyWith(color: RehabColors.ink),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: onChanged,
          ),
        ],
      );

  Widget _row(String label, double? a, double? b, String unit,
      {required bool higherIsBetter}) {
    final known = a != null && b != null;
    final delta = known ? b - a : 0.0;
    // A change under 2% of the earlier value is noise, not progress.
    final threshold = known ? (a.abs() * 0.02).clamp(0.5, 5.0) : 0.0;
    final meaningful = known && delta.abs() > threshold;
    final better = higherIsBetter ? delta > 0 : delta < 0;

    final colour = !meaningful
        ? RehabColors.inkSoft
        : better
            ? RehabColors.good
            : RehabColors.warn;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
              child: Text(label,
                  style: RehabText.body.copyWith(fontSize: 13))),
          SizedBox(
            width: 56,
            child: Text(a == null ? '–' : '${a.toStringAsFixed(0)}$unit',
                style: RehabText.numeric.copyWith(fontSize: 13),
                textAlign: TextAlign.right),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 56,
            child: Text(b == null ? '–' : '${b.toStringAsFixed(0)}$unit',
                style: RehabText.numeric.copyWith(fontSize: 13),
                textAlign: TextAlign.right),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 86,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (meaningful)
                  Icon(better ? Icons.arrow_upward : Icons.arrow_downward,
                      size: 13, color: colour),
                const SizedBox(width: 3),
                Text(
                  !known
                      ? '–'
                      : meaningful
                          ? (better ? 'better' : 'worse')
                          : 'about the same',
                  style: RehabText.label.copyWith(color: colour, fontSize: 10),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SavedList extends StatelessWidget {
  const _SavedList({
    required this.store,
    required this.onOpen,
    required this.onDelete,
  });

  final SessionStore store;
  final void Function(SessionSummary) onOpen;
  final void Function(SessionSummary) onDelete;

  @override
  Widget build(BuildContext context) {
    final items = store.forPatient(store.currentPatientId).reversed.toList();
    return ChartCard(
      title: 'Saved sessions',
      subtitle: 'Newest first. Open one to see its full timeline and reps.',
      child: Column(
        children: [
          for (final s in items)
            InkWell(
              onTap: () => onOpen(s),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: const BoxDecoration(
                  border: Border(
                      bottom: BorderSide(
                          color: RehabColors.divider, width: 0.5)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text('${s.dateLabel}  ${s.timeLabel}',
                                  style: RehabText.numeric
                                      .copyWith(fontSize: 13.5)),
                              if (s.source != SessionSource.live) ...[
                                const SizedBox(width: 8),
                                // A demo or replayed session is labelled, so
                                // it can never be mistaken for real data on a
                                // progress chart.
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: RehabColors.warn
                                        .withValues(alpha: 0.18),
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                  child: Text(s.source.name.toUpperCase(),
                                      style: RehabText.label.copyWith(
                                          color: RehabColors.warn,
                                          fontSize: 9)),
                                ),
                              ],
                            ],
                          ),
                          if (s.note.isNotEmpty)
                            Text(s.note,
                                style: RehabText.body.copyWith(fontSize: 12)),
                          Text(
                            '${s.countedCount} counted · '
                            '${s.partialCount} partial · '
                            '${s.meanPeakDeg?.toStringAsFixed(0) ?? '–'}° mean'
                            '${s.faultCount > 0 ? ' · ${s.faultCount} faults' : ''}',
                            style: RehabText.body.copyWith(
                                fontSize: 11.5, color: RehabColors.inkFaint),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Delete',
                      icon: const Icon(Icons.delete_outline, size: 18),
                      color: RehabColors.inkFaint,
                      onPressed: () => onDelete(s),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ExportImport extends StatelessWidget {
  const _ExportImport({
    required this.store,
    required this.busy,
    required this.onMessage,
    required this.onBusy,
  });

  final SessionStore store;
  final bool busy;
  final ValueChanged<String> onMessage;
  final ValueChanged<bool> onBusy;

  @override
  Widget build(BuildContext context) {
    return ChartCard(
      title: 'Export and import',
      subtitle: 'An export is one JSON document holding every saved session '
          'whole, so it restores the charts on another phone — and can be read '
          'by hand. Import is additive and keyed on session id, so importing '
          'the same file twice changes nothing.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : () => _export(context),
                icon: const Icon(Icons.ios_share, size: 17),
                label: const Text('Copy export to clipboard'),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : () => _import(context),
                icon: const Icon(Icons.download_outlined, size: 17),
                label: const Text('Paste an export'),
              ),
            ],
          ),
          if (store.lastError != null) ...[
            const SizedBox(height: 10),
            Text(store.lastError!,
                style: RehabText.body.copyWith(color: RehabColors.warn)),
          ],
        ],
      ),
    );
  }

  Future<void> _export(BuildContext context) async {
    onBusy(true);
    try {
      final text = await store.exportAll();
      await Clipboard.setData(ClipboardData(text: text));
      onMessage('Export copied to the clipboard — '
          '${(text.length / 1024).toStringAsFixed(0)} kB of JSON.');
    } finally {
      onBusy(false);
    }
  }

  Future<void> _import(BuildContext context) async {
    final controller = TextEditingController();
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (clip?.text != null) controller.text = clip!.text!;
    if (!context.mounted) return;

    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: RehabColors.surfaceHigh,
        title: const Text('Paste an export'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Anything already here is pre-filled from the clipboard. '
                'Sessions already saved are skipped.',
                style: RehabText.body,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 6,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '{"format":"rehabsense-progress", …}',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;

    onBusy(true);
    try {
      final result = await store.importJson(text);
      onMessage(result.message);
    } finally {
      onBusy(false);
    }
  }
}
