import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'message_transport.dart';
import 'nexus_message.dart';
import 'nexus_peer.dart';

/// Manages all registered transport backends with automatic fallback.
///
/// Fallback cascade (registration order):
///   LAN (preferred for direct messages) → BLE → Nostr → …
///
/// Responsibilities:
///   - Start / stop all transports.
///   - Merge peer lists across transports; track which transports each peer
///     is visible on ([NexusPeer.availableTransports]).
///   - Deduplicate incoming messages by ID.
///   - Sign outgoing messages with the node's Ed25519 key pair.
///   - For directed messages: prefer LAN when the recipient is reachable via LAN.
///
/// Usage:
/// ```dart
/// final manager = TransportManager.instance;
/// manager.registerTransport(BleTransport(myDid));
/// manager.registerTransport(LanTransport(myDid));
/// manager.setSigningKeyPair(keyPair);
/// await manager.start();
/// manager.sendMessage(NexusMessage.create(...));
/// ```
class TransportManager {
  // Singleton
  static final TransportManager instance = TransportManager._();
  TransportManager._();

  final List<MessageTransport> _transports = [];

  final _messageController = StreamController<NexusMessage>.broadcast();
  final _peersController = StreamController<List<NexusPeer>>.broadcast();

  // All known peers keyed by DID (merged across transports)
  final Map<String, NexusPeer> _peers = {};

  // Transport type → set of peer DIDs currently visible on that transport.
  // Used for LAN-prefer routing and for maintaining availableTransports.
  final Map<TransportType, Set<String>> _peersByTransport = {};

  // Message deduplication
  final Set<String> _seenIds = {};
  static const int _maxSeenIds = 10000;

  // Active subscriptions to individual transports
  final List<StreamSubscription<dynamic>> _subs = [];

  // Ed25519 key pair for signing outgoing messages
  SimpleKeyPair? _signingKeyPair;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Stream of all incoming messages (deduplicated, expired messages filtered).
  Stream<NexusMessage> get onMessageReceived => _messageController.stream;

  /// Stream of the merged peer list across all transports.
  Stream<List<NexusPeer>> get onPeersChanged => _peersController.stream;

  /// Current snapshot of all known peers.
  List<NexusPeer> get peers => List.unmodifiable(_peers.values);

  /// The transport type that is currently active (first non-error transport).
  TransportType? get activeTransportType {
    for (final t in _transports) {
      if (t.state != TransportState.idle && t.state != TransportState.error) {
        return t.type;
      }
    }
    return null;
  }

  /// Whether any transport is running.
  bool get isRunning => activeTransportType != null;

  /// Registers a transport backend. Call before [start].
  /// BLE should be registered first (so it acts as the default fallback when
  /// LAN is unavailable).
  void registerTransport(MessageTransport transport) {
    _transports.add(transport);
  }

  /// Clears all registered transports (call [stop] first).
  void clearTransports() {
    _transports.clear();
    _peersByTransport.clear();
  }

  /// Sets the Ed25519 key pair used to sign every outgoing message.
  void setSigningKeyPair(SimpleKeyPair keyPair) {
    _signingKeyPair = keyPair;
  }

  /// Starts all registered transports and subscribes to their streams.
  Future<void> start() async {
    for (final transport in _transports) {
      try {
        await transport.start();
        _subscribeToTransport(transport);
      } catch (_) {
        // A single transport failure must not block the others.
      }
    }
  }

  /// Sends a message. Signs it if a key pair is configured.
  ///
  /// Routing strategy:
  ///   - **Broadcasts**: sent via ALL transports (BLE + LAN + Nostr) so every
  ///     reachable peer receives the message regardless of transport type.
  ///   - **Directed messages**: prefer LAN if recipient is reachable via LAN,
  ///     otherwise try transports in registration order (cascade: first success
  ///     wins).
  Future<void> sendMessage(
    NexusMessage message, {
    String? recipientDid,
  }) async {
    var msg = message;

    // Sign if we have a key pair
    if (_signingKeyPair != null) {
      final sigObj = await Ed25519().sign(
        msg.toSignableBytes(),
        keyPair: _signingKeyPair!,
      );
      msg = msg.withSignature(base64.encode(sigObj.bytes));
    }

    // Mark as seen so we don't echo our own messages
    _markSeen(msg.id);

    if (msg.isBroadcast) {
      // Broadcasts are delivered on every transport – do not cascade-stop.
      // BLE reaches nearby BLE peers, LAN reaches local network peers,
      // Nostr reaches internet peers.  Failures on individual transports are
      // suppressed so one bad transport does not block the others.
      debugPrint('[TRANSPORT] Broadcast fan-out → ${_transports.length} transports');
      for (final transport in _transports) {
        if (transport.state == TransportState.error) {
          debugPrint('[TRANSPORT]   skip ${transport.type} (error state)');
          continue;
        }
        try {
          await transport.sendMessage(msg);
          debugPrint('[TRANSPORT]   ✓ ${transport.type}');
        } catch (e) {
          debugPrint('[TRANSPORT]   ✗ ${transport.type}: $e');
        }
      }
      return;
    }

    // Directed message: cascade – first transport that delivers successfully wins.
    final ordered = _buildTransportOrder(recipientDid);

    for (final transport in ordered) {
      if (transport.state == TransportState.error) continue;
      try {
        await transport.sendMessage(msg, recipientDid: recipientDid);
        return;
      } catch (_) {
        continue;
      }
    }
    throw StateError(
      'No transport available. Register and start at least one transport.',
    );
  }

