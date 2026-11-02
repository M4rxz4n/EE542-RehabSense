/// The app shell: five destinations and the connect flow.
///
/// ## Why these five, in this order
///
/// **Exercise** is first and is where the app opens, because that is the
/// screen someone is actually looking at mid-curl. **Calibrate** is next
/// because nothing else means anything until it has been done once.
/// **Session** and **Progress** are read between sets and between visits.
/// **Therapist** is a different reader asking a different question.
///
/// The developer tools are deliberately *not* a sixth tab competing for the
/// same row: they are reached from the overflow menu, because a bench tool one
/// tap from a patient's screen is a bench tool that gets opened by accident
/// mid-session.
///
/// ## The connect pane
///
/// Everything past it needs a live link, so there is nothing to look at
/// without one — except saved sessions, which are exactly what a therapist
/// looks at with no sleeve present, so that route is offered here.
///
/// Demo mode exists so the UI can be worked on away from the hardware, and it
/// is labelled for as long as it runs: synthetic data that is not obviously
/// synthetic is how a demo ends up quoted as a result.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../ble/permissions.dart';
import '../ble/rehab_device.dart';
import '../session/session_record.dart';
import '../session/session_state.dart';
import '../session/session_store.dart';
import '../sim/demo_driver.dart';
import 'calibration_screen.dart';
import 'developer_screen.dart';
import 'patient_screen.dart';
import 'progress_screen.dart';
import 'session_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';
import 'therapist_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.device,
    required this.state,
    required this.store,
  });

  final RehabDevice device;
  final SessionState state;
  final SessionStore store;

  @override
  State<AppShell> createState() => _AppShellState();
}

enum _Tab { exercise, calibrate, session, progress, therapist }

class _AppShellState extends State<AppShell> {
  _Tab _tab = _Tab.exercise;
  bool _connecting = false;
  StreamSubscription<String>? _problemSub;
  DemoDriver? _demo;

  /// A saved session being viewed on the Session tab instead of the live one.
  SessionRecord? _loaded;

  @override
  void initState() {
    super.initState();
    unawaited(widget.store.load());

    // Surface link complaints where they can be acted on. These are never
    // fatal — a corrupt frame or a dropped link must not end a session — so
    // they go to a snackbar rather than a dialog.
    _problemSub = widget.device.problems.listen((message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(label: 'Details', onPressed: _openDeveloper),
        ),
      );
    });
  }

  @override
  void dispose() {
    _problemSub?.cancel();
    _demo?.dispose();
    super.dispose();
  }

  void _toggleDemo() {
    if (_demo != null) {
      _demo!.stop();
      _demo = null;
    } else {
      _demo = DemoDriver(widget.device)..start();
    }
    setState(() {});
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

  Future<void> _openDeveloper() => _pushTool(
        'Developer',
        DeveloperScreen(state: widget.state, store: widget.store),
      );

  Future<void> _openSettings() => _pushTool(
        'Settings',
        SettingsScreen(state: widget.state),
      );

  Future<void> _pushTool(String title, Widget body) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => Scaffold(
            appBar: AppBar(title: Text(title)),
            body: body,
          ),
        ),
      );

  void _openSaved(SessionRecord record) {
    setState(() {
      _loaded = record;
      _tab = _Tab.session;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final live = widget.state.linkState.isLive;

        return Scaffold(
          appBar: _appBar(live),
          body: live
              ? _body()
              : _ConnectPane(
                  state: widget.state,
                  connecting: _connecting || widget.state.linkState.isBusy,
                  onConnect: _connect,
                  onDemo: _toggleDemo,
                  onProgress: () => setState(() => _tab = _Tab.progress),
                  savedCount: widget.store.all.length,
                ),
          bottomNavigationBar: live ? _nav() : null,
        );
      },
    );
  }

  PreferredSizeWidget? _appBar(bool live) {
    final demo = _demo != null;
    if (!live && !demo) return null;

    return AppBar(
      toolbarHeight: 44,
      backgroundColor:
          demo ? RehabColors.warn.withValues(alpha: 0.16) : RehabColors.bg,
      title: demo
          ? Text('DEMO — synthetic data, no sleeve',
              style: RehabText.label.copyWith(color: RehabColors.warn))
          : Text(_title(), style: RehabText.label),
      actions: [
        if (demo)
          TextButton(onPressed: _toggleDemo, child: const Text('Exit demo')),
        if (live)
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20),
            color: RehabColors.surfaceHigh,
            onSelected: (v) {
              switch (v) {
                case 'settings':
                  _openSettings();
                case 'developer':
                  _openDeveloper();
                case 'disconnect':
                  widget.device.disconnect();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'settings', child: Text('Settings')),
              PopupMenuItem(value: 'developer', child: Text('Developer tools')),
              PopupMenuItem(value: 'disconnect', child: Text('Disconnect')),
            ],
          ),
      ],
    );
  }

  String _title() => switch (_tab) {
        _Tab.exercise => 'Exercise',
        _Tab.calibrate => 'Calibrate',
        _Tab.session => _loaded == null ? 'This session' : 'Saved session',
        _Tab.progress => 'Progress',
        _Tab.therapist => 'Therapist',
      };

  Widget _nav() => NavigationBar(
        backgroundColor: RehabColors.surface,
        indicatorColor: RehabColors.actual.withValues(alpha: 0.18),
        selectedIndex: _Tab.values.indexOf(_tab),
        onDestinationSelected: (i) => setState(() => _tab = _Tab.values[i]),
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
            icon: Icon(Icons.timeline),
            label: 'Session',
          ),
          NavigationDestination(
            icon: Icon(Icons.trending_up),
            label: 'Progress',
          ),
          NavigationDestination(
            icon: Icon(Icons.monitor_heart_outlined),
            label: 'Therapist',
          ),
        ],
      );

  Widget _body() => switch (_tab) {
        _Tab.exercise => PatientScreen(state: widget.state),
        _Tab.calibrate => CalibrationScreen(state: widget.state),
        _Tab.session => SessionScreen(
            state: widget.state,
            store: widget.store,
            loaded: _loaded,
            onCloseLoaded:
                _loaded == null ? null : () => setState(() => _loaded = null),
          ),
        _Tab.progress => ProgressScreen(
            store: widget.store,
            onOpenSession: _openSaved,
          ),
        _Tab.therapist => TherapistScreen(state: widget.state),
      };
}

