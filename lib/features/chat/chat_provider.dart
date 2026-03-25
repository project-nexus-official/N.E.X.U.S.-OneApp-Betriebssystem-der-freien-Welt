import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';

import '../../core/identity/bip39.dart';
import '../../core/identity/identity_service.dart';
import '../../core/storage/pod_database.dart';
import '../../core/transport/ble/ble_transport.dart';
import '../../core/transport/lan/lan_transport.dart';
import '../../core/transport/nexus_message.dart';
import '../../core/transport/message_transport.dart';
import '../../core/transport/nexus_peer.dart';
import '../../core/transport/nostr/nostr_keys.dart';
import '../../core/transport/nostr/nostr_transport.dart';
import '../../core/transport/transport_manager.dart';
import 'conversation_service.dart';

/// ViewModel for the chat feature.
///
/// Responsibilities:
///   - Request runtime permissions (Android only).
///   - Initialize and start [TransportManager] with [BleTransport] (mobile)
///     and [LanTransport] (all platforms).
///   - Forward incoming [NexusMessage]s to the UI and persist them in the POD.
///   - Expose a per-conversation message list and peer list.
///   - Notify [ConversationService] on every message event.
class ChatProvider extends ChangeNotifier {
  ChatProvider() : _manager = TransportManager.instance;

  final TransportManager _manager;

  // Direct reference so the UI can call addManualPeer without going through
  // the manager (which doesn't expose transport internals).
  LanTransport? _lanTransport;

  // Nostr transport – started/stopped based on internet connectivity.
  NostrTransport? _nostrTransport;

  // Whether the user has enabled Nostr (persisted via POD).
  bool _nostrEnabled = true;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  // ── State ──────────────────────────────────────────────────────────────────

  bool _initialized = false;
  bool _permissionsGranted = false;
  bool _running = false;
  String? _error;

  bool get initialized => _initialized;
  bool get permissionsGranted => _permissionsGranted;
  bool get running => _running;
  String? get error => _error;

  bool get nostrEnabled => _nostrEnabled;

  /// Direct access to the Nostr transport (for settings screen).
  NostrTransport? get nostrTransport => _nostrTransport;

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

      // Nostr transport – internet fallback; started conditionally below.
      _nostrTransport = NostrTransport(
        localDid: identity.did,
        localPseudonym: identity.pseudonym,
      );
      _manager.registerTransport(_nostrTransport!);

      // Subscribe to events before starting
      _msgSub = _manager.onMessageReceived.listen(_onMessageReceived);
      _peersSub = _manager.onPeersChanged.listen((_) => notifyListeners());

      await _manager.start();
      _running = true;
      _error = null;

