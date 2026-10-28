import 'package:flutter/material.dart';
import 'app_state.dart';
import 'simulator_link.dart';
import 'ui/device_screen.dart';
import 'ui/patient_screen.dart';
import 'ui/therapist_screen.dart';

void main() => runApp(const RehabApp());

class RehabApp extends StatefulWidget {
  const RehabApp({super.key});
  @override
  State<RehabApp> createState() => _RehabAppState();
}

class _RehabAppState extends State<RehabApp> {
  // Swap SimulatorLink() for BleLink() when the BLE layer exists.
  final state = AppState(SimulatorLink());
  int tab = 1;

  @override
  void dispose() {
    state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screens = [DeviceScreen(state), PatientScreen(state), TherapistScreen(state)];
    return MaterialApp(
      title: 'RehabSense',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B6A8A)), useMaterial3: true),
      darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B6A8A), brightness: Brightness.dark), useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(title: const Text('RehabSense')),
        body: SafeArea(child: screens[tab]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.memory), label: 'Device'),
            NavigationDestination(icon: Icon(Icons.accessibility_new), label: 'Patient'),
            NavigationDestination(icon: Icon(Icons.monitor_heart), label: 'Therapist'),
          ],
        ),
      ),
    );
  }
}
