import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A peer discovered via UDP broadcast on the local network.
class DiscoveredLanPeer {
  final String did;
  final String pseudonym;
  final InternetAddress address;
  final int tcpPort;
  DateTime lastSeen;

  DiscoveredLanPeer({
    required this.did,
    required this.pseudonym,
    required this.address,
    required this.tcpPort,
    required this.lastSeen,
  });
}

/// Discovers NEXUS peers on the LAN via UDP broadcast.
///
/// Protocol:
///   - Every [announcementInterval] each node broadcasts a JSON datagram to
///     255.255.255.255:[udpBroadcastPort]:
///       {"did":"did:key:…","pseudonym":"…","port":51001}
///   - All nodes listen on the same port for announcements from others.
///   - Peers that have not announced within [peerTimeout] are evicted.
///
/// Android note: UDP broadcast reception on Android requires the app to hold a
/// WifiManager.MulticastLock.  Acquire it via a MethodChannel before calling
/// [start] on Android.  The manifest already declares
/// android.permission.CHANGE_WIFI_MULTICAST_STATE.
class LanPeerDiscovery {
  static const int udpBroadcastPort = 51000;
  static const Duration announcementInterval = Duration(seconds: 3);
  static const Duration peerTimeout = Duration(seconds: 15);

  LanPeerDiscovery({
    required this.localDid,
    required this.localPseudonym,
    required this.localTcpPort,
  });

  final String localDid;
  final String localPseudonym;
  final int localTcpPort;

  RawDatagramSocket? _socket;
  Timer? _announceTimer;
  Timer? _evictTimer;

  final Map<String, DiscoveredLanPeer> _peers = {};
  final _peersController =
      StreamController<List<DiscoveredLanPeer>>.broadcast();

  /// Emits the current peer list whenever it changes.
  Stream<List<DiscoveredLanPeer>> get onPeersChanged =>
      _peersController.stream;

  /// Current snapshot of all known LAN peers.
  List<DiscoveredLanPeer> get peers => List.unmodifiable(_peers.values);

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  Future<void> start() async {
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        udpBroadcastPort,
        reuseAddress: true,
        reusePort: false,
      );
      _socket!.broadcastEnabled = true;
      _socket!.listen(_onSocketEvent);

      // Send first announcement immediately, then on a timer
      _sendAnnouncement();
      _announceTimer =
          Timer.periodic(announcementInterval, (_) => _sendAnnouncement());

      // Periodic stale-peer eviction
      _evictTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _evictStalePeers(),
      );
    } catch (_) {
      // UDP socket unavailable on this platform/network – degrade gracefully.
    }
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _evictTimer?.cancel();
    _announceTimer = null;
    _evictTimer = null;
    _socket?.close();
    _socket = null;
    _peers.clear();
  }

  // ── Sending announcements ──────────────────────────────────────────────────

  void _sendAnnouncement() {
    final socket = _socket;
    if (socket == null) return;
    try {
      final payload = jsonEncode({
        'did': localDid,
        'pseudonym': localPseudonym,
        'port': localTcpPort,
      });
      socket.send(
        utf8.encode(payload),
        InternetAddress('255.255.255.255'),
        udpBroadcastPort,
      );
    } catch (_) {
      // Ignore transient send errors.
    }
  }

  // ── Receiving announcements ────────────────────────────────────────────────

  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _socket?.receive();
    if (datagram == null) return;

    try {
      final json =
          jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
      final did = json['did'] as String?;
      final pseudonym = json['pseudonym'] as String?;
      final tcpPort = json['port'] as int?;

      if (did == null || pseudonym == null || tcpPort == null) return;
      if (did == localDid) return; // ignore own announcements

      final existing = _peers[did];
      if (existing != null) {
        existing.lastSeen = DateTime.now();
      } else {
        _peers[did] = DiscoveredLanPeer(
          did: did,
          pseudonym: pseudonym,
          address: datagram.address,
          tcpPort: tcpPort,
          lastSeen: DateTime.now(),
        );
      }
      _peersController.add(List.unmodifiable(_peers.values));
    } catch (_) {
      // Ignore malformed datagrams.
    }
  }

  // ── Stale-peer eviction ────────────────────────────────────────────────────

  void _evictStalePeers() {
    final cutoff = DateTime.now().subtract(peerTimeout);
    final stale =
        _peers.keys.where((d) => _peers[d]!.lastSeen.isBefore(cutoff)).toList();
    if (stale.isNotEmpty) {
      for (final did in stale) {
        _peers.remove(did);
      }
      _peersController.add(List.unmodifiable(_peers.values));
    }
  }
}
