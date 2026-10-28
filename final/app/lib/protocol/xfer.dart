/// `xfer_info_t`, characteristic 0x0009. Read and notify. Packed, 63 bytes.
///
/// How the app learns where to fetch a sealed session from. Sent in answer to
/// [Cmd.startTransfer] and again whenever the transfer state changes, so a
/// client that reconnects mid-transfer picks up without restarting it.
///
/// Note what this is NOT: the sleeve's Wi-Fi is a SoftAP with no route
/// anywhere. Whatever joins it downloads the session and is responsible for
/// onward delivery. The sleeve never joins the clinic network and never
/// uploads anywhere itself.
///
/// The credentials deliberately travel over BLE rather than being printed on
/// the device, because the BLE link is already paired with the host that is
/// about to download a patient's session.
library;

import 'dart:typed_data';

import 'enums.dart';
import 'frames.dart';

const int kXferBytes = 63;

class XferInfo {
  const XferInfo({
    required this.state,
    required this.clients,
    required this.secondsRemaining,
    required this.ipv4,
    required this.port,
    required this.bytesServed,
    required this.ssid,
    required this.password,
  });

  final int state;

  /// Stations currently associated. Goes to 1 when the phone joins.
  final int clients;

  /// Until the idle timeout tears the AP down, so a forgotten transfer does
  /// not leave the radio up until the battery dies.
  final int secondsRemaining;

  final String ipv4;
  final int port;
  final int bytesServed;
  final String ssid;
  final String password;

  XferState? get kind => XferState.fromWire(state);
  String get stateLabel => XferState.nameOf(state);

  /// AP up and the HTTP server answering.
  bool get ready => state == XferState.ready.wire;

  /// The device refused. Almost always because a set is still running, or
  /// because no session has been sealed yet. Not something the host can
  /// override — it is a deliberate refusal, not a transient error.
  bool get failed => state == XferState.failed.wire;

  String get baseUrl => 'http://$ipv4:$port';

  static XferInfo parse(Uint8List data) {
    if (data.length < kXferBytes) {
      throw ProtocolError('xfer info is ${data.length} B, need $kXferBytes');
    }
    final d = ByteData.sublistView(data);
    final state = d.getUint8(0);
    final clients = d.getUint8(1);
    final secs = d.getUint16(2, Endian.little);
    final rawIp = d.getUint32(4, Endian.little);
    final port = d.getUint16(8, Endian.little);
    final served = d.getUint32(10, Endian.little);

    // The device stores the AP address in network byte order, as the lwIP
    // netif reports it, so the first octet is the low byte of the
    // little-endian word.
    final octets = [
      for (var i = 0; i < 4; i++) (rawIp >> (8 * i)) & 0xFF,
    ].join('.');

    String cstr(int offset, int len) {
      final bytes = data.sublist(offset, offset + len);
      final end = bytes.indexOf(0);
      return String.fromCharCodes(end < 0 ? bytes : bytes.sublist(0, end));
    }

    return XferInfo(
      state: state,
      clients: clients,
      secondsRemaining: secs,
      ipv4: octets,
      port: port,
      bytesServed: served,
      ssid: cstr(14, 33),
      password: cstr(47, 16),
    );
  }

  Uint8List pack() {
    final b = ByteData(kXferBytes);
    b.setUint8(0, state);
    b.setUint8(1, clients);
    b.setUint16(2, secondsRemaining, Endian.little);
    final octets = ipv4.split('.').map(int.parse).toList();
    var raw = 0;
    for (var i = 0; i < 4 && i < octets.length; i++) {
      raw |= octets[i] << (8 * i);
    }
    b.setUint32(4, raw, Endian.little);
    b.setUint16(8, port, Endian.little);
    b.setUint32(10, bytesServed, Endian.little);
    final out = b.buffer.asUint8List();
    void putStr(String s, int offset, int len) {
      final codes = s.codeUnits;
      for (var i = 0; i < len - 1 && i < codes.length; i++) {
        out[offset + i] = codes[i] & 0xFF;
      }
    }

    putStr(ssid, 14, 33);
    putStr(password, 47, 16);
    return out;
  }

  /// What to put in front of the operator, in one line.
  String get joinHint {
    if (!ready) return 'transfer ${stateLabel.toLowerCase()}';
    return 'Join Wi-Fi "$ssid" (password $password), then fetch from $baseUrl';
  }

  Map<String, dynamic> toJson() => {
        'state': state,
        'state_label': stateLabel,
        'clients': clients,
        'seconds_remaining': secondsRemaining,
        'ipv4': ipv4,
        'port': port,
        'bytes_served': bytesServed,
        'ssid': ssid,
      };
}
