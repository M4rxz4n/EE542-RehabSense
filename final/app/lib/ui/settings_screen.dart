/// Runtime parameters, PRD §5.9.1 — and the haptic bench test.
///
/// Every parameter here may be changed during a session and takes effect from
/// the next repetition. That is demo item 6, so the thing this screen has to
/// get right is **showing that the change landed**.
///
/// The firmware rejects a recognised tag carrying the wrong length and says
/// nothing on the wire about it. So each control writes only its own tag,
/// then issues GET_CONFIG, and the value shown is always the value that came
/// back from the device — never the position of the slider. If a write is
/// rejected the control visibly springs back, which is the behaviour you
/// want in front of an audience.
library;

import 'package:flutter/material.dart';

import '../protocol/config_tlv.dart';
import '../protocol/enums.dart';
import '../session/session_state.dart';
import 'theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final cfg = state.config;

        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              const Text('Exercise parameters', style: RehabText.big),
              const SizedBox(height: 4),
              Text(
                'Changes take effect from the next repetition. Each value '
                'shown is read back from the sleeve.',
                style: RehabText.body,
              ),
              const SizedBox(height: 22),

              _Section('Repetition'),

              // The PRD calls this the primary tuning control during
              // volunteer testing, so it goes first.
              _SliderRow(
                label: 'Confirming hold',
                value: cfg.holdMs.toDouble(),
                min: CfgDefaults.holdMsMin.toDouble(),
                max: CfgDefaults.holdMsMax.toDouble(),
                divisions: 27,
                format: (v) => '${v.round()} ms',
                note: 'How long the arm must stay at extension for the rep to '
                    'count. The primary tuning control.',
                onCommit: (v) => state.setParameters(
                    [cfgU16(CfgTag.holdMs, v.round())]),
              ),

              _SliderRow(
                label: 'Target angle',
                value: cfg.targetAngleDeg,
                min: 40,
                max: 150,
                divisions: 22,
                format: (v) => '${v.round()}°',
                note: 'Therapist-set. A rep must pass 80% of this — '
                    '${cfg.peakAngleDeg.toStringAsFixed(0)}° — to count.',
                onCommit: (v) => state.setParameters(
                    [cfgF32(CfgTag.targetAngle, [v])]),
              ),

              _SliderRow(
                label: 'Start angle',
                value: cfg.startAngleDeg,
                min: 0,
                max: 60,
                divisions: 12,
                format: (v) => '${v.round()}°',
                note: 'Raise this, and the finish angle with it, for a '
                    'patient who cannot fully extend.',
                onCommit: (v) => state.setParameters(
                    [cfgF32(CfgTag.startAngle, [v])]),
              ),

              _SliderRow(
                label: 'Finish angle',
                value: cfg.finishAngleDeg,
                min: 0,
                max: 55,
                divisions: 11,
                format: (v) => '${v.round()}°',
                note: 'Sits below the start angle; the gap is the hysteresis '
                    'that stops one slow rep counting twice.',
                onCommit: (v) => state.setParameters(
                    [cfgF32(CfgTag.finishAngle, [v])]),
              ),

              const SizedBox(height: 10),
              _Section('Set structure'),

              _SliderRow(
                label: 'Reps per set',
                value: cfg.repTarget.toDouble(),
                min: CfgDefaults.repTargetMin.toDouble(),
                max: CfgDefaults.repTargetMax.toDouble(),
                divisions: 49,
                format: (v) => '${v.round()}',
                note: 'Determines when the set-complete pattern fires.',
                onCommit: (v) => state.setParameters(
                    [cfgU8(CfgTag.repTarget, v.round())]),
              ),

              _SliderRow(
                label: 'Sets',
                value: cfg.setCount.toDouble(),
                min: 1,
                max: 10,
                divisions: 9,
                format: (v) => '${v.round()}',
                onCommit: (v) => state.setParameters(
                    [cfgU8(CfgTag.setCount, v.round())]),
              ),

              _SliderRow(
                label: 'Rest between sets',
                value: cfg.restSeconds.toDouble(),
                min: 0,
                max: 180,
                divisions: 18,
                format: (v) => '${v.round()} s',
                onCommit: (v) => state.setParameters(
                    [cfgU16(CfgTag.restSeconds, v.round())]),
              ),

              const SizedBox(height: 10),
              _Section('Pace'),

              _RangeRow(
                label: 'Prescribed tempo',
                lo: cfg.tempoMinS,
                hi: cfg.tempoMaxS,
                min: 0.5,
                max: 8.0,
                note: 'Seconds from the start threshold to the finish '
                    'threshold. Outside this window the rep is marked for '
                    'pace.',
                onCommit: (lo, hi) => state.setParameters(
                    [cfgF32(CfgTag.tempo, [lo, hi])]),
              ),

              const SizedBox(height: 10),
              _Section('Compensation sensitivity'),

              _SliderRow(
                label: 'Shoulder hike',
                value: cfg.compShoulderDeg,
                min: 5,
                max: 45,
                divisions: 40,
                format: (v) => '${v.round()}°',
                note: 'Upper-arm deviation from the calibrated neutral.',
                onCommit: (v) => state.setParameters([
                  cfgF32(CfgTag.compThresh,
                      [v, cfg.compTrunkDeg, cfg.compSwingDps])
                ]),
              ),

              _SliderRow(
                label: 'Trunk lean',
                value: cfg.compTrunkDeg,
                min: 3,
                max: 30,
                divisions: 27,
                format: (v) => '${v.round()}°',
                note: 'Detected as a common-mode rotation of both IMUs.',
                onCommit: (v) => state.setParameters([
                  cfgF32(CfgTag.compThresh,
                      [cfg.compShoulderDeg, v, cfg.compSwingDps])
                ]),
              ),

              _SliderRow(
                label: 'Momentum',
                value: cfg.compSwingDps,
                min: 10,
                max: 90,
                divisions: 16,
                format: (v) => '${v.round()}°/s',
                note: 'Angular rate that counts as swinging rather than '
                    'lifting.',
                onCommit: (v) => state.setParameters([
                  cfgF32(CfgTag.compThresh,
                      [cfg.compShoulderDeg, cfg.compTrunkDeg, v])
                ]),
              ),

              const SizedBox(height: 10),
              _Section('Streaming'),

              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: cfg.rawStreamEnable,
                // No activeColor / activeThumbColor here on purpose. That
                // parameter was renamed mid-2025 and the old name is
                // deprecated, so naming either one pins the project to a
                // Flutter version. The Material 3 switch already picks up
                // colorScheme.primary, which the theme sets to the same
                // colour.
                title: const Text('Full-rate raw stream',
                    style: RehabText.numeric),
                subtitle: Text(
                  'About 10.4 kB/s of EMG and IMU samples. Near the practical '
                  'ceiling of a phone BLE link, and the live view does not '
                  'need it — the sleeve has already done the analysis. Turn '
                  'it on for debugging, not for a session.',
                  style: RehabText.body.copyWith(fontSize: 13),
                ),
                onChanged: (v) => state.device.setRawStream(v),
              ),

              if (state.device.negotiatedMtu > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: Text(
                    'Negotiated MTU ${state.device.negotiatedMtu} bytes',
                    style: RehabText.label,
                  ),
                ),

              const SizedBox(height: 18),
              _Section('Haptic bench test'),
              Text(
                'Fires a pattern on demand. One motor, seven messages, told '
                'apart by rhythm — an ERM couples frequency to amplitude, so '
                '"stronger" also means "faster" and cannot carry a separate '
                'meaning.',
                style: RehabText.body.copyWith(fontSize: 13),
              ),
              const SizedBox(height: 12),
              for (final p in HapticPattern.values)
                if (p != HapticPattern.none)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 7),
                    child: OutlinedButton(
                      onPressed: () => state.device.testHaptic(p),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(p.label,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                          ),
                          Text(p.rhythm,
                              style: RehabText.label.copyWith(fontSize: 11)),
                        ],
                      ),
                    ),
                  ),

              const SizedBox(height: 26),
              _Section('Link'),
              _InfoRow('Device', state.device.deviceName),
              _InfoRow('Address', state.device.deviceId),
              _InfoRow('Frames received',
                  '${state.device.seq.framesSeen}'),
              _InfoRow('Acknowledged to',
                  '${state.device.seq.highestContiguous}'),
              _InfoRow('Outstanding gaps',
                  '${state.device.seq.gaps.length}'
                  '${state.device.seq.missingSamples > 0 ? " "
                      "(${state.device.seq.missingSamples} samples)" : ""}'),

              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: state.device.requestOutstandingBackfill,
                icon: const Icon(Icons.history),
                label: const Text('Re-request missing data'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: state.device.disconnect,
                icon: const Icon(Icons.bluetooth_disabled),
                label: const Text('Disconnect'),
              ),

              if (state.problems.isNotEmpty) ...[
                const SizedBox(height: 26),
                _Section('Link messages'),
                for (final p in state.problems.reversed.take(12))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(p,
                        style: RehabText.body
                            .copyWith(fontSize: 12.5, color: RehabColors.warn)),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 6),
      child: Text(title.toUpperCase(), style: RehabText.label),
    );
  }
}

