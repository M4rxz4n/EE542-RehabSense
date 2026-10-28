# RehabSense app (Flutter)

Patient, therapist and device dashboards. Runs on a built-in simulator today; the real sleeve plugs in through `DeviceLink`.

## Run
1. flutter create rehabsense_app   (anywhere), then replace its `lib/`, `test/` and `pubspec.yaml` with these.
2. cd rehabsense_app && flutter pub get
3. flutter test
4. flutter run -d chrome   (or a phone / simulator)
5. Patient tab: Get ready, then Start. Device tab: change scenario. Therapist tab: send feedback.

## Layout
lib/models.dart          data types      lib/grading.dart       scoring rules
lib/device_link.dart     the seam        lib/simulator_link.dart  fake sleeve
lib/ble_link.dart        wire codec + BLE stub    lib/app_state.dart   shared state
lib/ui/                  Patient, Therapist, Device screens and painters
