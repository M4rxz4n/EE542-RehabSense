import 'package:flutter/material.dart';
import '../app_state.dart';
import '../device_link.dart';
import '../models.dart';
import '../simulator_link.dart';
import 'widgets.dart';

/// Engineer view: calibration steps, simulator controls, haptic pattern test, event log.
class DeviceScreen extends StatelessWidget {
  const DeviceScreen(this.s, {super.key});
  final AppState s;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme, tt = Theme.of(context).textTheme;
        final link = s.link;
        final sim = link is SimulatorLink ? link : null;
        final running = s.frame?.running ?? false;
        return ListView(padding: const EdgeInsets.all(16), children: [
          Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Live session · ${s.frame?.state.name ?? 'connecting'}', style: tt.titleMedium),
            SizedBox(height: 200, child: CustomPaint(size: Size.infinite, painter: TracePainter(s.angle, s.bic, s.tri, s.params.targetAngle, cs))),
            Row(children: [
              FilledButton(onPressed: s.calibrated && !running ? s.start : null, child: const Text('Start session')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: running ? s.stop : null, child: const Text('Stop')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: running ? link.injectFault : null, child: const Text('Lift electrode')),
            ]),
            if (sim != null) Row(children: [
              const Text('Scenario '),
              DropdownButton<Scenario>(
                value: sim.scenario,
                items: [for (final x in Scenario.values) DropdownMenuItem(value: x, child: Text(x.name))],
                onChanged: (v) { if (v != null) { sim.scenario = v; s.refresh(); } },
              ),
              const SizedBox(width: 12),
              const Text('Speed '),
              DropdownButton<int>(
                value: sim.speed,
                items: [for (final x in [1, 3, 6]) DropdownMenuItem(value: x, child: Text('$x×'))],
                onChanged: (v) { if (v != null) { sim.speed = v; s.refresh(); } },
              ),
            ]),
          ]))),
          Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('Calibration', style: tt.titleMedium)),
              FilledButton(onPressed: running || s.calibrating ? null : s.calibrateAll, child: const Text('Run all steps')),
            ]),
            for (var i = 0; i < calibrationSteps.length; i++)
              ListTile(
                dense: true,
                title: Text(calibrationSteps[i].$1),
                subtitle: Text(calibrationSteps[i].$2),
                trailing: link.calibration[i] ? const Icon(Icons.check_circle, color: Colors.green) : TextButton(onPressed: running || s.calibrating ? null : () => link.runCalibrationStep(i), child: const Text('Run')),
              ),
          ]))),
          Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Haptic pattern test', style: tt.titleMedium),
            Wrap(spacing: 6, children: [
              for (final h in HapticPattern.values) OutlinedButton(onPressed: () => link.firePattern(h), child: Text(h.name)),
            ]),
          ]))),
          Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Events', style: tt.titleMedium),
            for (final e in s.log.take(20)) Text(e, style: tt.bodySmall),
          ]))),
        ]);
      },
    );
  }
}
