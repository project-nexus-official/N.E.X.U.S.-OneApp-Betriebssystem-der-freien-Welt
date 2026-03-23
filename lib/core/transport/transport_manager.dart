import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'message_transport.dart';
import 'nexus_message.dart';
import 'nexus_peer.dart';

/// Manages all registered transport backends with automatic fallback.
///
/// Fallback cascade (registration order):
///   BLE (preferred, offline-first) → Nostr (internet) → LoRa → …
///
/// Responsibilities:
///   - Start / stop all transports.
///   - Merge peer lists and message streams across all transports.
///   - Deduplicate incoming messages by ID.
///   - Sign outgoing messages with the node's Ed25519 key pair.
///   - Relay messages via the best available transport.
///
/// Usage:
/// ```dart
/// final manager = TransportManager.instance;
/// manager.registerTransport(BleTransport(myDid));
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
  /// Register in fallback priority order (BLE first, Nostr second, …).
  void registerTransport(MessageTransport transport) {
    _transports.add(transport);
  }

  /// Clears all registered transports (call [stop] first).
  void clearTransports() => _transports.clear();

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
  /// Tries transports in registration order; falls back to the next one
  /// if the preferred transport is unavailable.
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

    // Try transports in order (fallback cascade)
    for (final transport in _transports) {
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
      for (final peer in peers) {
        _peers[peer.did] = peer;
      }
      _evictStalePeers();
      _peersController.add(List.from(_peers.values));
    }));
  }

  bool _isDuplicate(String msgId) {
    if (_seenIds.contains(msgId)) return true;
    _markSeen(msgId);
    return false;
  }

  void _markSeen(String msgId) {
    if (_seenIds.length >= _maxSeenIds) {
      // Simple eviction: remove half the oldest entries
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
