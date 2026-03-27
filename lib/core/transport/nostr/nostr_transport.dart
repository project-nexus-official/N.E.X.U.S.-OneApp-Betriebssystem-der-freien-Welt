import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show AesCbc, MacAlgorithm,
    SecretKey, SecretBox, Mac;

import '../../../core/contacts/contact_service.dart';
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
  final String localPseudonym;
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

  StreamSubscription<NostrEvent>? _eventSub;
  Timer? _presenceTimer;

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
      await _sendPresenceAnnouncement();
      _startPresenceTimer();
    }
  }

  @override
  Future<void> stop() async {
    _state = TransportState.idle;
    _presenceTimer?.cancel();
    _presenceTimer = null;
    if (_dmSubId != null) _relayManager.closeSubscription(_dmSubId!);
    if (_meshSubId != null) _relayManager.closeSubscription(_meshSubId!);
    if (_presenceSubId != null) _relayManager.closeSubscription(_presenceSubId!);
    await _eventSub?.cancel();
    await _relayManager.stop();
    _peers.clear();
    _peerLastPresence.clear();
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

  /// Publishes a Kind 30078 presence announcement so other nodes can find us.
  Future<void> _sendPresenceAnnouncement() async {
    if (_keys == null) return;

    final tags = <List<String>>[
      ['d', 'nexus-presence'],          // NIP-78 parameterized replaceable key
      ['t', 'nexus-presence'],          // filter tag
      ['did', localDid],                // DID for relay-side filtering
      ['name', localPseudonym],
    ];
    if (currentGeohash != null) {
      tags.add(['t', 'nexus-geo-$currentGeohash']);
    }

    final event = NostrEvent.create(
      keys: _keys!,
      kind: NostrKind.presence,
      content: jsonEncode({
        'did': localDid,
        'pseudonym': localPseudonym,
        if (_encryptionPublicKeyHex != null) 'enc_key': _encryptionPublicKeyHex,
      }),
      tags: tags,
    );
    _relayManager.publish(event);
  }

  void _startPresenceTimer() {
    _presenceTimer?.cancel();
    _presenceTimer = Timer.periodic(presenceInterval, (_) async {
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

    for (final pubkey in stale) {
      _peers.remove(pubkey);
      _peerLastPresence.remove(pubkey);
      // Also clean up DID mapping for this pubkey
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
  }

  void _onRelayEvent(NostrEvent event) {
    if (_keys == null) return;

    switch (event.kind) {
      case NostrKind.encryptedDm:
        _handleDm(event);
      case NostrKind.textNote:
        _handleBroadcast(event);
      case NostrKind.presence:
        _handlePresenceEvent(event);
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

      final encKey = data['enc_key'] as String?;
      if (encKey != null) {
        // Store in ContactService so ChatProvider can encrypt to this peer
        ContactService.instance.setEncryptionKey(did, encKey);
      }

      // Store DID ↔ Nostr pubkey mapping so we can send DMs
      _didToNostrPubkey[did] = event.pubkey;

      // Update peer record
      _peers[event.pubkey] = NexusPeer(
        did: did,
        pseudonym: pseudonym,
        transportType: TransportType.nostr,
        lastSeen: DateTime.now().toUtc(),
      );

      // Record presence timestamp for timeout tracking
      _peerLastPresence[event.pubkey] = DateTime.now().toUtc();

      _peersController.add(List.from(_peers.values));
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
