/// The Developer tab: the bench tools, in one place away from the patient.
///
/// Everything here exists because somebody has to debug the sleeve, and none
/// of it belongs in front of a patient mid-exercise. Keeping it on its own tab
/// is what lets the patient and therapist screens stay about the exercise.
///
/// What it holds, and why each one:
///
/// - **The sleeve's own command line.** The sleeve has a richer vocabulary than
///   the frozen opcode table and always will. A text box that sends any of it
///   means a new firmware command needs no app change at all.
/// - **The haptic vocabulary, by the sleeve's numbering.** Twelve patterns,
///   including the guided-pace beats the frozen pattern ids do not cover, plus
///   a blind test — the only honest way to find out whether a vibration
///   vocabulary is actually distinguishable.
/// - **The EMG signal test.** Three seconds relaxed, three squeezing, then a
///   verdict with an SNR figure. The first thing to run when scores look wrong,
///   and the fastest way to tell a bad electrode from a bad threshold.
/// - **Every line the sleeve printed.** The audit trail. When a number on a
///   chart looks wrong this is what says why.
/// - **The adaptive target controls.** Calibration can quietly replace a
///   therapist's target with one of the patient's own; this is where that is
///   seen and locked.
/// - **Link diagnostics**, the clinician bridge and the Wi-Fi fetch.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/clinician_server.dart';
import '../protocol/config_tlv.dart';
import '../protocol/sleeve_messages.dart';
import '../session/session_state.dart';
import '../session/session_store.dart';
import '../xfer/session_fetch.dart';
import 'charts/chart_kit.dart';
import 'theme.dart';

/// The sleeve's haptic vocabulary, as `haptic.cpp` defines it.
///
/// Numbered the sleeve's way, because that is what `h1`..`h12` sends and what
/// the Serial Monitor prints back. The rhythm text is the actual step list, so
/// a bench tester can check what they felt against what was asked for rather
/// than against a description of the intent.
const List<(int, String, String)> sleeveHaptics = [
  (1, 'Rep counted', 'one 100 ms click'),
  (2, 'Rep counted, form flagged', 'three 80 ms pulses, 80 ms gaps'),
  (3, 'Set complete', 'two 70 ms, a 150 ms gap, then 500 ms'),
  (4, 'Rest now', 'a 500 ms ramp up and 500 ms down'),
  (5, 'Fault', 'two 300 ms pulses, 300 ms apart'),
  (6, 'Tick', '40 ms — acknowledgement'),
  (7, 'Set complete (long)', 'one 1000 ms buzz'),
  (8, 'Countdown start', 'one 200 ms pulse'),
  (9, 'Ready, 10 s left', 'two 200 ms pulses, 150 ms apart'),
  (10, 'Rep start', 'one 700 ms buzz'),
  (11, 'Pace: hold', '980 ms at reduced level — reads as continuous'),
  (12, 'Pace: lower', '40 ms, 70 ms gap, 40 ms'),
];

class DeveloperScreen extends StatefulWidget {
  const DeveloperScreen({
    super.key,
    required this.state,
    required this.store,
  });

  final SessionState state;
  final SessionStore store;

  @override
  State<DeveloperScreen> createState() => _DeveloperScreenState();
}

class _DeveloperScreenState extends State<DeveloperScreen> {
  late final ClinicianServer _server = ClinicianServer(widget.state);
  late final SessionFetcher _fetcher = SessionFetcher(widget.state.device);
  StreamSubscription<void>? _serverSub;

  final TextEditingController _command = TextEditingController();
  String? _message;
  int? _blindPattern;

  /// Which kinds of printed line the log shows. All of them by default: the
  /// point of a log is that nothing is hidden until you ask.
  final Set<SleeveMessageKind> _hidden = {};
  bool _onlyConcerning = false;

  @override
  void initState() {
    super.initState();
    _serverSub = _server.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _serverSub?.cancel();
    _server.dispose();
    _fetcher.dispose();
    _command.dispose();
    super.dispose();
  }

