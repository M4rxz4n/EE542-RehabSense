# Toolchain setup

Nothing in `final/app` can be built until the Flutter SDK and the Android SDK
are on the machine. Neither is installed on `clanker` as of 28 October 2026 —
`flutter` is not on PATH and there is no `AppData\Local\Android\Sdk`.

Already present and reused below: **Git** (`C:\Program Files\Git`), **Node**,
and a **JDK** (`C:\Program Files\Eclipse Adoptium`). Android Studio brings its
own JDK, so the Adoptium one does not have to be the one Gradle uses.

Budget 45–60 minutes, most of it downloads: the Flutter SDK is around 1 GB and
the Android SDK components another 2–3 GB.

---

## The short path: let VS Code do it

VS Code is already installed, and this is the route Flutter's own docs
recommend over the manual one.

1. In VS Code, install the **Flutter** extension (publisher: Dart Code). It
   pulls in the Dart extension with it.
2. <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>P</kbd> → **Flutter: New Project**.
3. It will report that no SDK is found and offer **Download SDK**. Accept, and
   choose a location with **no spaces and no special characters** —
   `C:\Users\<you>\develop` is what the docs suggest. It handles the download,
   the extraction and the PATH entry.
4. Close and reopen every terminal and editor window, then carry on at
   **Android SDK** below.

Step 3 is the only part that needs attention: a path with a space in it causes
failures later that look like anything but a path problem.

## The manual path

Do this instead if the extension route misbehaves, or if you want the SDK
somewhere specific.

1. Download the Windows stable bundle from
   <https://docs.flutter.dev/install/manual> (the download button on that
   page always points at current stable).

2. Extract it. **Not** into `Program Files` — the path must have no spaces and
   must not need administrator rights:

   ```bat
   mkdir "%USERPROFILE%\develop"
   tar -xf "%USERPROFILE%\Downloads\flutter_windows_<version>-stable.zip" -C "%USERPROFILE%\develop"
   ```

   That leaves the SDK at `%USERPROFILE%\develop\flutter`.

   If `flutter.bat` is missing from `develop\flutter\bin` afterwards, antivirus
   quarantined it. Add the folder as a trusted location and extract again.

3. Add it to PATH. <kbd>Win</kbd>+<kbd>Pause</kbd> (or
   <kbd>Win</kbd>+<kbd>Fn</kbd>+<kbd>B</kbd>) → **Advanced System Settings** →
   **Environment Variables** → under **User variables**, edit **Path** and add:

   ```
   %USERPROFILE%\develop\flutter\bin
   ```

   Move it to the top of the list.

4. **Close and reopen every terminal, VS Code window and IDE.** A PATH change
   does not reach a shell that is already running — which is the usual reason
   `flutter` still is not recognised after a correct install.

5. Check:

   ```bat
   flutter --version
   dart --version
   ```

---

## Android SDK

Flutter needs the Android SDK, and the SDK Manager inside Android Studio is
the least painful way to get it plus the licence acceptance.

1. Install **Android Studio** (latest stable) from
   <https://developer.android.com/studio>.

2. Open it, then **More Actions → SDK Manager** from the welcome dialog
   (or **Tools → SDK Manager** once a project is open), and install:

   - **SDK Platforms** tab: the first entry at **API Level 36**.
   - **SDK Tools** tab — tick **Show Package Details** if you need specific
     versions:
     - Android SDK Build-Tools
     - Android SDK Command-line Tools
     - Android SDK Platform-Tools
     - Android Emulator
     - CMake
     - NDK (Side by side)

   The NDK is a large download and this project has no native code of its own,
   but `flutter doctor` asks for it and some plugins need it. Easier to take it
   now than to debug a Gradle failure later.

3. Accept the licences — `flutter doctor` reports a failure until this is done:

   ```bat
   flutter doctor --android-licenses
   ```

   Answer `y` to each. Success prints `All SDK package licenses accepted.`

4. Install the **Flutter** and **Dart** plugins in Android Studio too if you
   plan to use it as the editor. Not needed if you are staying in VS Code.

---

## A phone to run on

**Use a real phone, not the emulator.** The Android emulator has no Bluetooth
radio — it cannot see the sleeve, so it cannot exercise anything this app
exists to do. It is useful only for checking that the UI lays out.

On the phone: **Settings → About phone → tap Build number seven times** to
unlock Developer options, then **Developer options → USB debugging**. Plug it
in, accept the RSA prompt on the phone, and:

```bat
flutter devices
```

The phone should appear with platform `android`. If Windows does not see it at
all, install the manufacturer's USB driver.

---

## Then build this project

```bat
cd C:\AREAS\skool\Q5\cse475\EE542-RehabSense\final\app

rem Generate the platform scaffolding. Once only, on a clone with no android\.
rem It overwrites lib\main.dart, pubspec.yaml and README.md with placeholders,
rem so git restores ours straight after.
flutter create --org edu.usc.rehabsense --platforms=android,ios .
git checkout -- lib pubspec.yaml README.md
del /q test\widget_test.dart

rem The Bluetooth permissions. Without these a scan returns zero devices and
rem reports nothing about why.
copy /y platform\AndroidManifest.xml android\app\src\main\AndroidManifest.xml

flutter pub get
flutter test
flutter run
```

Then commit `android/` and `ios/` so the permission entries survive and nobody
has to reapply them.

`flutter test` is the one to run first. It is pure Dart, needs no phone, and it
checks the wire format against byte vectors generated from
`../python/rehab_protocol.py`. If those fail, this app and the firmware
disagree about the protocol, and that is worth settling before chasing anything
on the device.

---

## What will probably go wrong first

| Symptom | Cause |
|---|---|
| `'flutter' is not recognized` after installing | The terminal predates the PATH change. Open a new one. |
| `flutter doctor` flags "Android licence status unknown" | `flutter doctor --android-licenses` has not been run. |
| `flutter pub get` fails on `flutter_blue_plus` | 1.x may be too old for current Flutter. See the note in `pubspec.yaml` — the subscription and MTU paths are what change in 2.x, so it wants a real port rather than a version bump. |
| Gradle fails on `compileSdk` or NDK | Usually a plugin wanting a newer `compileSdk` than the template set. Raise it in `android/app/build.gradle(.kts)`. |
| App runs, scan finds nothing | The manifest copy in step 3 was skipped, or permission was denied. The Settings tab shows link messages. |
| Connects, then parse errors on good data | MTU. Android starts at 23 bytes; frames here run to 180. The Settings tab shows the negotiated value. |

## Sources

- [Install Flutter manually](https://docs.flutter.dev/install/manual)
- [Set up Android development](https://docs.flutter.dev/platform-integration/android/setup)
