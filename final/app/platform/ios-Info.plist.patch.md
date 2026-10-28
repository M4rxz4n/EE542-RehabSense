# iOS platform patches

Apply these to `ios/Runner/Info.plist` after `flutter create .`.

None of this can be done on Windows — the iOS toolchain is macOS-only. Write
the keys in now anyway, so the day someone opens the project on a Mac the only
remaining work is signing. Commit the result.

## 1. Bluetooth usage descriptions

iOS kills the app on the first BLE call if these are missing, with a console
message that is easy to miss. The strings are shown verbatim in the system
permission dialog, so write them for a patient, not for us.

Add inside the top-level `<dict>`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>RehabSense connects to your exercise sleeve to show your arm position and count your repetitions.</string>

<key>NSBluetoothPeripheralUsageDescription</key>
<string>RehabSense connects to your exercise sleeve to show your arm position and count your repetitions.</string>
```

`NSBluetoothPeripheralUsageDescription` is the iOS 12 and earlier spelling.
Harmless to keep, and it costs nothing.

## 2. Local network access, for the clinician bridge

The app serves the clinician page over the local network. Since iOS 14 that
requires a declaration, and without it the server starts but nothing can
reach it — no error, just silence.

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>RehabSense shares your live session with a clinician on the same network.</string>

<key>NSBonjourServices</key>
<array>
  <string>_rehabsense._tcp</string>
</array>
```

## 3. Background BLE — only if the screen will lock mid-set

Needed if a set should survive the screen locking. It restricts what else the
app may do in the background and Apple asks about it at review, so leave it
out unless a volunteer session actually runs into it.

```xml
<key>UIBackgroundModes</key>
<array>
  <string>bluetooth-central</string>
</array>
```

A simpler answer for the demo: keep the screen awake while a set is running.
`WakelockPlus` or a `MethodChannel` to `UIApplication.isIdleTimerDisabled`
both do it, and neither needs this key.

## 4. Minimum deployment target

`flutter_blue_plus` requires iOS 12 or later. In `ios/Podfile`, make sure the
first line is not commented out and reads at least:

```ruby
platform :ios, '13.0'
```

Then in Xcode set the Runner target's **Minimum Deployments** to the same.

## 5. Signing, when you get to a Mac

A free Apple ID installs on a connected device for 7 days, which is enough to
test platform BLE behaviour. TestFlight, or anything that lasts, needs the
paid Developer Program account ($99/yr) — see the README for the decision.

```
open ios/Runner.xcworkspace
```

Runner target → Signing & Capabilities → set Team. Then `flutter run -d <device>`.
