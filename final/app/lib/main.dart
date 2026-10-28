/// RehabSense Phase 2 host.
///
/// See README.md for the build steps and for why the clinician view is served
/// by the phone rather than by the sleeve.
library;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble/rehab_device.dart';
import 'session/session_state.dart';
import 'ui/app.dart';
import 'ui/theme.dart';

void main() {
  // The plugin is chatty by default and the raw stream makes it unreadable.
  // Turn it up to LogLevel.verbose when a connection is misbehaving.
  FlutterBluePlus.setLogLevel(LogLevel.warning, color: false);

  runApp(const RehabSenseApp());
}

class RehabSenseApp extends StatefulWidget {
  const RehabSenseApp({super.key});

  @override
  State<RehabSenseApp> createState() => _RehabSenseAppState();
}

class _RehabSenseAppState extends State<RehabSenseApp> {
  late final RehabDevice _device = RehabDevice();
  late final SessionState _state = SessionState(_device);

  @override
  void dispose() {
    _state.dispose();
    _device.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RehabSense',
      debugShowCheckedModeBanner: false,
      theme: buildRehabTheme(),
      home: AppShell(device: _device, state: _state),
    );
  }
}