  Future<void> _send(String cmd, {String? note}) async {
    final ok = await widget.state.device.sendText(cmd);
    if (!mounted) return;
    setState(() => _message =
        ok ? (note ?? 'Sent "$cmd".') : 'Could not send "$cmd".');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final live = widget.state.linkState.isLive;

        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 28),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Developer',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                          color: RehabColors.ink,
                        )),
                    Text(
                      'Bench tools. Everything here talks to the sleeve '
                      'directly; none of it is meant to be in front of a '
                      'patient.',
                      style: RehabText.body.copyWith(fontSize: 12.5),
                    ),
                    if (_message != null) ...[
                      const SizedBox(height: 8),
                      Text(_message!,
                          style: RehabText.body.copyWith(
                              fontSize: 12.5, color: RehabColors.good)),
                    ],
                  ],
                ),
              ),
              _CommandCard(
                controller: _command,
                enabled: live,
                onSend: (c) => _send(c),
                onQuick: _send,
              ),
              _EmgTestCard(state: widget.state, enabled: live, onRun: _send),
              _HapticCard(
                enabled: live,
                blind: _blindPattern,
                onPlay: (n) => _send('h$n',
                    note: 'Playing h$n: ${sleeveHaptics[n - 1].$2}.'),
                onBlind: () async {
                  await _send('hx',
                      note: 'Played a random pattern. Guess, then reveal.');
                  setState(() => _blindPattern = -1);
                },
                onReveal: () async {
                  await _send('h?',
                      note: 'Asked the sleeve which it was — watch the log.');
                  setState(() => _blindPattern = null);
                },
                onStop: () => _send('h0', note: 'Haptics stopped.'),
                onAll: () async {
                  for (final (n, name, _) in sleeveHaptics) {
                    if (!mounted) return;
                    setState(() => _message = 'h$n: $name');
                    await widget.state.device.sendText('h$n');
                    await Future<void>.delayed(
                        const Duration(milliseconds: 1600));
                  }
                  if (mounted) {
                    setState(() => _message = 'Played all twelve patterns.');
                  }
                },
              ),
              _TargetCard(
                state: widget.state,
                enabled: live,
                onSend: _send,
              ),
              _SessionControlCard(
                state: widget.state,
                enabled: live,
                onSend: _send,
                onExport: _exportCsv,
              ),
              _MessageLogCard(
                state: widget.state,
                hidden: _hidden,
                onlyConcerning: _onlyConcerning,
                onToggleKind: (k) => setState(() {
                  if (!_hidden.remove(k)) _hidden.add(k);
                }),
                onToggleConcerning: (v) =>
                    setState(() => _onlyConcerning = v),
                onCopy: _copyLog,
              ),
              _EventLogCard(state: widget.state),
              _LinkCard(state: widget.state),
              _BridgeCard(server: _server, onToggle: _toggleServer),
              _FetchCard(state: widget.state, fetcher: _fetcher),
            ],
          ),
        );
      },
    );
  }

  Future<void> _toggleServer() async {
    if (_server.running) {
      await _server.stop();
    } else {
      final ok = await _server.start();
      if (!ok && mounted) {
        setState(() =>
            _message = 'Could not start the server. Is the phone on Wi-Fi?');
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _copyLog() async {
    final text = widget.state.messages.map((m) => m.raw).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _message =
        'Copied ${widget.state.messages.length} printed lines. This is the '
        'same text the Serial Monitor shows, so it loads in the HTML viewer.');
  }

  Future<void> _exportCsv() async {
    if (widget.state.repRows.isEmpty) {
      setState(() => _message = 'No reps to export yet.');
      return;
    }
    final record = widget.state
        .buildRecord(patientId: widget.store.currentPatientId);
    await Clipboard.setData(ClipboardData(text: record.toCsv()));
    if (!mounted) return;
    setState(() => _message =
        'Rep log copied as CSV — ${widget.state.repRows.length} rows.');
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => ChartCard(
        title: title,
        subtitle: subtitle,
        trailing: trailing,
        child: child,
      );
}

class _CommandCard extends StatelessWidget {
  const _CommandCard({
    required this.controller,
    required this.enabled,
    required this.onSend,
    required this.onQuick,
  });

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onSend;
  final Future<void> Function(String, {String? note}) onQuick;

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'Send a command',
      subtitle: 'Runs on the sleeve exactly as if typed into its Serial '
          'Monitor. The sleeve\'s line buffer holds 23 characters and drops '
          'the rest silently, so anything longer is refused here rather than '
          'arriving as a different command.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  enabled: enabled,
                  maxLength: 23,
                  style: const TextStyle(fontFamily: 'monospace'),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                    counterText: '',
                    hintText: 'e.g. i, t?, t110, l, e, h1',
                  ),
                  onSubmitted: enabled ? onSend : null,
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: enabled ? () => onSend(controller.text) : null,
                child: const Text('Send'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('QUICK', style: RehabText.label),
          const SizedBox(height: 7),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (cmd, label) in const [
                ('i', 'Status + params'),
                ('?', 'Help'),
                ('l', 'Detailed logging'),
                ('p', 'Plotter output'),
                ('z', 'Re-zero straight arm'),
                ('b', 'Guided pace on/off'),
                ('c', 'Calibrate'),
                ('n', 'Next calib step'),
                ('g', 'Start reps'),
                ('r', 'New session'),
              ])
                OutlinedButton(
                  onPressed: enabled ? () => onQuick(cmd) : null,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  child: Text('$label  ·  $cmd',
                      style: const TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmgTestCard extends StatelessWidget {
  const _EmgTestCard({
    required this.state,
    required this.enabled,
    required this.onRun,
  });

  final SessionState state;
  final bool enabled;
  final Future<void> Function(String, {String? note}) onRun;

  @override
  Widget build(BuildContext context) {
    final lines = state.emgTestLines;

    return _Card(
      title: 'EMG signal test',
      subtitle: 'Three seconds relaxed, three squeezing, then a verdict. Run '
          'this first whenever effort percentages or scores look wrong — it '
          'separates a bad electrode from a bad threshold in ten seconds.',
      trailing: state.emgTestRunning
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FilledButton.icon(
                onPressed: enabled && !state.emgTestRunning
                    ? () => onRun('e',
                        note: 'Running the EMG test — sit still, laptop on '
                            'battery.')
                    : null,
                icon: const Icon(Icons.graphic_eq, size: 17),
                label: const Text('Run the test'),
              ),
            ],
          ),
          if (lines.isNotEmpty) ...[
            const SizedBox(height: 12),
            _Summary(lines: lines),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: RehabColors.bg,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: RehabColors.divider),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final m in lines)
                    Text(m.display,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10.5,
                          height: 1.5,
                          color: RehabColors.inkSoft,
                        )),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.lines});

  final List<SleeveMessage> lines;

  @override
  Widget build(BuildContext context) {
    double? find(String part, String field) {
      for (final m in lines) {
        if (m.str('part') == part) return m.num_(field);
      }
      return null;
    }

    String? verdict;
    String? detail;
    for (final m in lines) {
      if (m.str('part') == 'verdict') {
        verdict = m.str('verdict');
        detail = m.str('detail');
        break;
      }
    }

    final snr = find('snr', 'snrDb');
    final grade = switch (verdict) {
      'PASS' => TileGrade.good,
      'WEAK' => TileGrade.warn,
      'FAIL' => TileGrade.bad,
      _ => TileGrade.neutral,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            StatTile(
              label: 'SNR',
              value: snr == null ? '–' : snr.toStringAsFixed(1),
              unit: snr == null ? null : 'dB',
              detail: '20 dB or more is clean',
              grade: grade,
            ),
            StatTile(
              label: 'Rest',
              value: find('rest', 'meanMv')?.toStringAsFixed(0) ?? '–',
              unit: 'mV',
              detail: 'noise '
                  '${find('rest', 'noiseSdMv')?.toStringAsFixed(1) ?? '–'} mV',
            ),
            StatTile(
              label: 'Squeeze rise',
              value: find('squeeze', 'riseMv')?.toStringAsFixed(0) ?? '–',
              unit: 'mV',
              detail: 'peak '
                  '${find('squeeze', 'peakMv')?.toStringAsFixed(0) ?? '–'} mV',
            ),
          ],
        ),
        if (verdict != null) ...[
          const SizedBox(height: 10),
          Text('$verdict — ${detail ?? ''}',
              style: RehabText.body
                  .copyWith(fontSize: 12.5, color: grade.color)),
        ],
      ],
    );
  }
}

