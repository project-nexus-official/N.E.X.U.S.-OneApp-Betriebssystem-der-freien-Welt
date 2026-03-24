import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../nexus_message.dart';

/// Manages TCP connections for sending and receiving [NexusMessage]s over LAN.
///
/// Wire framing per connection:
///   [4 bytes: uint32 big-endian payload length][N bytes: ZLib-compressed JSON]
///
/// A new TCP socket is opened for each outgoing message and closed after
/// flushing (simple, stateless; latency is acceptable on LAN).
/// Incoming connections are served by a persistent [ServerSocket].
class LanMessageChannel {
  LanMessageChannel({required this.tcpPort});

  final int tcpPort;

  ServerSocket? _server;
  final _msgController = StreamController<NexusMessage>.broadcast();

  /// Emits every [NexusMessage] received over a TCP connection.
  Stream<NexusMessage> get onMessageReceived => _msgController.stream;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  Future<void> start() async {
    try {
      _server = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        tcpPort,
        shared: true,
      );
      _server!.listen(_onIncomingConnection);
    } catch (_) {
      // Port in use or platform restriction – degrade gracefully.
    }
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }

  // ── Outgoing ──────────────────────────────────────────────────────────────

  /// Sends [message] to [address]:[port] via a short-lived TCP connection.
  Future<void> sendTo(
    NexusMessage message,
    InternetAddress address,
    int port,
  ) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        address,
        port,
        timeout: const Duration(seconds: 5),
      );
      socket.add(_buildFrame(message.toWireBytes()));
      await socket.flush();
    } finally {
      socket?.destroy();
    }
  }

  // ── Incoming ──────────────────────────────────────────────────────────────

  void _onIncomingConnection(Socket socket) {
    final reader = _FrameReader(
      onFrame: (bytes) {
        try {
          _msgController.add(NexusMessage.fromWireBytes(bytes));
        } catch (_) {
          // Malformed payload – discard.
        }
      },
    );

    socket.listen(
      reader.feed,
      onDone: socket.destroy,
      onError: (_) => socket.destroy(),
      cancelOnError: true,
    );
  }

  // ── Framing ───────────────────────────────────────────────────────────────

  static Uint8List _buildFrame(Uint8List payload) {
    final frame = Uint8List(4 + payload.length);
    final len = payload.length;
    frame[0] = (len >> 24) & 0xff;
    frame[1] = (len >> 16) & 0xff;
    frame[2] = (len >> 8) & 0xff;
    frame[3] = len & 0xff;
    frame.setRange(4, 4 + payload.length, payload);
    return frame;
  }
}

// ── Frame reader (handles TCP stream fragmentation) ───────────────────────────

/// Buffers incoming TCP bytes and fires [onFrame] for each complete frame.
///
/// Frame format: [4-byte big-endian length][N bytes payload]
class _FrameReader {
  _FrameReader({required this.onFrame});

  final void Function(Uint8List) onFrame;

  final _buf = <int>[];

  void feed(Uint8List data) {
    _buf.addAll(data);

    while (true) {
      if (_buf.length < 4) break;

      final len =
          (_buf[0] << 24) | (_buf[1] << 16) | (_buf[2] << 8) | _buf[3];

      // Sanity-check: reject absurdly large frames (> 4 MB)
      if (len > 4 * 1024 * 1024) {
        _buf.clear();
        break;
      }

      if (_buf.length < 4 + len) break;

      final payload = Uint8List.fromList(_buf.sublist(4, 4 + len));
      _buf.removeRange(0, 4 + len);

      onFrame(payload);
    }
  }
}
