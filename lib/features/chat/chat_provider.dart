import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';

import '../../core/contacts/contact_service.dart';
import '../../core/crypto/encryption_keys.dart';
import '../../core/crypto/message_encryption.dart';
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
import '../../services/background_service.dart';
import '../../services/notification_service.dart';
import '../../shared/widgets/notification_banner.dart';
import 'conversation_service.dart';
import 'group_channel.dart';
import 'group_channel_service.dart';

/// ViewModel for the chat feature.
///
/// Responsibilities:
///   - Request runtime permissions (Android only).
///   - Initialize and start [TransportManager] with [BleTransport] (mobile)
///     and [LanTransport] (all platforms).
///   - Forward incoming [NexusMessage]s to the UI and persist them in the POD.
///   - Expose a per-conversation message list and peer list.
///   - Notify [ConversationService] on every message event.
class ChatProvider extends ChangeNotifier with WidgetsBindingObserver {
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

  static const String _nostrTimestampKey = 'last_nostr_timestamp_seconds';

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

  /// Re-publishes Kind-0 metadata and presence with the current effective
  /// pseudonym. Call this immediately after the user saves a new display name
  /// so peers see the update without waiting for the next heartbeat.
  Future<void> republishIdentity() => _nostrTransport?.republishMetadata() ?? Future.value();

  List<NexusPeer> get peers => _manager.peers;

  // Per-conversation cached messages
  final Map<String, List<NexusMessage>> _conversationCache = {};

  // Tracks which convIds have been merged with the DB at least once.
  final Set<String> _cacheLoadedFromDb = {};

  // Notification state
  bool _appInForeground = true;
  String? _activeConversationId;

  // Subscriptions
  StreamSubscription<NexusMessage>? _msgSub;
  StreamSubscription<List<NexusPeer>>? _peersSub;
  StreamSubscription<Map<String, dynamic>>? _channelAnnouncedSub;

  // ── Initialization ─────────────────────────────────────────────────────────

  /// Requests permissions (Android only) and starts the transport stack.
  ///
  /// Safe to call multiple times; subsequent calls are no-ops if already
  /// initialized.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    WidgetsBinding.instance.addObserver(this);

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
      _msgSub = _manager.onMessageReceived.listen((msg) => _onMessageReceived(msg));
      _peersSub = _manager.onPeersChanged.listen((_) => notifyListeners());

      await _manager.start();
      _running = true;
      _error = null;

