import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/identity/identity_service.dart';
import '../../core/transport/message_transport.dart';
import '../../core/transport/nexus_peer.dart';
import '../../core/transport/transport_manager.dart';

/// Tracks the count of NEXUS nodes currently active on the Nostr network.
///
/// **Online definition**: a node is ONLINE when its last presence event
/// arrived within the last [_onlineWindow] (15 minutes).
///
/// Entries are pruned:
///   - immediately on [init] (removes ghosts from previous sessions)
///   - on every peer-change event
///   - every [_cleanupInterval] (60 seconds) via a background timer
///
/// The own device's DID is always excluded from the count so both
/// devices show symmetric, consistent numbers.
///
/// Uses SharedPreferences key [_seenNodesKey] (v2 — v1 used a 7-day
/// window and is intentionally abandoned).
class NodeCounterService {
  NodeCounterService._();
  static final instance = NodeCounterService._();

  static const _seenNodesKey = 'nexus_seen_nodes_v2';

  /// A node is counted as ONLINE when its last presence is within this window.
  static const _onlineWindow = Duration(minutes: 15);

  /// How often the background timer prunes expired entries.
  static const _cleanupInterval = Duration(seconds: 60);

  int _count = 0;
  DateTime? _lastUpdated;
  bool _initialized = false;

  final _countController = StreamController<int>.broadcast();

  /// Live stream of the current global node count (ONLINE peers only).
  Stream<int> get countStream => _countController.stream;

  /// Latest known count of active NEXUS nodes (excluding self).
  int get count => _count;

  /// When the count was last refreshed (null if never).
  DateTime? get lastUpdated => _lastUpdated;

  StreamSubscription<List<NexusPeer>>? _peersSub;
  Timer? _cleanupTimer;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // Immediately prune stale ghost-nodes from previous sessions so the
    // count is correct from the very first frame.
    await _pruneAndEmit();

    // Listen to live peer changes from any transport.
    _peersSub = TransportManager.instance.onPeersChanged.listen(
      (peers) async => _onPeersChanged(peers),
    );

    // Background cleanup: prune expired entries every 60 seconds so the
    // count drops to zero promptly when no peers are online.
    _cleanupTimer = Timer.periodic(_cleanupInterval, (_) async {
      await _pruneAndEmit();
    });

    // Seed with whatever peers are already visible.
    await _onPeersChanged(TransportManager.instance.peers);
  }

  void dispose() {
    _peersSub?.cancel();
    _cleanupTimer?.cancel();
    _initialized = false;
    if (!_countController.isClosed) _countController.close();
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  Future<void> _onPeersChanged(List<NexusPeer> peers) async {
    final nostrPeers = peers
        .where((p) => p.transportType == TransportType.nostr)
        .toList();

    if (nostrPeers.isEmpty) {
      await _pruneAndEmit();
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_seenNodesKey);
    final Map<String, dynamic> map = raw != null
        ? Map<String, dynamic>.from(jsonDecode(raw) as Map)
        : {};

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final peer in nostrPeers) {
      map[peer.did] = nowMs;
      final shortDid =
          peer.did.length > 12 ? '…${peer.did.substring(peer.did.length - 12)}' : peer.did;
      debugPrint('[NODES] Peer seen: $shortDid (${peer.pseudonym})');
    }

    await _saveAndEmit(prefs, map);
  }

  Future<void> _pruneAndEmit() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_seenNodesKey);
    final Map<String, dynamic> map = raw != null
        ? Map<String, dynamic>.from(jsonDecode(raw) as Map)
        : {};
    await _saveAndEmit(prefs, map);
  }

  Future<void> _saveAndEmit(
    SharedPreferences prefs,
    Map<String, dynamic> map,
  ) async {
    // Remove entries outside the 15-minute online window.
    final cutoffMs =
        DateTime.now().subtract(_onlineWindow).millisecondsSinceEpoch;
    map.removeWhere((_, ts) => (ts as int) < cutoffMs);

    // Always exclude own DID — we never count ourselves.
    final ownDid = IdentityService.instance.currentIdentity?.did;
    if (ownDid != null) map.remove(ownDid);

    await prefs.setString(_seenNodesKey, jsonEncode(map));
    _count = map.length;
    _lastUpdated = DateTime.now();

    final shortDids = map.keys
        .map((d) => d.length > 12 ? '…${d.substring(d.length - 12)}' : d)
        .join(', ');
    debugPrint('[NODES] Active nodes: $_count'
        '${map.isEmpty ? '' : ', DIDs: [$shortDids]'}');

    if (!_countController.isClosed) {
      _countController.add(_count);
    }
  }
}
