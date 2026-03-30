import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show AesCbc, MacAlgorithm,
    SecretKey, SecretBox, Mac;

import '../../../core/contacts/contact_service.dart';
import '../../../core/identity/profile_service.dart';
import '../message_transport.dart';
import '../nexus_message.dart';
import '../nexus_peer.dart';
import 'nostr_event.dart';
import 'nostr_keys.dart';
import 'nostr_relay_manager.dart';

/// Internet fallback transport via Nostr protocol (NIP-01, NIP-04, NIP-78).
///
/// - Encrypted DMs (Kind 4 / NIP-04) for peer-to-peer messages.
/// - Public Kind 1 notes tagged with ["t","nexus-mesh"] for #mesh broadcasts.
/// - Kind 30078 presence announcements every [presenceInterval] so peers can
///   discover this node.  Peers that stop announcing for [peerTimeout] are
///   removed from the peer list.
/// - Geohash channel tag is appended to broadcasts and presence events when
///   location is available.
class NostrTransport implements MessageTransport {
  NostrTransport({
    required this.localDid,
    required this.localPseudonym,
    NostrRelayManager? relayManager,
    this.presenceInterval = const Duration(seconds: 30),
    this.peerTimeout = const Duration(minutes: 2),
  }) : _relayManager = relayManager ?? NostrRelayManager();

  final String localDid;
  String localPseudonym;
  final NostrRelayManager _relayManager;

  /// How often to (re)publish a presence announcement.
  final Duration presenceInterval;

  /// How long without a presence announcement before a peer is evicted.
  final Duration peerTimeout;

  NostrKeys? _keys;
  String? _encryptionPublicKeyHex;

  /// Unix timestamp (seconds) of the last received message.
  /// Used as the Nostr subscription `since` filter on startup so that messages
  /// sent while the app was offline are fetched on the next connection.
  int? _lastMessageTimestampSeconds;

  TransportState _state = TransportState.idle;

  final _msgController = StreamController<NexusMessage>.broadcast();
  final _peersController = StreamController<List<NexusPeer>>.broadcast();

  // DID → Nostr pubkey hex (learned from presence / received messages)
  final Map<String, String> _didToNostrPubkey = {};

  // Nostr pubkey hex → NexusPeer
  final Map<String, NexusPeer> _peers = {};

  // Nostr pubkey hex → last presence timestamp (for timeout eviction)
  final Map<String, DateTime> _peerLastPresence = {};

  // Active relay subscriptions
  String? _dmSubId;
  String? _meshSubId;
  String? _presenceSubId;
  String? _metadataSubId;
  String? _channelDiscoverySubId;

  // nostrTag → subscription ID for joined group channels
  final Map<String, String> _channelSubIds = {};

  final _channelAnnouncedController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Emits a channel data map whenever a Kind-40 announcement arrives.
  Stream<Map<String, dynamic>> get onChannelAnnounced =>
      _channelAnnouncedController.stream;

  StreamSubscription<NostrEvent>? _eventSub;
  Timer? _presenceTimer;
  Timer? _metadataRefreshTimer;

  // ── Public API ────────────────────────────────────────────────────────────

  @override
  TransportType get type => TransportType.nostr;

  @override
  TransportState get state => _state;

  @override
  Stream<NexusMessage> get onMessageReceived => _msgController.stream;

  @override
  Stream<List<NexusPeer>> get onPeersChanged => _peersController.stream;

  @override
  List<NexusPeer> get currentPeers => List.unmodifiable(_peers.values);

  /// The Nostr keypair for this node (available after [start]).
  NostrKeys? get keys => _keys;

  /// Current geohash (set by [ChatProvider] after location is obtained).
  String? currentGeohash;

  /// Registers a DID → Nostr pubkey mapping learned from a QR code scan.
  ///
  /// This allows sending DMs to a contact even before their first presence
  /// event is received (e.g. immediately after adding them via QR).
  void registerDidMapping(String did, String nostrPubkeyHex) {
    _didToNostrPubkey[did] = nostrPubkeyHex;
  }

  /// List of relay statuses (URL, state, latency).
  List<RelayStatus> get relayStatuses => _relayManager.statuses;

  /// Adds a custom relay URL.
  void addRelay(String url) => _relayManager.addRelay(url);