class _HapticCard extends StatelessWidget {
  const _HapticCard({
    required this.enabled,
    required this.blind,
    required this.onPlay,
    required this.onBlind,
    required this.onReveal,
    required this.onStop,
    required this.onAll,
  });

  final bool enabled;
  final int? blind;
  final ValueChanged<int> onPlay;
  final VoidCallback onBlind;
  final VoidCallback onReveal;
  final VoidCallback onStop;
  final VoidCallback onAll;

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'Haptic patterns',
      subtitle: 'The sleeve\'s twelve patterns, by its own numbering — which '
          'reaches the guided-pace beats and countdown cues that the frozen '
          'team pattern ids do not cover. One motor, so every cue is told '
          'apart by rhythm, never by strength: an ERM\'s frequency is coupled '
          'to its amplitude, so "stronger" also means "faster" and cannot '
          'carry a second meaning.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (n, name, rhythm) in sleeveHaptics)
            InkWell(
              onTap: enabled ? () => onPlay(n) : null,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: const BoxDecoration(
                  border: Border(
                      bottom:
                          BorderSide(color: RehabColors.divider, width: 0.5)),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 34,
                      child: Text('h$n',
                          style: RehabText.numeric.copyWith(
                              fontSize: 12.5, color: RehabColors.inkFaint)),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name,
                              style: RehabText.body.copyWith(
                                  fontSize: 13, color: RehabColors.ink)),
                          Text(rhythm,
                              style: RehabText.body.copyWith(fontSize: 11.5)),
                        ],
                      ),
                    ),
                    Icon(Icons.play_circle_outline,
                        size: 19,
                        color: enabled
                            ? RehabColors.actual
                            : RehabColors.inkFaint),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: enabled ? onAll : null,
                icon: const Icon(Icons.playlist_play, size: 17),
                label: const Text('Play all'),
              ),
              OutlinedButton.icon(
                onPressed: enabled ? onBlind : null,
                icon: const Icon(Icons.help_outline, size: 17),
                label: const Text('Blind test'),
              ),
              OutlinedButton(
                onPressed: enabled && blind != null ? onReveal : null,
                child: const Text('Reveal'),
              ),
              OutlinedButton(
                onPressed: enabled ? onStop : null,
                child: const Text('Stop'),
              ),
            ],
          ),
          if (blind != null) ...[
            const SizedBox(height: 10),
            Text(
              'A random pattern is playing. Say which one you think it was, '
              'then reveal — the answer comes back on the printed log.',
              style:
                  RehabText.body.copyWith(fontSize: 12.5, color: RehabColors.warn),
            ),
          ],
        ],
      ),
    );
  }
}