      // Restore timestamp BEFORE initNostrKeys so that the very first
      // _setupSubscriptions() call already uses the correct since value.
      // (initNostrKeys → initKeys → _setupSubscriptions inside NostrTransport)
      await _restoreNostrTimestamp();
      await _initNostrKeys(identity);
      await _initEncryptionKeys();
      await _startNostrIfConnected();
      _watchConnectivity();
      await _initChannels(identity.did);
    } catch (e) {
      _error = 'Fehler beim Starten: $e';
      _running = false;
    }

    notifyListeners();
  }

  Future<void> _initChannels(String myDid) async {
    try {
      await GroupChannelService.instance.load();
      await GroupChannelService.instance.ensureDefaults(myDid);

      // Subscribe Nostr to each joined channel.
      for (final ch in GroupChannelService.instance.joinedChannels) {
        _nostrTransport?.subscribeToChannel(ch.nostrTag);
      }

      // Listen for newly discovered channels via Kind-40.
      _channelAnnouncedSub?.cancel();
      if (_nostrTransport != null) {
        _channelAnnouncedSub =
            _nostrTransport!.onChannelAnnounced.listen(_onChannelAnnounced);
      }

      // Re-subscribe when channel list changes (join/leave).
      GroupChannelService.instance.joinedStream.listen((channels) {
        for (final ch in channels) {
          _nostrTransport?.subscribeToChannel(ch.nostrTag);
        }
      });
    } catch (e) {
      debugPrint('[CHAT] Channel init failed: $e');
    }
  }

  void _onChannelAnnounced(Map<String, dynamic> data) {
    try {
      final name = data['name'] as String?;
      final nostrTag = data['nostrTag'] as String?;
      if (name == null || nostrTag == null) return;
      final channel = GroupChannel(
        id: data['id'] as String? ?? nostrTag,
        name: GroupChannel.normaliseName(name),
        description: (data['description'] as String?) ?? '',
        createdBy: (data['createdBy'] as String?) ?? '',
        createdAt: data['_created_at'] != null
            ? DateTime.fromMillisecondsSinceEpoch(
                (data['_created_at'] as int) * 1000,
                isUtc: true,
              )
            : DateTime.now().toUtc(),
        nostrTag: nostrTag,
      );
      GroupChannelService.instance.addDiscoveredFromNostr(channel);
    } catch (e) {
      debugPrint('[CHAT] Channel announced parse error: $e');
    }
  }

  Future<void> _initNostrKeys(dynamic identity) async {
    try {
      final mnemonic = await IdentityService.instance.loadSeedPhrase();
      if (mnemonic == null) return;
      final seed64 = Bip39.mnemonicToSeed(mnemonic);
      await _nostrTransport?.initKeys(seed64);
    } catch (_) {}
  }

  Future<void> _initEncryptionKeys() async {
    try {
      final ed25519Bytes = await IdentityService.instance.getEd25519PrivateBytes();
      if (ed25519Bytes == null) return;
      await EncryptionKeys.instance.initFromEd25519Private(ed25519Bytes);
      final pubHex = EncryptionKeys.instance.publicKeyHex;
      if (pubHex != null) {
        _nostrTransport?.setEncryptionPublicKey(pubHex);
      }
    } catch (e) {
      debugPrint('[CRYPTO] Encryption key init failed: $e');
    }
  }

  /// Loads the last message timestamp from SharedPreferences and passes it to
  /// the Nostr transport so subscriptions start from the right point.
  /// Must be called BEFORE [_initNostrKeys] so subscriptions are correct from
  /// the very first [_setupSubscriptions] call.
  Future<void> _restoreNostrTimestamp() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ts = prefs.getInt(_nostrTimestampKey);
      final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      if (ts != null) {
        _nostrTransport?.setLastMessageTimestamp(ts);
        final age = nowSec - ts;
        debugPrint('[SYNC] Last seen timestamp: $ts  '
            '(${age}s ago = ${(age / 3600).toStringAsFixed(1)}h)');
        debugPrint('[SYNC] Subscribing with since: ${ts - 60}  (buffer 60s)');
      } else {
        debugPrint('[SYNC] No saved timestamp – defaulting to since=${nowSec - 86400} '
            '(last 24 h)');
      }
    } catch (e) {
      debugPrint('[SYNC] Failed to restore timestamp: $e');
    }
  }

  /// Saves [timestamp] as the new high-water mark for Nostr message fetch.
  Future<void> _saveNostrTimestamp(DateTime timestamp) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final epochSec = timestamp.millisecondsSinceEpoch ~/ 1000;
      final saved = prefs.getInt(_nostrTimestampKey) ?? 0;
      if (epochSec > saved) {
        await prefs.setInt(_nostrTimestampKey, epochSec);
        debugPrint('[SYNC] Saved new high-water timestamp: $epochSec');
      }
    } catch (e) {
      debugPrint('[SYNC] Failed to save timestamp: $e');
    }
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

  // ── App lifecycle & notification helpers ───────────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInForeground = state == AppLifecycleState.resumed;
    if (Platform.isAndroid) {
      if (_appInForeground) {
        BackgroundServiceManager.instance.pauseNostr();
      } else {
        BackgroundServiceManager.instance.resumeNostr();
      }
    }
  }

  /// Sets the conversation currently visible in the UI so that in-app banners
  /// are suppressed for that conversation.
  void setActiveConversation(String? id) => _activeConversationId = id;

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

  Future<void> _onMessageReceived(NexusMessage msg) async {
    // Silent block: discard messages from blocked peers without any feedback.
    if (!msg.isBroadcast &&
        ContactService.instance.isBlocked(msg.fromDid)) {
      debugPrint('[CHAT] Message from blocked peer dropped: ${msg.fromDid}');
      return;
    }

    // Track the latest message timestamp so Nostr can catch up on missed
    // messages after the next app restart.
    unawaited(_saveNostrTimestamp(msg.timestamp));

    // ── Key exchange: learn sender's encryption key ──────────────────────────
    final encKeyFromMsg = msg.metadata?['enc_key'] as String?;
    if (encKeyFromMsg != null && !msg.isBroadcast) {
      ContactService.instance.setEncryptionKey(msg.fromDid, encKeyFromMsg);
    }

    // ── Decrypt if encrypted ─────────────────────────────────────────────────
    NexusMessage processedMsg = msg;
    if (msg.metadata?['encrypted'] == true && !msg.isBroadcast) {
      final senderEncKeyHex =
          encKeyFromMsg ?? ContactService.instance.findByDid(msg.fromDid)?.encryptionPublicKey;
      if (senderEncKeyHex != null) {
        final plaintext = await MessageEncryption.decrypt(
          msg.body,
          recipientKeyPair: EncryptionKeys.instance.keyPair,
          senderPublicKeyBytes: EncryptionKeys.hexToBytes(senderEncKeyHex),
        );
        if (plaintext != null) {
          // Rebuild message with decrypted body
          processedMsg = NexusMessage(
            id: msg.id,
            fromDid: msg.fromDid,
            toDid: msg.toDid,
            type: msg.type,
            channel: msg.channel,
            body: plaintext,
            timestamp: msg.timestamp,
            ttlHours: msg.ttlHours,
            hopCount: msg.hopCount,
            signature: msg.signature,
            metadata: {
              ...?msg.metadata,
              'encrypted': true, // preserve flag for UI lock icon
            },
          );
        } else {
          // Decryption failed: show placeholder
          processedMsg = NexusMessage(
            id: msg.id,
            fromDid: msg.fromDid,
            toDid: msg.toDid,
            type: msg.type,
            channel: msg.channel,
            body: '[Nachricht konnte nicht entschlüsselt werden]',
            timestamp: msg.timestamp,
            ttlHours: msg.ttlHours,
            hopCount: msg.hopCount,
            signature: msg.signature,
            metadata: msg.metadata,
          );
        }
      }
    }

    final myDid = IdentityService.instance.currentIdentity?.did ?? '';

    // Determine conversation ID:
    //   - broadcast / #mesh → NexusMessage.broadcastDid ("broadcast")
    //   - named group channel (channel != '#mesh' and starts with '#') → channel name
    //   - DM → sorted DID pair
    final String convId;
    if (processedMsg.isBroadcast) {
      final ch = processedMsg.channel;
      if (ch != null && ch != '#mesh' && ch.startsWith('#')) {
        convId = ch; // e.g. "#teneriffa"
      } else {
        convId = NexusMessage.broadcastDid;
      }
    } else {
      convId = _conversationId(processedMsg.fromDid, myDid);
    }

    debugPrint('[CHAT] Message received: convId=$convId  from=${processedMsg.fromDid}');

    _conversationCache.putIfAbsent(convId, () => []);
    final cache = _conversationCache[convId]!;
    if (cache.any((m) => m.id == processedMsg.id)) {
      debugPrint('[CHAT] Duplicate message dropped (already in cache): ${processedMsg.id}');
      return;
    }

    // For received voice messages: decode the base64 audio and save it to a
    // permanent local file so playback survives app restarts and temp-dir
    // clean-ups.  This runs for both live and catch-up messages.
    if (processedMsg.type == NexusMessageType.voice) {
      processedMsg = await _cacheVoiceAudio(processedMsg);
    }

    cache.add(processedMsg);

    // Persist first, then notify so the DB query in notifyUpdate() finds the
    // new message (avoids a race condition where the query runs before the
    // INSERT completes).
    _persistMessage(convId, processedMsg).then((_) {
      debugPrint('[CHAT] Persisted → notifying ConversationService');
      ConversationService.instance.notifyUpdate();
    });

    // ── Notifications ────────────────────────────────────────────────────────
    // Don't notify if this exact conversation is open in the UI.
    if (_activeConversationId != convId) {
      final contact = ContactService.instance.findByDid(processedMsg.fromDid);
      final muted = !processedMsg.isBroadcast && (contact?.muted ?? false);

      if (!muted) {
        final senderName = contact?.pseudonym ??
            (processedMsg.fromDid.length > 12
                ? processedMsg.fromDid.substring(processedMsg.fromDid.length - 12)
                : processedMsg.fromDid);
        final preview = switch (processedMsg.type) {
          NexusMessageType.image => '\u{1F4F7} Foto',
          NexusMessageType.voice => '\u{1F3A4} Sprachnachricht',
          _ => processedMsg.body.length > 100
              ? '${processedMsg.body.substring(0, 100)}…'
              : processedMsg.body,
        };

        if (_appInForeground) {
          // In-app banner
          InAppNotificationController.instance.show(InAppBannerData(
            senderName: processedMsg.isBroadcast ? '#mesh' : senderName,
            preview: preview,
            conversationId: convId,
            isBroadcast: processedMsg.isBroadcast,
          ));
        } else {
          // System notification
          if (processedMsg.isBroadcast) {
            NotificationService.instance.showBroadcastNotification(
              senderName: senderName,
              messagePreview: preview,
            );
          } else {
            NotificationService.instance.showMessageNotification(
              senderDid: processedMsg.fromDid,
              senderName: senderName,
              messagePreview: preview,
              conversationId: convId,
            );
          }
        }
      }
    }

    notifyListeners();
  }

  Future<void> _persistMessage(String convId, NexusMessage msg) async {
    try {
      await PodDatabase.instance.insertMessage(
        conversationId: convId,
        senderDid: msg.fromDid,
        data: msg.toJson(),
      );
      debugPrint('[CHAT] DB insert OK: convId=$convId');
    } catch (e) {
      debugPrint('[CHAT] DB insert FAILED: $e');
    }
  }

  /// Decodes the base64 voice audio from [msg.body] into a permanent local
  /// file (app documents directory) and returns a new message with
  /// [audio_local_path] in its metadata.
  ///
  /// Returns [msg] unchanged on error or if a valid local path already exists.
  /// Skips messages whose body starts with '[' (decryption-error placeholder).
  Future<NexusMessage> _cacheVoiceAudio(NexusMessage msg) async {
    // Skip decryption-error placeholders.
    if (msg.body.startsWith('[')) return msg;

    // Already cached.
    final existing = msg.metadata?['audio_local_path'] as String?;
    if (existing != null && File(existing).existsSync()) return msg;

    try {
      final audioBytes = base64Decode(msg.body);
      final dir = await getApplicationDocumentsDirectory();
      // Use .m4a for AAC recordings (Android/iOS) and .wav for desktop.
      final ext = (Platform.isAndroid || Platform.isIOS) ? 'm4a' : 'wav';
      final path = '${dir.path}/nexus_voice_${msg.id}.$ext';
      await File(path).writeAsBytes(audioBytes);
      debugPrint('[CHAT] Voice audio cached → $path');

      return NexusMessage(
        id: msg.id,
        fromDid: msg.fromDid,
        toDid: msg.toDid,
        type: msg.type,
        channel: msg.channel,
        body: msg.body,
        timestamp: msg.timestamp,
        ttlHours: msg.ttlHours,
        hopCount: msg.hopCount,
        signature: msg.signature,
        metadata: {
          ...?msg.metadata,
          'audio_local_path': path,
        },
      );
    } catch (e) {
      debugPrint('[CHAT] Voice audio cache failed: $e');
      return msg;
    }
  }

  // ── Sending ────────────────────────────────────────────────────────────────

  /// Sends a direct text message to [recipientDid].
  Future<void> sendMessage(
    String recipientDid,
    String text, {
    NexusMessage? replyTo,
    String? replyToSenderName,
  }) async {
    final myDid = IdentityService.instance.currentIdentity?.did ?? 'unknown';
    final contact = ContactService.instance.findByDid(recipientDid);
    final recipientEncKey = contact?.encryptionPublicKey;
    final myEncKeyHex = EncryptionKeys.instance.publicKeyHex;

    // Base metadata includes our encryption public key so the recipient can
    // start encrypting to us on their next message even if they had no key yet.
    final baseMeta = myEncKeyHex != null ? {'enc_key': myEncKeyHex} : null;

    // Add reply metadata if replying to a message
    Map<String, dynamic>? replyMeta;
    if (replyTo != null) {
      final isImg = replyTo.type == NexusMessageType.image;
      final isVoice = replyTo.type == NexusMessageType.voice;
      replyMeta = {
        'reply_to_id': replyTo.id,
        'reply_to_sender': replyToSenderName ?? replyTo.fromDid,
        'reply_to_preview': isImg
            ? 'Foto'
            : isVoice
                ? 'Sprachnachricht'
                : replyTo.body.substring(0, replyTo.body.length.clamp(0, 100)),
        if (isImg) 'reply_to_image': true,
        if (isVoice) 'reply_to_voice': true,
      };
    }

    // Local message (always plaintext – what we display and persist locally).
    final localMsg = NexusMessage.create(
      fromDid: myDid,
      toDid: recipientDid,
      body: text,
      metadata: {
        ...?baseMeta,
        if (recipientEncKey != null) 'encrypted': true,
        ...?replyMeta,
      }.isNotEmpty
          ? {
              ...?baseMeta,
              if (recipientEncKey != null) 'encrypted': true,
              ...?replyMeta,
            }
          : null,
    );

    // Transport message: encrypted body when the recipient's key is known,
    // otherwise identical to the local message.
    NexusMessage transportMsg = localMsg;
    if (recipientEncKey != null) {
      final encryptedBody = await MessageEncryption.encrypt(
        text,
        senderKeyPair: EncryptionKeys.instance.keyPair,
        recipientPublicKeyBytes: EncryptionKeys.hexToBytes(recipientEncKey),
      );
      if (encryptedBody != null) {
        transportMsg = NexusMessage(
          id: localMsg.id,
          fromDid: localMsg.fromDid,
          toDid: localMsg.toDid,
          type: localMsg.type,
          channel: localMsg.channel,
          body: encryptedBody,
          timestamp: localMsg.timestamp,
          ttlHours: localMsg.ttlHours,
          hopCount: localMsg.hopCount,
          signature: localMsg.signature,
          metadata: {
            ...?baseMeta,
            'encrypted': true,
            ...?replyMeta,
          },
        );
      }
    }

    await _manager.sendMessage(transportMsg, recipientDid: recipientDid);

    // Optimistic local cache update – always use plaintext local message.
    final convId = _conversationId(recipientDid, myDid);
    _conversationCache.putIfAbsent(convId, () => []);
    _conversationCache[convId]!.add(localMsg);
    await _persistMessage(convId, localMsg);
    ConversationService.instance.notifyUpdate();

    notifyListeners();
  }

  /// Sends a broadcast message to the #mesh channel.
  Future<void> sendBroadcast(
    String text, {
    NexusMessage? replyTo,
    String? replyToSenderName,
  }) async {
    final myDid = IdentityService.instance.currentIdentity?.did ?? 'unknown';

    Map<String, dynamic>? replyMeta;
    if (replyTo != null) {
      final isImg = replyTo.type == NexusMessageType.image;
      final isVoice = replyTo.type == NexusMessageType.voice;
      replyMeta = {
        'reply_to_id': replyTo.id,
        'reply_to_sender': replyToSenderName ?? replyTo.fromDid,
        'reply_to_preview': isImg
            ? 'Foto'
            : isVoice
                ? 'Sprachnachricht'
                : replyTo.body.substring(0, replyTo.body.length.clamp(0, 100)),
        if (isImg) 'reply_to_image': true,
        if (isVoice) 'reply_to_voice': true,
      };
    }

    final msg = NexusMessage.create(
      fromDid: myDid,
      toDid: NexusMessage.broadcastDid,
      body: text,
      channel: '#mesh',
      metadata: {
        if (EncryptionKeys.instance.publicKeyHex != null)
          'enc_key': EncryptionKeys.instance.publicKeyHex!,
        ...?replyMeta,
      }.isNotEmpty
          ? {
              if (EncryptionKeys.instance.publicKeyHex != null)
                'enc_key': EncryptionKeys.instance.publicKeyHex!,
              ...?replyMeta,
            }
          : null,
    );

    await _manager.sendMessage(msg);

    _conversationCache.putIfAbsent(NexusMessage.broadcastDid, () => []);
    _conversationCache[NexusMessage.broadcastDid]!.add(msg);
    await _persistMessage(NexusMessage.broadcastDid, msg);
    ConversationService.instance.notifyUpdate();

    notifyListeners();
  }

  /// Sends a text message to a named group channel (e.g. "#teneriffa").
  Future<void> sendToChannel(String channelName, String text) async {
    final myDid = IdentityService.instance.currentIdentity?.did ?? 'unknown';
    final name =
        channelName.startsWith('#') ? channelName : '#$channelName';

    final msg = NexusMessage.create(
      fromDid: myDid,
      toDid: NexusMessage.broadcastDid,
      body: text,
      channel: name,
    );

    await _manager.sendMessage(msg);

    _conversationCache.putIfAbsent(name, () => []);
    _conversationCache[name]!.add(msg);
    await _persistMessage(name, msg);
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
        if (EncryptionKeys.instance.publicKeyHex != null)
          'enc_key': EncryptionKeys.instance.publicKeyHex,
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

  /// Sends a voice message to [recipientDid].
  ///
  /// [filePath] – local path to the recorded audio file.
  /// [durationMs] – recording length in milliseconds (shown in the bubble).
  ///
  /// The audio file is read as bytes, base64-encoded, and encrypted with the
  /// same X25519/AES-256-GCM scheme used for text messages when a key is known.
  Future<void> sendVoice(
    String recipientDid,
    String filePath,
    int durationMs, {
    NexusMessage? replyTo,
    String? replyToSenderName,
  }) async {
    final myDid = IdentityService.instance.currentIdentity?.did ?? 'unknown';
    final contact = ContactService.instance.findByDid(recipientDid);
    final recipientEncKey = contact?.encryptionPublicKey;
    final myEncKeyHex = EncryptionKeys.instance.publicKeyHex;

    final file = File(filePath);
    if (!file.existsSync()) return;
    final Uint8List audioBytes = await file.readAsBytes();
    final audioBase64 = base64Encode(audioBytes);

    Map<String, dynamic>? replyMeta;
    if (replyTo != null) {
      final isImg = replyTo.type == NexusMessageType.image;
      final isVoice = replyTo.type == NexusMessageType.voice;
      replyMeta = {
        'reply_to_id': replyTo.id,
        'reply_to_sender': replyToSenderName ?? replyTo.fromDid,
        'reply_to_preview': isImg ? 'Foto' : isVoice ? 'Sprachnachricht' : replyTo.body.substring(0, replyTo.body.length.clamp(0, 100)),
        if (isImg) 'reply_to_image': true,
        if (isVoice) 'reply_to_voice': true,
      };
    }

    // Local message: plaintext body + local audio path.  'encrypted' flag
    // shown as lock icon in the UI when the message was (or will be) sent E2E.
    final localMsg = NexusMessage.create(
      fromDid: myDid,
      toDid: recipientDid,
      type: NexusMessageType.voice,
      body: audioBase64,
      metadata: {
        'duration_ms': durationMs,
        'audio_local_path': filePath,
        if (myEncKeyHex != null) 'enc_key': myEncKeyHex,
        if (recipientEncKey != null) 'encrypted': true,
        ...?replyMeta,
      },
    );

    // Transport message: omits the local file path; body is encrypted when
    // the recipient's key is known.  If encryption fails for any reason the
    // audio is still sent unencrypted (NIP-04 / LAN outer layer still applies)
    // WITHOUT the 'encrypted' flag so the receiver does not try to decrypt it.
    final transportBaseMeta = <String, dynamic>{
      'duration_ms': durationMs,
      if (myEncKeyHex != null) 'enc_key': myEncKeyHex,
      ...?replyMeta,
    };

    NexusMessage transportMsg = NexusMessage(
      id: localMsg.id,
      fromDid: localMsg.fromDid,
      toDid: localMsg.toDid,
      type: NexusMessageType.voice,
      body: audioBase64,
      timestamp: localMsg.timestamp,
      ttlHours: localMsg.ttlHours,
      hopCount: localMsg.hopCount,
      metadata: transportBaseMeta,
    );

    if (recipientEncKey != null) {
      final encryptedBody = await MessageEncryption.encrypt(
        audioBase64,
        senderKeyPair: EncryptionKeys.instance.keyPair,
        recipientPublicKeyBytes: EncryptionKeys.hexToBytes(recipientEncKey),
      );
      if (encryptedBody != null) {
        transportMsg = NexusMessage(
          id: localMsg.id,
          fromDid: localMsg.fromDid,
          toDid: localMsg.toDid,
          type: NexusMessageType.voice,
          body: encryptedBody,
          timestamp: localMsg.timestamp,
          ttlHours: localMsg.ttlHours,
          hopCount: localMsg.hopCount,
          metadata: {
            ...transportBaseMeta,
            'encrypted': true,
          },
        );
      }
      // If encryptedBody is null the plaintext transportMsg above is used.
      // No 'encrypted' flag → receiver plays audio directly.
    }

    await _manager.sendMessage(transportMsg, recipientDid: recipientDid);

    final convId = _conversationId(recipientDid, myDid);
    _conversationCache.putIfAbsent(convId, () => []);
    _conversationCache[convId]!.add(localMsg);
    await _persistMessage(convId, localMsg);
    ConversationService.instance.notifyUpdate();

    notifyListeners();
  }

  /// Sends a voice broadcast to the #mesh channel (no E2E encryption).
  Future<void> sendVoiceBroadcast(
    String filePath,
    int durationMs, {
    NexusMessage? replyTo,
    String? replyToSenderName,
  }) async {
    final myDid = IdentityService.instance.currentIdentity?.did ?? 'unknown';

    final file = File(filePath);
    if (!file.existsSync()) return;
    final Uint8List audioBytes = await file.readAsBytes();
    final audioBase64 = base64Encode(audioBytes);

    Map<String, dynamic>? replyMeta;
    if (replyTo != null) {
      final isVoice = replyTo.type == NexusMessageType.voice;
      replyMeta = {
        'reply_to_id': replyTo.id,
        'reply_to_sender': replyToSenderName ?? replyTo.fromDid,
        'reply_to_preview': replyTo.type == NexusMessageType.image
            ? 'Foto'
            : isVoice
                ? 'Sprachnachricht'
                : replyTo.body.substring(0, replyTo.body.length.clamp(0, 100)),
        if (replyTo.type == NexusMessageType.image) 'reply_to_image': true,
        if (isVoice) 'reply_to_voice': true,
      };
    }

    final msg = NexusMessage.create(
      fromDid: myDid,
      toDid: NexusMessage.broadcastDid,
      type: NexusMessageType.voice,
      body: audioBase64,
      channel: '#mesh',
      metadata: {
        'duration_ms': durationMs,
        'audio_local_path': filePath,
        if (EncryptionKeys.instance.publicKeyHex != null)
          'enc_key': EncryptionKeys.instance.publicKeyHex!,
        ...?replyMeta,
      },
    );

    await _manager.sendMessage(msg);

    _conversationCache.putIfAbsent(NexusMessage.broadcastDid, () => []);
    _conversationCache[NexusMessage.broadcastDid]!.add(msg);
    await _persistMessage(NexusMessage.broadcastDid, msg);
    ConversationService.instance.notifyUpdate();

    notifyListeners();
  }

  /// Deletes all messages in [conversationId] from cache and POD.
  Future<void> deleteConversation(String conversationId) async {
    _conversationCache.remove(conversationId);
    _cacheLoadedFromDb.remove(conversationId);
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

  /// Returns messages for [convId].
  ///
  /// On first access per convId, loads from DB and merges with any in-memory
  /// messages accumulated before the load (e.g. messages received during app
  /// startup before the UI opened the conversation).  Subsequent calls return
  /// the merged cache directly without hitting the DB again.
  Future<List<NexusMessage>> getMessages(String convId) async {
    if (!_cacheLoadedFromDb.contains(convId)) {
      await _loadAndMergeFromDb(convId);
    }
    return List.unmodifiable(_conversationCache[convId] ?? []);
  }

  /// Loads messages for [convId] from the DB and merges them with any existing
  /// in-memory messages, deduplicating by message ID and sorting by timestamp.
  Future<void> _loadAndMergeFromDb(String convId) async {
    try {
      final rows = await PodDatabase.instance.listMessages(convId);
      debugPrint('[CHAT] Loading ${rows.length} messages from DB for conv=$convId');
      final dbMsgs = rows.map((row) {
        try {
          return NexusMessage.fromJson(
            Map<String, dynamic>.from(row)
              ..remove('sender_did'),
          );
        } catch (e) {
          debugPrint('[CHAT] Failed to deserialize message from DB: $e');
          return null;
        }
      }).whereType<NexusMessage>().toList();

      // Merge: start with DB messages, then add in-memory messages not in DB.
      final dbIds = dbMsgs.map((m) => m.id).toSet();
      final inMemory = _conversationCache[convId] ?? [];
      final newOnly = inMemory.where((m) => !dbIds.contains(m.id)).toList();

      final merged = [...dbMsgs, ...newOnly]
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

      debugPrint('[CHAT] Merged cache: ${merged.length} messages '
          '(${dbMsgs.length} from DB, ${newOnly.length} in-memory-only) '
          'for conv=$convId');
      _conversationCache[convId] = merged;
      _cacheLoadedFromDb.add(convId);
    } catch (e, st) {
      // On error, mark as loaded so we don't retry on every call, and keep
      // whatever in-memory messages exist.
      debugPrint('[CHAT] _loadAndMergeFromDb failed for conv=$convId: $e\n$st');
      _cacheLoadedFromDb.add(convId);
    }
  }

  /// Clears all in-memory message caches and the DB-loaded tracking set.
  ///
  /// Call this after a bulk deletion (e.g. "delete all messages") so that the
  /// next [getMessages] call reloads from the (now empty) DB.
  void clearAllCaches() {
    _conversationCache.clear();
    _cacheLoadedFromDb.clear();
    notifyListeners();
  }

  // ── Utilities ──────────────────────────────────────────────────────────────

  static String _conversationId(String didA, String didB) {
    final sorted = [didA, didB]..sort();
    return '${sorted[0]}:${sorted[1]}';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
