/// Calibration, as the sleeve actually runs it.
///
/// ## Three steps, not six
///
/// The ESP-IDF firmware's protocol has six steps — contact check, rest,
/// straight, biceps maximum, triceps maximum, range sweep. The shipping sleeve
/// runs **three**: rest, straight arm, maximum contraction. Triceps needs a
/// second channel the prototype does not have, and the contact check and sweep
/// are not implemented.
///
/// This screen shows three. A wizard offering six steps against firmware that
/// runs three would leave a patient waiting for prompts that never come, which
/// is the single easiest way to make a working device look broken.
///
/// ## Why it is step-at-a-time and not one button
///
/// A maximum voluntary contraction on a paretic limb is the step most likely
/// to be rejected, and it is the one a patient least wants to repeat four
/// others to get back to. So the sleeve waits: each step advances when told,
/// and this screen's job is to say which step is running and what the patient
/// should be doing during it.
///
/// Started from the app, the sleeve advances each step by itself after three
/// seconds. That is why **Next step** is offered as well — if the patient is
/// not ready, the prompt is still there to be read, and the step can be driven
/// by hand.
///
/// ## Where the detail comes from
///
/// `EVT_CALIB_PHASE_DONE` gives a phase and a percentage, and nothing else.
/// The measured rest level, the noise floor, the maximum contraction and the
/// comfortable bend the sleeve settled on arrive only as printed lines on the
/// Messages characteristic — which is why the console below is part of this
/// screen rather than a debugging extra.
library;

import 'package:flutter/material.dart';

import '../protocol/enums.dart';
import '../protocol/sleeve_messages.dart';
import '../session/session_state.dart';
import 'theme.dart';

/// The steps the shipping sleeve actually walks, in order.
const List<(CalibPhase, String, String)> sleeveCalibSteps = [
  (
    CalibPhase.rest,
    'Arm relaxed',
    'Let the arm hang loose and still, by your side. The sleeve measures the '
        'resting muscle level and the noise floor here, and everything it '
        'later calls "working" is judged against them.',
  ),
  (
    CalibPhase.straight,
    'Straight arm',
    'Straighten the arm as far as is comfortable and hold it still. This '
        'becomes 0°. If this is off, every angle for the rest of the session '
        'is off by the same amount.',
  ),
  (
    CalibPhase.biceps,
    'Squeeze as hard as is comfortable',
    'Curl against resistance. This sets 100% effort, so a gentle squeeze here '
        'compresses every percentage afterwards — but a painful one is never '
        'worth it. The sleeve says if it saw too little change.',
  ),
];