class _TargetCard extends StatefulWidget {
  const _TargetCard({
    required this.state,
    required this.enabled,
    required this.onSend,
  });

  final SessionState state;
  final bool enabled;
  final Future<void> Function(String, {String? note}) onSend;

  @override
  State<_TargetCard> createState() => _TargetCardState();
}

class _TargetCardState extends State<_TargetCard> {
  double _target = 90;
  bool _seeded = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    if (!_seeded && s.sleeveParams != null) {
      _target = s.effectiveTargetDeg.clamp(40, 140);
      _seeded = true;
    }

    final written = s.config.targetAngleDeg;
    final inForce = s.effectiveTargetDeg;
    final differs = (written - inForce).abs() > 1;

    return _Card(
      title: 'Adaptive target',
      subtitle: 'The sleeve picks its own target at calibration — capped at '
          'today\'s comfortable bend plus 15° — and adjusts it between '
          'sessions. Locking it makes the therapist\'s number stick.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: 'In force on the sleeve',
                  value: inForce.toStringAsFixed(0),
                  unit: '°',
                  detail: 'a rep counts above '
                      '${s.effectivePeakDeg.toStringAsFixed(0)}°',
                  grade: differs ? TileGrade.warn : TileGrade.neutral,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatTile(
                  label: 'Configured by the app',
                  value: written.toStringAsFixed(0),
                  unit: '°',
                  detail: differs ? 'not what the sleeve is using' : 'matches',
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Text('${_target.round()}°',
                  style: RehabText.numeric.copyWith(fontSize: 16)),
              Expanded(
                child: Slider(
                  value: _target,
                  min: 40,
                  max: 140,
                  divisions: 20,
                  label: '${_target.round()}°',
                  onChanged:
                      widget.enabled ? (v) => setState(() => _target = v) : null,
                ),
              ),
            ],
          ),
          Text(
            'The sleeve rejects anything outside 40–140°.',
            style: RehabText.body.copyWith(fontSize: 11.5),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: widget.enabled
                    ? () => widget.onSend('t${_target.round()}',
                        note: 'Target set to ${_target.round()}° and locked.')
                    : null,
                child: Text('Set and lock ${_target.round()}°'),
              ),
              OutlinedButton(
                onPressed: widget.enabled
                    ? () => widget.onSend('tl',
                        note: 'Toggled the target lock — see the log.')
                    : null,
                child: const Text('Toggle lock'),
              ),
              OutlinedButton(
                onPressed: widget.enabled
                    ? () => widget.onSend('t?')
                    : null,
                child: const Text('Show saved'),
              ),
              OutlinedButton(
                onPressed: widget.enabled ? _confirmClear : null,
                style: OutlinedButton.styleFrom(
                    foregroundColor: RehabColors.bad),
                child: const Text('Clear saved progress'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: RehabColors.surfaceHigh,
        title: const Text('Clear the sleeve\'s saved progress?'),
        content: Text(
          'This erases the adaptive target and the session count stored in the '
          'sleeve\'s flash. The next calibration starts from the patient\'s '
          'comfortable bend as though it were their first session. It does not '
          'touch the sessions saved on this phone.',
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
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.onSend('tr', note: 'Saved progress cleared on the sleeve.');
    }
  }
}

class _SessionControlCard extends StatelessWidget {
  const _SessionControlCard({
    required this.state,
    required this.enabled,
    required this.onSend,
    required this.onExport,
  });

