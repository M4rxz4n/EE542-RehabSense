/// Controls the clinician bridge, and runs the post-session Wi-Fi fetch.
///
/// Both live here because they are the two halves of the same answer to "how
/// does the clinician get the data": the live view streams from the phone
/// during the set, and the full record comes off the sleeve over Wi-Fi after
/// it. The sleeve cannot do both at once — one radio — which is why the
/// sequence matters and why this screen presents it as a sequence.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/clinician_server.dart';
import '../protocol/enums.dart';
import '../protocol/xfer.dart';
import '../session/session_state.dart';
import '../xfer/session_fetch.dart';
import 'theme.dart';

class ClinicianScreen extends StatefulWidget {
  const ClinicianScreen({super.key, required this.state});

  final SessionState state;

  @override
  State<ClinicianScreen> createState() => _ClinicianScreenState();
}

class _ClinicianScreenState extends State<ClinicianScreen> {
  late final ClinicianServer _server = ClinicianServer(widget.state);
  late final SessionFetcher _fetcher = SessionFetcher(widget.state.device);
  StreamSubscription<void>? _serverSub;

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
    super.dispose();
  }

  Future<void> _toggleServer() async {
    if (_server.running) {
      await _server.stop();
    } else {
      final ok = await _server.start();
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not start the server. Is the phone on Wi-Fi?'),
        ));
      }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              const Text('Clinician view', style: RehabText.big),
              const SizedBox(height: 4),
              Text(
                'The phone serves a live page on this network. Nothing is '
                'uploaded anywhere and no account is needed.',
                style: RehabText.body,
              ),
              const SizedBox(height: 20),

              _LiveCard(
                server: _server,
                onToggle: _toggleServer,
              ),

              const SizedBox(height: 16),
              _FetchCard(state: widget.state, fetcher: _fetcher),

              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: RehabColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('WHY TWO STEPS', style: RehabText.label),
                    const SizedBox(height: 8),
                    Text(
                      'The sleeve has one 2.4 GHz radio. Wi-Fi and a busy BLE '
                      'link together make BLE miss connection events, and the '
                      'live stream is what must not degrade — so the firmware '
                      'refuses a transfer while a set is running, and that is '
                      'not something the app can override.\n\n'
                      'During the set the phone bridges the live feed. After '
                      'it, the sleeve brings up its own access point and the '
                      'full record — about 6.6 MB for ten minutes — comes '
                      'across in seconds instead of the ten minutes it would '
                      'take over BLE.',
                      style: RehabText.body.copyWith(fontSize: 13.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LiveCard extends StatelessWidget {
  const _LiveCard({required this.server, required this.onToggle});

  final ClinicianServer server;
  final VoidCallback onToggle;

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
          Row(
            children: [
              Expanded(
                child: Text('LIVE STREAM', style: RehabText.label),
              ),
              if (server.running)
                Text(
                  server.viewerCount == 1
                      ? '1 viewer'
                      : '${server.viewerCount} viewers',
                  style: RehabText.label.copyWith(
                    color: server.viewerCount > 0
                        ? RehabColors.good
                        : RehabColors.inkFaint,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),

          if (!server.running)
            Text(
              'Start the server, then give the clinician the address it '
              'shows. They need to be on the same Wi-Fi.',
              style: RehabText.body,
            )
          else if (server.addresses.isEmpty)
            Text(
              'Server is running, but this phone has no network address — it '
              'is probably not on Wi-Fi. Cellular alone will not work: the '
              'clinician has to be able to reach this phone.',
              style: RehabText.body.copyWith(color: RehabColors.warn),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Open this on the clinician’s computer:',
                    style: RehabText.body),
                const SizedBox(height: 10),
                // More than one address is normal — Wi-Fi plus a cellular
                // interface at least — and only one will be reachable, so all
                // are offered rather than guessed at.
                for (final url in server.addresses)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      onTap: () {
                        unawaited(
                            Clipboard.setData(ClipboardData(text: url)));
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Copied $url')),
                        );
                      },
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 13, vertical: 11),
                        decoration: BoxDecoration(
                          color: RehabColors.surfaceHigh,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(url,
                                  style: RehabText.numeric
                                      .copyWith(fontSize: 15)),
                            ),
                            const Icon(Icons.copy,
                                size: 16, color: RehabColors.inkFaint),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (server.addresses.length > 1)
                  Text(
                    'Several addresses because this phone has more than one '
                    'network interface. The Wi-Fi one is the one that works.',
                    style: RehabText.body.copyWith(fontSize: 12.5),
                  ),
              ],
            ),

          const SizedBox(height: 14),
          FilledButton(
            onPressed: onToggle,
            style: FilledButton.styleFrom(
              backgroundColor: server.running
                  ? RehabColors.surfaceHigh
                  : RehabColors.actual,
              foregroundColor:
                  server.running ? RehabColors.ink : RehabColors.bg,
            ),
            child: Text(server.running ? 'Stop sharing' : 'Start sharing'),
          ),
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
    final xfer = state.transfer;
    final deviceState = state.status?.state;
    final sessionRunning = state.sessionRequested ||
        deviceState == FwState.operational;

    return ListenableBuilder(
      listenable: fetcher,
      builder: (context, _) {
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: RehabColors.surface,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('FULL SESSION RECORD', style: RehabText.label),
              const SizedBox(height: 12),

              if (sessionRunning)
                Text(
                  'A set is running. The sleeve will refuse a transfer until '
                  'it is stopped — one radio, and the live stream wins.',
                  style: RehabText.body.copyWith(color: RehabColors.warn),
                )
              else
                Text(
                  'Brings up the sleeve’s own Wi-Fi, downloads the '
                  'record, then shuts the radio down again.',
                  style: RehabText.body,
                ),

              if (xfer != null) ...[
                const SizedBox(height: 14),
                _XferStatus(xfer: xfer),
              ],

              if (fetcher.stage != FetchStage.idle) ...[
                const SizedBox(height: 14),
                _FetchProgress(fetcher: fetcher),
              ],

              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: sessionRunning || fetcher.busy
                          ? null
                          : () => fetcher.run(),
                      style: FilledButton.styleFrom(
                        backgroundColor: RehabColors.actual,
                        foregroundColor: RehabColors.bg,
                      ),
                      child: Text(fetcher.busy
                          ? 'Working…'
                          : 'Fetch session'),
                    ),
                  ),
                  if (xfer != null && xfer.ready) ...[
                    const SizedBox(width: 10),
                    OutlinedButton(
                      onPressed: state.device.stopTransfer,
                      child: const Text('Stop AP'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _XferStatus extends StatelessWidget {
  const _XferStatus({required this.xfer});

  final XferInfo xfer;

  @override
  Widget build(BuildContext context) {
    final ready = xfer.ready;
    final failed = xfer.failed;

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: RehabColors.surfaceHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(xfer.stateLabel.toUpperCase(),
                  style: RehabText.label.copyWith(
                    color: ready
                        ? RehabColors.good
                        : (failed ? RehabColors.bad : RehabColors.warn),
                  )),
              const Spacer(),
              if (ready)
                Text('${xfer.secondsRemaining}s left',
                    style: RehabText.label),
            ],
          ),
          if (failed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'The sleeve refused. Either a set is still running, or no '
                'session has been sealed yet.',
                style: RehabText.body.copyWith(fontSize: 13),
              ),
            ),
          if (ready) ...[
            const SizedBox(height: 10),
            Text(
              'Join this Wi-Fi network on the phone, then the download will '
              'start. You will lose internet while joined — the sleeve’s '
              'network has no route anywhere.',
              style: RehabText.body.copyWith(fontSize: 13),
            ),
            const SizedBox(height: 10),
            SelectableText(xfer.ssid,
                style: RehabText.numeric.copyWith(fontSize: 16)),
            SelectableText('password  ${xfer.password}',
                style: RehabText.body),
            const SizedBox(height: 6),
            Text('${xfer.baseUrl}  ·  ${xfer.clients} client(s)  ·  '
                '${xfer.bytesServed ~/ 1024} kB served',
                style: RehabText.label),
          ],
        ],
      ),
    );
  }
}

class _FetchProgress extends StatelessWidget {
  const _FetchProgress({required this.fetcher});

  final SessionFetcher fetcher;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(fetcher.stage.label, style: RehabText.numeric),
        if (fetcher.message != null) ...[
          const SizedBox(height: 4),
          Text(fetcher.message!,
              style: RehabText.body.copyWith(
                fontSize: 13,
                color: fetcher.stage == FetchStage.failed
                    ? RehabColors.bad
                    : RehabColors.inkSoft,
              )),
        ],
        if (fetcher.busy) ...[
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: fetcher.fraction,
            backgroundColor: RehabColors.surfaceHigh,
            color: RehabColors.actual,
          ),
        ],
        if (fetcher.savedTo != null) ...[
          const SizedBox(height: 10),
          Text('Saved to ${fetcher.savedTo}',
              style: RehabText.body.copyWith(fontSize: 12.5)),
        ],
      ],
    );
  }
}
