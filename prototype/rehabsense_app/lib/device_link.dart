import 'models.dart';

/// The one seam between the app and the sleeve. Screens never know whether
/// they are talking to the simulator or to real BLE (PRD 4: firmware uses
/// the same idea for its acquisition backends).
abstract class DeviceLink {
  Stream<Frame> get frames;
  Stream<RepResult> get reps;
  Stream<String> get events;
  Params get params;
  List<bool> get calibration;

  Future<void> connect();
  Future<void> runCalibrationStep(int index);
  Future<void> startSession();
  Future<void> stopSession();
  void setParams(Params p);
  Future<void> firePattern(HapticPattern pattern);
  void injectFault() {}
  void dispose();
}

const calibrationSteps = <(String, String, double)>[
  ('0. Setup and contact check', 'Sleeve on, electrodes placed.', 1.5),
  ('1. Rest', 'Arm relaxed at your side, completely still.', 5.0),
  ('2. Straight arm', 'Straighten comfortably, not locked, and hold still.', 2.0),
  ('3. Biceps maximum', 'Elbow at about 90°, push up against a table.', 3.0),
  ('4. Triceps maximum', 'Same posture, push down.', 3.0),
  ('5. Range sweep', 'Two slow, full-range curls.', 6.0),
];