/// A slider that commits on release and then shows whatever the device says.
///
/// The local value is only held while dragging. Once released it writes, and
/// from then on the displayed value comes from the config read-back — so a
/// rejected write is visible rather than silently assumed to have worked.
class _SliderRow extends StatefulWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.format,
    required this.onCommit,
    this.divisions,
    this.note,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String Function(double) format;
  final Future<bool> Function(double) onCommit;
  final String? note;

  @override
  State<_SliderRow> createState() => _SliderRowState();
}

class _SliderRowState extends State<_SliderRow> {
  double? _dragging;
  bool _pending = false;

  @override
  Widget build(BuildContext context) {
    final shown = _dragging ?? widget.value;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(widget.label, style: RehabText.numeric)),
              if (_pending)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: RehabColors.actual),
                  ),
                ),
              Text(
                widget.format(shown),
                style: RehabText.numeric.copyWith(
                  color: _dragging != null
                      ? RehabColors.actual
                      : RehabColors.ink,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: RehabColors.actual,
              inactiveTrackColor: RehabColors.surfaceHigh,
              thumbColor: RehabColors.actual,
              overlayColor: RehabColors.actual.withValues(alpha: 0.15),
              trackHeight: 3,
            ),
            child: Slider(
              value: shown.clamp(widget.min, widget.max),
              min: widget.min,
              max: widget.max,
              divisions: widget.divisions,
              onChanged: (v) => setState(() => _dragging = v),
              onChangeEnd: (v) async {
                setState(() => _pending = true);
                await widget.onCommit(v);
                // Drop the local value either way. What the device reports is
                // now the truth, whether or not it accepted the write.
                if (mounted) {
                  setState(() {
                    _dragging = null;
                    _pending = false;
                  });
                }
              },
            ),
          ),
          if (widget.note != null)
            Text(widget.note!,
                style: RehabText.body.copyWith(fontSize: 12.5)),
        ],
      ),
    );
  }
}