class CalibrationScreen extends StatelessWidget {
  const CalibrationScreen({super.key, required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final running = state.calibratingPhase != null ||
            state.calibrationPrompt != null;

        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            children: [
              _Status(state: state),
              const SizedBox(height: 18),
              if (state.calibrationPrompt != null) ...[
                _Prompt(text: state.calibrationPrompt!),
                const SizedBox(height: 18),
              ],
              for (final (phase, title, detail) in sleeveCalibSteps)
                _StepRow(
                  phase: phase,
                  title: title,
                  detail: detail,
                  done: state.calibrationDone.contains(phase),
                  active: state.calibratingPhase == phase,
                ),
              const SizedBox(height: 20),
              _Actions(state: state, running: running),
              const SizedBox(height: 22),
              _Console(state: state),
              const SizedBox(height: 18),
              _Record(state: state),
            ],
          ),
        );
      },
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    final calibrated = state.isCalibrated;
    final running = state.calibratingPhase != null;

    final (icon, colour, headline, body) = running
        ? (
            Icons.sync,
            RehabColors.actual,
            'Calibrating',
            'Follow the prompt. Each step moves on by itself after three '
                'seconds, or use Next step.',
          )
        : calibrated
            ? (
                Icons.check_circle_outline,
                RehabColors.good,
                'Calibrated',
                'Scores, angles and effort percentages all mean something. '
                    'Re-zero if the angle drifts; recalibrate if the sleeve '
                    'has been taken off and put back on.',
              )
            : (
                Icons.error_outline,
                RehabColors.warn,
                'Not calibrated',
                'The sleeve counts reps either way, but the angles are '
                    'relative to nothing and the effort percentages mean '
                    'nothing until this is done once.',
              );

    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colour.withValues(alpha: 0.42)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: colour),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(headline,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: colour,
                    )),
                const SizedBox(height: 4),
                Text(body, style: RehabText.body.copyWith(fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The sleeve's own prompt, large, because this is what the patient reads.
class _Prompt extends StatelessWidget {
  const _Prompt({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: RehabColors.surfaceHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('THE SLEEVE SAYS', style: RehabText.label),
          const SizedBox(height: 7),
          Text(text,
              style: const TextStyle(
                fontSize: 21,
                height: 1.25,
                fontWeight: FontWeight.w500,
                color: RehabColors.ink,
              )),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.phase,
    required this.title,
    required this.detail,
    required this.done,
    required this.active,
  });

  final CalibPhase phase;
  final String title;
  final String detail;
  final bool done;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colour = active
        ? RehabColors.actual
        : done
            ? RehabColors.good
            : RehabColors.inkFaint;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: active
            ? RehabColors.actual.withValues(alpha: 0.08)
            : RehabColors.surface,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: active ? RehabColors.actual : RehabColors.divider,
          width: active ? 1.6 : 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // State by shape as well as colour: a filled tick, an open ring, a
          // dash. Colour alone is not an acceptable encoding here.
          SizedBox(
            width: 26,
            child: Icon(
              done
                  ? Icons.check_circle
                  : active
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
              size: 19,
              color: colour,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: active ? RehabColors.ink : RehabColors.inkSoft,
                    )),
                const SizedBox(height: 3),
                Text(detail, style: RehabText.body.copyWith(fontSize: 12.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.state, required this.running});

  final SessionState state;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final live = state.linkState.isLive;
    final device = state.device;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (running)
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: live ? device.calibrationNext : null,
                  icon: const Icon(Icons.skip_next, size: 18),
                  label: const Text('Next step'),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: live ? state.abortCalibration : null,
                style: OutlinedButton.styleFrom(
                    foregroundColor: RehabColors.bad),
                child: const Text('Stop'),
              ),
            ],
          )
        else
          FilledButton.icon(
            onPressed:
                live ? () => state.runCalibrationStep(CalibPhase.all) : null,
            icon: const Icon(Icons.play_arrow, size: 19),
            label: Text(state.isCalibrated
                ? 'Calibrate again'
                : 'Start calibration'),
          ),
        const SizedBox(height: 14),
        if (running)
          OutlinedButton.icon(
            onPressed: live ? device.calibrationGo : null,
            icon: const Icon(Icons.fitness_center, size: 17),
            label: const Text('Skip ahead and start the reps'),
          ),
        if (!running) ...[
          Text('IF SOMETHING IS OFF', style: RehabText.label),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: live ? device.reZero : null,
                icon: const Icon(Icons.straighten, size: 17),
                label: const Text('Re-zero the straight arm'),
              ),
              OutlinedButton.icon(
                onPressed: live ? device.runEmgTest : null,
                icon: const Icon(Icons.graphic_eq, size: 17),
                label: const Text('Test the EMG signal'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Re-zeroing takes two seconds with the arm held straight and asks '
            'nothing of the muscle — it is the fix when the angle has drifted '
            'but the effort percentages are still good. The EMG test is the '
            'first thing to run when effort looks wrong; its results appear '
            'in the Developer tab.',
            style: RehabText.body.copyWith(fontSize: 12.5),
          ),
        ],
      ],
    );
  }
}

