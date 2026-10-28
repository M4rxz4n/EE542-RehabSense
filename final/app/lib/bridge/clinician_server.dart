/// The clinician bridge: an HTTP + WebSocket server running on the phone.
///
/// ## Why the phone serves this
///
/// The design that looks obvious — sleeve joins the clinic Wi-Fi and streams
/// to a dashboard — is not available, and deliberately so:
///
/// - The ESP32-S3 has one 2.4 GHz radio. Running Wi-Fi alongside a saturated
///   BLE link means software coexistence arbitrating between them, costing
///   throughput on both and making BLE miss connection events. The live
///   stream is the one thing that must not degrade.
/// - So the firmware refuses to start a transfer while `OPERATIONAL`, and
///   `session_xfer.h` states plainly that this is not a policy the host can
///   override.
/// - The sleeve's Wi-Fi is a SoftAP with no route anywhere. Station mode needs
///   credential provisioning and is out of this revision.
///
/// The phone already holds the BLE link, so it bridges: it relays a thinned
/// JSON feed over a WebSocket to a page it serves itself. A clinician on the
/// same network opens the phone's address. Nothing is deployed, no account
/// exists, and no patient data leaves the local network.
///
/// Replacing this with a cloud relay later is a URL change on the other side
/// of the same feed.
///
/// ## Deliberately no dependencies
///
/// `dart:io` has `HttpServer` and `WebSocketTransformer`. Adding shelf,
/// shelf_web_socket and web_socket_channel would buy nothing here and put
/// three more version constraints between the team and a working build.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../session/session_state.dart';
import 'clinician_page.dart';

class BridgeViewer {
  BridgeViewer(this.socket, this.remote);
  final WebSocket socket;
  final String remote;
  final DateTime since = DateTime.now();
}

class ClinicianServer {
  ClinicianServer(this.state);

  final SessionState state;

  HttpServer? _server;
  StreamSubscription<Map<String, dynamic>>? _feedSub;
  final List<BridgeViewer> _viewers = [];
  Timer? _keepAlive;

  bool get running => _server != null;
  int get port => _server?.port ?? 0;
  int get viewerCount => _viewers.length;
  List<BridgeViewer> get viewers => List.unmodifiable(_viewers);

  /// The URLs a clinician can open, one per network interface the phone has.
  ///
  /// More than one is normal — Wi-Fi and a cellular interface at least — and
  /// only the Wi-Fi one will be reachable, so all of them are offered rather
  /// than guessing.
  List<String> addresses = [];

  final _changed = StreamController<void>.broadcast();
  Stream<void> get changes => _changed.stream;

  /// Bind and start serving. [preferredPort] 0 lets the OS choose.
  Future<bool> start({int preferredPort = 8723}) async {
    if (_server != null) return true;
    try {
      _server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        preferredPort,
        shared: true,
      );
    } on SocketException {
      // Port in use — most likely a previous run that has not released it.
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      } catch (_) {
        return false;
      }
    }

    addresses = await _localAddresses();
    _server!.listen(_handle, onError: (Object _) {});

    // Relay everything the session publishes. Note this listens to the
    // session's own broadcast feed rather than to the ChangeNotifier: a slow
    // or stalled viewer must never be able to hold a repaint hostage.
    _feedSub = state.bridgeFeed.listen(_broadcast);

    // A ping every 20 s, so a viewer that walked out of range is reaped
    // rather than counted forever.
    _keepAlive = Timer.periodic(const Duration(seconds: 20), (_) {
      _broadcast({'kind': 'ping', 'at': DateTime.now().toIso8601String()});
    });

    _changed.add(null);
    return true;
  }

  Future<void> stop() async {
    _keepAlive?.cancel();
    _keepAlive = null;
    await _feedSub?.cancel();
    _feedSub = null;
    for (final v in List.of(_viewers)) {
      try {
        await v.socket.close();
      } catch (_) {}
    }
    _viewers.clear();
    await _server?.close(force: true);
    _server = null;
    addresses = [];
    _changed.add(null);
  }

  Future<void> _handle(HttpRequest request) async {
    // Same-origin only in spirit: this is a LAN service with no auth, so it
    // sends no cache headers and accepts no writes. Everything is read-only.
    if (request.method != 'GET') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }

    final path = request.uri.path;

    if (path == '/ws') {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      await _upgrade(request);
      return;
    }

    if (path == '/snapshot.json') {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..headers.set('Cache-Control', 'no-store')
        ..write(jsonEncode(state.snapshot()));
      await request.response.close();
      return;
    }

    if (path == '/' || path == '/index.html') {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..headers.set('Cache-Control', 'no-store')
        ..write(clinicianPageHtml);
      await request.response.close();
      return;
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  Future<void> _upgrade(HttpRequest request) async {
    final WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(request);
    } catch (_) {
      return;
    }

    final viewer = BridgeViewer(
      socket,
      request.connectionInfo?.remoteAddress.address ?? 'unknown',
    );
    _viewers.add(viewer);
    _changed.add(null);

    // A page that has just connected needs something to render before the
    // next feature frame arrives — which, between sets, could be a while.
    try {
      socket.add(jsonEncode(state.snapshot()));
    } catch (_) {}

    socket.listen(
      // Read-only: a clinician view must not be able to start a set or change
      // a parameter. Those decisions stay with whoever is holding the phone
      // next to the patient.
      (_) {},
      onDone: () {
        _viewers.remove(viewer);
        _changed.add(null);
      },
      onError: (Object _) {
        _viewers.remove(viewer);
        _changed.add(null);
      },
      cancelOnError: true,
    );
  }

  void _broadcast(Map<String, dynamic> message) {
    if (_viewers.isEmpty) return;
    final encoded = jsonEncode(message);
    for (final v in List.of(_viewers)) {
      try {
        v.socket.add(encoded);
      } catch (_) {
        _viewers.remove(v);
      }
    }
  }

  /// Non-loopback IPv4 addresses, which is what a clinician can actually
  /// reach. Loopback is filtered because `127.0.0.1` on the phone is useless
  /// to anyone else.
  Future<List<String>> _localAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      return [
        for (final i in interfaces)
          for (final a in i.addresses) 'http://${a.address}:$port',
      ];
    } catch (_) {
      return [];
    }
  }

  void dispose() {
    // Fire and forget: dispose() cannot be async, and a socket that outlives
    // the widget by a few milliseconds is harmless — the server is closed
    // with force and the viewers are dropped either way.
    unawaited(stop());
    unawaited(_changed.close());
  }
}
