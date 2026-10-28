import 'package:flutter/material.dart';
import '../app_state.dart';
import '../models.dart';
import 'widgets.dart';

/// Large, simple, high-contrast. The patient sees plain-language cues only.
class PatientScreen extends StatelessWidget {
  const PatientScreen(this.s, {super.key});
  final AppState s;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme, tt = Theme.of(context).textTheme;
        final f = s.frame;
        final (title, sub) = s.patientText;
        final running = f?.running ?? false;
        final last = s.setReps.isEmpty ? null : s.setReps.last;
        final p = s.params;
        final label = running ? 'Stop' : (!s.calibrated ? 'Get ready' : 'Start');
        return ListView(padding: const EdgeInsets.all(20), children: [
          if (s.pending != null)
            Card(
              color: cs.primaryContainer,
              child: ListTile(
                title: Text('Therapist: ${s.pending!.text}', style: tt.titleMedium),
                trailing: FilledButton(onPressed: s.acknowledge, child: const Text('Got it')),
              ),
            ),
          Text(title, textAlign: TextAlign.center, style: tt.headlineLarge?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(sub, textAlign: TextAlign.center, style: tt.titleMedium),
          SizedBox(height: 150, child: CustomPaint(painter: GaugePainter(f?.angle ?? 0, p.targetAngle, cs))),
          Text(running ? (s.liveCue ?? '') : '', textAlign: TextAlign.center, style: tt.titleMedium?.copyWith(color: cs.error, fontWeight: FontWeight.bold)),
          if (running && last != null)
            Text(last.flags.isEmpty ? 'Last repetition: good.' : 'Last repetition counted. ${_tip(last, p)}',
                textAlign: TextAlign.center, style: tt.titleMedium),
          const SizedBox(height: 8),
          Text('${s.setReps.length} of ${p.repTarget} repetitions · set ${f?.set ?? 1} of ${p.setCount}', textAlign: TextAlign.center, style: tt.titleLarge),
          const SizedBox(height: 12),
          Wrap(alignment: WrapAlignment.center, spacing: 6, runSpacing: 6, children: [
            for (var i = 0; i < p.repTarget; i++)
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < s.setReps.length ? (s.setReps[i].flagged ? Colors.amber.shade700 : Colors.green.shade700) : null,
                  border: Border.all(color: i < s.setReps.length ? Colors.transparent : cs.outlineVariant, width: 2),
                ),
              ),
          ]),
          const SizedBox(height: 24),
          Center(
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(220, 64), textStyle: tt.titleLarge),
              onPressed: s.calibrating
                  ? null
                  : () {
                      if (running) {
                        s.stop();
                      } else if (!s.calibrated) {
                        s.calibrateAll();
                      } else {
                        s.start();
                      }
                    },
              child: Text(label),
            ),
          ),
        ]);
      },
    );
  }

  String _tip(RepResult r, Params p) {
    switch (r.flags.first) {
      case 'shoulder compensation':
        return 'Keep your shoulder down and relaxed.';
      case 'trunk lean':
        return 'Stay upright, don’t lean.';
      case 'momentum':
        return 'Slow and steady, no swinging.';
      case 'range':
        return 'Try to curl a little higher.';
      default:
        return r.duration < p.tempoMin ? 'Slow down a little.' : 'Move a bit faster.';
    }
  }
}