  /// Stops all transports and cancels subscriptions.
  Future<void> stop() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    for (final transport in _transports) {
      try {
        await transport.stop();
      } catch (_) {}
    }
    _peers.clear();
    _peersByTransport.clear();
  }

  // ── Routing helpers ────────────────────────────────────────────────────────

  /// Returns transports sorted so that LAN comes first for a directed message
  /// if (and only if) the recipient is currently visible via LAN.
  List<MessageTransport> _buildTransportOrder(String? recipientDid) {
    if (recipientDid == null) return List.from(_transports);

    final lanTransports = _transports.where((t) =>
        t.type == TransportType.lan &&
        t.state != TransportState.error &&
        t.currentPeers.any((p) => p.did == recipientDid)).toList();

    if (lanTransports.isEmpty) return List.from(_transports);

    final rest = _transports.where((t) => !lanTransports.contains(t)).toList();
    return [...lanTransports, ...rest];
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  void _subscribeToTransport(MessageTransport transport) {
    // Incoming messages
    _subs.add(transport.onMessageReceived.listen((msg) {
      if (msg.isExpired) return;
      if (_isDuplicate(msg.id)) return;
      _messageController.add(msg);
    }));

    // Peer list updates
    _subs.add(transport.onPeersChanged.listen((peers) {
      _mergePeerUpdate(transport.type, peers);
    }));
  }

  void _mergePeerUpdate(
    TransportType transportType,
    List<NexusPeer> updatedPeers,
  ) {
    final newDids = updatedPeers.map((p) => p.did).toSet();
    final oldDids = _peersByTransport[transportType] ?? const <String>{};

    // Update the per-transport DID set
    _peersByTransport[transportType] = newDids;

    // Handle peers that disappeared from this transport
    for (final removedDid in oldDids.difference(newDids)) {
      final existing = _peers[removedDid];
      if (existing == null) continue;

      final remaining = Set<TransportType>.from(existing.availableTransports)
        ..remove(transportType);

      if (remaining.isEmpty) {
        _peers.remove(removedDid);
      } else {
        // Demote to the next best transport
        final newPrimary = _preferredType(remaining);
        _peers[removedDid] = existing.copyWith(
          transportType: newPrimary,
          availableTransports: remaining,
        );
      }
    }

    // Add / update peers reported by this transport
    for (final peer in updatedPeers) {
      final existing = _peers[peer.did];
      final allTransports = <TransportType>{
        ...(existing?.availableTransports ?? const <TransportType>{}),
        transportType,
      };
      final primary = _preferredType(allTransports);

      _peers[peer.did] = NexusPeer(
        did: peer.did,
        pseudonym: peer.pseudonym,
        transportType: primary,
        availableTransports: allTransports,
        signalStrength: peer.signalStrength ?? existing?.signalStrength,
        lastSeen: peer.lastSeen,
      );
    }

    _evictStalePeers();
    _peersController.add(List.from(_peers.values));
  }

  /// Returns the preferred primary transport type from a set of available ones.
  /// Priority: LAN > BLE > Nostr > others.
  static TransportType _preferredType(Set<TransportType> types) {
    if (types.contains(TransportType.lan)) return TransportType.lan;
    if (types.contains(TransportType.ble)) return TransportType.ble;
    if (types.contains(TransportType.nostr)) return TransportType.nostr;
    return types.first;
  }

  bool _isDuplicate(String msgId) {
    if (_seenIds.contains(msgId)) return true;
    _markSeen(msgId);
    return false;
  }

  void _markSeen(String msgId) {
    if (_seenIds.length >= _maxSeenIds) {
      final toRemove = _seenIds.take(_maxSeenIds ~/ 2).toList();
      _seenIds.removeAll(toRemove);
    }
    _seenIds.add(msgId);
  }

  void _evictStalePeers() {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 5));
    _peers.removeWhere((_, peer) => peer.lastSeen.isBefore(cutoff));
  }
}