  final SessionState state;
  final bool enabled;
  final Future<void> Function(String, {String? note}) onSend;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'Session and stream',
      subtitle: 'The raw stream is off by default, and that is deliberate: on '
          'the shipping sleeve NimBLE has about a dozen notification buffers, '
          'and ~17 unread IMU frames a second is what used to exhaust them and '
          'silently discard printed lines and rep events.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: enabled
                    ? () => onSend('r', note: 'Started a new session.')
                    : null,
                icon: const Icon(Icons.restart_alt, size: 17),
                label: const Text('New session'),
              ),
              OutlinedButton.icon(
                onPressed: enabled
                    ? () => onSend('b', note: 'Toggled the guided pace.')
                    : null,
                icon: const Icon(Icons.graphic_eq, size: 17),
                label: Text(state.paceOn ? 'Pace: on' : 'Pace: off'),
              ),
              OutlinedButton.icon(
                onPressed: onExport,
                icon: const Icon(Icons.table_view_outlined, size: 17),
                label: const Text('Copy rep CSV'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: state.config.rawStreamEnable,
            title: Text('Raw IMU stream',
                style: RehabText.body.copyWith(color: RehabColors.ink)),
            subtitle: Text(
              'Only needed for signal debugging. The app does not subscribe to '
              'it unless asked, so turning it on here affects the sleeve\'s '
              'own transmit decision.',
              style: RehabText.body.copyWith(fontSize: 11.5),
            ),
            onChanged: enabled
                ? (v) => state.setParameters(
                    [cfgU8(CfgTag.rawStream, v ? 1 : 0)])
                : null,
          ),
        ],
      ),
    );
  }
}

/// Every printed line, newest last, filterable by kind.
class _MessageLogCard extends StatelessWidget {
  const _MessageLogCard({
    required this.state,
    required this.hidden,
    required this.onlyConcerning,
    required this.onToggleKind,
    required this.onToggleConcerning,
    required this.onCopy,
  });

  final SessionState state;
  final Set<SleeveMessageKind> hidden;
  final bool onlyConcerning;
  final ValueChanged<SleeveMessageKind> onToggleKind;
  final ValueChanged<bool> onToggleConcerning;
  final VoidCallback onCopy;

  /// The kinds worth offering as filters. The rest are rare enough that a
  /// filter chip for each would be more work to read than the log.
  static const List<SleeveMessageKind> filterable = [
    SleeveMessageKind.rep,
    SleeveMessageKind.partial,
    SleeveMessageKind.formFault,
    SleeveMessageKind.fatigueTrend,
    SleeveMessageKind.calibration,
    SleeveMessageKind.paceePhase,
    SleeveMessageKind.sessionFlow,
    SleeveMessageKind.other,
  ];

