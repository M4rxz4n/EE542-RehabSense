/// The app shell: four destinations and the connect flow.
///
/// The patient view is first and is where the app opens, because that is the
/// screen someone is actually looking at mid-exercise. Calibration, settings
/// and the clinician bridge are things done between sets.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../ble/permissions.dart';
import '../ble/rehab_device.dart';
import '../session/session_state.dart';
import 'calibration_screen.dart';
import 'clinician_screen.dart';
import 'patient_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.device, required this.state});

  final RehabDevice device;
  final SessionState state;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = 0;
  bool _connecting = false;
  StreamSubscription<String>? _problemSub;

  @override
  void initState() {
    super.initState();
    // Surface link complaints where they can be acted on. These are never
    // fatal — a corrupt frame or a dropped link must not end a session — so
    // they go to a snackbar rather than a dialog.
    _problemSub = widget.device.problems.listen((message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Details',
            onPressed: () => setState(() => _tab = 3),
          ),
        ),
      );
    });
  }

  @override
  void dispose() {
    _problemSub?.cancel();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() => _connecting = true);
    try {
      final readiness = await BlePermissions.ensure();
      if (readiness != BleReadiness.ready) {
        if (!mounted) return;
        await _showPermissionHelp(readiness);
        return;
      }
      await widget.device.connect();
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _showPermissionHelp(BleReadiness r) async {
    final permanent = r == BleReadiness.permissionPermanentlyDenied;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: RehabColors.surfaceHigh,
        title: const Text('Bluetooth permission'),
        content: Text(BlePermissions.advice(r), style: RehabText.body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Not now'),
          ),
          if (permanent)
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                unawaited(BlePermissions.openSettings());
              },
              child: const Text('Open Settings'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final live = widget.state.linkState.isLive;

        return Scaffold(
          body: live
              ? _body()
              : _ConnectPane(
                  state: widget.state,
                  connecting:
                      _connecting || widget.state.linkState.isBusy,
                  onConnect: _connect,
                ),
          bottomNavigationBar: live
              ? NavigationBar(
                  backgroundColor: RehabColors.surface,
                  indicatorColor:
                      RehabColors.actual.withValues(alpha: 0.18),
                  selectedIndex: _tab,
                  onDestinationSelected: (i) => setState(() => _tab = i),
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.accessibility_new),
                      label: 'Exercise',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.straighten),
                      label: 'Calibrate',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.monitor_heart_outlined),
                      label: 'Clinician',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.tune),
                      label: 'Settings',
                    ),
                  ],
                )
              : null,
        );
      },
    );
  }

  Widget _body() => switch (_tab) {
        0 => PatientScreen(state: widget.state),
        1 => CalibrationScreen(state: widget.state),
        2 => ClinicianScreen(state: widget.state),
        _ => SettingsScreen(state: widget.state),
      };
}

class _ConnectPane extends StatelessWidget {
  const _ConnectPane({
    required this.state,
    required this.connecting,
    required this.onConnect,
  });

  final SessionState state;
  final bool connecting;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final failed = state.linkState == LinkState.failed;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('RehabSense', style: RehabText.hero),
            const SizedBox(height: 8),
            Text(
              connecting
                  ? state.linkState.label
                  : 'Put the sleeve on, switch it on, then connect.',
              style: RehabText.body,
            ),
            const SizedBox(height: 32),

            if (connecting)
              const LinearProgressIndicator(
                backgroundColor: RehabColors.surfaceHigh,
                color: RehabColors.actual,
              )
            else
              FilledButton(
                onPressed: onConnect,
                style: FilledButton.styleFrom(
                  backgroundColor: RehabColors.actual,
                  foregroundColor: RehabColors.bg,
                ),
                child: Text(failed ? 'Try again' : 'Connect to sleeve'),
              ),

            if (failed) ...[
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: RehabColors.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('If it does not appear',
                        style: RehabText.label
                            .copyWith(color: RehabColors.inkSoft)),
                    const SizedBox(height: 8),
                    // These four cover essentially every failure seen on the
                    // bench, in the order they are worth checking.
                    ...const [
                      'Is the sleeve powered on? The status LED should be lit.',
                      'Is another host already connected? The sleeve accepts '
                          'one at a time.',
                      'Is Bluetooth on, and is permission granted?',
                      'Try power-cycling the sleeve — it advertises on boot.',
                    ].map((t) => Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('·  ', style: RehabText.body),
                              Expanded(
                                  child: Text(t, style: RehabText.body)),
                            ],
                          ),
                        )),
                  ],
                ),
              ),
            ],

            if (state.problems.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(state.problems.last,
                  style: RehabText.body
                      .copyWith(color: RehabColors.warn, fontSize: 13)),
            ],
          ],
        ),
      ),
    );
  }
}