  /// Sets the X25519 encryption public key to broadcast in presence events.
  void setEncryptionPublicKey(String hexKey) {
    _encryptionPublicKeyHex = hexKey;
  }

  /// Persists the timestamp of the last received message so that the next
  /// [_setupSubscriptions] call fetches only events newer than this point.
  /// Call this whenever a message is received (from any transport).
  void setLastMessageTimestamp(int epochSeconds) {
    if (_lastMessageTimestampSeconds == null ||
        epochSeconds > _lastMessageTimestampSeconds!) {
      _lastMessageTimestampSeconds = epochSeconds;
    }
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Initialises the Nostr keypair and connects to relays.
  ///
  /// **Idempotent** – safe to call multiple times.  If already connected this
  /// only (re)activates subscriptions when new keys are provided; it never
  /// reconnects relays or creates a second event listener.
  ///
  /// [keysOverride] allows injecting a keypair in tests.
  @override
  Future<void> start({NostrKeys? keysOverride}) async {
    if (keysOverride != null) _keys = keysOverride;

    // ── Already running ────────────────────────────────────────────────────
    // Called a second time (e.g. connectivity watcher or _startNostrIfConnected
    // after _manager.start() already started us).  Just ensure subs are live.
    if (_state == TransportState.connected ||
        _state == TransportState.scanning) {
      if (_keys != null) {
        _setupSubscriptions();
        await _publishMetadata();
        await _sendPresenceAnnouncement();
        _startPresenceTimer();
      }
      return;
    }

    // ── First start ────────────────────────────────────────────────────────
    _state = TransportState.scanning;
    print('[NOSTR] Transport starting…');

    await _relayManager.start();

    // Cancel any stale listener before creating a new one.
    await _eventSub?.cancel();
    _eventSub = _relayManager.onEvent.listen(_onRelayEvent);

    if (_keys != null) {
      _setupSubscriptions();
      await _publishMetadata();
      await _sendPresenceAnnouncement();
      _startPresenceTimer();
    } else {
      print('[NOSTR] No keys yet – subscriptions deferred until initKeys()');
    }

    _state = TransportState.connected;
  }

  /// Derives and stores the Nostr keypair from a BIP-39 seed.
  /// Must be called before the transport can send/receive DMs.
  Future<void> initKeys(Uint8List seed64) async {
    _keys = NostrKeys.fromBip39Seed(seed64);
    print('[NOSTR] Keys initialised, pubkey: ${_keys!.publicKeyHex}');
    if (_state == TransportState.connected) {
      _setupSubscriptions();
      await _publishMetadata();
      await _sendPresenceAnnouncement();
      _startPresenceTimer();
    }
  }

  @override
  Future<void> stop() async {
    _state = TransportState.idle;
    _presenceTimer?.cancel();
    _presenceTimer = null;
    _metadataRefreshTimer?.cancel();
    _metadataRefreshTimer = null;
    if (_dmSubId != null) _relayManager.closeSubscription(_dmSubId!);
    if (_meshSubId != null) _relayManager.closeSubscription(_meshSubId!);
    if (_presenceSubId != null) _relayManager.closeSubscription(_presenceSubId!);
    if (_metadataSubId != null) _relayManager.closeSubscription(_metadataSubId!);
    if (_channelDiscoverySubId != null) {
      _relayManager.closeSubscription(_channelDiscoverySubId!);
    }
    for (final subId in _channelSubIds.values) {
      _relayManager.closeSubscription(subId);
    }
    _channelSubIds.clear();
    await _eventSub?.cancel();
    await _relayManager.stop();
    _peers.clear();
    _peerLastPresence.clear();
  }

  // ── Group channels ────────────────────────────────────────────────────────

  /// Subscribes to Kind-42 messages for the given Nostr tag (channel).
  void subscribeToChannel(String nostrTag) {
    if (_keys == null) return;
    if (_channelSubIds.containsKey(nostrTag)) return; // already subscribed
    final nowSeconds =
        DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final since = _lastMessageTimestampSeconds != null
        ? _lastMessageTimestampSeconds! - 60
        : nowSeconds - 86400;
    final subId = _relayManager.subscribe({
      'kinds': [NostrKind.channelMessage],
      '#t': [nostrTag],
      'since': since,
    });
    _channelSubIds[nostrTag] = subId;
    print('[NOSTR] Channel sub: $subId  (#t: $nostrTag)');
  }

  /// Unsubscribes from Kind-42 messages for [nostrTag].
  void unsubscribeFromChannel(String nostrTag) {
    final subId = _channelSubIds.remove(nostrTag);
    if (subId != null) _relayManager.closeSubscription(subId);
  }

  /// Publishes a Kind-40 channel creation announcement.
  void publishChannelCreate(Map<String, dynamic> channelData) {
    if (_keys == null) return;
    final event = NostrEvent.create(
      keys: _keys!,
      kind: NostrKind.channelCreate,
      content: jsonEncode(channelData),
      tags: [
        ['t', channelData['nostrTag'] as String? ?? 'nexus-channel'],
        ['t', 'nexus-channel'],
      ],
    );
    _relayManager.publish(event);
    print('[NOSTR] Published Kind-40 channel: ${channelData['name']}');
  }

  // ── Sending ───────────────────────────────────────────────────────────────

  @override
  Future<void> sendMessage(
    NexusMessage message, {
    String? recipientDid,
  }) async {
    if (_keys == null) return;
    if (_state == TransportState.error) return;

    if (message.isBroadcast) {
      await _sendBroadcast(message);
    } else {
      await _sendDm(message);
    }
  }

  Future<void> _sendBroadcast(NexusMessage message) async {
    final channel = message.channel;

    // Named group channels use Kind-42; #mesh uses Kind-1.
    if (channel != null && channel != '#mesh') {
      final nostrTag =
          'nexus-channel-${channel.startsWith('#') ? channel.substring(1) : channel}';
      final event = NostrEvent.create(
        keys: _keys!,
        kind: NostrKind.channelMessage,
        content: jsonEncode(message.toJson()),
        tags: [
          ['t', nostrTag],
        ],
      );
      print('[NOSTR] Publishing Kind-42 channel=$channel '
          'id=${event.id.substring(0, 8)}…');
      _relayManager.publish(event);
      return;
    }

    final tags = <List<String>>[
      ['t', 'nexus-mesh'],
    ];
    if (currentGeohash != null) {
      tags.add(['t', 'nexus-geo-$currentGeohash']);
    }

    final event = NostrEvent.create(
      keys: _keys!,
      kind: NostrKind.textNote,
      content: jsonEncode(message.toJson()),
      tags: tags,
    );
    print('[NOSTR] Publishing broadcast kind=1 '
        'id=${event.id.substring(0, 8)}… tags=${event.tags.map((t) => t.join('=')).join(',')}');
    _relayManager.publish(event);
  }

  Future<void> _sendDm(NexusMessage message) async {
    final recipientNostrPubkey = _didToNostrPubkey[message.toDid];
    if (recipientNostrPubkey == null) {
      print('[NOSTR] DM send FAILED – no Nostr pubkey known for DID: '
          '${message.toDid}  (known DIDs: ${_didToNostrPubkey.keys.join(', ')})');
      return;
    }

    print('[NOSTR] Sending DM → pubkey: '
        '${recipientNostrPubkey.substring(0, 8)}…  DID: ${message.toDid}');

    final recipientPubBytes =
        Uint8List.fromList(_hexToBytes(recipientNostrPubkey));
    final content = await _nip04Encrypt(
      jsonEncode(message.toJson()),
      recipientPubBytes,
    );

    final event = NostrEvent.create(
      keys: _keys!,
      kind: NostrKind.encryptedDm,
      content: content,
      tags: [
        ['p', recipientNostrPubkey],
      ],
    );
    _relayManager.publish(event);
    print('[NOSTR] DM published, event id: ${event.id.substring(0, 8)}…');
  }

  // ── Presence ──────────────────────────────────────────────────────────────

  /// The current effective display name.
  ///
  /// Prefers the profile pseudonym (updated when the user edits their profile)
  /// over [localPseudonym] (set at construction from identity secure storage).
  /// This ensures Kind-0 and presence immediately reflect name changes within
  /// the same app session, without needing a restart.
  String get _effectivePseudonym {
    final profileName =
        ProfileService.instance.currentProfile?.pseudonym.value;
    if (profileName != null && profileName.isNotEmpty) return profileName;
    return localPseudonym;
  }

  /// Re-publishes Kind-0 metadata and a presence announcement immediately.
  ///
  /// Call this after the user saves a new pseudonym so peers see the updated
  /// name without waiting for the next periodic heartbeat.
  Future<void> republishMetadata() async {
    if (_state != TransportState.connected) return;
    await _publishMetadata();
    await _sendPresenceAnnouncement();
  }

  /// Publishes a Kind-0 (NIP-01) metadata event with our own display name.
  ///
  /// Relays store only the latest kind-0 per pubkey, so contacts can fetch it
  /// at any time to learn our pseudonym even without a live presence event.
  Future<void> _publishMetadata() async {
    if (_keys == null) return;
    final name = _effectivePseudonym;
    final event = NostrEvent.create(
      keys: _keys!,
      kind: NostrKind.metadata,
      content: jsonEncode({
        'name': name,
        'about': 'DID: $localDid',
      }),
      tags: [],
    );
    _relayManager.publish(event);
    print('[NOSTR] Published Kind-0 metadata (name: $name)');
  }

  /// Publishes a Kind 30078 presence announcement so other nodes can find us.
  Future<void> _sendPresenceAnnouncement() async {
    if (_keys == null) return;

    final name = _effectivePseudonym;
    final tags = <List<String>>[
      ['d', 'nexus-presence'],          // NIP-78 parameterized replaceable key
      ['t', 'nexus-presence'],          // filter tag
      ['did', localDid],                // DID for relay-side filtering
      ['name', name],
    ];
    if (currentGeohash != null) {
      tags.add(['t', 'nexus-geo-$currentGeohash']);
    }

    final event = NostrEvent.create(
      keys: _keys!,
      kind: NostrKind.presence,
      content: jsonEncode({
        'did': localDid,
        'pseudonym': name,
        if (_encryptionPublicKeyHex != null) 'enc_key': _encryptionPublicKeyHex,
      }),
      tags: tags,
    );
    _relayManager.publish(event);
  }

  /// Re-subscribes to Kind-0 for all known contacts.
  ///
  /// Called every 30 minutes to pick up name changes made while the app was
  /// running, and also when new contacts are added at runtime.
  void _refreshMetadataSubscription() {
    if (_keys == null || _state != TransportState.connected) return;

    // Re-seed the reverse map from latest persisted contacts.
    for (final contact in ContactService.instance.contacts) {
      if (contact.nostrPubkey != null && contact.nostrPubkey!.isNotEmpty) {
        _didToNostrPubkey[contact.did] = contact.nostrPubkey!;
      }
    }

    final pubkeys = <String>{
      ...ContactService.instance.contacts
          .where((c) => c.nostrPubkey != null && c.nostrPubkey!.isNotEmpty)
          .map((c) => c.nostrPubkey!),
      ..._didToNostrPubkey.values,
    };
    if (pubkeys.isEmpty) return;

    if (_metadataSubId != null) {
      _relayManager.closeSubscription(_metadataSubId!);
    }
    _metadataSubId = _relayManager.subscribe({
      'kinds': [NostrKind.metadata],
      'authors': pubkeys.toList(),
    });
    print('[NOSTR] Metadata refresh sub: $_metadataSubId  '
        '(${pubkeys.length} contacts)');
  }

  void _startPresenceTimer() {
    _presenceTimer?.cancel();
    print('[NOSTR] Presence heartbeat scheduled, interval=${presenceInterval.inSeconds}s');
    _presenceTimer = Timer.periodic(presenceInterval, (_) async {
      print('[NOSTR] Sending presence heartbeat');
      await _sendPresenceAnnouncement();
      _evictStalePeers();
    });
  }

  /// Removes peers whose last presence announcement is older than [peerTimeout].
  void _evictStalePeers() {
    final cutoff = DateTime.now().toUtc().subtract(peerTimeout);
    final stale = _peerLastPresence.entries
        .where((e) => e.value.isBefore(cutoff))
        .map((e) => e.key)
        .toList();

    if (stale.isEmpty) return;

    print('[NOSTR] Evicting ${stale.length} stale peer(s) '
        '(timeout: ${peerTimeout.inSeconds}s)');
    for (final pubkey in stale) {
      _peers.remove(pubkey);
      _peerLastPresence.remove(pubkey);
      _didToNostrPubkey.removeWhere((_, v) => v == pubkey);
    }
    _peersController.add(List.from(_peers.values));
  }

  // ── Receiving ─────────────────────────────────────────────────────────────

  void _setupSubscriptions() {
    if (_keys == null) return;
    final myPubkey = _keys!.publicKeyHex;
    final nowSeconds = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

    // Use the timestamp of the last received message (minus 60 s relay-latency
    // buffer) so missed messages are fetched on startup.  Fall back to the
    // last 24 hours when no prior timestamp is available.
    final msgSince = _lastMessageTimestampSeconds != null
        ? _lastMessageTimestampSeconds! - 60
        : nowSeconds - 86400;

    // Close stale subscriptions before recreating to avoid accumulating
    // orphaned REQ IDs in the relay manager.
    if (_dmSubId != null) _relayManager.closeSubscription(_dmSubId!);
    if (_meshSubId != null) _relayManager.closeSubscription(_meshSubId!);
    if (_presenceSubId != null) _relayManager.closeSubscription(_presenceSubId!);
    if (_metadataSubId != null) _relayManager.closeSubscription(_metadataSubId!);

    print('[NOSTR] Setting up subscriptions for pubkey: '
        '${myPubkey.substring(0, 8)}…${myPubkey.substring(myPubkey.length - 4)}');

    final humanSince = DateTime.fromMillisecondsSinceEpoch(msgSince * 1000).toUtc();
    print('[SYNC] DM filter: {"kinds":[4],"#p":["${myPubkey.substring(0, 8)}…"],'
        '"since":$msgSince}  ← ${humanSince.toIso8601String()}');

    // DMs addressed to us – since last known message (or last 24 h)
    _dmSubId = _relayManager.subscribe({
      'kinds': [NostrKind.encryptedDm],
      '#p': [myPubkey],
      'since': msgSince,
    });
    print('[NOSTR] DM sub: $_dmSubId  (#p: ${myPubkey.substring(0, 8)}…)');

    // Mesh broadcasts – same since window.
    // Always subscribe to 'nexus-mesh' tag.  If we have a geohash we also
    // add it so geo-filtered senders reach us – but the base tag alone is
    // sufficient to receive all broadcasts regardless of sender location.
    final meshTagFilter = <String>['nexus-mesh'];
    if (currentGeohash != null) {
      meshTagFilter.add('nexus-geo-$currentGeohash');
    }
    print('[SYNC] Broadcast filter: {"kinds":[1],"#t":$meshTagFilter,"since":$msgSince}');
    _meshSubId = _relayManager.subscribe({
      'kinds': [NostrKind.textNote],
      '#t': meshTagFilter,
      'since': msgSince,
    });
    print('[NOSTR] Mesh sub: $_meshSubId  (#t: $meshTagFilter)');

    // Presence announcements – last 5 minutes for initial peer discovery,
    // then live as new nodes come online.
    _presenceSubId = _relayManager.subscribe({
      'kinds': [NostrKind.presence],
      '#t': ['nexus-presence'],
      'since': nowSeconds - 300,
    });
    print('[NOSTR] Presence sub: $_presenceSubId');

    // ── Kind-0 metadata sync ──────────────────────────────────────────────
    //
    // CRITICAL: pre-populate _didToNostrPubkey from persisted contacts BEFORE
    // subscribing. Without this, when Kind-0 events arrive _handleMetadataEvent
    // cannot reverse-look up the sender's DID (the map is only populated by
    // incoming messages, which may not have been exchanged yet on a fresh start).
    for (final contact in ContactService.instance.contacts) {
      if (contact.nostrPubkey != null && contact.nostrPubkey!.isNotEmpty) {
        _didToNostrPubkey[contact.did] = contact.nostrPubkey!;
      }
    }

    final contactPubkeys = <String>{
      ...ContactService.instance.contacts
          .where((c) => c.nostrPubkey != null && c.nostrPubkey!.isNotEmpty)
          .map((c) => c.nostrPubkey!),
      ..._didToNostrPubkey.values,
    };
    if (contactPubkeys.isNotEmpty) {
      _metadataSubId = _relayManager.subscribe({
        'kinds': [NostrKind.metadata],
        'authors': contactPubkeys.toList(),
      });
      print('[NOSTR] Metadata sub: $_metadataSubId  '
          '(${contactPubkeys.length} contacts, pubkeys pre-populated)');
    }

    // Refresh metadata every 30 minutes to pick up name changes.
    _metadataRefreshTimer?.cancel();
    _metadataRefreshTimer = Timer.periodic(
      const Duration(minutes: 30),
      (_) => _refreshMetadataSubscription(),
    );

    // Channel discovery: subscribe to Kind-40 to find available channels.
    if (_channelDiscoverySubId != null) {
      _relayManager.closeSubscription(_channelDiscoverySubId!);
    }
    _channelDiscoverySubId = _relayManager.subscribe({
      'kinds': [NostrKind.channelCreate],
      '#t': ['nexus-channel'],
    });
    print('[NOSTR] Channel discovery sub: $_channelDiscoverySubId');
  }

  void _onRelayEvent(NostrEvent event) {
    if (_keys == null) return;

    switch (event.kind) {
      case NostrKind.metadata:
        _handleMetadataEvent(event);
      case NostrKind.encryptedDm:
        _handleDm(event);
      case NostrKind.textNote:
        _handleBroadcast(event);
      case NostrKind.channelCreate:
        _handleChannelCreateEvent(event);
      case NostrKind.channelMessage:
        _handleChannelMessageEvent(event);
      case NostrKind.presence:
        _handlePresenceEvent(event);
    }
  }

  void _handleChannelCreateEvent(NostrEvent event) {
    try {
      final data = jsonDecode(event.content) as Map<String, dynamic>;
      // Emit so GroupChannelService / ChatProvider can add to discovered list.
      _channelAnnouncedController.add({
        ...data,
        '_nostr_pubkey': event.pubkey,
        '_created_at': event.createdAt,
      });
      print('[NOSTR] Kind-40 channel announced: ${data['name']}');
    } catch (_) {}
  }

  void _handleChannelMessageEvent(NostrEvent event) {
    if (_keys == null) return;
    if (event.pubkey == _keys!.publicKeyHex) return;

    try {
      final msgJson = jsonDecode(event.content) as Map<String, dynamic>;
      final message = NexusMessage.fromJson(msgJson);
      _learnPeer(event.pubkey, message.fromDid, message.metadata);
      _msgController.add(message);
    } catch (e) {
      print('[NOSTR] Kind-42 parse FAILED: $e');
    }
  }

  void _handleDm(NostrEvent event) async {
    if (_keys == null) return;
    // Ignore our own events
    if (event.pubkey == _keys!.publicKeyHex) return;

    print('[NOSTR] DM received from pubkey: ${event.pubkey.substring(0, 8)}…, '
        'event: ${event.id.substring(0, 8)}…  decrypting…');
    print('[SYNC] Received event: ${event.id.substring(0, 8)} '
        'kind=${event.kind} created_at=${event.createdAt}');

    try {
      final senderPubBytes = Uint8List.fromList(_hexToBytes(event.pubkey));
      final plaintext = await _nip04Decrypt(event.content, senderPubBytes);
      final msgJson = jsonDecode(plaintext) as Map<String, dynamic>;
      final message = NexusMessage.fromJson(msgJson);

      print('[NOSTR] DM decrypted OK: ${message.fromDid} → ${message.toDid}');
      print('[SYNC] Stored message: ${message.id}');
      _learnPeer(event.pubkey, message.fromDid, message.metadata);
      _msgController.add(message);
    } catch (e) {
      print('[NOSTR] DM decrypt FAILED (not for us or malformed): $e');
    }
  }

  void _handleBroadcast(NostrEvent event) {
    if (_keys == null) return;
    if (event.pubkey == _keys!.publicKeyHex) return;

    // Must have nexus-mesh tag
    if (!event.tagValues('t').contains('nexus-mesh')) return;

    print('[NOSTR] Broadcast received from ${event.pubkey.substring(0, 8)}… '
        'id=${event.id.substring(0, 8)} tags=${event.tagValues('t')}');
    print('[SYNC] Received event: ${event.id.substring(0, 8)} '
        'kind=${event.kind} created_at=${event.createdAt}');

    try {
      final msgJson = jsonDecode(event.content) as Map<String, dynamic>;
      final message = NexusMessage.fromJson(msgJson);
      final didLen = message.fromDid.length;
      print('[NOSTR] Broadcast parsed OK: from=${message.fromDid.substring(0, didLen.clamp(0, 12))}… '
          'body="${message.body.length > 40 ? message.body.substring(0, 40) : message.body}"');
      print('[SYNC] Stored message: ${message.id}');
      _learnPeer(event.pubkey, message.fromDid, message.metadata);
      _msgController.add(message);
    } catch (e) {
      print('[NOSTR] Broadcast parse FAILED: $e');
    }
  }

  void _handlePresenceEvent(NostrEvent event) {
    if (_keys == null) return;
    // Ignore our own presence events
    if (event.pubkey == _keys!.publicKeyHex) return;

    try {
      final data = jsonDecode(event.content) as Map<String, dynamic>;
      final did = (data['did'] as String?) ?? event.tagValue('did');
      final pseudonym = (data['pseudonym'] as String?) ??
          event.tagValue('name') ??
          _shortDid(event.pubkey);

      if (did == null || did.isEmpty) return;

      final nowSeconds =
          DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      final ageSeconds = nowSeconds - event.createdAt;
      print('[NOSTR] Presence received: '
          'pubkey=${event.pubkey.substring(0, 8)}, '
          'timestamp=${event.createdAt}, age=${ageSeconds}s, '
          'pseudonym=$pseudonym');

      final encKey = data['enc_key'] as String?;
      if (encKey != null) {
        // Store in ContactService so ChatProvider can encrypt to this peer
        ContactService.instance.setEncryptionKey(did, encKey);
      }

      // Store DID ↔ Nostr pubkey mapping so we can send DMs.
      final isNewPubkey = _didToNostrPubkey[did] != event.pubkey;
      _didToNostrPubkey[did] = event.pubkey;

      // Persist nostrPubkey to the contact record so that on the next startup
      // _setupSubscriptions() can pre-populate _didToNostrPubkey and subscribe
      // to Kind-0 metadata before any messages have been exchanged.
      ContactService.instance.setNostrPubkey(did, event.pubkey);

      // If this is a newly learned pubkey, immediately request their Kind-0
      // metadata so the display name is updated without waiting for the
      // 30-minute refresh timer.
      if (isNewPubkey) _refreshMetadataSubscription();

      // Update peer record
      _peers[event.pubkey] = NexusPeer(
        did: did,
        pseudonym: pseudonym,
        transportType: TransportType.nostr,
        lastSeen: DateTime.now().toUtc(),
      );

      // Record presence timestamp for timeout tracking
      _peerLastPresence[event.pubkey] = DateTime.now().toUtc();

      // Persist the peer's self-reported name so it survives across sessions.
      ContactService.instance.updatePseudonymIfBetter(did, pseudonym);

      _peersController.add(List.from(_peers.values));
      print('[NOSTR] Active nodes: ${_peers.length}, '
          'pubkeys: [${_peers.keys.map((k) => k.substring(0, 8)).join(', ')}]');
    } catch (_) {}
  }

  /// Handles a Kind-0 (NIP-01 metadata) event.
  ///
  /// Resolves the sender's DID via [_didToNostrPubkey] (pre-populated from
  /// persisted contacts on startup) and updates the stored pseudonym.
  void _handleMetadataEvent(NostrEvent event) {
    if (_keys == null) return;
    // Ignore our own metadata events.
    if (event.pubkey == _keys!.publicKeyHex) return;

    try {
      final data = jsonDecode(event.content) as Map<String, dynamic>;

      // NIP-01 uses "name"; some clients also set "display_name" (NIP-24).
      // Prefer display_name when it is a non-empty human-readable name.
      final name = (data['name'] as String?)?.trim() ?? '';
      final displayName = (data['display_name'] as String?)?.trim() ?? '';
      final resolved = displayName.isNotEmpty ? displayName : name;

      print('[NOSTR] Kind-0 received: pubkey=${event.pubkey.substring(0, 8)}… '
          'name="$name" display_name="$displayName"');

      if (resolved.isEmpty) return;

      // Resolve the DID for this Nostr pubkey via the reverse map.
      final did = _didToNostrPubkey.entries
          .where((e) => e.value == event.pubkey)
          .map((e) => e.key)
          .firstOrNull;

      if (did != null) {
        final oldName =
            ContactService.instance.findByDid(did)?.pseudonym ?? '?';
        print('[NOSTR] Kind-0 updating contact: did=…${did.length > 8 ? did.substring(did.length - 8) : did} '
            '"$oldName" → "$resolved"');
        ContactService.instance.updatePseudonymIfBetter(did, resolved);
      } else {
        print('[NOSTR] Kind-0 DID not found for pubkey: '
            '${event.pubkey.substring(0, 8)}… '
            '(known mappings: ${_didToNostrPubkey.length})');
      }
    } catch (_) {}
  }

  void _learnPeer(
    String nostrPubkey,
    String senderDid,
    Map<String, dynamic>? metadata,
  ) {
    // Build DID ↔ Nostr pubkey mapping
    _didToNostrPubkey[senderDid] = nostrPubkey;

    // Also learn from metadata if another transport sent the message
    final metaNostrPubkey = metadata?['nostr_pubkey'] as String?;
    if (metaNostrPubkey != null) {
      _didToNostrPubkey[senderDid] = metaNostrPubkey;
    }

    final existing = _peers[nostrPubkey];
    final pseudonym = existing?.pseudonym ?? _shortDid(senderDid);

    _peers[nostrPubkey] = NexusPeer(
      did: senderDid,
      pseudonym: pseudonym,
      transportType: TransportType.nostr,
      lastSeen: DateTime.now().toUtc(),
    );
    _peersController.add(List.from(_peers.values));
  }

  static String _shortDid(String did) {
    if (did.length > 20) {
      return '${did.substring(0, 10)}…${did.substring(did.length - 6)}';
    }
    return did;
  }

  // ── NIP-04 Encryption ─────────────────────────────────────────────────────

  Future<String> _nip04Encrypt(
    String plaintext,
    Uint8List recipientPubKey,
  ) async {
    final sharedSecret = _keys!.computeSharedSecret(recipientPubKey);
    final iv = _randomBytes(16);

    final encrypted = await _aesCbc256Encrypt(
      key: sharedSecret,
      iv: iv,
      plaintext: utf8.encode(plaintext),
    );

    return '${base64.encode(encrypted)}?iv=${base64.encode(iv)}';
  }

  Future<String> _nip04Decrypt(
    String encryptedContent,
    Uint8List senderPubKey,
  ) async {
    final parts = encryptedContent.split('?iv=');
    if (parts.length != 2) throw FormatException('Invalid NIP-04 format');

    final ciphertext = base64.decode(parts[0]);
    final iv = base64.decode(parts[1]);

    final sharedSecret = _keys!.computeSharedSecret(senderPubKey);
    final decrypted = await _aesCbc256Decrypt(
      key: sharedSecret,
      iv: iv,
      ciphertext: Uint8List.fromList(ciphertext),
    );
    return utf8.decode(decrypted);
  }

  // ── AES-256-CBC helpers ───────────────────────────────────────────────────

  static final _aesCbc = AesCbc.with256bits(macAlgorithm: MacAlgorithm.empty);

  static Future<Uint8List> _aesCbc256Encrypt({
    required Uint8List key,
    required Uint8List iv,
    required List<int> plaintext,
  }) async {
    final secretKey = SecretKey(key);
    final box = await _aesCbc.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: iv,
    );
    return Uint8List.fromList(box.cipherText);
  }

  static Future<Uint8List> _aesCbc256Decrypt({
    required Uint8List key,
    required Uint8List iv,
    required Uint8List ciphertext,
  }) async {
    final secretKey = SecretKey(key);
    final box = SecretBox(ciphertext, nonce: iv, mac: Mac.empty);
    final decrypted = await _aesCbc.decrypt(box, secretKey: secretKey);
    return Uint8List.fromList(decrypted);
  }

  // ── Utilities ─────────────────────────────────────────────────────────────

  static Uint8List _randomBytes(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rng.nextInt(256)));
  }

  static List<int> _hexToBytes(String hex) => List.generate(
        hex.length ~/ 2,
        (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
      );
}
