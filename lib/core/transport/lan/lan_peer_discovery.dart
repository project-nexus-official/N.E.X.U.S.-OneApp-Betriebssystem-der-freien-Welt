import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// A peer discovered via UDP broadcast or unicast on the local network.
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

/// Discovers NEXUS peers on the LAN via UDP broadcast + optional unicast fallback.
///
/// Discovery strategy (in order):
///   1. Subnet broadcast: sends to 192.168.x.255 / 10.x.x.255 etc. (from
///      local interface addresses). More reliable than 255.255.255.255 on
///      Windows because directed broadcasts are less likely to be blocked.
///   2. Limited broadcast: also sends to 255.255.255.255 as a fallback.
///   3. Manual unicast: if the remote IP is added via [addManualTarget],
///      announcements are sent directly to that address. This bypasses
///      Windows Firewall rules that block inbound UDP broadcast reception.
///      When a device receives a unicast from an unknown IP it automatically
///      adds that IP as a mutual unicast target so both sides discover each
///      other after a single manual entry.
///
/// Android note: receiving UDP broadcasts requires CHANGE_WIFI_MULTICAST_STATE
/// permission and (on some devices) a WifiManager.MulticastLock acquired via
/// a MethodChannel before [start] is called.
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

  // Computed once on start: 255.255.255.255 + all subnet broadcast addresses.
  List<InternetAddress> _broadcastTargets = [];

  // Manual unicast targets: IPs added by the user or learned from received
  // unicast datagrams. Persistent across announcement cycles.
  final Set<String> _manualTargets = {};

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Emits the current peer list whenever it changes.
  Stream<List<DiscoveredLanPeer>> get onPeersChanged =>
      _peersController.stream;

  /// Current snapshot of all known LAN peers.
  List<DiscoveredLanPeer> get peers => List.unmodifiable(_peers.values);

  /// Adds [address] as a manual unicast target.
  ///
  /// Use this when UDP broadcast is blocked (e.g. Windows Firewall): enter
  /// the remote device's IP on this side.  The remote device will then
  /// receive our unicast announcement, add us mutually, and send us theirs.
  void addManualTarget(InternetAddress address) {
    final ip = address.address;
    if (_manualTargets.add(ip)) {
      debugPrint('[LAN-DISC] Manual target added: $ip');
      _sendAnnouncementTo(address);
    }
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  Future<void> start() async {
    _broadcastTargets = await _resolveBroadcastTargets();
    debugPrint(
      '[LAN-DISC] Broadcast targets: '
      '${_broadcastTargets.map((a) => a.address).join(', ')}',
    );

    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        udpBroadcastPort,
        reuseAddress: true,
        reusePort: false,
      );
      _socket!.broadcastEnabled = true;

      debugPrint(
        '[LAN-DISC] UDP socket bound to '
        '0.0.0.0:$udpBroadcastPort  broadcastEnabled=true',
      );

      _socket!.listen(_onSocketEvent);

      _sendAnnouncement();
      _announceTimer =
          Timer.periodic(announcementInterval, (_) => _sendAnnouncement());
      _evictTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _evictStalePeers(),
      );
    } catch (e, st) {
      debugPrint('[LAN-DISC] Failed to bind UDP socket: $e\n$st');
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
    debugPrint('[LAN-DISC] Stopped.');
  }

  // ── Sending announcements ──────────────────────────────────────────────────

  void _sendAnnouncement() {
    // Send to every broadcast target.
    for (final target in _broadcastTargets) {
      _sendAnnouncementTo(target);
    }
    // Also send unicast to manual targets.
    for (final ip in _manualTargets) {
      _sendAnnouncementTo(InternetAddress(ip));
    }
  }

  void _sendAnnouncementTo(InternetAddress target) {
    final socket = _socket;
    if (socket == null) return;
    try {
      final payload = jsonEncode({
        'did': localDid,
        'pseudonym': localPseudonym,
        'port': localTcpPort,
      });
      final bytes = utf8.encode(payload);
      final sent = socket.send(bytes, target, udpBroadcastPort);
      debugPrint(
        '[LAN-DISC] TX → ${target.address}:$udpBroadcastPort  '
        '${bytes.length} B  sent=$sent',
      );
    } catch (e) {
      debugPrint('[LAN-DISC] TX failed → ${target.address}: $e');
    }
  }

  // ── Receiving announcements ────────────────────────────────────────────────

  void _onSocketEvent(RawSocketEvent event) {
    debugPrint('[LAN-DISC] Socket event: $event');

    if (event != RawSocketEvent.read) return;

    final datagram = _socket?.receive();
    if (datagram == null) {
      debugPrint('[LAN-DISC] RawSocketEvent.read but receive() returned null');
      return;
    }

    final senderIp = datagram.address.address;
    debugPrint(
      '[LAN-DISC] RX ← $senderIp:${datagram.port}  '
      '${datagram.data.length} B',
    );

    // If this packet came from a unicast address (not a broadcast originator),
    // add it as a mutual target so the sender can also discover us.
    final isBroadcastSender = _broadcastTargets
        .any((t) => t.address == senderIp);
    if (!isBroadcastSender && !_manualTargets.contains(senderIp)) {
      debugPrint('[LAN-DISC] Auto-adding mutual unicast target: $senderIp');
      _manualTargets.add(senderIp);
    }

    String rawJson;
    try {
      rawJson = utf8.decode(datagram.data);
    } catch (e) {
      debugPrint('[LAN-DISC] UTF-8 decode failed: $e');
      return;
    }

    debugPrint('[LAN-DISC] Payload: $rawJson');

    try {
      final json = jsonDecode(rawJson) as Map<String, dynamic>;
      final did = json['did'] as String?;
      final pseudonym = json['pseudonym'] as String?;
      final tcpPort = json['port'] as int?;

      if (did == null || pseudonym == null || tcpPort == null) {
        debugPrint('[LAN-DISC] Missing field in announcement, ignoring.');
        return;
      }

      if (did == localDid) {
        debugPrint('[LAN-DISC] Own announcement echo, ignoring.');
        return;
      }

      final existing = _peers[did];
      if (existing != null) {
        existing.lastSeen = DateTime.now();
        debugPrint('[LAN-DISC] Refreshed peer: $pseudonym ($senderIp)');
      } else {
        _peers[did] = DiscoveredLanPeer(
          did: did,
          pseudonym: pseudonym,
          address: datagram.address,
          tcpPort: tcpPort,
          lastSeen: DateTime.now(),
        );
        debugPrint('[LAN-DISC] NEW peer discovered: $pseudonym @ $senderIp:$tcpPort');
      }
      _peersController.add(List.unmodifiable(_peers.values));
    } catch (e) {
      debugPrint('[LAN-DISC] JSON parse error: $e  raw=$rawJson');
    }
  }

  // ── Stale-peer eviction ────────────────────────────────────────────────────

  void _evictStalePeers() {
    final cutoff = DateTime.now().subtract(peerTimeout);
    final stale = _peers.keys
        .where((d) => _peers[d]!.lastSeen.isBefore(cutoff))
        .toList();
    if (stale.isNotEmpty) {
      for (final did in stale) {
        debugPrint('[LAN-DISC] Evicted stale peer: $did');
        _peers.remove(did);
      }
      _peersController.add(List.unmodifiable(_peers.values));
    }
  }

  // ── Network interface helpers ──────────────────────────────────────────────

  /// Returns a list of UDP broadcast addresses:
  ///   - One subnet broadcast per local interface (e.g. 192.168.1.255 for /24)
  ///   - Plus 255.255.255.255 as a catch-all
  ///
  /// Subnet broadcasts are more reliable on Windows than 255.255.255.255
  /// because some Windows Firewall profiles allow LAN traffic but block the
  /// limited broadcast address.
  ///
  /// Note: Prefix length is not exposed by dart:io, so we assume /24 for
  /// private address ranges (covers 99 % of home/office networks).
  static Future<List<InternetAddress>> _resolveBroadcastTargets() async {
    final targets = <String>{'255.255.255.255'};

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );

      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;

          // Subnet broadcast for a /24 network (last octet → 255)
          final subnetBroadcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
          targets.add(subnetBroadcast);

          debugPrint(
            '[LAN-DISC] Interface ${iface.name}: ${addr.address}'
            ' → subnet broadcast $subnetBroadcast',
          );
        }
      }
    } catch (e) {
      debugPrint('[LAN-DISC] NetworkInterface.list failed: $e');
    }

    return targets.map(InternetAddress.new).toList();
  }
}
