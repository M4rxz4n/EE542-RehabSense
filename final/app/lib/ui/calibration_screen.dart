/// The calibration wizard — PRD §5.3, six prompted steps, under 30 seconds.
///
/// ## Why every step is individually repeatable
///
/// The firmware takes a phase argument on `CMD_START_CALIBRATION` precisely so
/// one step can be re-run alone. That is not a convenience: the step most
/// likely to fail is the maximum voluntary contraction on a paretic limb, and
/// that is exactly the step a patient least wants to repeat four others to get
/// back to. So this screen never offers "start over" as the primary action —
/// each row re-runs itself.
///
/// ## The clinician override
///
/// If a true maximum cannot be elicited, the device flags the record
/// `MVC_UNRELIABLE` and every effort percentage afterwards is normalised
/// against a number nobody trusts. The escape hatch is a clinician-supplied
/// value written as a whole `calib_record_t` to the calibration
/// characteristic — not through SET_CONFIG. This screen exposes it, with the
/// caveat shown rather than hidden.
library;

import 'package:flutter/material.dart';

import '../protocol/calib.dart';
import '../protocol/enums.dart';
import '../session/session_state.dart';
import 'theme.dart';

class CalibrationScreen extends StatelessWidget {
  const CalibrationScreen({super.key, required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final steps = CalibPhase.wizardSteps;
        final record = state.calibration;
        final running = state.calibratingPhase;

        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Calibration', style: RehabText.big),
                        const SizedBox(height: 4),
                        Text(
                          '${state.calibrationDone.length} of ${steps.length} '
                          'steps done',
                          style: RehabText.body,
                        ),
                      ],
                    ),
                  ),
                  if (running != null)
                    OutlinedButton(
                      onPressed: state.abortCalibration,
                      child: const Text('Abort'),
                    ),
                ],
              ),
              const SizedBox(height: 18),

              if (record != null && !record.isCalibrated)
                const _Banner(
                  color: RehabColors.warn,
                  icon: Icons.priority_high,
                  text: 'This sleeve has no usable profile yet. Effort '
                      'percentages and scores will not mean much until the '
                      'steps below are done.',
                ),

              if (record?.mvcUnreliable ?? false)
                const _Banner(
                  color: RehabColors.warn,
                  icon: Icons.warning_amber,
                  text: 'The recorded maximum contraction was not reliable. '
                      'Effort is being normalised against it anyway. A '
                      'clinician can supply a value instead — see below.',
                ),

              if (record?.clinicianOverride ?? false)
                const _Banner(
                  color: RehabColors.actual,
                  icon: Icons.medical_information_outlined,
                  text: 'Effort is normalised against a clinician-supplied '
                      'maximum, not a measured one.',
                ),

              const SizedBox(height: 6),
              for (final step in steps)
                _StepRow(
                  step: step,
                  done: state.calibrationDone.contains(step),
                  running: running == step,
                  busy: running != null,
                  onRun: () => state.runCalibrationStep(step),
                ),

              const SizedBox(height: 22),
              OutlinedButton.icon(
                onPressed: running != null
                    ? null
                    : () => state.runCalibrationStep(CalibPhase.all),
                icon: const Icon(Icons.playlist_play),
                label: const Text('Run the whole protocol'),
              ),

              const SizedBox(height: 28),
              if (record != null) _RecordCard(record: record, state: state),
            ],
          ),
        );
      },
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.step,
    required this.done,
    required this.running,
    required this.busy,
    required this.onRun,
  });

  final CalibPhase step;
  final bool done;
  final bool running;
  final bool busy;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final Color accent;
    if (running) {
      accent = RehabColors.actual;
    } else if (done) {
      accent = RehabColors.good;
    } else {
      accent = RehabColors.inkFaint;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: RehabColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: running
              ? RehabColors.actual.withValues(alpha: 0.6)
              : RehabColors.divider,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: running
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: RehabColors.actual,
                    ),
                  )
                : Icon(
                    done ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: accent,
                    size: 20,
                  ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(step.label,
                    style: RehabText.numeric.copyWith(
                      color: running ? RehabColors.actual : RehabColors.ink,
                    )),
                const SizedBox(height: 3),
                // The prompt is what the patient is told, so it lives on the
                // phase itself rather than in this widget.
                Text(step.prompt, style: RehabText.body),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // Re-run is always available on a completed step. That is the whole
          // point of the per-phase argument.
          TextButton(
            onPressed: busy ? null : onRun,
            child: Text(done ? 'Redo' : 'Run'),
          ),
        ],
      ),
    );
  }
}

class _RecordCard extends StatelessWidget {
  const _RecordCard({required this.record, required this.state});

  final CalibRecord record;
  final SessionState state;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: RehabColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('STORED PROFILE', style: RehabText.label),
          const SizedBox(height: 12),

          _Row('Version', '${record.version}'),

          // The thing every rep band is a fraction of. An absolute angle is
          // never the criterion.
          _Row('Range of motion', '${record.rom.toStringAsFixed(1)}°'),
          _Row('Extension / flexion',
              '${record.angleMin.toStringAsFixed(1)}° … '
                  '${record.angleMax.toStringAsFixed(1)}°'),
          _Row('Resting RMS', record.emgRestRms.first.toStringAsFixed(4)),
          _Row('Resting σ', record.emgRestSd.first.toStringAsFixed(4)),
          _Row('Maximum contraction',
              record.emgMvc.first.toStringAsFixed(3)),
          _Row('Median freq. baseline',
              '${record.mdfBaseline.first.toStringAsFixed(1)} Hz'),

          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 14),

          Text(
            'If a true maximum contraction cannot be elicited, a clinician '
            'can supply one. It is written to the sleeve as a whole '
            'calibration record and supersedes the measured value.',
            style: RehabText.body.copyWith(fontSize: 13),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => _promptOverride(context),
            child: const Text('Supply a maximum'),
          ),
        ],
      ),
    );
  }

  Future<void> _promptOverride(BuildContext context) async {
    final controller = TextEditingController(
      text: record.emgMvc.first.toStringAsFixed(3),
    );

    final value = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: RehabColors.surfaceHigh,
        title: const Text('Clinician-supplied maximum'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Everything else the protocol measured is kept. The record is '
              'marked as overridden so it is clear later that this value was '
              'not measured.',
              style: RehabText.body.copyWith(fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Maximum, same units as the measured value',
                border: OutlineInputBorder(),
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
            onPressed: () {
              final v = double.tryParse(controller.text);
              Navigator.pop(context, (v != null && v > 0) ? v : null);
            },
            child: const Text('Write to sleeve'),
          ),
        ],
      ),
    );

    if (value == null) return;
    await state.device.writeCalibration(record.withMvcOverride([value]));
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        children: [
          Expanded(child: Text(label, style: RehabText.body)),
          Text(value, style: RehabText.numeric.copyWith(fontSize: 15)),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.color,
    required this.icon,
    required this.text,
  });

  final Color color;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 11),
          Expanded(
            child: Text(text,
                style: RehabText.body.copyWith(fontSize: 13.5, height: 1.4)),
          ),
        ],
      ),
    );
  }
}
