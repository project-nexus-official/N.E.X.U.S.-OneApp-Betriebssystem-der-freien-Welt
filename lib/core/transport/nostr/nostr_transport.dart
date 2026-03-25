import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show AesCbc, MacAlgorithm,
    SecretKey, SecretBox, Mac;

import '../message_transport.dart';
import '../nexus_message.dart';
import '../nexus_peer.dart';
import 'nostr_event.dart';
import 'nostr_keys.dart';
import 'nostr_relay_manager.dart';

/// Internet fallback transport via Nostr protocol (NIP-01, NIP-04).
///
/// - Encrypted DMs (Kind 4 / NIP-04) for peer-to-peer messages.
/// - Public Kind 1 notes tagged with ["t","nexus-mesh"] for #mesh broadcasts.
/// - Peers are discovered when they send messages; no active "scanning".
/// - Geohash channel tag is appended to broadcasts when location is available.
class NostrTransport implements MessageTransport {
  NostrTransport({
    required this.localDid,
    required this.localPseudonym,
    NostrRelayManager? relayManager,
  }) : _relayManager = relayManager ?? NostrRelayManager();

  final String localDid;
  final String localPseudonym;
  final NostrRelayManager _relayManager;

  NostrKeys? _keys;

  TransportState _state = TransportState.idle;

  final _msgController = StreamController<NexusMessage>.broadcast();
  final _peersController = StreamController<List<NexusPeer>>.broadcast();

  // DID → Nostr pubkey hex (learned from received messages)
  final Map<String, String> _didToNostrPubkey = {};

  // Nostr pubkey hex → NexusPeer
  final Map<String, NexusPeer> _peers = {};

  // Active relay subscriptions
  String? _dmSubId;
  String? _meshSubId;

  StreamSubscription<NostrEvent>? _eventSub;

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

  /// List of relay statuses (URL, state, latency).
  List<RelayStatus> get relayStatuses => _relayManager.statuses;

  /// Adds a custom relay URL.
  void addRelay(String url) => _relayManager.addRelay(url);

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Initialises the Nostr keypair and connects to relays.
  ///
  /// [keysOverride] allows injecting a keypair in tests.
  @override
  Future<void> start({NostrKeys? keysOverride}) async {
    _state = TransportState.scanning;

    _keys = keysOverride;
    // If no override, caller must call initKeys() separately after loading
    // the mnemonic from IdentityService.

    await _relayManager.start();

    _eventSub = _relayManager.onEvent.listen(_onRelayEvent);

    if (_keys != null) {
      _subscribeToOwnPubkey();
    }

    _state = TransportState.connected;
  }

  /// Derives and stores the Nostr keypair from a BIP-39 seed.
  /// Must be called before the transport can send/receive DMs.
  Future<void> initKeys(Uint8List seed64) async {
    _keys = NostrKeys.fromBip39Seed(seed64);
    if (_state == TransportState.connected) {
      _subscribeToOwnPubkey();
    }
  }

  @override
  Future<void> stop() async {
    _state = TransportState.idle;
    if (_dmSubId != null) _relayManager.closeSubscription(_dmSubId!);
    if (_meshSubId != null) _relayManager.closeSubscription(_meshSubId!);
    await _eventSub?.cancel();
    await _relayManager.stop();
    _peers.clear();
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
    _relayManager.publish(event);
  }

  Future<void> _sendDm(NexusMessage message) async {
    final recipientNostrPubkey = _didToNostrPubkey[message.toDid];
    if (recipientNostrPubkey == null) {
      // Don't know recipient's Nostr pubkey yet – can't send DM
      return;
    }

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
  }

  // ── Receiving ─────────────────────────────────────────────────────────────

  void _subscribeToOwnPubkey() {
    if (_keys == null) return;
    final myPubkey = _keys!.publicKeyHex;

    // DMs addressed to us
    _dmSubId = _relayManager.subscribe({
      'kinds': [NostrKind.encryptedDm],
      '#p': [myPubkey],
      'since': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 - 3600,
    });

    // Mesh broadcasts
    final meshFilters = <String, dynamic>{
      'kinds': [NostrKind.textNote],
      '#t': ['nexus-mesh'],
      'since': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 - 3600,
    };
    if (currentGeohash != null) {
      meshFilters['#t'] = ['nexus-mesh', 'nexus-geo-$currentGeohash'];
    }
    _meshSubId = _relayManager.subscribe(meshFilters);
  }

  void _onRelayEvent(NostrEvent event) {
    if (_keys == null) return;

    switch (event.kind) {
      case NostrKind.encryptedDm:
        _handleDm(event);
      case NostrKind.textNote:
        _handleBroadcast(event);
    }
  }

  void _handleDm(NostrEvent event) async {
    if (_keys == null) return;
    // Ignore our own events
    if (event.pubkey == _keys!.publicKeyHex) return;

    try {
      final senderPubBytes = Uint8List.fromList(_hexToBytes(event.pubkey));
      final plaintext = await _nip04Decrypt(event.content, senderPubBytes);
      final msgJson = jsonDecode(plaintext) as Map<String, dynamic>;
      final message = NexusMessage.fromJson(msgJson);

      _learnPeer(event.pubkey, message.fromDid, message.metadata);
      _msgController.add(message);
    } catch (_) {
      // Decryption failure (message not for us or malformed)
    }
  }

  void _handleBroadcast(NostrEvent event) {
    if (_keys == null) return;
    if (event.pubkey == _keys!.publicKeyHex) return;

    // Must have nexus-mesh tag
    if (!event.tagValues('t').contains('nexus-mesh')) return;

    try {
      final msgJson = jsonDecode(event.content) as Map<String, dynamic>;
      final message = NexusMessage.fromJson(msgJson);
      _learnPeer(event.pubkey, message.fromDid, message.metadata);
      _msgController.add(message);
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
    final pseudonym = existing?.pseudonym ??
        _shortDid(senderDid);

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
