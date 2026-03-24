import 'dart:async';

import '../message_transport.dart';
import '../nexus_message.dart';
import '../nexus_peer.dart';
import 'lan_message_channel.dart';
import 'lan_peer_discovery.dart';

/// LAN-based [MessageTransport] using UDP broadcast for discovery and
/// TCP for message transfer.
///
/// Works on Android, Windows, macOS, Linux, and Raspberry Pi — any platform
/// with WiFi/Ethernet and dart:io support.
///
/// Discovery port : UDP 51000  (broadcast announcements every 3 s)
/// Message port   : TCP 51001  (framed ZLib-compressed JSON)
///
/// No additional packages required — uses only dart:io.
class LanTransport implements MessageTransport {
  static const int _udpPort = 51000;
  static const int _tcpPort = 51001;

  LanTransport({
    required this.localDid,
    required this.localPseudonym,
  });

  final String localDid;
  final String localPseudonym;

  // ── State ──────────────────────────────────────────────────────────────────

  TransportState _state = TransportState.idle;

  @override
  TransportType get type => TransportType.lan;

  @override
  TransportState get state => _state;

  // ── Streams ────────────────────────────────────────────────────────────────

  final _msgController = StreamController<NexusMessage>.broadcast();
  final _peersController = StreamController<List<NexusPeer>>.broadcast();

  @override
  Stream<NexusMessage> get onMessageReceived => _msgController.stream;

  @override
  Stream<List<NexusPeer>> get onPeersChanged => _peersController.stream;

  // ── Peer tracking ──────────────────────────────────────────────────────────

  final Map<String, NexusPeer> _peers = {};

  @override
  List<NexusPeer> get currentPeers => List.unmodifiable(_peers.values);

  // ── Internal components ────────────────────────────────────────────────────

  late final LanPeerDiscovery _discovery;
  late final LanMessageChannel _channel;
  final List<StreamSubscription<dynamic>> _subs = [];

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  Future<void> start() async {
    if (_state != TransportState.idle) return;

    _discovery = LanPeerDiscovery(
      localDid: localDid,
      localPseudonym: localPseudonym,
      localTcpPort: _tcpPort,
    );
    _channel = LanMessageChannel(tcpPort: _tcpPort);

    try {
      await _discovery.start();
      await _channel.start();

      _subs
        ..add(_discovery.onPeersChanged.listen(_onDiscoveredPeersChanged))
        ..add(_channel.onMessageReceived.listen(_msgController.add));

      _state = TransportState.scanning;
    } catch (_) {
      _state = TransportState.error;
    }
  }

  @override
  Future<void> stop() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();

    await _discovery.stop();
    await _channel.stop();

    _peers.clear();
    _state = TransportState.idle;
  }

  // ── Sending ────────────────────────────────────────────────────────────────

  @override
  Future<void> sendMessage(NexusMessage message, {String? recipientDid}) async {
    if (recipientDid != null) {
      // Direct message: find the LAN peer and open a TCP connection.
      final lanPeer = _discovery.peers
          .where((p) => p.did == recipientDid)
          .firstOrNull;

      if (lanPeer == null) {
        throw StateError('LAN: peer $recipientDid not reachable');
      }
      await _channel.sendTo(message, lanPeer.address, lanPeer.tcpPort);
      return;
    }

    // Broadcast: send to all known LAN peers.
    final allPeers = _discovery.peers;
    if (allPeers.isEmpty) {
      throw StateError('LAN: no peers to broadcast to');
    }

    final errors = <Object>[];
    for (final peer in allPeers) {
      try {
        await _channel.sendTo(message, peer.address, peer.tcpPort);
      } catch (e) {
        errors.add(e);
      }
    }
    // Only rethrow if every single peer failed.
    if (errors.length == allPeers.length) {
      throw StateError('LAN broadcast failed for all ${allPeers.length} peers');
    }
  }

  // ── Discovery callback ─────────────────────────────────────────────────────

  void _onDiscoveredPeersChanged(List<DiscoveredLanPeer> lanPeers) {
    final newDids = lanPeers.map((p) => p.did).toSet();

    // Remove disappeared peers.
    _peers.removeWhere((did, _) => !newDids.contains(did));

    // Add / update known peers.
    for (final lp in lanPeers) {
      _peers[lp.did] = NexusPeer(
        did: lp.did,
        pseudonym: lp.pseudonym,
        transportType: TransportType.lan,
        lastSeen: lp.lastSeen,
      );
    }

    _peersController.add(List.from(_peers.values));
  }
}