  static String labelOf(SleeveMessageKind k) => switch (k) {
        SleeveMessageKind.rep => 'Reps',
        SleeveMessageKind.partial => 'Partials',
        SleeveMessageKind.formFault => 'Form faults',
        SleeveMessageKind.fatigueTrend => 'Fatigue',
        SleeveMessageKind.calibration => 'Calibration',
        SleeveMessageKind.paceePhase => 'Pace',
        SleeveMessageKind.sessionFlow => 'Session flow',
        SleeveMessageKind.other => 'Everything else',
        SleeveMessageKind.live => 'Status',
        SleeveMessageKind.params => 'Params',
        SleeveMessageKind.setProgress => 'Set progress',
        SleeveMessageKind.paceVerdict => 'Pace verdict',
        SleeveMessageKind.pause => 'Pause',
        SleeveMessageKind.target => 'Target',
        SleeveMessageKind.emgTest => 'EMG test',
      };

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'Everything the sleeve printed',
      subtitle: 'The same text its Serial Monitor shows, so a copy of this '
          'loads straight into the HTML session viewer. This is the audit '
          'trail: when a number on a chart looks wrong, the reason is here.',
      trailing: IconButton(
        tooltip: 'Copy the whole log',
        icon: const Icon(Icons.copy_all_outlined, size: 19),
        onPressed: onCopy,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              FilterChip(
                label: const Text('Only what matters'),
                selected: onlyConcerning,
                onSelected: onToggleConcerning,
                backgroundColor: RehabColors.surfaceHigh,
                selectedColor: RehabColors.warn.withValues(alpha: 0.22),
                labelStyle: RehabText.label.copyWith(
                    color: onlyConcerning
                        ? RehabColors.warn
                        : RehabColors.inkSoft),
              ),
              for (final k in filterable)
                FilterChip(
                  label: Text(labelOf(k)),
                  selected: !hidden.contains(k),
                  onSelected: (_) => onToggleKind(k),
                  backgroundColor: RehabColors.surfaceHigh,
                  selectedColor: RehabColors.actual.withValues(alpha: 0.18),
                  labelStyle: RehabText.label.copyWith(
                      color: hidden.contains(k)
                          ? RehabColors.inkFaint
                          : RehabColors.inkSoft),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // Watches the revision counter, not the state, so a burst of lines
          // repaints this box and nothing else on the screen.
          ValueListenableBuilder<int>(
            valueListenable: state.messageRevision,
            builder: (context, _, __) {
              final shown = [
                for (final m in state.messages)
                  if (!hidden.contains(m.kind) &&
                      (!onlyConcerning || m.isConcerning))
                    m,
              ];
              if (shown.isEmpty) {
                return const ChartEmpty(
                  message: 'Nothing yet. The sleeve sends these only once the '
                      'app has subscribed, which happens on connect.',
                  icon: Icons.terminal,
                );
              }
              return Container(
                height: 260,
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: RehabColors.bg,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: RehabColors.divider),
                ),
                child: ListView.builder(
                  reverse: true,
                  itemCount: shown.length,
                  itemBuilder: (context, i) {
                    final m = shown[shown.length - 1 - i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        m.display,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10.5,
                          height: 1.45,
                          color: m.isConcerning
                              ? RehabColors.warn
                              : RehabColors.inkSoft,
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _EventLogCard extends StatelessWidget {
  const _EventLogCard({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    final log = state.log.reversed.take(60).toList();
    return _Card(
      title: 'Binary events',
      subtitle: 'The frames the sleeve sent on the events characteristic, '
          'newest first. Distinct from the printed lines above: these are what '
          'the app actually counts reps and scores from.',
      child: log.isEmpty
          ? const ChartEmpty(
              message: 'No events yet.', icon: Icons.bolt_outlined)
          : Column(
              children: [
                for (final e in log)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    decoration: const BoxDecoration(
                      border: Border(
                          bottom: BorderSide(
                              color: RehabColors.divider, width: 0.5)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 54,
                          child: Text(
                            '${e.wallClock.hour.toString().padLeft(2, '0')}:'
                            '${e.wallClock.minute.toString().padLeft(2, '0')}:'
                            '${e.wallClock.second.toString().padLeft(2, '0')}',
                            style: RehabText.body.copyWith(
                                fontSize: 11, color: RehabColors.inkFaint),
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(e.label,
                                  style: RehabText.body.copyWith(
                                    fontSize: 12.5,
                                    color: e.isConcerning
                                        ? RehabColors.warn
                                        : RehabColors.ink,
                                  )),
                              if (e.detail != null)
                                Text(e.detail!,
                                    style:
                                        RehabText.body.copyWith(fontSize: 11.5)),
                            ],
                          ),
                        ),
                        Text('0x${e.event.toRadixString(16).padLeft(2, '0')}',
                            style: RehabText.body.copyWith(
                                fontSize: 10.5,
                                fontFamily: 'monospace',
                                color: RehabColors.inkFaint)),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _LinkCard extends StatelessWidget {
  const _LinkCard({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    final d = state.device;
    return _Card(
      title: 'Link',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv('State', state.linkState.label),
          _kv('Device', d.deviceName.isEmpty ? '–' : d.deviceName),
          _kv('Address', d.deviceId.isEmpty ? '–' : d.deviceId),
          _kv(
            'MTU',
            d.negotiatedMtu == 0
                ? 'not ours to ask (iOS and macOS negotiate it themselves)'
                : '${d.negotiatedMtu} bytes',
          ),
          _kv('Raw stream subscribed', d.wantRawSamples ? 'yes' : 'no'),
          if (state.problems.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('COMPLAINTS', style: RehabText.label),
            const SizedBox(height: 5),
            for (final p in state.problems.reversed.take(8))
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text('· $p',
                    style: RehabText.body
                        .copyWith(fontSize: 11.5, color: RehabColors.warn)),
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
                child: Text(k, style: RehabText.body.copyWith(fontSize: 12.5))),
            Expanded(
              child: Text(v,
                  style: RehabText.body
                      .copyWith(fontSize: 12.5, color: RehabColors.ink)),
            ),
          ],
        ),
      );
}

class _BridgeCard extends StatelessWidget {
  const _BridgeCard({required this.server, required this.onToggle});

  final ClinicianServer server;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'Clinician bridge',
      subtitle: 'Serves a live page from the phone over the local network, so '
          'a clinician can watch on a laptop without installing anything. The '
          'phone stays the only thing connected to the sleeve.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FilledButton.icon(
                onPressed: onToggle,
                style: FilledButton.styleFrom(
                  backgroundColor:
                      server.running ? RehabColors.bad : RehabColors.actual,
                  foregroundColor: RehabColors.bg,
                ),
                icon: Icon(server.running ? Icons.stop : Icons.wifi_tethering,
                    size: 17),
                label: Text(server.running ? 'Stop serving' : 'Start serving'),
              ),
            ],
          ),
          if (server.running && server.url != null) ...[
            const SizedBox(height: 12),
            Text('OPEN ON THE LAPTOP', style: RehabText.label),
            const SizedBox(height: 4),
            SelectableText(server.url!,
                style: RehabText.numeric.copyWith(fontSize: 15)),
            const SizedBox(height: 6),
            Text('${server.clientCount} viewer'
                '${server.clientCount == 1 ? '' : 's'} connected',
                style: RehabText.body.copyWith(fontSize: 12)),
          ],
        ],
      ),
    );
  }
}

class _FetchCard extends StatelessWidget {
  const _FetchCard({required this.state, required this.fetcher});

  final SessionState state;
  final SessionFetcher fetcher;

  @override
  Widget build(BuildContext context) {
    // Worth saying plainly rather than letting someone discover it by waiting:
    // the shipping sleeve has no Wi-Fi transfer at all and answers every
    // START_TRANSFER with FAILED. This whole path is for the ESP-IDF firmware.
    return _Card(
      title: 'Wi-Fi session fetch',
      subtitle: 'Pulls the full recorded session off the sleeve after a set. '
          'The shipping Arduino firmware does not implement this — it buffers '
          'nothing and answers every request with FAILED — so this is here for '
          'the ESP-IDF firmware, which does.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: RehabColors.surfaceHigh,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline,
                    size: 15, color: RehabColors.inkFaint),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    state.transfer == null
                        ? 'The sleeve has not reported a transfer state yet.'
                        : 'Sleeve reports: ${state.transfer!.stateLabel}.',
                    style: RehabText.body.copyWith(fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: state.linkState.isLive
                ? () => state.device.startTransfer()
                : null,
            icon: const Icon(Icons.cloud_download_outlined, size: 17),
            label: const Text('Ask the sleeve to start a transfer'),
          ),
          if (fetcher.message != null) ...[
            const SizedBox(height: 10),
            Text(fetcher.message!,
                style: RehabText.body.copyWith(fontSize: 12.5)),
          ],
        ],
      ),
    );
  }
}
