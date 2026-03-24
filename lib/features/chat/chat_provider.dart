import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/identity/identity_service.dart';
import '../../core/storage/pod_database.dart';
import '../../core/transport/ble/ble_transport.dart';
import '../../core/transport/lan/lan_transport.dart';
import '../../core/transport/nexus_message.dart';
import '../../core/transport/nexus_peer.dart';
import '../../core/transport/transport_manager.dart';

/// ViewModel for the chat feature.
///
/// Responsibilities:
///   - Request runtime permissions (Android only).
///   - Initialize and start [TransportManager] with [BleTransport] (mobile)
///     and [LanTransport] (all platforms).
///   - Forward incoming [NexusMessage]s to the UI and persist them in the POD.
///   - Expose a per-conversation message list and peer list.
class ChatProvider extends ChangeNotifier {
  ChatProvider() : _manager = TransportManager.instance;

  final TransportManager _manager;

  // Direct reference so the UI can call addManualPeer without going through
  // the manager (which doesn't expose transport internals).
  LanTransport? _lanTransport;

  // ── State ──────────────────────────────────────────────────────────────────

  bool _initialized = false;
  bool _permissionsGranted = false;
  bool _running = false;
  String? _error;

  bool get initialized => _initialized;
  bool get permissionsGranted => _permissionsGranted;
  bool get running => _running;
  String? get error => _error;

  List<NexusPeer> get peers => _manager.peers;

  // Per-conversation cached messages
  final Map<String, List<NexusMessage>> _conversationCache = {};

  // Subscriptions
  StreamSubscription<NexusMessage>? _msgSub;
  StreamSubscription<List<NexusPeer>>? _peersSub;

  // ── Initialization ─────────────────────────────────────────────────────────

  /// Requests permissions (Android only) and starts the transport stack.
  ///
  /// Safe to call multiple times; subsequent calls are no-ops if already
  /// initialized.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    try {
      _permissionsGranted = await _requestPermissions();
      if (!_permissionsGranted) {
        _error = 'Bluetooth-Berechtigungen verweigert.';
        notifyListeners();
        return;
      }

      final identity = IdentityService.instance.currentIdentity;
      if (identity == null) {
        _error = 'Keine Identität gefunden.';
        notifyListeners();
        return;
      }

      // Set up signing key pair
      final keyPair = await IdentityService.instance.getSigningKeyPair();
      if (keyPair != null) {
        _manager.setSigningKeyPair(keyPair);
      }

      _manager.clearTransports();

      // BLE transport – mobile only (desktop degrades gracefully via timeout,
      // but we skip registration entirely on desktop to avoid plugin issues).
      if (Platform.isAndroid || Platform.isIOS) {
        _manager.registerTransport(
          BleTransport(
            localDid: identity.did,
            localPseudonym: identity.pseudonym,
          ),
        );
      }

      // LAN transport – all platforms (uses dart:io, no extra permissions).
      _lanTransport = LanTransport(
        localDid: identity.did,
        localPseudonym: identity.pseudonym,
      );
      _manager.registerTransport(_lanTransport!);

      // Subscribe to events before starting
      _msgSub = _manager.onMessageReceived.listen(_onMessageReceived);
      _peersSub = _manager.onPeersChanged.listen((_) => notifyListeners());

      await _manager.start();
      _running = true;
      _error = null;
    } catch (e) {
      _error = 'Fehler beim Starten: $e';
      _running = false;
    }

    notifyListeners();
  }

  // ── Permissions ────────────────────────────────────────────────────────────

  Future<bool> _requestPermissions() async {
    // Desktop platforms don't use permission_handler for BLE.
    if (!Platform.isAndroid && !Platform.isIOS) return true;

    final results = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.locationWhenInUse,
    ].request();

    return results.values.every(
      (status) => status == PermissionStatus.granted,
    );
  }

  // ── Incoming messages ──────────────────────────────────────────────────────

  void _onMessageReceived(NexusMessage msg) {
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';

    final convId = msg.isBroadcast
        ? 'broadcast'
        : _conversationId(msg.fromDid, myDid);

    _conversationCache.putIfAbsent(convId, () => []);
    _conversationCache[convId]!.add(msg);

    _persistMessage(convId, msg);

    notifyListeners();
  }

  Future<void> _persistMessage(String convId, NexusMessage msg) async {
    try {
      await PodDatabase.instance.insertMessage(
        conversationId: convId,
        senderDid: msg.fromDid,
        data: msg.toJson(),
      );
    } catch (_) {
      // POD might not be open yet; ignore.
    }
  }

  // ── Sending ────────────────────────────────────────────────────────────────

  /// Sends a direct message to [recipientDid].
  Future<void> sendMessage(String recipientDid, String text) async {
    final myDid = IdentityService.instance.currentIdentity?.did ?? 'unknown';

    final msg = NexusMessage.create(
      fromDid: myDid,
      toDid: recipientDid,
      body: text,
    );

    await _manager.sendMessage(msg, recipientDid: recipientDid);

    // Optimistic local cache update
    final convId = _conversationId(recipientDid, myDid);
    _conversationCache.putIfAbsent(convId, () => []);
    _conversationCache[convId]!.add(msg);
    await _persistMessage(convId, msg);

    notifyListeners();
  }

  // ── Manual LAN peer (broadcast-firewall workaround) ───────────────────────

  /// Adds [ipAddress] as a manual unicast target for LAN discovery.
  ///
  /// Use this when UDP broadcast is blocked by the remote device's firewall
  /// (most commonly Windows with default settings).  Once called, this device
  /// sends unicast UDP announcements directly to that IP.  The remote device
  /// receives them, automatically adds a mutual target, and replies — both
  /// devices discover each other without relying on broadcast.
  void addLanPeer(String ipAddress) {
    _lanTransport?.addManualPeer(ipAddress.trim());
  }

  // ── Message history ────────────────────────────────────────────────────────

  /// Returns cached messages for [convId]. Loads from POD on first access.
  Future<List<NexusMessage>> getMessages(String convId) async {
    if (_conversationCache.containsKey(convId)) {
      return List.unmodifiable(_conversationCache[convId]!);
    }

    try {
      final rows = await PodDatabase.instance.listMessages(convId);
      final msgs = rows.map((row) {
        try {
          return NexusMessage.fromJson(
            Map<String, dynamic>.from(row)
              ..removeWhere((k, _) => k == 'sender_did' || k == 'ts'),
          );
        } catch (_) {
          return null;
        }
      }).whereType<NexusMessage>().toList();

      _conversationCache[convId] = msgs;
      return List.unmodifiable(msgs);
    } catch (_) {
      return const [];
    }
  }

  // ── Utilities ──────────────────────────────────────────────────────────────

  static String _conversationId(String didA, String didB) {
    final sorted = [didA, didB]..sort();
    return '${sorted[0]}:${sorted[1]}';
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _peersSub?.cancel();
    _manager.stop();
    super.dispose();
  }
}
