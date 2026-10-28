import 'package:flutter/material.dart';
import '../app_state.dart';
import '../models.dart';
import 'widgets.dart';

/// Live view, per-rep analysis, one-tap feedback to the patient,
/// prescription and session history.
class TherapistScreen extends StatefulWidget {
  const TherapistScreen(this.s, {super.key});
  final AppState s;
  @override
  State<TherapistScreen> createState() => _TherapistScreenState();
}

class _TherapistScreenState extends State<TherapistScreen> {
  final _text = TextEditingController();
  AppState get s => widget.s;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Widget _stepper(String label, num value, num step, num min, num max, void Function(num) set) {
    return Row(children: [
      Expanded(child: Text(label)),
      IconButton(onPressed: value > min ? () => set(value - step) : null, icon: const Icon(Icons.remove_circle_outline)),
      SizedBox(width: 44, child: Text('$value', textAlign: TextAlign.center)),
      IconButton(onPressed: value < max ? () => set(value + step) : null, icon: const Icon(Icons.add_circle_outline)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme, tt = Theme.of(context).textTheme;
        final f = s.frame, p = s.params;
        final last = s.allReps.isEmpty ? null : s.allReps.last;
        final sug = s.suggestion;
        return ListView(padding: const EdgeInsets.all(16), children: [
          Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Live view · ${f?.state.name ?? 'connecting'} · set ${f?.set ?? 0}, ${s.setReps.length} of ${p.repTarget}', style: tt.titleMedium),
            const SizedBox(height: 8),
            SizedBox(height: 220, child: CustomPaint(size: Size.infinite, painter: TracePainter(s.angle, s.bic, s.tri, p.targetAngle, cs))),
            Wrap(spacing: 6, children: liveChips(f)),
            Text(f == null ? '' : 'Biceps ${(f.bic * 100).round()}% · Triceps ${(f.tri * 100).round()}% · Median freq ${f.medianFreq?.toStringAsFixed(1) ?? '–'} Hz · Angle ${f.angle.round()}° · Velocity ${f.velocity.round()} °/s', style: tt.bodySmall),
          ]))),
          Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Last repetition', style: tt.titleMedium),
            if (last == null) const Text('Complete a repetition to see its analysis.') else ..._analysis(last, p),
          ]))),
          Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Live feedback to patient', style: tt.titleMedium),
            if (sug != null) TextButton(onPressed: () => s.sendMessage(sug), child: Text('Suggested: $sug')),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final k in ['shoulder', 'trunk', 'swing', 'range', 'slow', 'fast', 'good', 'rest'])
                OutlinedButton(onPressed: () => s.sendMessage(AppState.msg[k]!), child: Text(k)),
            ]),
            Row(children: [
              Expanded(child: TextField(controller: _text, decoration: const InputDecoration(hintText: 'Type a message'))),
              FilledButton(onPressed: () { s.sendMessage(_text.text); _text.clear(); }, child: const Text('Send')),
            ]),
            for (final m in s.messages.take(6)) Text('${m.text} · ${m.seen ? 'seen by patient' : 'sent'}', style: tt.bodySmall),
          ]))),
          Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(children: [
            Align(alignment: Alignment.centerLeft, child: Text('Prescription (applies from next rep)', style: tt.titleMedium)),
            _stepper('Repetitions per set', p.repTarget, 1, 1, 50, (v) => s.updateParams((x) => x.repTarget = v.toInt())),
            _stepper('Sets', p.setCount, 1, 1, 6, (v) => s.updateParams((x) => x.setCount = v.toInt())),
            _stepper('Target angle (°)', p.targetAngle.round(), 5, 40, 150, (v) => s.updateParams((x) => x.targetAngle = v.toDouble())),
            _stepper('Confirming hold (ms)', p.holdDurationMs, 100, 300, 3000, (v) => s.updateParams((x) => x.holdDurationMs = v.toInt())),
          ]))),
          Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Session history', style: tt.titleMedium),
            if (s.history.isEmpty) const Text('No sessions yet.'),
            for (final h in s.history.reversed)
              Text('${h.time.toString().substring(0, 16)} · ${h.reps} reps · ${(100 * h.flagged / h.reps).round()}% flagged · mean ${h.meanScore.round()} · shoulder ${h.shoulder} · fatigue ${h.fatigue}'),
          ]))),
        ]);
      },
    );
  }

  List<Widget> _analysis(RepResult g, Params p) => [
        Wrap(spacing: 8, runSpacing: 8, children: [
          Tile('Score', '${g.score.round()}'),
          Tile('Peak angle', '${g.peakAngle.round()}° (${(100 * g.peakAngle / p.targetAngle).round()}%)', bad: g.flags.contains('range')),
          Tile('Duration', '${g.duration.toStringAsFixed(1)} s', bad: g.flags.contains('tempo')),
          Tile('Velocity peaks', '${g.velocityPeaks} (ideal 2)', bad: g.velocityPeaks > 2),
          Tile('Biceps onset', g.latency == null ? '–' : '${(g.latency! * 1000).round()} ms'),
          Tile('Co-contraction', '${(g.overlap * 100).round()}% overlap', bad: g.overlap > .4),
          Tile('Shoulder', '${g.maxUpper.round()}° (limit ${p.shoulderDeg.round()})', bad: g.flags.contains('shoulder compensation')),
          Tile('Trunk lean', '${g.maxTrunk.round()}° (limit 10)', bad: g.flags.contains('trunk lean')),
          Tile('Median freq', '${g.medianFreq.toStringAsFixed(1)} Hz'),
        ]),
        const SizedBox(height: 8),
        for (final w in g.why) Text('• $w'),
      ];
}