class _ConnectPane extends StatelessWidget {
  const _ConnectPane({
    required this.state,
    required this.connecting,
    required this.onConnect,
    required this.onDemo,
    required this.onProgress,
    required this.savedCount,
  });

  final SessionState state;
  final bool connecting;
  final VoidCallback onConnect;
  final VoidCallback onDemo;
  final VoidCallback onProgress;
  final int savedCount;

  @override
  Widget build(BuildContext context) {
    final failed = state.linkState == LinkState.failed;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(28),
        children: [
          const SizedBox(height: 40),
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
                      style:
                          RehabText.label.copyWith(color: RehabColors.inkSoft)),
                  const SizedBox(height: 8),
                  // These five cover essentially every failure seen on the
                  // bench, in the order they are worth checking.
                  ...const [
                    'Is the sleeve powered on? Its LED blinks once a second '
                        'while it waits to calibrate.',
                    'Is another host already connected? The sleeve accepts '
                        'one at a time — close the HTML viewer tab.',
                    'Is Bluetooth on, and is permission granted?',
                    'Try power-cycling the sleeve — it advertises on boot, and '
                        'again after every disconnect.',
                    'On the Serial Monitor, does it say advertising as '
                        '"RehabSense"?',
                  ].map((t) => Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('·  ', style: RehabText.body),
                            Expanded(child: Text(t, style: RehabText.body)),
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

          // Saved sessions are readable with no sleeve present, which is
          // exactly when a therapist is most likely to want them.
          if (savedCount > 0 && !connecting) ...[
            const SizedBox(height: 26),
            OutlinedButton.icon(
              onPressed: onProgress,
              icon: const Icon(Icons.trending_up, size: 18),
              label: Text('Open progress · $savedCount saved '
                  'session${savedCount == 1 ? '' : 's'}'),
            ),
          ],

          // No sleeve to hand. Every live screen needs a link, so without this
          // there is nothing to look at and no way to work on the UI away from
          // the hardware.
          if (!connecting) ...[
            const SizedBox(height: 28),
            const Divider(),
            const SizedBox(height: 18),
            Text('NO SLEEVE HERE?', style: RehabText.label),
            const SizedBox(height: 8),
            Text(
              'Demo mode drives the app with synthetic frames in the real wire '
              'format. The movement, scoring, compensation and fatigue all '
              'behave like a session. It proves nothing about Bluetooth '
              'itself, and every screen says DEMO while it runs.',
              style: RehabText.body.copyWith(fontSize: 13.5),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onDemo,
              icon: const Icon(Icons.play_circle_outline, size: 18),
              label: const Text('Start demo mode'),
            ),
          ],
        ],
      ),
    );
  }
}
