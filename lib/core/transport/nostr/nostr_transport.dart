import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:cryptography/cryptography.dart' show AesCbc, MacAlgorithm,
    SecretKey, SecretBox, Mac;

import '../../../core/contacts/contact_service.dart';
import '../../../core/identity/profile.dart';
import '../../../core/identity/profile_service.dart';
import '../../../features/profile/profile_image_service.dart';
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

  final _feedPostController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Emits a raw FeedPost data map when a Kind-1/nexus-dorfplatz event arrives.
  Stream<Map<String, dynamic>> get onFeedPost => _feedPostController.stream;

  final _cellAnnouncedController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Emits a Cell JSON map whenever a Kind-30000 cell announcement arrives.
  Stream<Map<String, dynamic>> get onCellAnnounced =>
      _cellAnnouncedController.stream;

  final _cellDeletedController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Emits {id, name, nostrTag} when a Kind-30000 cell-dissolution event
  /// (content contains "deleted":true) arrives.
  Stream<Map<String, dynamic>> get onCellDeleted =>
      _cellDeletedController.stream;

  String? _cellSubId;

  final _cellJoinRequestController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Emits a CellJoinRequest JSON map (+requesterNostrPubkey) when a
  /// Kind-31003 join request arrives. Used by founders/moderators.
  Stream<Map<String, dynamic>> get onCellJoinRequest =>
      _cellJoinRequestController.stream;

  final _cellMembershipConfirmedController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Emits {cell: cellJson, member: memberJson} when a Kind-31004
  /// membership-confirmation event addressed to this node arrives.
  Stream<Map<String, dynamic>> get onCellMembershipConfirmed =>
      _cellMembershipConfirmedController.stream;

  String? _cellJoinSubId;
  String? _cellMembershipSubId;
  String? _cellMemberUpdateSubId;

  final _cellMemberUpdateController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Emits `{cellId, targetDid, action: 'left'|'removed', reason?}` when a
  /// Kind-31005 member-update event arrives.
  Stream<Map<String, dynamic>> get onCellMemberUpdate =>
      _cellMemberUpdateController.stream;

  final _feedCommentController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Emits a raw FeedComment data map when a Kind-1/nexus-dorfplatz-comment arrives.
  Stream<Map<String, dynamic>> get onFeedComment =>
      _feedCommentController.stream;

  // G2 governance streams ───────────────────────────────────────────────────

  final _proposalEventController = StreamController<NostrEvent>.broadcast();
  final _voteEventController = StreamController<NostrEvent>.broadcast();
  final _decisionRecordController = StreamController<NostrEvent>.broadcast();

  /// Emits Kind-31010 proposal events received from Nostr.
  Stream<NostrEvent> get onProposalEvent => _proposalEventController.stream;

  /// Emits Kind-31011 vote events received from Nostr.
  Stream<NostrEvent> get onVoteEvent => _voteEventController.stream;

  /// Emits Kind-31013 decision record events received from Nostr.
  Stream<NostrEvent> get onDecisionRecordEvent =>
      _decisionRecordController.stream;

  // Active subscription IDs for governance events (cell-filtered).
  String? _proposalSubId;
  String? _voteSubId;
  String? _decisionSubId;

  // Last cell-ID list used when opening governance subscriptions.
  // Used to skip redundant close+reopen when the list hasn't changed.
  List<String> _lastSubscribedCellIds = [];

  final _feedReactionController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Emits {emoji, referencedEventId, senderPubkey} when a Kind-7 reaction arrives.
  Stream<Map<String, dynamic>> get onFeedReaction =>
      _feedReactionController.stream;

  /// Emits a list of Nostr event IDs when a Kind-5 deletion request arrives.
  final _feedDeleteController =
      StreamController<List<String>>.broadcast();

  /// Stream of Nostr event IDs to delete, from incoming Kind-5 events.
  Stream<List<String>> get onFeedDelete => _feedDeleteController.stream;

  String? _feedSubId;

  /// Dedicated author-based subscription for Kind-6 reposts.
  /// Public relays do NOT index Kind-6 by #t tags, so a tag-filtered sub
  /// never delivers reposts.  This sub uses only 'authors' + 'since' so the
  /// relay returns all reposts from known contacts without tag filtering.
  String? _feedRepostSubId;

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

  /// The local Nostr public key as a lowercase hex string, or null before [start].
  String? get localNostrPubkeyHex => _keys?.publicKeyHex;

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
    if (_feedSubId != null) _relayManager.closeSubscription(_feedSubId!);
    if (_feedRepostSubId != null) _relayManager.closeSubscription(_feedRepostSubId!);
    if (_proposalSubId != null) _relayManager.closeSubscription(_proposalSubId!);
    if (_voteSubId != null) _relayManager.closeSubscription(_voteSubId!);
    if (_decisionSubId != null) _relayManager.closeSubscription(_decisionSubId!);
    _proposalSubId = null;
    _voteSubId = null;
    _decisionSubId = null;
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
  ///
  /// Tags include:
  ///   ["access", "public"|"private"] — whether the channel is open to all
  ///   ["discoverable", "true"|"false"] — whether it appears in discovery
  ///
  /// The channelSecret (for private channels) is NOT included in the Kind-40
  /// event — it is distributed only to accepted members via encrypted DMs.
  void publishChannelCreate(Map<String, dynamic> channelData) {
    if (_keys == null) return;
    final isPublic = (channelData['isPublic'] as bool?) ?? true;
    final isDiscoverable = (channelData['isDiscoverable'] as bool?) ?? true;
    final channelId = channelData['id'] as String? ?? '';
    final channelName = channelData['name'] as String? ?? '';
    final nostrTag = channelData['nostrTag'] as String? ?? 'nexus-channel';
    // Strip channelSecret before publishing to Nostr.
    final publicData = Map<String, dynamic>.from(channelData)
      ..remove('channelSecret')
      ..remove('members');
    final event = NostrEvent.create(
      keys: _keys!,
      kind: NostrKind.channelCreate,
      content: jsonEncode(publicData),
      tags: [
        ['t', nostrTag],
        ['t', 'nexus-channel'],
        ['access', isPublic ? 'public' : 'private'],
        ['discoverable', isDiscoverable ? 'true' : 'false'],
      ],
    );
    final connectedRelays =
        _relayManager.statuses.where((s) => s.state == RelayState.connected).length;
    print('[CHANNEL-CREATE] Publishing: channelId=$channelId name=$channelName kind=40');
    print('[CHANNEL-CREATE] EventId: ${event.id.length >= 8 ? event.id.substring(0, 8) : event.id}…');
    print('[CHANNEL-CREATE] Tags: t=$nostrTag t=nexus-channel access=${isPublic ? 'public' : 'private'} discoverable=$isDiscoverable');
    print('[CHANNEL-CREATE] Relays: $connectedRelays (see [RELAY-OK] for responses)');
    _relayManager.publish(event);
  }

  /// Publishes a NIP-28 Kind-41 channel metadata update.
  void publishChannelMetadata(Map<String, dynamic> channelData) {
    if (_keys == null) return;
    final isPublic = (channelData['isPublic'] as bool?) ?? true;
    final isDiscoverable = (channelData['isDiscoverable'] as bool?) ?? true;
    final publicData = Map<String, dynamic>.from(channelData)
      ..remove('channelSecret')
      ..remove('members');
    final event = NostrEvent.create(
      keys: _keys!,
      kind: NostrKind.channelMetadata,
      content: jsonEncode(publicData),
      tags: [
        ['e', channelData['id'] as String? ?? ''],
        ['t', channelData['nostrTag'] as String? ?? 'nexus-channel'],
        ['t', 'nexus-channel'],
        ['access', isPublic ? 'public' : 'private'],
        ['discoverable', isDiscoverable ? 'true' : 'false'],
      ],
    );
    _relayManager.publish(event);
    print('[NOSTR] Published Kind-41 channel metadata: ${channelData['name']}');
  }

  /// Publishes a NIP-09 Kind-5 deletion request for [messageId].
  ///
  /// Best-effort: relays may ignore the request, and clients that already
  /// cached the message may not remove it automatically.
  void publishDeletion(String messageId) {
    if (_keys == null) return;
    final event = NostrEvent.create(
      keys: _keys!,
      kind: NostrKind.deletion,
      content: 'Nachricht gelöscht',
      tags: [
        ['e', messageId],
      ],
    );
    final connectedRelays =
        _relayManager.statuses.where((s) => s.state == RelayState.connected).length;
    print('[MSG-DELETE] Publishing kind=5: msgId=${messageId.length >= 8 ? messageId.substring(0, 8) : messageId}…');
    print('[MSG-DELETE] e-tag: $messageId');
    print('[MSG-DELETE] Relays: $connectedRelays (see [RELAY-OK] for responses)');
    _relayManager.publish(event);
  }

  /// Publishes a Kind-30000 cell announcement so other nodes can discover the cell.
  ///
  /// Uses parameterized replaceable event with d-tag = cell ID, so updating
  /// the cell simply replaces the previous announcement on relays.
  void publishCellAnnouncement(Map<String, dynamic> cellJson) {
    if (_keys == null) return;
    final cellId = cellJson['id'] as String? ?? '';
    final cellName = cellJson['name'] as String? ?? cellId;
    final event = NostrEvent.create(
      keys: _keys!,
      kind: NostrKind.cellAnnounce,
      content: jsonEncode(cellJson),
      tags: [
        ['d', cellId],
        ['t', 'nexus-cell'],
      ],
    );
    final connectedRelays =
        _relayManager.statuses.where((s) => s.state == RelayState.connected).length;
    print('[CELL-CREATE] Publishing: cellId=$cellId name=$cellName');
    print('[CELL-CREATE] EventId: ${event.id.length >= 8 ? event.id.substring(0, 8) : event.id}…');
    print('[CELL-CREATE] Tags: [d,$cellId] [t,nexus-cell]');
    print('[CELL-CREATE] Relays: $connectedRelays (see [RELAY-OK] for responses)');
    _relayManager.publish(event);
    print('[CELL-RENAME] Kind-30000 published: accepted=${connectedRelays > 0}');
  }

  /// Publishes a Kind-5 deletion event for a cell (NIP-09).
  ///
  /// Uses the proper NIP-09 `a` tag for parameterized replaceable events:
  /// `['a', '30000:{pubkeyHex}:{cellId}']` so compliant relays actually
  /// remove the original Kind-30000 announcement.
  void publishCellDeletion(String cellId, String cellName) {
    if (_keys == null) return;
    // NIP-09: 'a' tag identifies the parameterized replaceable event to delete.
    final aTag = '${NostrKind.cellAnnounce}:${_keys!.publicKeyHex}:$cellId';
    final event = NostrEvent.create(
      keys: _keys!,
      kind: NostrKind.deletion,
      content: 'Zelle "$cellName" wurde aufgelöst.',
      tags: [
        ['a', aTag],
        ['t', 'nexus-cell'], // keep for backward-compat with older clients
      ],
    );
    _relayManager.publish(event);
    print('[CELL-DEL] Publishing Kind-5 delete for cell: $cellId');
  }

  /// Publishes a Kind-31003 cell join request.
  ///
  /// [reqJson] is the full `CellJoinRequest.toJson()` map, which must already
  /// include a `requesterNostrPubkey` field so the founder can send the
  /// Kind-31004 confirmation back.
  void publishCellJoinRequest(Map<String, dynamic> reqJson) {
    if (_keys == null) return;
    final cellId = reqJson['cellId'] as String? ?? '';
    final requestId = reqJson['id'] as String? ?? '';
    final event = NostrEvent.create(
      keys: _keys!,
      kind: NostrKind.cellJoinRequest,
      content: jsonEncode(reqJson),
      tags: [
        ['t', 'nexus-cell-join'],
        ['d', requestId],
        ['cell', cellId],
      ],
    );
    _relayManager.publish(event);
    print('[JOIN] Request sent to cell: $cellId (requestId: ${requestId.substring(0, 8)}…)');
  }

  /// Publishes a Kind-31004 membership confirmation to [requesterNostrPubkeyHex].
  ///
  /// [cellJson] is `Cell.toJson()`, [memberJson] is `CellMember.toJson()`.
  void publishCellMembershipConfirmed(
    Map<String, dynamic> cellJson,
    Map<String, dynamic> memberJson,
    String requesterNostrPubkeyHex,
  ) {
    if (_keys == null) return;
    final cellId = cellJson['id'] as String? ?? '';
    final event = NostrEvent.create(
      keys: _keys!,
      kind: NostrKind.cellMembershipConfirmed,
      content: jsonEncode({'cell': cellJson, 'member': memberJson}),
      tags: [
        ['t', 'nexus-cell-confirmed'],
        ['p', requesterNostrPubkeyHex],
        ['cell', cellId],
      ],
    );
    _relayManager.publish(event);
    print('[JOIN] Confirmation sent to ${requesterNostrPubkeyHex.substring(0, 8)}… for cell: $cellId');
  }

  /// Publishes a Kind-30000 cell-dissolution event.
  ///
  /// Uses the same d-tag as the original announcement so relays replace it
  /// with this "deleted" version.  All devices subscribed to
  /// `#t: ['nexus-cell']` will receive it and clean up their local state.
  void publishCellDissolution(Map<String, dynamic> cellJson) {
    if (_keys == null) return;
    final cellId = cellJson['id'] as String? ?? '';
    final cellName = cellJson['name'] as String? ?? cellId;
    final event = NostrEvent.create(
      keys: _keys!,
      kind: NostrKind.cellAnnounce,
      content: jsonEncode({...cellJson, 'deleted': true}),
      tags: [
        ['d', cellId],
        ['t', 'nexus-cell'],
        ['deleted', 'true'], // explicit tag so receivers can filter without parsing JSON
      ],
    );
    _relayManager.publish(event);
    print('[CELL-DEL] Publishing deleted-flag Kind-30000: $cellId ($cellName)');
  }

  /// Publishes a Kind-31005 cell member update (leave or remove).
  ///
  /// [cellId] identifies the cell.
  /// [targetDid] is the DID of the member who is leaving or being removed.
  /// [action] is `'left'` (voluntary) or `'removed'` (kicked by founder/mod).
  /// [reason] is an optional human-readable reason (only for 'removed').
  void publishCellMemberUpdate({
    required String cellId,
    required String targetDid,
    required String action,
    String? reason,
  }) {
    if (_keys == null) return;
    final payload = <String, dynamic>{
      'cellId': cellId,
      'targetDid': targetDid,
      'action': action,
      if (reason != null && reason.isNotEmpty) 'reason': reason,
    };
    final event = NostrEvent.create(
      keys: _keys!,
      kind: NostrKind.cellMemberUpdate,
      content: jsonEncode(payload),
      tags: [
        ['t', 'nexus-cell-member-update'],
        ['cell', cellId],
      ],
    );
    _relayManager.publish(event);
    print('[CELL] Published Kind-31005 member-$action event for cell: $cellId '
        '(target: ${targetDid.length > 20 ? '${targetDid.substring(0, 20)}…' : targetDid})');
  }

  /// Publishes a NIP-25 Kind-7 reaction for [messageId].
  void publishReaction(String messageId, String emoji) {
    if (_keys == null) return;
    final event = NostrEvent.create(
      keys: _keys!,
      kind: NostrKind.reaction,
      content: emoji,
      tags: [
        ['e', messageId],
      ],
    );
    final connectedRelays =
        _relayManager.statuses.where((s) => s.state == RelayState.connected).length;
    print('[REACTION-SEND] Publishing kind=7: emoji=$emoji target=${messageId.length >= 8 ? messageId.substring(0, 8) : messageId}…');
    print('[REACTION-SEND] Tags: e=$messageId');
    print('[REACTION-SEND] Relays: $connectedRelays (see [RELAY-OK] for responses)');
    _relayManager.publish(event);
  }

  /// Publishes a Dorfplatz feed event (Kind-1 post, Kind-6 repost, Kind-7
  /// reaction, Kind-5 deletion) and returns the assigned Nostr event ID.
  ///
  /// Returns null if keys are not yet initialised.
  String? publishFeedEvent(
      int kind, String content, List<List<String>> tags) {
    if (_keys == null) return null;
    final event = NostrEvent.create(
      keys: _keys!,
      kind: kind,
      content: content,
      tags: tags,
    );
    final connectedRelays =
        _relayManager.statuses.where((s) => s.state == RelayState.connected).length;
    if (kind == NostrKind.reaction) {
      final targetTag = tags.firstWhere(
          (t) => t.isNotEmpty && t[0] == 'e',
          orElse: () => ['e', '?']);
      final targetId = targetTag.length > 1 ? targetTag[1] : '?';
      final shortTarget = targetId.length >= 8 ? targetId.substring(0, 8) : targetId;
      print('[DORFPLATZ-REACT-SEND] Publishing kind=7: emoji=$content target=$shortTarget…');
      print('[DORFPLATZ-REACT-SEND] Relays: $connectedRelays (see [RELAY-OK] for responses)');
    } else {
      print('[NOSTR] Feed Kind-$kind published: ${event.id.substring(0, 8)}… '
          '→ $connectedRelays relay(s)');
    }
    _relayManager.publish(event);
    return event.id;
  }

  // ── G2 Governance publishing ──────────────────────────────────────────────

  /// Publishes a Kind-31010 proposal lifecycle event (NIP-33 parameterized
  /// replaceable). Returns true on success, false if keys are not ready.
  Future<bool> publishProposalEvent({
    required String proposalId,
    required String cellId,
    required String type,
    required String status,
    required String title,
    required String description,
    required String creatorDid,
    required String creatorPseudonym,
    required DateTime createdAt,
    required int version,
    String? category,
    DateTime? votingEndsAt,
    String? editReason,
  }) async {
    if (_keys == null) {
      print('[PROPOSAL-PUB] Keys not ready — cannot publish');
      return false;
    }
    print('[PROPOSAL-PUB] === START === proposalId=$proposalId v=$version '
        'status=$status');
    try {
      final tags = <List<String>>[
        ['d', proposalId],
        ['t', 'nexus-proposal'],
        ['t', 'nexus-cell-$cellId'],
        ['type', type.toLowerCase()],
        ['status', status.toLowerCase()],
        ['version', version.toString()],
      ];
      if (votingEndsAt != null) {
        tags.add([
          'voting_ends_at',
          (votingEndsAt.millisecondsSinceEpoch ~/ 1000).toString(),
        ]);
      }
      if (category != null && category.isNotEmpty) {
        tags.add(['category', category]);
      }
      final content = <String, dynamic>{
        'title': title,
        'description': description,
        'creatorDid': creatorDid,
        'creatorPseudonym': creatorPseudonym,
        'createdAt': createdAt.millisecondsSinceEpoch ~/ 1000,
        'version': version,
        if (editReason != null) 'editReason': editReason,
      };
      final event = NostrEvent.create(
        keys: _keys!,
        kind: NostrKind.proposalEvent,
        content: jsonEncode(content),
        tags: tags,
      );
      print('[PROPOSAL-PUB] Event built: id=${event.id.substring(0, 16)}… '
          'kind=${event.kind} tags=${event.tags.length}');

      final relayCount = _relayManager.connectedRelayCount;
      if (relayCount == 0) {
        print('[PROPOSAL-PUB] No relays connected — event NOT sent, retry queued');
        return false;
      }
      _relayManager.publish(event);
      print('[PROPOSAL-PUB] === SUCCESS === Published to $relayCount relay(s): '
          '${event.id.substring(0, 16)}…');
      return true;
    } catch (e, stack) {
      print('[PROPOSAL-PUB] === EXCEPTION === $e');
      print('[PROPOSAL-PUB] Stack: $stack');
      return false;
    }
  }

  /// Publishes a Kind-31011 vote event (NIP-33 parameterized replaceable).
  /// The d-tag is "vote-${proposalId}-${voterPubkeyHex}" to ensure at-most-one
  /// vote per voter per proposal on compliant relays (dash avoids colon issues).
  /// Returns true on success, false if keys are not ready.
  Future<bool> publishVoteEvent({
    required String proposalId,
    required String cellId,
    required String voteId,
    required String choiceName,
    required String voterDid,
    required String voterPseudonym,
    required DateTime createdAt,
    String? reasoning,
  }) async {
    if (_keys == null) return false;
    final voterPubkey = _keys!.publicKeyHex;
    // Use dash separator instead of colon: some relays mishandle ':' in d-tags.
    final dTag = 'vote-$proposalId-$voterPubkey';
    print('[VOTE-PUB] === START === voteId=$voteId proposalId=$proposalId '
        'choice=$choiceName');
    try {
      final tags = <List<String>>[
        ['d', dTag],
        ['t', 'nexus-vote'],
        ['t', 'nexus-cell-$cellId'],
        ['proposal_id', proposalId],
        ['choice', choiceName.toLowerCase()],
        ['weight', '1'],
      ];
      final content = <String, dynamic>{
        'voteId': voteId,
        'voterDid': voterDid,
        'voterPseudonym': voterPseudonym,
        'createdAt': createdAt.millisecondsSinceEpoch ~/ 1000,
        if (reasoning != null) 'reasoning': reasoning,
      };
      final event = NostrEvent.create(
        keys: _keys!,
        kind: NostrKind.voteEvent,
        content: jsonEncode(content),
        tags: tags,
      );
      print('[VOTE-PUB] Tags: ${event.tags}');
      final relayCount = _relayManager.connectedRelayCount;
      if (relayCount == 0) {
        print('[VOTE-PUB] No relays connected — event NOT sent, retry queued');
        return false;
      }
      _relayManager.publish(event);
      print('[VOTE-PUB] === SUCCESS === Published to $relayCount relay(s): '
          '${event.id.substring(0, 16)}…');
      return true;
    } catch (e, stack) {
      print('[VOTE-PUB] === EXCEPTION === $e');
      print('[VOTE-PUB] Stack: $stack');
      return false;
    }
  }

  /// Publishes a Kind-31013 decision record (NIP-33 parameterized replaceable).
  /// The d-tag is the proposalId to ensure at-most-one record per proposal.
  /// Returns true on success, false if keys are not ready.
  Future<bool> publishDecisionRecord({
    required String proposalId,
    required String cellId,
    required Map<String, dynamic> recordContent,
    required String result,
    required String contentHash,
    String? previousDecisionHash,
  }) async {
    if (_keys == null) return false;
    print('[DECISION-PUB] === START === proposalId=$proposalId result=$result '
        'hash=${contentHash.substring(0, 8)}…');
    try {
      final tags = <List<String>>[
        ['d', proposalId],
        ['t', 'nexus-decision'],
        ['t', 'nexus-cell-$cellId'],
        ['proposal_id', proposalId],
        ['result', result],
        ['prev_hash', previousDecisionHash ?? ''],
        ['content_hash', contentHash],
      ];
      final event = NostrEvent.create(
        keys: _keys!,
        kind: NostrKind.decisionRecord,
        content: jsonEncode(recordContent),
        tags: tags,
      );
      print('[DECISION-PUB] Tags: ${event.tags}');
      final relayCount = _relayManager.connectedRelayCount;
      if (relayCount == 0) {
        print('[DECISION-PUB] No relays connected — event NOT sent, retry queued');
        return false;
      }
      _relayManager.publish(event);
      print('[DECISION-PUB] === SUCCESS === Published to $relayCount relay(s): '
          '${event.id.substring(0, 16)}…');
      return true;
    } catch (e, stack) {
      print('[DECISION-PUB] === EXCEPTION === $e');
      print('[DECISION-PUB] Stack: $stack');
      return false;
    }
  }

  /// Refreshes governance (proposal/vote/decision) subscriptions for the
  /// given cell IDs.  Call this after joining or leaving a cell.
  void refreshGovernanceSubscriptions(List<String> cellIds) {
    // Idempotency guard: skip if the cell list hasn't changed and
    // subscriptions are already open.  This prevents the startup double-call
    // (initKeys → _setupSubscriptions, then _startNostrIfConnected → start()
    // → _setupSubscriptions again) from closing+reopening subscriptions
    // unnecessarily, which can cause events to be missed during the gap.
    final sortedNew = [...cellIds]..sort();
    final sortedOld = [..._lastSubscribedCellIds]..sort();
    if (sortedNew.join(',') == sortedOld.join(',') && _proposalSubId != null) {
      print('[NOSTR] refreshGovernanceSubscriptions: no change '
          '(${cellIds.length} cells, sub=$_proposalSubId) — skipping');
      return;
    }

    print('[NOSTR] refreshGovernanceSubscriptions: ${cellIds.length} cells');
    for (final id in cellIds) {
      print('[NOSTR]   - ${id.substring(0, id.length.clamp(0, 12))}…');
    }
    if (_keys == null) {
      print('[NOSTR] refreshGovernanceSubscriptions: keys not ready, skipping');
      return;
    }
    _lastSubscribedCellIds = List.from(cellIds);
    if (cellIds.isEmpty) {
      print('[NOSTR] No cells — closing existing governance subs');
      // No cells — close existing subs if any.
      if (_proposalSubId != null) {
        _relayManager.closeSubscription(_proposalSubId!);
        _proposalSubId = null;
      }
      if (_voteSubId != null) {
        _relayManager.closeSubscription(_voteSubId!);
        _voteSubId = null;
      }
      if (_decisionSubId != null) {
        _relayManager.closeSubscription(_decisionSubId!);
        _decisionSubId = null;
      }
      return;
    }

    final nowSeconds = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final since = nowSeconds - 30 * 86400; // 30 days back

    final cellTags = cellIds.map((id) => 'nexus-cell-$id').toList();
    print('[NOSTR] Governance #t tags: $cellTags');

    if (_proposalSubId != null) _relayManager.closeSubscription(_proposalSubId!);
    _proposalSubId = _relayManager.subscribe({
      'kinds': [NostrKind.proposalEvent],
      '#t': cellTags,
      'since': since,
    });
    print('[NOSTR] Subscription Kind-31010 #t tags: $cellTags');
    print('[PROPOSAL] Proposal sub: $_proposalSubId  (${cellIds.length} cells)');

    if (_voteSubId != null) _relayManager.closeSubscription(_voteSubId!);
    _voteSubId = _relayManager.subscribe({
      'kinds': [NostrKind.voteEvent],
      '#t': cellTags,
      'since': since,
    });
    print('[NOSTR] Subscription Kind-31011 #t tags: $cellTags');
    print('[VOTE] Vote sub: $_voteSubId  (${cellIds.length} cells)');

    if (_decisionSubId != null) _relayManager.closeSubscription(_decisionSubId!);
    _decisionSubId = _relayManager.subscribe({
      'kinds': [NostrKind.decisionRecord],
      '#t': cellTags,
      'since': since,
    });
    print('[NOSTR] Subscription Kind-31013 #t tags: $cellTags');
    print('[PROPOSAL] Decision sub: $_decisionSubId  (${cellIds.length} cells)');
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
    final msgType = message.metadata?['type'] as String?;
    if (recipientNostrPubkey == null) {
      print('[NOSTR] DM send FAILED – no Nostr pubkey known for DID: '
          '${message.toDid}  (known DIDs: ${_didToNostrPubkey.keys.join(', ')})');
      if (msgType == 'contact_request') {
        print('[ContactRequest] SEND FAILED – Windows Nostr pubkey not in map. '
            'Ensure Windows has broadcast presence before sending request.');
      }
      // Throw so the TransportManager cascade can try the next transport.
      throw StateError('No Nostr pubkey for recipient: ${message.toDid}');
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

  /// Publishes a Kind-0 (NIP-01) metadata event with our own display name
  /// and, if set, profile picture as a base64 data URL.
  ///
  /// Relays store only the latest kind-0 per pubkey, so contacts can fetch it
  /// at any time to learn our pseudonym even without a live presence event.
  Future<void> _publishMetadata() async {
    if (_keys == null) return;
    final name = _effectivePseudonym;
    final profile = ProfileService.instance.currentProfile;
    debugPrint('[Nostr] _publishMetadata called  name=$name');

    // Only embed the profile picture when the user has set visibility to
    // "public" (Alle). For any more restrictive level the picture field is
    // omitted – Nostr relays are public infrastructure and anyone can read
    // Kind-0 events.
    String? pictureDataUrl;
    final imageVisibility =
        profile?.profileImage.visibility ?? VisibilityLevel.contacts;
    if (imageVisibility == VisibilityLevel.public) {
      final imagePath = profile?.profileImage.value;
      debugPrint('[Nostr] profileImage visibility=public, imagePath=$imagePath');
      pictureDataUrl =
          await ProfileImageService.instance.toBase64DataUrl(imagePath);
    } else {
      debugPrint('[Nostr] profileImage visibility=$imageVisibility → omitting picture from Kind-0');
    }

    final bio = profile?.bio.value;
    final content = <String, dynamic>{
      'name': name,
      'about': (bio != null && bio.isNotEmpty) ? bio : 'DID: $localDid',
    };
    if (pictureDataUrl != null) content['picture'] = pictureDataUrl;

    // Generic NEXUS profile block – all non-private, non-empty fields.
    final nexusFields = profile?.toNexusKind0() ?? {};
    if (nexusFields.isNotEmpty) content['nexus_profile'] = nexusFields;

    debugPrint('[Kind0-Send] about=${content["about"]}');
    debugPrint('[Nostr] picture field present: ${content.containsKey("picture")}  '
        'length: ${(content["picture"] as String?)?.length ?? 0}');

    final event = NostrEvent.create(
      keys: _keys!,
      kind: NostrKind.metadata,
      content: jsonEncode(content),
      tags: [],
    );
    _relayManager.publish(event);
    debugPrint('[Nostr] Kind-0 event published: ${event.id}');
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

  /// Actively fetches the latest Kind-0 metadata for a single contact's
  /// Nostr pubkey.  The relay will return the newest stored kind-0 event,
  /// which is then processed by the existing [_handleMetadataEvent] handler.
  /// The subscription is closed after [timeout] (default 5 s).
  void fetchContactMetadata(
    String nostrPubkey, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    if (_state != TransportState.connected) return;
    debugPrint('[Nostr] Active Kind-0 fetch for pubkey=${nostrPubkey.substring(0, 8)}…');
    final subId = _relayManager.subscribe({
      'kinds': [NostrKind.metadata],
      'authors': [nostrPubkey],
    });
    Future.delayed(timeout, () {
      _relayManager.closeSubscription(subId);
      debugPrint('[Nostr] Kind-0 fetch sub closed: $subId');
    });
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

    // Cell announcements (Kind-30000, parameterized replaceable) — all time.
    if (_cellSubId != null) _relayManager.closeSubscription(_cellSubId!);
    _cellSubId = _relayManager.subscribe({
      'kinds': [NostrKind.cellAnnounce],
      '#t': ['nexus-cell'],
    });
    print('[CELL] Subscribed to cell announcements, subId=$_cellSubId');

    // Cell join requests (Kind-31003) — founders receive these from non-contacts.
    if (_cellJoinSubId != null) _relayManager.closeSubscription(_cellJoinSubId!);
    _cellJoinSubId = _relayManager.subscribe({
      'kinds': [NostrKind.cellJoinRequest],
      '#t': ['nexus-cell-join'],
      'since': nowSeconds - 7 * 86400,
    });
    print('[JOIN] Subscribed to cell join requests, subId=$_cellJoinSubId');

    // Cell membership confirmations (Kind-31004) — applicants receive these.
    if (_cellMembershipSubId != null) {
      _relayManager.closeSubscription(_cellMembershipSubId!);
    }
    _cellMembershipSubId = _relayManager.subscribe({
      'kinds': [NostrKind.cellMembershipConfirmed],
      '#p': [myPubkey],
      'since': nowSeconds - 7 * 86400,
    });
    print('[JOIN] Subscribed to membership confirmations for $myPubkey, subId=$_cellMembershipSubId');

    // Cell member updates (Kind-31005) — leave + remove events.
    if (_cellMemberUpdateSubId != null) {
      _relayManager.closeSubscription(_cellMemberUpdateSubId!);
    }
    _cellMemberUpdateSubId = _relayManager.subscribe({
      'kinds': [NostrKind.cellMemberUpdate],
      '#t': ['nexus-cell-member-update'],
      'since': nowSeconds - 7 * 86400,
    });
    print('[CELL] Subscribed to member-update events, subId=$_cellMemberUpdateSubId');

    // Dorfplatz feed posts + comments (Kind-1/6 with nexus-dorfplatz* tags),
    // Kind-7 reactions, Kind-5 deletions — tag-based subscription for last 7 days.
    if (_feedSubId != null) _relayManager.closeSubscription(_feedSubId!);
    _feedSubId = _relayManager.subscribe({
      'kinds': [
        NostrKind.textNote,
        NostrKind.deletion,
        NostrKind.repost,
        NostrKind.reaction,
      ],
      '#t': ['nexus-dorfplatz', 'nexus-dorfplatz-comment'],
      'since': nowSeconds - 7 * 86400,
    });
    print('[NOSTR] Feed sub: $_feedSubId');

    // Author-based feed subscription: fetch own posts + known contacts' posts
    // from the last 30 days.  This restores posts after a seed-phrase restore
    // when the local DB is empty but Nostr still holds the events.
    final feedAuthors = <String>{
      if (myPubkey.isNotEmpty) myPubkey,
      ...ContactService.instance.contacts
          .where((c) => c.nostrPubkey != null && c.nostrPubkey!.isNotEmpty)
          .map((c) => c.nostrPubkey!),
    };
    if (feedAuthors.isNotEmpty) {
      _relayManager.subscribe({
        'kinds': [NostrKind.textNote],
        'authors': feedAuthors.toList(),
        '#t': ['nexus-dorfplatz'],
        'since': nowSeconds - 30 * 86400,
      });
      print('[NOSTR] Feed author-sync sub: ${feedAuthors.length} authors '
          '(own + contacts), last 30 days');
    }

    // Dedicated Kind-6 repost subscription — author-based WITHOUT #t filter.
    // Public Nostr relays do not index Kind-6 events by arbitrary tags, so a
    // #t filter silently returns nothing for reposts.  Using only 'authors'
    // ensures we get all reposts from contacts regardless of relay implementation.
    if (_feedRepostSubId != null) {
      _relayManager.closeSubscription(_feedRepostSubId!);
    }
    final repostAuthors = feedAuthors; // same set: own pubkey + contact pubkeys
    if (repostAuthors.isNotEmpty) {
      _feedRepostSubId = _relayManager.subscribe({
        'kinds': [NostrKind.repost],
        'authors': repostAuthors.toList(),
        'since': nowSeconds - 30 * 86400,
      });
      print('[FEED-SUB] kind=6 Autoren-Subscription: ${repostAuthors.length} '
          'autoren since=${nowSeconds - 30 * 86400}');
    } else {
      _feedRepostSubId = null;
      print('[FEED-SUB] kind=6 Autoren-Subscription: keine Autoren bekannt, '
          'übersprungen');
    }

    // G2 governance — proposals, votes, decision records for all joined cells.
    // Import is deferred to avoid circular dependency; access via late import.
    _setupGovernanceSubscriptions();
  }

  /// Sets up proposal/vote/decision subscriptions for all cells the local user
  /// is currently a member of.  Called from [_setupSubscriptions] and also
  /// by [refreshGovernanceSubscriptions] when the cell list changes.
  void _setupGovernanceSubscriptions() {
    // Lazy import pattern: access CellService via its singleton.
    // We need the cellIds of all cells the user has joined.
    try {
      // CellService is initialized before NostrTransport starts, so this is safe.
      // We import it dynamically to avoid a circular dependency at the file level.
      // The import is already present in the file (cell_service is separate package).
      // We use a helper that ChatProvider can set to provide the cell ID list.
      final cellIds = _governanceCellIds;
      if (cellIds.isEmpty) {
        print('[PROPOSAL] No cells to subscribe to governance events');
        return;
      }
      refreshGovernanceSubscriptions(cellIds);
    } catch (e) {
      print('[PROPOSAL] _setupGovernanceSubscriptions error: $e');
    }
  }

  /// Cell IDs to subscribe governance events for.  Set by [ChatProvider] after
  /// joining/leaving cells so subscriptions stay accurate.
  List<String> _governanceCellIds = [];

  /// Updates the list of cell IDs used for governance subscriptions and
  /// refreshes the subscriptions immediately.
  void updateGovernanceCellIds(List<String> cellIds) {
    _governanceCellIds = List.from(cellIds);
    print('[NOSTR] updateGovernanceCellIds: ${cellIds.length} cells, '
        'state=$_state, keysReady=${_keys != null}');
    // Refresh whenever the transport is live (connected or scanning means
    // relays are up and subscriptions can be opened/replaced).
    if (_keys != null &&
        (_state == TransportState.connected ||
            _state == TransportState.scanning)) {
      refreshGovernanceSubscriptions(_governanceCellIds);
    }
  }

  /// Re-runs [_setupSubscriptions] so that freshly restored contacts, channels,
  /// and cells are included in the active Nostr filters.
  ///
  /// Call this after a backup restore once all services have finished merging
  /// their data into memory.
  void resetSubscriptions() {
    print('[RESTORE] Resetting Nostr subscriptions after backup restore…');
    _setupSubscriptions();
    print('[RESTORE] Subscriptions successfully reset');
  }

  void _onRelayEvent(NostrEvent event) {
    if (_keys == null) return;

    switch (event.kind) {
      case NostrKind.metadata:
        _handleMetadataEvent(event);
      case NostrKind.encryptedDm:
        _handleDm(event);
      case NostrKind.textNote:
        final tags = event.tagValues('t');
        if (tags.contains('nexus-dorfplatz-comment')) {
          _handleFeedComment(event);
        } else if (tags.contains('nexus-dorfplatz')) {
          _handleFeedPost(event);
        } else {
          _handleBroadcast(event);
        }
      case NostrKind.deletion:
        _handleFeedDeletion(event);
      case NostrKind.repost:
        _handleFeedPost(event);
      case NostrKind.reaction:
        _handleReaction(event);
      case NostrKind.channelCreate:
        _handleChannelCreateEvent(event);
      case NostrKind.channelMessage:
        _handleChannelMessageEvent(event);
      case NostrKind.presence:
        _handlePresenceEvent(event);
      case NostrKind.cellAnnounce:
        _handleCellAnnounceEvent(event);
      case NostrKind.cellJoinRequest:
        _handleCellJoinRequestEvent(event);
      case NostrKind.cellMembershipConfirmed:
        _handleCellMembershipConfirmedEvent(event);
      case NostrKind.cellMemberUpdate:
        _handleCellMemberUpdateEvent(event);
      case NostrKind.proposalEvent:
        _handleProposalEvent(event);
      case NostrKind.voteEvent:
        _handleVoteEvent(event);
      case NostrKind.decisionRecord:
        _handleDecisionRecordEvent(event);
    }
  }

  void _handleProposalEvent(NostrEvent event) {
    print('[PROPOSAL] Kind-31010 received: ${event.id}');
    _proposalEventController.add(event);
  }

  void _handleVoteEvent(NostrEvent event) {
    print('[VOTE] handleIncomingVote: ${event.id}');
    _voteEventController.add(event);
  }

  void _handleDecisionRecordEvent(NostrEvent event) {
    print('[PROPOSAL] Kind-31013 decision record received: ${event.id}');
    _decisionRecordController.add(event);
  }

  void _handleFeedPost(NostrEvent event) {
    if (_keys == null) return;
    if (event.pubkey == _keys!.publicKeyHex) return; // own event, already stored
    try {
      final data = jsonDecode(event.content) as Map<String, dynamic>;
      _feedPostController.add({
        ...data,
        'nostrEventId': event.id,
        '_nostrPubkey': event.pubkey,
      });
    } catch (e) {
      print('[NOSTR] Feed post parse FAILED: $e');
    }
  }

  void _handleFeedComment(NostrEvent event) {
    if (_keys == null) return;
    if (event.pubkey == _keys!.publicKeyHex) return; // own event
    try {
      final data = jsonDecode(event.content) as Map<String, dynamic>;
      _feedCommentController.add({
        ...data,
        'nostrEventId': event.id,
        '_nostrPubkey': event.pubkey,
      });
    } catch (e) {
      print('[NOSTR] Feed comment parse FAILED: $e');
    }
  }

  void _handleReaction(NostrEvent event) {
    if (_keys == null) return;
    if (event.pubkey == _keys!.publicKeyHex) return; // own reaction
    final referencedEventId = event.tagValue('e');
    if (referencedEventId == null) {
      print('[REACTION-RECV] Kind-7 received but missing e-tag — ignored');
      return;
    }
    final shortTarget = referencedEventId.length >= 8
        ? referencedEventId.substring(0, 8)
        : referencedEventId;
    final shortSender = event.pubkey.length >= 8
        ? event.pubkey.substring(0, 8)
        : event.pubkey;
    print('[REACTION-RECV] Kind-7 received: emoji=${event.content} target=$shortTarget…');
    print('[REACTION-RECV] sender=$shortSender… → dispatching to feed+chat handlers');
    _feedReactionController.add({
      'emoji': event.content,
      'referencedEventId': referencedEventId,
      'senderPubkey': event.pubkey,
    });
  }

  /// Handles incoming NIP-09 Kind-5 deletion requests.
  ///
  /// Reads all ['e', <nostrEventId>] tags and emits the list of IDs to delete.
  /// Only processes events from other peers — own deletions are already applied
  /// locally in FeedService.deletePost() before the event is published.
  void _handleFeedDeletion(NostrEvent event) {
    if (_keys == null) return;
    if (event.pubkey == _keys!.publicKeyHex) return; // own deletion, already applied locally
    final ids = event.tagValues('e');
    if (ids.isEmpty) return;
    final tTags = event.tagValues('t');
    final isDorfplatz = tTags.contains('nexus-dorfplatz');
    // Distinguish Dorfplatz post deletions (have t=nexus-dorfplatz) from
    // chat message deletions (no t-tag) so we can diagnose routing gaps.
    final prefix = isDorfplatz ? 'FEED-DELETE-RECV' : 'MSG-DELETE-RECV';
    final shortSender = event.pubkey.length >= 8
        ? event.pubkey.substring(0, 8)
        : event.pubkey;
    print('[$prefix] Kind-5 received from $shortSender…: '
        '${ids.length} e-tag(s), t-tags=$tTags');
    for (final id in ids) {
      final shortId = id.length >= 8 ? id.substring(0, 8) : id;
      print('[$prefix]   e-tag: $shortId…');
    }
    if (!isDorfplatz) {
      print('[MSG-DELETE-RECV] ⚠ Chat-Löschung hat keinen separaten Recv-Handler — '
          'wird an FeedService weitergeleitet (wird dort nicht matchen)');
    }
    _feedDeleteController.add(ids);
  }

  void _handleCellAnnounceEvent(NostrEvent event) {
    try {
      // IMPORT FILTER — check the 'deleted' tag BEFORE parsing JSON content.
      // This is faster and works even if the content is malformed.
      final isDeletedByTag = event.tagValue('deleted') == 'true';

      final data = jsonDecode(event.content) as Map<String, dynamic>;
      final cellId = data['id'] as String? ?? event.tagValue('d') ?? '?';
      final cellName = data['name'] as String? ?? '?';
      final isOwnPubkey = _keys != null && event.pubkey == _keys!.publicKeyHex;

      // ── ZOMBIE-V3 ────────────────────────────────────────────────────────
      if (kDebugMode) {
        print('[ZOMBIE-V3] Nostr event: kind=30000, id=${event.id.substring(0, 8)}…,'
            ' cellId=$cellId, name="$cellName",'
            ' from=${event.pubkey.substring(0, 8)}…,'
            ' self=$isOwnPubkey,'
            ' deleted=$isDeletedByTag,'
            ' createdAt=${event.createdAt}');
      }
      // ────────────────────────────────────────────────────────────────────

      // ── ZOMBIE-DIAG ─────────────────────────────────────────────────────
      if (kDebugMode) {
        print('[ZOMBIE-DIAG] Incoming Kind-30000: "$cellName" id=$cellId'
            '  deleted=$isDeletedByTag|${data['deleted']}'
            '  createdAt=${event.createdAt}'
            '  pubkey=${event.pubkey.substring(0, 8)}…');
      }
      // ────────────────────────────────────────────────────────────────────

      // Dissolution marker: either via content JSON or via explicit tag.
      if (isDeletedByTag || data['deleted'] == true) {
        print('[CELL-DEL] Import blocked for cell $cellId (deleted flag)');
        if (kDebugMode) print('[ZOMBIE-DIAG]   RESULT: DISSOLUTION — emitting to cellDeleted stream');
        // Always emit — even for own-pubkey events.  The same seed may be
        // used on multiple devices; a dissolution published on Android must
        // also update the block list on Windows.
        _cellDeletedController.add({
          'id': cellId,
          'name': cellName,
          'nostrTag': data['nostrTag'] as String? ?? 'nexus-cell-$cellId',
        });
        return;
      }

      // ── ZOMBIE-FIX: skip own-published non-deletion announcements ─────────
      // Own cells are already loaded from the local DB on startup.
      // Re-importing them from Nostr would bypass the tombstone filter and
      // re-surface dissolved cells as zombie entries.
      // Dissolution events (deleted=true) are intentionally kept above so that
      // a seed used on multiple devices still propagates tombstones.
      //
      // EXCEPTION: the same seed may be used on multiple devices (e.g. Android
      // + Windows).  If a cell was renamed on one device it publishes a new
      // Kind-30000 with the same pubkey.  The other device must receive that
      // update, so we pass own-pubkey events through marked as `_own_device`.
      // CellService.addDiscoveredCell uses this flag to update-in-place rather
      // than skip or re-import.
      print('[CELL-UPDATE] Incoming Kind-30000: cellId=$cellId, name="$cellName", version=n/a, self=$isOwnPubkey');
      // ─────────────────────────────────────────────────────────────────────

      print('[CELL] Received cell announcement: $cellId ($cellName) '
          'from pubkey=${event.pubkey.substring(0, 8)}…');
      if (kDebugMode) print('[ZOMBIE-DIAG]   RESULT: ANNOUNCEMENT — passing to onCellAnnounced stream');
      _cellAnnouncedController.add({
        ...data,
        '_nostr_pubkey': event.pubkey,
        '_created_at': event.createdAt,
        '_own_device': isOwnPubkey,
      });
    } catch (e) {
      print('[CELL] Cell announce parse FAILED: $e');
    }
  }

  void _handleCellJoinRequestEvent(NostrEvent event) {
    if (_keys == null) return;
    // Ignore our own events (already stored locally by CellService).
    if (event.pubkey == _keys!.publicKeyHex) return;
    try {
      final data = jsonDecode(event.content) as Map<String, dynamic>;
      final cellId = event.tagValue('cell') ?? data['cellId'] as String? ?? '?';
      final action = data['action'] as String?;

      if (action == 'withdraw') {
        // Requester is withdrawing a previously sent join request.
        final requestId = data['id'] as String? ?? '';
        print('[JOIN] Withdraw received, removing pending request: $requestId');
        _cellJoinRequestController.add({
          ...data,
          'action': 'withdraw',
          'requesterNostrPubkey': event.pubkey,
        });
        return;
      }

      final requesterPseudonym = data['requesterPseudonym'] as String? ?? '?';
      print('[JOIN] Request received from non-contact: ${event.pubkey.substring(0, 8)}… '
          '($requesterPseudonym) for cell: $cellId — ALLOWED (cell join)');
      // Enrich with the sender's Nostr pubkey so the founder can send
      // the Kind-31004 confirmation even without a contact relationship.
      _cellJoinRequestController.add({
        ...data,
        'requesterNostrPubkey': event.pubkey,
      });
    } catch (e) {
      print('[JOIN] Cell join request parse FAILED: $e');
    }
  }

  void _handleCellMembershipConfirmedEvent(NostrEvent event) {
    if (_keys == null) return;
    // Only process events addressed to us.
    if (!event.tagValues('p').contains(_keys!.publicKeyHex)) return;
    try {
      final data = jsonDecode(event.content) as Map<String, dynamic>;
      final cellId = event.tagValue('cell') ?? '?';
      print('[JOIN] Membership confirmation received for cell: $cellId');
      _cellMembershipConfirmedController.add(data);
    } catch (e) {
      print('[JOIN] Cell membership confirmation parse FAILED: $e');
    }
  }

  void _handleCellMemberUpdateEvent(NostrEvent event) {
    if (_keys == null) return;
    // Ignore our own events (we handle them locally already).
    if (event.pubkey == _keys!.publicKeyHex) return;
    try {
      final data = jsonDecode(event.content) as Map<String, dynamic>;
      final cellId = event.tagValue('cell') ?? data['cellId'] as String? ?? '?';
      final action = data['action'] as String? ?? 'left';
      final targetDid = data['targetDid'] as String? ?? '';
      print('[CELL] Kind-31005 member-$action event received for cell: $cellId '
          '(target: ${targetDid.length > 20 ? '${targetDid.substring(0, 20)}…' : targetDid})');
      _cellMemberUpdateController.add(data);
    } catch (e) {
      print('[CELL] Cell member-update parse FAILED: $e');
    }
  }

  void _handleChannelCreateEvent(NostrEvent event) {
    try {
      final data = jsonDecode(event.content) as Map<String, dynamic>;
      final channelName = data['name'] as String? ?? '?';
      final channelId = data['id'] as String? ?? '?';
      final shortSender = event.pubkey.length >= 8
          ? event.pubkey.substring(0, 8)
          : event.pubkey;
      print('[CHANNEL-CREATE-RECV] Kind-40 received from $shortSender…: '
          'name=$channelName id=$channelId');
      print('[CHANNEL-CREATE-RECV] Dispatching to channel discovery stream');
      // Emit so GroupChannelService / ChatProvider can add to discovered list.
      _channelAnnouncedController.add({
        ...data,
        '_nostr_pubkey': event.pubkey,
        '_created_at': event.createdAt,
      });
    } catch (e) {
      print('[CHANNEL-CREATE-RECV] ✗ Parse FAILED: $e');
    }
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

    final myPubkey = _keys!.publicKeyHex;
    final isForMe = event.tagValues('p').contains(myPubkey);
    print('[ContactRequest] incoming event received: ${event.kind}');
    print('[ContactRequest] for my pubkey: $isForMe '
        '(mine: ${myPubkey.substring(0, 8)}… '
        'p-tags: ${event.tagValues('p').map((k) => k.substring(0, 8)).join(', ')})');
    print('[NOSTR] DM received from pubkey: ${event.pubkey.substring(0, 8)}…, '
        'event: ${event.id.substring(0, 8)}…  decrypting…');
    print('[SYNC] Received event: ${event.id.substring(0, 8)} '
        'kind=${event.kind} created_at=${event.createdAt}');

    try {
      final senderPubBytes = Uint8List.fromList(_hexToBytes(event.pubkey));
      final plaintext = await _nip04Decrypt(event.content, senderPubBytes);
      final msgJson = jsonDecode(plaintext) as Map<String, dynamic>;
      final message = NexusMessage.fromJson(msgJson);

      final msgType = message.metadata?['type'] as String?;
      print('[NOSTR] DM decrypted OK: ${message.fromDid} → ${message.toDid}'
          '${msgType != null ? '  type=$msgType' : ''}');
      if (msgType == 'contact_request') {
        print('[ContactRequest] contact_request DM arrived – routing to service');
      }
      print('[SYNC] Stored message: ${message.id}');
      _learnPeer(event.pubkey, message.fromDid, message.metadata);
      _msgController.add(message);
    } catch (e) {
      print('[NOSTR] DM decrypt FAILED (not for us or malformed): $e');
      print('[ContactRequest] decrypt error detail: $e');
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
      final picture = data['picture'] as String?;
      final about = (data['about'] as String?)?.trim();
      final website = (data['website'] as String?)?.trim();
      final nip05 = (data['nip05'] as String?)?.trim();

      debugPrint('[Kind0-Recv] pubkey=${event.pubkey.substring(0, 8)}');
      debugPrint('[Kind0-Recv] about=${data["about"]}');
      debugPrint('[Kind0-Recv] raw content=$data');
      debugPrint('[Nostr] picture field in event: ${data.containsKey("picture")}  '
          'length: ${picture?.length ?? 0}');

      // Resolve the DID for this Nostr pubkey via the reverse map.
      final did = _didToNostrPubkey.entries
          .where((e) => e.value == event.pubkey)
          .map((e) => e.key)
          .firstOrNull;

      if (did != null) {
        debugPrint('[Nostr] Kind-0 resolved DID: …${did.length > 8 ? did.substring(did.length - 8) : did}');
        if (resolved.isNotEmpty) {
          final oldName =
              ContactService.instance.findByDid(did)?.pseudonym ?? '?';
          debugPrint('[Nostr] Kind-0 updating contact: "$oldName" → "$resolved"');
          ContactService.instance.updatePseudonymIfBetter(did, resolved);
        }
        // Save about/website/nip05 if present.
        // Skip the "DID: did:key:…" placeholder we inject ourselves.
        final aboutClean = (about != null &&
                !about.startsWith('DID: did:key:') &&
                !about.startsWith('DID: did:web:'))
            ? about
            : null;
        if (aboutClean != null || website != null || nip05 != null) {
          ContactService.instance.updateMetadataFields(
            did,
            about: aboutClean,
            website: website,
            nip05: nip05,
          );
        }

        // Generic NEXUS profile block (languages, realName, location, skills, …).
        final nexusProfile = data['nexus_profile'];
        if (nexusProfile is Map<String, dynamic> && nexusProfile.isNotEmpty) {
          debugPrint('[Kind0-Recv] nexus_profile keys: ${nexusProfile.keys.toList()}');
          ContactService.instance.updateNexusProfile(did, nexusProfile);
        }
        // Save profile picture if provided and the cached file is missing.
        if (picture != null && picture.isNotEmpty) {
          final contact = ContactService.instance.findByDid(did);
          _savePeerPicture(did, picture, contact?.profileImage);
        }
      } else {
        debugPrint('[Nostr] Kind-0 DID not found for pubkey: ${event.pubkey}  '
            '(known mappings: ${_didToNostrPubkey.length})');
      }
    } catch (_) {}
  }

  /// Saves a peer's profile picture (base64 data URL or HTTPS URL) to a local
  /// file and updates the contact record.  Runs asynchronously to avoid
  /// blocking the event handler.
  void _savePeerPicture(
      String did, String picture, String? existingPath) {
    // Skip only if the cached file actually exists on disk.
    if (existingPath != null && File(existingPath).existsSync()) {
      debugPrint('[Nostr] _savePeerPicture: already cached at $existingPath, skip');
      return;
    }

    if (picture.startsWith('data:')) {
      // Embedded base64 image – decode and save locally.
      ProfileImageService.instance.saveFromBase64(picture).then((path) {
        if (path != null) {
          ContactService.instance.updateProfileImage(did, path);
          debugPrint('[Nostr] Saved peer picture to $path  '
              'did=…${did.length > 8 ? did.substring(did.length - 8) : did}');
        }
      }).catchError((_) {});
    }
    // HTTPS URLs are intentionally not downloaded here (no http dependency in
    // the transport layer).  A future enhancement could add a download step.
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
