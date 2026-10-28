/// RehabSense BLE wire constants.
///
/// Mirrors `firmware/main/rehab_config.h` and `host/rehab_protocol.py`.
/// Everything on the wire is little-endian.
///
/// Do not change a value here on its own. These numbers are one half of an
/// interface contract frozen in `firmware/main/ble/ble_service.h`; the other
/// half is the firmware and `rehab_protocol.py`. Change all sides together.
library;

/// Channels fitted to the analogue front end.
///
/// 1 for the MyoWare prototype, 2 once the custom PCB adds the triceps pair.
/// Several wire sizes derive from this, so the frames stay the same length
/// whichever front end is present: 80 samples of one channel and 40 of two
/// both come to 14 + 160 = 174 B.
const int kEmgChannels = 1;

const int kEmgSampleRateHz = 2000;
const int kImuSampleRateHz = 100;

/// Internal analysis rate. The device transmits features decimated to
/// [kFeatureTxRateHz]; grading and rep detection run at the full rate.
const int kFeatureRateHz = 50;
const int kFeatureTxRateHz = 20;

/// Frames are capped well below what a 247-byte MTU allows.
///
/// macOS caps ATT MTU at 185, and the Python host's `bleak` exposes no
/// portable MTU request, so the conservative size keeps one firmware working
/// against any host. It also means the frames fit iOS's negotiated MTU with
/// no request at all — but Android still defaults to 23 and must ask for
/// more. See `RehabDevice.connect`.
const int kFrameMaxBytes = 180;
const int kFrameHeaderBytes = 14;

/// What Android must negotiate up to. 180 + 3 bytes of ATT overhead is the
/// floor; 247 is what the firmware advertises and costs nothing extra.
const int kDesiredMtu = 247;
const int kMinUsableMtu = kFrameMaxBytes + 3;

const int kBleEmgBatch = 80 ~/ kEmgChannels;
const int kBleImuBatch = 6;

const int kEmgFrameBytes = kFrameHeaderBytes + kBleEmgBatch * kEmgChannels * 2;
const int kImuFrameBytes = kFrameHeaderBytes + kBleImuBatch * 24;

const String kDeviceName = 'RehabSense';

/// IMU wire scaling, as `ble_notify_imu` applies it.
const double kAccelLsbPerG = 1000.0;
const double kGyroLsbPerDps = 10.0;

// ── GATT UUIDs ───────────────────────────────────────────────────────────
//
// The identifiers themselves are arbitrary and carry no meaning: generated
// once, recorded here and in ble_service.h, and never reasoned about again.

String _uuid(int short) =>
    'a5b1${short.toRadixString(16).padLeft(4, '0')}-7c4e-4d9a-9e3f-1d2c3b4a5968';

final String kUuidService = _uuid(0x0001);

/// Host to device. Write.
final String kUuidControl = _uuid(0x0002);

/// Full-rate EMG and IMU, ~10.4 kB/s. Notify. Switchable.
final String kUuidRaw = _uuid(0x0003);

/// Feature frames and events. Notify. This is the one the patient view needs.
final String kUuidEvents = _uuid(0x0004);

/// `device_status_t`. Read and notify, unframed.
final String kUuidStatus = _uuid(0x0005);

/// Replay of a range missed during a disconnection. Notify.
final String kUuidBackfill = _uuid(0x0006);

/// `calib_record_t` whole. Read and write.
final String kUuidCalib = _uuid(0x0007);

/// Serialised configuration TLV. Read and notify.
final String kUuidConfig = _uuid(0x0008);

/// `xfer_info_t`: where to fetch a sealed session from. Read and notify.
final String kUuidXfer = _uuid(0x0009);