class _RangeRow extends StatefulWidget {
  const _RangeRow({
    required this.label,
    required this.lo,
    required this.hi,
    required this.min,
    required this.max,
    required this.onCommit,
    this.note,
  });

  final String label;
  final double lo;
  final double hi;
  final double min;
  final double max;
  final Future<bool> Function(double lo, double hi) onCommit;
  final String? note;

  @override
  State<_RangeRow> createState() => _RangeRowState();
}

class _RangeRowState extends State<_RangeRow> {
  RangeValues? _dragging;

  @override
  Widget build(BuildContext context) {
    final shown = _dragging ?? RangeValues(widget.lo, widget.hi);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(widget.label, style: RehabText.numeric)),
              Text(
                '${shown.start.toStringAsFixed(1)} – '
                '${shown.end.toStringAsFixed(1)} s',
                style: RehabText.numeric.copyWith(
                  color: _dragging != null
                      ? RehabColors.actual
                      : RehabColors.ink,
                ),
              ),
            ],
          ),
          RangeSlider(
            values: RangeValues(
              shown.start.clamp(widget.min, widget.max),
              shown.end.clamp(widget.min, widget.max),
            ),
            min: widget.min,
            max: widget.max,
            divisions: ((widget.max - widget.min) * 4).round(),
            activeColor: RehabColors.actual,
            inactiveColor: RehabColors.surfaceHigh,
            onChanged: (v) => setState(() => _dragging = v),
            onChangeEnd: (v) async {
              await widget.onCommit(v.start, v.end);
              if (mounted) setState(() => _dragging = null);
            },
          ),
          if (widget.note != null)
            Text(widget.note!,
                style: RehabText.body.copyWith(fontSize: 12.5)),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(child: Text(label, style: RehabText.body)),
          Flexible(
            child: Text(value,
                style: RehabText.numeric.copyWith(fontSize: 14),
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}