/// What the sleeve printed during calibration.
///
/// Not a debugging extra. The measured rest level, the noise floor, the
/// maximum contraction, the comfortable bend and any warning about electrode
/// contact exist only here — the calibration event carries a phase and a
/// percentage and nothing more.
class _Console extends StatelessWidget {
  const _Console({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('WHAT THE SLEEVE REPORTED', style: RehabText.label),
        const SizedBox(height: 7),
        ValueListenableBuilder<int>(
          valueListenable: state.messageRevision,
          builder: (context, _, __) {
            final lines = [
              for (final m in state.messages)
                if (m.kind == SleeveMessageKind.calibration ||
                    m.kind == SleeveMessageKind.target ||
                    m.kind == SleeveMessageKind.params)
                  m,
            ];
            if (lines.isEmpty) {
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: RehabColors.surface,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: RehabColors.divider),
                ),
                child: Text(
                  'Nothing yet. The measured levels and the target the sleeve '
                  'settles on appear here as it works through the steps.',
                  style: RehabText.body.copyWith(fontSize: 12.5),
                ),
              );
            }
            final recent = lines.length > 40
                ? lines.sublist(lines.length - 40)
                : lines;
            return Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 240),
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: RehabColors.bg,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: RehabColors.divider),
              ),
              child: ListView.builder(
                reverse: true,
                itemCount: recent.length,
                itemBuilder: (context, i) {
                  final m = recent[recent.length - 1 - i];
                  final warn = m.raw.contains('WARNING') ||
                      m.raw.contains("Couldn't") ||
                      m.raw.contains('stopped');
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      m.display,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        height: 1.45,
                        color:
                            warn ? RehabColors.warn : RehabColors.inkSoft,
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ],
    );
  }
}

/// The stored profile, as the sleeve holds it.
class _Record extends StatelessWidget {
  const _Record({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    final r = state.calibration;
    if (r == null) {
      return Text(
        'The sleeve has not returned a calibration profile yet. It is read on '
        'connect and after each calibration.',
        style: RehabText.body.copyWith(fontSize: 12.5),
      );
    }

    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: RehabColors.surface,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: RehabColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('STORED PROFILE', style: RehabText.label),
          const SizedBox(height: 10),
          _kv('Range of motion recorded',
              '${r.angleMin.toStringAsFixed(0)}° to '
                  '${r.angleMax.toStringAsFixed(0)}°'),
          if (r.emgRestRms.isNotEmpty)
            _kv('Resting muscle level',
                '${r.emgRestRms.first.toStringAsFixed(0)} (counts)'),
          if (r.emgRestSd.isNotEmpty)
            _kv('Noise floor',
                '${r.emgRestSd.first.toStringAsFixed(1)} — the activation '
                    'threshold is three of these above rest'),
          if (r.emgMvc.isNotEmpty)
            _kv('Maximum contraction',
                r.emgMvc.first.toStringAsFixed(0)),
          _kv('Target in force on the sleeve',
              '${state.effectiveTargetDeg.toStringAsFixed(0)}° — a rep counts '
                  'above ${state.effectivePeakDeg.toStringAsFixed(0)}°'),
          if (r.mvcUnreliable) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline,
                    size: 15, color: RehabColors.warn),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    'The maximum contraction is marked unreliable, so every '
                    'effort percentage this session is a guess. Worth '
                    'repeating that step if the patient can manage it.',
                    style: RehabText.body
                        .copyWith(fontSize: 12.5, color: RehabColors.warn),
                  ),
                ),
              ],
            ),
          ],
          if (r.clinicianOverride) ...[
            const SizedBox(height: 10),
            Text(
              'A clinician-supplied normalisation value is in use instead of a '
              'measured one.',
              style: RehabText.body.copyWith(fontSize: 12.5),
            ),
          ],
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 150,
              child: Text(k, style: RehabText.body.copyWith(fontSize: 12.5)),
            ),
            Expanded(
              child: Text(v,
                  style: RehabText.body
                      .copyWith(fontSize: 12.5, color: RehabColors.ink)),
            ),
          ],
        ),
      );
}