      // Derive Nostr keys from seed and start Nostr if internet is available.
      await _initNostrKeys(identity);
      await _startNostrIfConnected();
      _watchConnectivity();
    } catch (e) {
      _error = 'Fehler beim Starten: $e';
      _running = false;
    }

    notifyListeners();
  }

  Future<void> _initNostrKeys(dynamic identity) async {
    try {
      final mnemonic = await IdentityService.instance.loadSeedPhrase();
      if (mnemonic == null) return;
      final seed64 = Bip39.mnemonicToSeed(mnemonic);
      await _nostrTransport?.initKeys(seed64);
    } catch (_) {}
  }

  Future<void> _startNostrIfConnected() async {
    if (!_nostrEnabled) return;
    try {
      final results = await Connectivity().checkConnectivity();
      final hasInternet = _hasInternet(results);
      if (hasInternet && _nostrTransport != null) {
        await _nostrTransport!.start();
        await _tryGetGeohash();
      }
    } catch (_) {}
  }

  void _watchConnectivity() {
    _connectivitySub?.cancel();
    _connectivitySub =
        Connectivity().onConnectivityChanged.listen((results) async {
      if (!_nostrEnabled) return;
      final hasInternet = _hasInternet(results);
      final nostrRunning =
          _nostrTransport?.state == TransportState.connected;

      if (hasInternet && !nostrRunning) {
        try {
          await _nostrTransport?.start();
          await _tryGetGeohash();
          notifyListeners();
        } catch (_) {}
      } else if (!hasInternet && nostrRunning) {
        try {
          await _nostrTransport?.stop();
          notifyListeners();
        } catch (_) {}
      }
    });
  }

  Future<void> _tryGetGeohash() async {
    if (_nostrTransport == null) return;
    try {
      final permission = await Geolocator.checkPermission();
      LocationPermission resolved = permission;
      if (permission == LocationPermission.denied) {
        resolved = await Geolocator.requestPermission();
      }
      if (resolved == LocationPermission.whileInUse ||
          resolved == LocationPermission.always) {
        final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.low,
        );
        _nostrTransport!.currentGeohash =
            geohashEncode(pos.latitude, pos.longitude);
      }
    } catch (_) {
      // Location unavailable – skip geohash
    }
  }

  static bool _hasInternet(List<ConnectivityResult> results) =>
      results.any((r) =>
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.ethernet);

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
        ? NexusMessage.broadcastDid
        : _conversationId(msg.fromDid, myDid);

    _conversationCache.putIfAbsent(convId, () => []);
    _conversationCache[convId]!.add(msg);

    _persistMessage(convId, msg);
    ConversationService.instance.notifyUpdate();

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

  /// Sends a direct text message to [recipientDid].
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
    ConversationService.instance.notifyUpdate();

    notifyListeners();
  }

  /// Sends a broadcast message to the #mesh channel.
  Future<void> sendBroadcast(String text) async {
    final myDid = IdentityService.instance.currentIdentity?.did ?? 'unknown';

    final msg = NexusMessage.create(
      fromDid: myDid,
      toDid: NexusMessage.broadcastDid,
      body: text,
      channel: '#mesh',
    );

    await _manager.sendMessage(msg);

    _conversationCache.putIfAbsent(NexusMessage.broadcastDid, () => []);
    _conversationCache[NexusMessage.broadcastDid]!.add(msg);
    await _persistMessage(NexusMessage.broadcastDid, msg);
    ConversationService.instance.notifyUpdate();

    notifyListeners();
  }

  /// Sends a JPEG image to [recipientDid] (or broadcast if null).
  ///
  /// [imageBytes] should be the raw file bytes of any supported image format.
  /// The image is resized to max 1024 px on the longest side and compressed to
  /// JPEG quality 75.  A 200 px thumbnail is also generated for previews.
  ///
  /// Throws [UnsupportedError] if the image cannot be decoded.
  Future<void> sendImage(
    String recipientDid,
    Uint8List imageBytes,
  ) async {
    final myDid = IdentityService.instance.currentIdentity?.did ?? 'unknown';

    final (base64Full, base64Thumb, width, height) =
        await compute(_processImage, imageBytes);

    final msg = NexusMessage.create(
      fromDid: myDid,
      toDid: recipientDid,
      type: NexusMessageType.image,
      body: base64Full,
      metadata: {
        'width': width,
        'height': height,
        'thumbnail': base64Thumb,
      },
    );

    await _manager.sendMessage(msg, recipientDid: recipientDid);

    final convId = recipientDid == NexusMessage.broadcastDid
        ? NexusMessage.broadcastDid
        : _conversationId(recipientDid, myDid);

    _conversationCache.putIfAbsent(convId, () => []);
    _conversationCache[convId]!.add(msg);
    await _persistMessage(convId, msg);
    ConversationService.instance.notifyUpdate();

    notifyListeners();
  }

  /// Deletes all messages in [conversationId] from cache and POD.
  Future<void> deleteConversation(String conversationId) async {
    _conversationCache.remove(conversationId);
    await ConversationService.instance.deleteConversation(conversationId);
    notifyListeners();
  }

  // ── Manual LAN peer (broadcast-firewall workaround) ───────────────────────

  /// Enables or disables the Nostr transport.
  Future<void> setNostrEnabled(bool enabled) async {
    _nostrEnabled = enabled;
    if (enabled) {
      await _startNostrIfConnected();
    } else {
      await _nostrTransport?.stop();
    }
    notifyListeners();
  }

  /// Adds a custom Nostr relay URL.
  void addNostrRelay(String url) {
    _nostrTransport?.addRelay(url);
    notifyListeners();
  }

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
    _connectivitySub?.cancel();
    _manager.stop();
    super.dispose();
  }
}

// ── Image processing (runs in isolate via compute) ────────────────────────────

/// Resizes and compresses an image for transport.
///
/// Returns (base64Full, base64Thumbnail, width, height).
(String, String, int, int) _processImage(Uint8List rawBytes) {
  final original = img.decodeImage(rawBytes);
  if (original == null) {
    throw UnsupportedError('Ungültiges Bildformat.');
  }

  // Resize to max 1024 px on the longest side
  const maxSize = 1024;
  final img.Image resized;
  if (original.width >= original.height) {
    resized = original.width > maxSize
        ? img.copyResize(original, width: maxSize)
        : original;
  } else {
    resized = original.height > maxSize
        ? img.copyResize(original, height: maxSize)
        : original;
  }

  // Thumbnail – max 200 px on the longest side
  const thumbSize = 200;
  final img.Image thumb;
  if (resized.width >= resized.height) {
    thumb = resized.width > thumbSize
        ? img.copyResize(resized, width: thumbSize)
        : resized;
  } else {
    thumb = resized.height > thumbSize
        ? img.copyResize(resized, height: thumbSize)
        : resized;
  }

  final jpegFull = img.encodeJpg(resized, quality: 75);
  final jpegThumb = img.encodeJpg(thumb, quality: 75);

  return (
    base64Encode(jpegFull),
    base64Encode(jpegThumb),
    resized.width,
    resized.height,
  );
}
