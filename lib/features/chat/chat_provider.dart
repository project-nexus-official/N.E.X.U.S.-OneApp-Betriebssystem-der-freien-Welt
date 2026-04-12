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
import '../../core/crypto/channel_encryption.dart';
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
import '../../services/contact_request_service.dart';
import '../../services/notification_service.dart';
import '../../services/notification_settings.dart';
import '../../shared/widgets/notification_banner.dart';
import '../../core/roles/role_enums.dart';
import 'channel_access_service.dart';
import 'conversation_service.dart';
import 'group_channel.dart';
import 'group_channel_service.dart';
import '../dorfplatz/feed_service.dart';
import '../governance/cell.dart';
import '../governance/cell_join_request.dart';
import '../governance/cell_member.dart';
import '../governance/cell_service.dart';
import '../governance/proposal_service.dart';
import '../../services/invite_service.dart';

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

  /// Actively fetches the latest Kind-0 metadata from Nostr relays for [did].
  /// No-op if the contact has no known Nostr pubkey or Nostr is not connected.
  void fetchContactMetadata(String did) {
    final contact = ContactService.instance.findByDid(did);
    final pubkey = contact?.nostrPubkey;
    if (pubkey == null || pubkey.isEmpty) return;
    _nostrTransport?.fetchContactMetadata(pubkey);
  }

  List<NexusPeer> get peers => _manager.peers;

  /// The local Nostr public key as hex (available after transport start).
  String? get nostrPubkeyHex => _nostrTransport?.localNostrPubkeyHex;

  /// Registers a DID → Nostr pubkey mapping so DMs can be sent to peers
  /// who are not yet contacts (e.g. cell-join applicants).
  void registerPeerNostrPubkey(String did, String nostrPubkeyHex) {
    _nostrTransport?.registerDidMapping(did, nostrPubkeyHex);
  }

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
  Timer? _muteExpiryTimer;

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

      // Wire FeedService to the Nostr transport for publishing and receiving.
      FeedService.instance.setNostrPublisher((kind, content, tags) =>
          _nostrTransport?.publishFeedEvent(kind, content, tags));
      _nostrTransport!.onFeedPost
          .listen((data) => FeedService.instance.handleIncomingPost(data));
      _nostrTransport!.onFeedComment
          .listen((data) => FeedService.instance.handleIncomingComment(data));
      _nostrTransport!.onFeedReaction.listen(_handleIncomingReaction);
      _nostrTransport!.onFeedDelete
          .listen((ids) => FeedService.instance.handleIncomingDelete(ids));

      // Wire CellService to Nostr for join requests and membership confirmations.
      // These bypass the contact system so strangers can apply to join cells.
      CellService.instance.onPublishJoinRequest =
          (reqJson) => _nostrTransport?.publishCellJoinRequest(reqJson);
      CellService.instance.onPublishMembershipConfirmed =
          (cellJson, memberJson, pubkeyHex) =>
              _nostrTransport?.publishCellMembershipConfirmed(
                  cellJson, memberJson, pubkeyHex);
      CellService.instance.onRegisterNostrMapping =
          (did, pubkey) => _nostrTransport?.registerDidMapping(did, pubkey);
      CellService.instance.onPublishMemberUpdate =
          ({required cellId, required targetDid, required action, reason}) =>
              _nostrTransport?.publishCellMemberUpdate(
                  cellId: cellId,
                  targetDid: targetDid,
                  action: action,
                  reason: reason);
      _nostrTransport!.onCellJoinRequest.listen(_onCellJoinRequest);
      _nostrTransport!.onCellMembershipConfirmed
          .listen(_onCellMembershipConfirmed);
      _nostrTransport!.onCellMemberUpdate.listen(_onCellMemberUpdate);

      // G2 governance – wire ProposalService callbacks to NostrTransport.
      _wireGovernanceTransport();

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
      await ChannelAccessService.instance.load();

      // Clear any already-expired mutes on startup, then check every 60 s.
      await ContactService.instance.clearExpiredMutes();
      _muteExpiryTimer?.cancel();
      _muteExpiryTimer = Timer.periodic(
        const Duration(seconds: 60),
        (_) => ContactService.instance.clearExpiredMutes(),
      );

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

      // Listen for newly discovered cells via Kind-30000.
      if (_nostrTransport != null) {
        _nostrTransport!.onCellAnnounced.listen(_onCellAnnounced);
        _nostrTransport!.onCellDeleted.listen(_onCellDeleted);
      }

      // Re-subscribe when channel list changes (join/leave).
      GroupChannelService.instance.joinedStream.listen((channels) {
        for (final ch in channels) {
          _nostrTransport?.subscribeToChannel(ch.nostrTag);
        }
      });

      // Retrofit existing cells that don't yet have internal channels.
      await _retrofitCellChannels(myDid);

      // Wire up callback so new cell memberships auto-create channels.
      CellService.instance.onMembershipConfirmed = (cell, did) =>
          subscribeToCellChannels(cell, did);

      // Wire up callback so approved members get a welcome post.
      CellService.instance.onMemberApproved =
          (cellId, pseudonym) async {
        final msg = '$pseudonym ist der Zelle beigetreten! 🌱';
        debugPrint('[CELL] Welcome message posted in discussion: $pseudonym');
        await postCellSystemMessage(cellId, msg);
      };

      // Republish all cells where the local user is FOUNDER so that other
      // devices can discover them. We delay by 3 s to let relays connect first.
      Future.delayed(const Duration(seconds: 3), _republishMyCells);
    } catch (e) {
      debugPrint('[CHAT] Channel init failed: $e');
    }
  }

  /// Creates Pinnwand + Diskussion channels for [cell] if they don't exist yet.
  /// Subscribes to their Nostr tags and posts a welcome message in Diskussion.
  Future<void> createCellInternalChannels(Cell cell, String myDid) async {
    final existing = GroupChannelService.instance.cellChannelsFor(cell.id);
    if (existing.length >= 2) {
      debugPrint('[CELL] Cell ${cell.id} already has internal channels – skipping');
      return;
    }
    debugPrint('[CELL] Creating cell internal channels for cellId: ${cell.id}');

    // Bulletin (Pinnwand) – announcement mode, only founder/mod can post.
    final bulletinName = '#cell-${cell.id}-bulletin';
    if (!GroupChannelService.instance.isJoined(bulletinName)) {
      final bulletin = GroupChannel.create(
        name: bulletinName,
        description: 'Pinnwand von ${cell.name}',
        createdBy: myDid,
        isPublic: false,
        isDiscoverable: false,
        channelMode: ChannelMode.announcement,
        cellId: cell.id,
      );
      await GroupChannelService.instance.createChannel(bulletin);
      _nostrTransport?.subscribeToChannel(bulletin.nostrTag);
      debugPrint('[CELL] Pinnwand channel created: ${bulletin.id}');
    }

    // Discussion (Diskussion) – all members can post.
    final discussionName = '#cell-${cell.id}-discussion';
    if (!GroupChannelService.instance.isJoined(discussionName)) {
      final discussion = GroupChannel.create(
        name: discussionName,
        description: 'Diskussion von ${cell.name}',
        createdBy: myDid,
        isPublic: false,
        isDiscoverable: false,
        channelMode: ChannelMode.discussion,
        cellId: cell.id,
      );
      await GroupChannelService.instance.createChannel(discussion);
      _nostrTransport?.subscribeToChannel(discussion.nostrTag);
      debugPrint('[CELL] Discussion channel created: ${discussion.id}');
    }
  }

  /// Subscribes to cell-internal channels for a cell the local user just joined.
  Future<void> subscribeToCellChannels(Cell cell, String myDid) async {
    final channels = GroupChannelService.instance.cellChannelsFor(cell.id);
    if (channels.isEmpty) {
      // Channels may not exist locally yet — create/subscribe from cellId convention.
      await createCellInternalChannels(cell, myDid);
      return;
    }
    for (final ch in channels) {
      if (!GroupChannelService.instance.isJoined(ch.name)) {
        await GroupChannelService.instance.joinChannel(ch);
      }
      _nostrTransport?.subscribeToChannel(ch.nostrTag);
      debugPrint('[CELL] Member joined, subscribing to cell channels: ${cell.id}');
    }
  }

  /// Posts a system message in the cell's discussion channel.
  /// System messages are sent unencrypted so all members can read them
  /// regardless of whether they hold the channel secret.
  Future<void> postCellSystemMessage(String cellId, String text) async {
    final channels = GroupChannelService.instance.cellChannelsFor(cellId);
    final discussion = channels.where(
      (c) => c.name.endsWith('-discussion'),
    ).firstOrNull;
    if (discussion == null) return;
    await sendToChannel(discussion.name, text,
        extraMeta: {'is_cell_system': true}, skipEncryption: true);
  }

  /// Checks all joined cells and creates internal channels for those missing them.
  Future<void> _retrofitCellChannels(String myDid) async {
    for (final cell in CellService.instance.myCells) {
      final existing = GroupChannelService.instance.cellChannelsFor(cell.id);
      if (existing.length < 2) {
        debugPrint('[CELL] Retrofitting existing cell: ${cell.id}');
        await createCellInternalChannels(cell, myDid);
      }
    }
  }

  /// Leaves cell-internal channels when the local user leaves a cell.
  Future<void> leaveCellChannels(String cellId) async {
    // Post farewell message before leaving.
    final pseudonym =
        IdentityService.instance.currentIdentity?.pseudonym ?? 'Jemand';
    await postCellSystemMessage(cellId, '$pseudonym hat die Zelle verlassen.');

    final channels = GroupChannelService.instance.cellChannelsFor(cellId);
    for (final ch in channels) {
      try {
        await GroupChannelService.instance.leaveChannel(ch.name);
      } catch (_) {}
    }
    debugPrint('[CELL] Left cell channels for $cellId');
  }

  /// Deletes cell-internal channels when a cell is dissolved.
  Future<void> deleteCellChannels(String cellId) async {
    await PodDatabase.instance.deleteCellChannels(cellId);
    // Remove from in-memory joined list.
    final channels = GroupChannelService.instance.cellChannelsFor(cellId);
    for (final ch in channels) {
      try {
        await GroupChannelService.instance.leaveChannel(ch.name);
      } catch (_) {}
    }
    debugPrint('[CELL] Deleted cell channels for $cellId');
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
        isPublic: (data['isPublic'] as bool?) ?? true,
        isDiscoverable: (data['isDiscoverable'] as bool?) ?? true,
        nostrTag: nostrTag,
      );

      final myDid = IdentityService.instance.currentIdentity?.did ?? '';
      final isOwnChannel = channel.createdBy == myDid;
      final alreadyJoined = GroupChannelService.instance.isJoined(channel.name);

      // Diagnostic: show which list the channel lands in.
      print('[CHANNEL-UI] Channel added to UI: ${channel.name}');
      print('[CHANNEL-UI] List source: ${alreadyJoined ? "_joined" : isOwnChannel ? "_joined (auto)" : "_discovered"}'
          ' count=${GroupChannelService.instance.joinedChannels.length}');

      if (alreadyJoined) {
        // Already in _joined — just refresh the UI list.
        ConversationService.instance.notifyUpdate();
        print('[CHANNEL-UI] Rebuild triggered for channel list');
        notifyListeners();
        return;
      }

      if (isOwnChannel) {
        // Channel was created by the current user on another device → auto-join
        // so it appears in the Kanäle tab on this device without manual action.
        GroupChannelService.instance.joinChannel(channel).then((_) {
          ConversationService.instance.notifyUpdate();
          print('[CHANNEL-UI] Rebuild triggered for channel list');
          notifyListeners();
        });
      } else {
        // Another user's channel: add to _discovered for the discovery screen
        // (JoinChannelScreen). It intentionally does NOT appear in the Kanäle tab.
        GroupChannelService.instance.addDiscoveredFromNostr(channel);
        ConversationService.instance.notifyUpdate();
        print('[CHANNEL-UI] Rebuild triggered for channel list');
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[CHAT] Channel announced parse error: $e');
    }
  }

  // ── G2 Governance wiring ──────────────────────────────────────────────────

  void _wireGovernanceTransport() {
    final transport = _nostrTransport;
    if (transport == null) return;

    // Incoming governance events → ProposalService handlers.
    transport.onProposalEvent.listen((event) {
      ProposalService.instance.handleIncomingProposal(event);
    });
    transport.onVoteEvent.listen((event) {
      ProposalService.instance.handleIncomingVote(event);
    });
    transport.onDecisionRecordEvent.listen((event) {
      ProposalService.instance.handleIncomingDecisionRecord(event);
    });

    // Outgoing: ProposalService → NostrTransport publish methods.
    ProposalService.instance.onPublishProposalToNostr = (params) async {
      return transport.publishProposalEvent(
        proposalId: params['proposalId'] as String,
        cellId: params['cellId'] as String,
        type: params['type'] as String,
        status: params['status'] as String,
        title: params['title'] as String,
        description: params['description'] as String,
        creatorDid: params['creatorDid'] as String,
        creatorPseudonym: params['creatorPseudonym'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (params['createdAt'] as int) * 1000,
            isUtc: true),
        version: params['version'] as int,
        category: params['category'] as String?,
        votingEndsAt: params['votingEndsAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(
                (params['votingEndsAt'] as int) * 1000,
                isUtc: true)
            : null,
        editReason: params['editReason'] as String?,
      );
    };

    ProposalService.instance.onPublishVoteToNostr = (params) async {
      return transport.publishVoteEvent(
        proposalId: params['proposalId'] as String,
        cellId: params['cellId'] as String,
        voteId: params['voteId'] as String,
        choiceName: params['choiceName'] as String,
        voterDid: params['voterDid'] as String,
        voterPseudonym: params['voterPseudonym'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (params['createdAt'] as int) * 1000,
            isUtc: true),
        reasoning: params['reasoning'] as String?,
      );
    };

    ProposalService.instance.onPublishDecisionToNostr = (params) async {
      return transport.publishDecisionRecord(
        proposalId: params['proposalId'] as String,
        cellId: params['cellId'] as String,
        recordContent:
            Map<String, dynamic>.from(params['recordContent'] as Map),
        result: params['result'] as String,
        contentHash: params['contentHash'] as String,
        previousDecisionHash: params['previousDecisionHash'] as String?,
      );
    };

    ProposalService.instance.getMyNostrPubkeyHex = () => transport.localNostrPubkeyHex;

    // Discussion messages → broadcast via TransportManager.
    ProposalService.instance.onSendDiscussionMessage = (params) async {
      final myDid = IdentityService.instance.currentIdentity?.did ?? '';
      final msg = NexusMessage.create(
        fromDid: myDid,
        toDid: NexusMessage.broadcastDid,
        body: params['content'] as String,
        metadata: {
          'type': 'proposal_discussion',
          'proposal_id': params['proposalId'] as String,
          'author_pseudo': params['authorPseudonym'] as String,
          'message_id': params['id'] as String,
        },
      );
      await _manager.sendMessage(msg);
    };

    // Direct callback: CellService calls this immediately after any membership
    // change (join / leave / dissolution) so subscriptions stay in sync even
    // when the stream dispatch is asynchronously delayed.
    CellService.instance.onGovernanceMembershipChanged = _refreshGovernanceCellIds;

    // Initial governance subscriptions based on current cell memberships.
    _refreshGovernanceCellIds();

    // Belt-and-suspenders: also listen on the CellService stream in case the
    // direct callback is not triggered (e.g. during a data-restore path).
    CellService.instance.stream.listen((_) => _refreshGovernanceCellIds());
  }

  void _refreshGovernanceCellIds() {
    final cellIds = CellService.instance.myCells.map((c) => c.id).toList();
    print('[NOSTR] _refreshGovernanceCellIds: ${cellIds.length} cells '
        '(${cellIds.map((id) => id.substring(0, id.length.clamp(0, 8))).join(', ')})');
    _nostrTransport?.updateGovernanceCellIds(cellIds);
  }

  void _onCellAnnounced(Map<String, dynamic> data) {
    try {
      final nostrCreatedAt = data['_created_at'] as int?;
      // Remove internal nostr fields before passing to Cell.fromJson.
      final cellJson = Map<String, dynamic>.from(data)
        ..remove('_nostr_pubkey')
        ..remove('_created_at');
      final ownDevice = data['_own_device'] as bool? ?? false;
      final cell = Cell.fromJson(cellJson);
      print('[CELL-UPDATE] _onCellAnnounced: cellId=${cell.id}, name="${cell.name}", version=n/a, self=$ownDevice');

      // ── ZOMBIE-FIX: belt-and-suspenders tombstone check ──────────────────
      // Even if _handleCellAnnounceEvent already filtered self-events,
      // a second layer here catches any future path that emits to the stream.
      if (CellService.instance.isTombstoned(cell.id)) {
        if (kDebugMode) {
          print('[ZOMBIE-FIX] Blocked in _onCellAnnounced (tombstone): '
              '${cell.id} ("${cell.name}")');
          print('[CELL-UPDATE] Decision: SKIPPED reason=tombstoned_in_chat_provider');
        }
        return;
      }
      // ─────────────────────────────────────────────────────────────────────

      CellService.instance.addDiscoveredCell(
        cell,
        nostrCreatedAt: nostrCreatedAt,
        ownDevice: ownDevice,
      );
    } catch (e) {
      debugPrint('[CHAT] Cell announced parse error: $e');
    }
  }

  /// Handles an incoming Kind-31003 cell join request (or withdrawal) from a non-contact.
  Future<void> _onCellJoinRequest(Map<String, dynamic> data) async {
    try {
      final action = data['action'] as String?;
      final senderPubkey = data['requesterNostrPubkey'] as String?;

      if (action == 'withdraw') {
        // Applicant withdrew their request — remove from founder's pending list.
        final requestId = data['id'] as String? ?? '';
        final cellId = data['cellId'] as String? ?? '';
        if (requestId.isNotEmpty && cellId.isNotEmpty) {
          await CellService.instance.handleJoinRequestWithdrawn(requestId, cellId);
        }
        return;
      }

      final req = CellJoinRequest.fromJson(data);
      final isContact = ContactService.instance.findByDid(req.requesterDid) != null;
      print('[JOIN] Incoming message from: ${req.requesterDid}');
      print('[JOIN] Is sender a contact? $isContact');
      print('[JOIN] Message type: cell_join_request');
      print('[JOIN] Message filtered/blocked? false');
      print('[JOIN] Reason for filter: ALLOWED — cell join requests bypass contact check');
      print('[JOIN] Join request recognized: true');

      // Register the requester's Nostr pubkey so the founder can send
      // the Kind-31004 reply even without a contact relationship.
      if (senderPubkey != null && senderPubkey.isNotEmpty) {
        _nostrTransport?.registerDidMapping(req.requesterDid, senderPubkey);
      }

      await CellService.instance.handleIncomingJoinRequest(req);
      print('[JOIN] Join request saved to DB: true');
    } catch (e) {
      debugPrint('[CHAT] Cell join request parse error: $e');
      print('[JOIN] Join request saved to DB: false (parse error: $e)');
    }
  }

  /// Handles an incoming Kind-31004 membership confirmation.
  /// The applicant's device uses this to auto-join the cell.
  Future<void> _onCellMembershipConfirmed(Map<String, dynamic> data) async {
    try {
      final cellJson = data['cell'] as Map<String, dynamic>?;
      final memberJson = data['member'] as Map<String, dynamic>?;
      if (cellJson == null || memberJson == null) return;
      final cell = Cell.fromJson(cellJson);
      final member = CellMember.fromJson(memberJson);
      await CellService.instance.handleMembershipConfirmed(cell, member);
      print('[JOIN] Membership confirmed — cell "${cell.name}" added to My Cells');
    } catch (e) {
      debugPrint('[CHAT] Cell membership confirmed parse error: $e');
    }
  }

  /// Handles an incoming Kind-30000 cell-dissolution event from Nostr.
  /// Called on member devices when the founder dissolves a cell.
  Future<void> _onCellDeleted(Map<String, dynamic> data) async {
    final cellId = data['id'] as String? ?? '';
    final cellName = data['name'] as String? ?? cellId;
    if (cellId.isEmpty) return;
    print('[CELL-DEL] Received cell deletion for: $cellId ($cellName)');

    // Check tombstone BEFORE doing anything — replayed Nostr events for
    // already-dissolved cells must not trigger a second notification.
    final alreadyTombstoned = CellService.instance.isTombstoned(cellId);
    if (alreadyTombstoned) {
      print('[NOTIF-FIX] Suppressed "Zelle aufgelöst" notification for '
          'already-tombstoned cell: $cellId ($cellName)');
      return;
    }

    await CellService.instance.handleCellDeleted(cellId, cellName);
    await deleteCellChannels(cellId);
    print('[CELL-DEL] Removing cell + channels from local DB: $cellId');

    await NotificationService.instance.showGenericNotification(
      title: 'Zelle aufgelöst',
      body: 'Die Zelle "$cellName" wurde aufgelöst.',
      payload: 'cell_deleted:$cellId',
    );
  }

  /// Handles an incoming Kind-31005 cell member-update event from Nostr.
  ///
  /// action='left' → a member voluntarily left; update local member list.
  /// action='removed' + targetDid==me → I was kicked; clean up + notify.
  Future<void> _onCellMemberUpdate(Map<String, dynamic> data) async {
    final cellId = data['cellId'] as String? ?? '';
    final targetDid = data['targetDid'] as String? ?? '';
    final action = data['action'] as String? ?? 'left';
    if (cellId.isEmpty || targetDid.isEmpty) return;

    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final wasRemoved = action == 'removed' && targetDid == myDid;

    await CellService.instance.handleMemberLeft(cellId, targetDid, action);

    if (wasRemoved) {
      // I was kicked — leave the cell-internal channels silently (no farewell msg).
      await deleteCellChannels(cellId);
      await NotificationService.instance.showGenericNotification(
        title: 'Aus Zelle entfernt',
        body: 'Du wurdest aus einer Zelle entfernt.',
        payload: 'cell_removed:$cellId',
      );
      print('[CELL] Removed from cell $cellId — channels cleaned up, notification shown');
    }
  }

  /// Re-runs Nostr subscriptions. Used after a debug data reset.
  void resetNostrSubscriptions() {
    _nostrTransport?.resetSubscriptions();
    print('[CLEANUP] Subscriptions reset');
  }

  /// Publishes a Kind-30000 cell announcement event to Nostr relays.
  void publishNostrCellAnnouncement(Cell cell) {
    _nostrTransport?.publishCellAnnouncement(cell.toJson());
  }

  /// Publishes a Kind-30000 cell-dissolution event (deleted:true) so that
  /// all member devices receive and clean up this cell automatically.
  void publishNostrCellDissolution(Map<String, dynamic> cellJson) {
    _nostrTransport?.publishCellDissolution(cellJson);
    print('[CELL-DEL] Publishing cell deletion event: ${cellJson['id']}');
  }

  /// Re-publishes all cells where the local user is FOUNDER so that other
  /// nodes can discover them via the Nostr Kind-30000 subscription.
  void _republishMyCells() {
    final myDid = IdentityService.instance.currentIdentity?.did;
    if (myDid == null) return;
    final cells = CellService.instance.myCells;
    final founderCells = cells.where((c) => c.createdBy == myDid).toList();
    if (founderCells.isEmpty) return;
    debugPrint('[CELL] Republishing ${founderCells.length} founder cell(s) to Nostr');
    for (final cell in founderCells) {
      _nostrTransport?.publishCellAnnouncement(cell.toJson());
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
          r == ConnectivityResult.ethernet ||
          r == ConnectivityResult.other); // Windows VPN / unusual adapters

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

    // ── Private channel message decryption ───────────────────────────────────
    if (processedMsg.isBroadcast &&
        processedMsg.metadata?['ch_enc'] == true &&
        processedMsg.channel != null &&
        processedMsg.channel != '#mesh') {
      final ch =
          GroupChannelService.instance.findByName(processedMsg.channel!);
      if (ch != null && ch.channelSecret != null) {
        final plaintext = await ChannelEncryption.decrypt(
          processedMsg.body,
          ch.channelSecret!,
          ch.id,
        );
        processedMsg = NexusMessage(
          id: processedMsg.id,
          fromDid: processedMsg.fromDid,
          toDid: processedMsg.toDid,
          type: processedMsg.type,
          channel: processedMsg.channel,
          body: plaintext ?? '[Nachricht konnte nicht entschlüsselt werden]',
          timestamp: processedMsg.timestamp,
          ttlHours: processedMsg.ttlHours,
          hopCount: processedMsg.hopCount,
          signature: processedMsg.signature,
          metadata: processedMsg.metadata,
        );
      } else {
        // Non-member: store a placeholder.
        processedMsg = NexusMessage(
          id: processedMsg.id,
          fromDid: processedMsg.fromDid,
          toDid: processedMsg.toDid,
          type: processedMsg.type,
          channel: processedMsg.channel,
          body: '🔒 Verschlüsselte Nachricht',
          timestamp: processedMsg.timestamp,
          ttlHours: processedMsg.ttlHours,
          hopCount: processedMsg.hopCount,
          signature: processedMsg.signature,
          metadata: processedMsg.metadata,
        );
      }
    }

    // ── Channel access system messages ────────────────────────────────────────
    final sysType = processedMsg.metadata?['sys_type'] as String?;
    if (sysType != null && sysType.startsWith('channel_')) {
      try {
        final bodyData =
            jsonDecode(processedMsg.body) as Map<String, dynamic>;
        await _handleChannelSystemMessage(
            sysType, bodyData, processedMsg.fromDid);
      } catch (e) {
        debugPrint('[CHAT] Channel system-message parse error: $e');
      }
      return; // never store system messages in the conversation cache
    }

    // ── Contact request routing ──────────────────────────────────────────────
    final msgType = processedMsg.metadata?['type'] as String?;
    if (msgType == 'contact_request') {
      // Register the sender's Nostr pubkey immediately so we can send the
      // acceptance reply even if their presence hasn't been received yet.
      final crData =
          processedMsg.metadata?['contact_request_data'] as Map<String, dynamic>?;
      final senderNostrPubkey = crData?['fromNostrPubkey'] as String? ?? '';
      if (senderNostrPubkey.isNotEmpty) {
        _nostrTransport?.registerDidMapping(
            processedMsg.fromDid, senderNostrPubkey);
        ContactService.instance.setNostrPubkey(
            processedMsg.fromDid, senderNostrPubkey);
        debugPrint('[ContactRequest] Registered sender pubkey: '
            '${senderNostrPubkey.substring(0, 8)}… for ${processedMsg.fromDid}');
      }
      debugPrint('[ContactRequest] Incoming contact_request routed to service '
          'from ${processedMsg.fromDid}');
      await ContactRequestService.instance.handleIncomingRequest(processedMsg);
      return;
    }
    if (msgType == 'contact_request_accepted') {
      // Register the acceptor's Nostr pubkey so subsequent messages work
      // immediately without waiting for the next presence event.
      final crData =
          processedMsg.metadata?['contact_request_data'] as Map<String, dynamic>?;
      final acceptorNostrPubkey = crData?['fromNostrPubkey'] as String? ?? '';
      if (acceptorNostrPubkey.isNotEmpty) {
        _nostrTransport?.registerDidMapping(
            processedMsg.fromDid, acceptorNostrPubkey);
        debugPrint('[ContactRequest] Registered acceptor pubkey: '
            '${acceptorNostrPubkey.substring(0, 8)}… for ${processedMsg.fromDid}');
      }
      await ContactRequestService.instance.handleAcceptance(
        processedMsg,
        addContactFn: (did, pseudonym, encKey, nostrPubkey) async {
          await ContactService.instance.addContactFromQr(
            did: did,
            pseudonym: pseudonym,
            encryptionPublicKey: encKey.isNotEmpty ? encKey : null,
            nostrPubkey: nostrPubkey.isNotEmpty ? nostrPubkey : null,
          );
        },
      );
      return;
    }
    if (msgType == 'contact_request_cancelled') {
      await ContactRequestService.instance.handleCancellation(processedMsg.fromDid);
      return;
    }

    // ── Proposal discussion messages ─────────────────────────────────────────
    if (msgType == 'proposal_discussion') {
      final meta = processedMsg.metadata ?? {};
      await ProposalService.instance.handleDiscussionMessage({
        'id': meta['message_id'] as String? ?? processedMsg.id,
        'proposalId': meta['proposal_id'] as String? ?? '',
        'authorDid': processedMsg.fromDid,
        'authorPseudonym': meta['author_pseudo'] as String? ?? '',
        'content': processedMsg.body,
        'createdAt': processedMsg.timestamp.millisecondsSinceEpoch,
      });
      return;
    }

    // ── Invite redemption notification ───────────────────────────────────────
    if (msgType == 'invite_redeemed') {
      final meta = processedMsg.metadata!;
      final code = meta['invite_code'] as String? ?? '';
      final redeemerPseudonym = meta['redeemer_pseudonym'] as String? ?? '';
      final redeemerDid = meta['redeemer_did'] as String? ?? processedMsg.fromDid;
      print('[INVITE] Incoming DM recognized as invite redemption for code: $code');

      if (code.isNotEmpty) {
        await InviteService.instance.markRedeemed(code, redeemerPseudonym);
        print('[INVITE] InviteRecord updated: redeemedByPseudonym = $redeemerPseudonym');
      }

      // Add the redeemer as a contact on the inviter's side if not already known.
      if (redeemerDid.isNotEmpty && ContactService.instance.findByDid(redeemerDid) == null) {
        final encKey = meta['enc_key'] as String?;
        await ContactService.instance.addContactFromQr(
          did: redeemerDid,
          pseudonym: redeemerPseudonym,
          encryptionPublicKey: encKey?.isNotEmpty == true ? encKey : null,
          nostrPubkey: null,
        );
      }
      return;
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

    // If the sender included their enc_key (signalling E2E capability) and this
    // DM was not already marked as inner-encrypted, mark it now so the message
    // info sheet shows "Ende-zu-Ende verschlüsselt" consistently with the E2E
    // banner.  The first message in a key-exchange is plaintext body but still
    // part of an E2E session.
    if (!processedMsg.isBroadcast &&
        encKeyFromMsg != null &&
        processedMsg.metadata?['encrypted'] != true) {
      processedMsg = processedMsg.copyWith(
        metadata: {
          ...?processedMsg.metadata,
          'encrypted': true,
        },
      );
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
      final muted = !processedMsg.isBroadcast &&
          ContactService.instance.isMuted(processedMsg.fromDid);

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
          // For named channels use the channel name; #mesh falls back to #hotnews
          final bannerTitle = processedMsg.isBroadcast
              ? (processedMsg.channel != null &&
                      processedMsg.channel != '#mesh' &&
                      processedMsg.channel!.startsWith('#')
                  ? processedMsg.channel!
                  : '#hotnews')
              : senderName;
          InAppNotificationController.instance.show(InAppBannerData(
            senderName: bannerTitle,
            preview: preview,
            conversationId: convId,
            isBroadcast: processedMsg.isBroadcast,
          ));
        } else {
          // System notification
          if (processedMsg.isBroadcast) {
            final channelTitle = (processedMsg.channel != null &&
                    processedMsg.channel != '#mesh' &&
                    processedMsg.channel!.startsWith('#'))
                ? processedMsg.channel
                : null; // null → service defaults to #hotnews
            NotificationService.instance.showBroadcastNotification(
              senderName: senderName,
              messagePreview: preview,
              title: channelTitle,
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

      // Trigger 2: Channel reply targeting my message
      if (processedMsg.isBroadcast && !muted) {
        final replyToId = processedMsg.metadata?['reply_to_id'] as String?;
        if (replyToId != null && processedMsg.fromDid != myDid) {
          final myMessages = _conversationCache[convId] ?? [];
          final isReplyToMe =
              myMessages.any((m) => m.id == replyToId && m.fromDid == myDid);
          if (isReplyToMe && await NotificationSettings.channelReplies()) {
            final contact =
                ContactService.instance.findByDid(processedMsg.fromDid);
            final senderName = contact?.pseudonym ??
                processedMsg.fromDid.substring(
                    (processedMsg.fromDid.length - 8)
                        .clamp(0, processedMsg.fromDid.length));
            final channelLabel = processedMsg.channel ?? convId;
            final msgPreview = processedMsg.body.length > 50
                ? '${processedMsg.body.substring(0, 50)}…'
                : processedMsg.body;
            NotificationService.instance.showGenericNotification(
              title: 'Antwort in $channelLabel',
              body: '$senderName: $msgPreview',
              payload: convId,
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

  // ── Contact requests ──────────────────────────────────────────────────────

  /// Sends a contact request to [toDid] with [introMessage].
  ///
  /// Returns `null` on success, or a localised error message on failure.
  Future<String?> sendContactRequest(
      String toDid, String introMessage) async {
    final identity = IdentityService.instance.currentIdentity;
    if (identity == null) return 'Keine Identität';
    final myDid = identity.did;
    final myPseudonym = identity.pseudonym;
    final myPublicKey =
        EncryptionKeys.instance.publicKeyHex ?? '';
    final myNostrPubkey = _nostrTransport?.localNostrPubkeyHex ?? '';

    return ContactRequestService.instance.sendRequest(
      toDid,
      introMessage,
      myDid: myDid,
      myPseudonym: myPseudonym,
      myPublicKey: myPublicKey,
      myNostrPubkey: myNostrPubkey,
      sendFn: (req) async {
        final meta = <String, dynamic>{
          'type': 'contact_request',
          'contact_request_data': {
            'fromPublicKey': req.fromPublicKey,
            'fromNostrPubkey': req.fromNostrPubkey,
            'message': req.message,
          },
          if (myPublicKey.isNotEmpty) 'enc_key': myPublicKey,
        };
        final msg = NexusMessage.create(
          fromDid: myDid,
          toDid: toDid,
          body: req.message,
          metadata: meta,
        );
        await _manager.sendMessage(msg, recipientDid: toDid);
      },
    );
  }

  /// Accepts an incoming contact request by [requestId] and sends a
  /// confirmation DM back to the requester.
  Future<void> acceptContactRequest(String requestId) async {
    final identity = IdentityService.instance.currentIdentity;
    if (identity == null) return;
    final myDid = identity.did;
    final myPseudonym = identity.pseudonym;
    final myPublicKey =
        EncryptionKeys.instance.publicKeyHex ?? '';
    final myNostrPubkey = _nostrTransport?.localNostrPubkeyHex ?? '';

    await ContactRequestService.instance.acceptRequest(
      requestId,
      addContactFn: (did, pseudonym, encKey, nostrPubkey) async {
        await ContactService.instance.addContactFromQr(
          did: did,
          pseudonym: pseudonym,
          encryptionPublicKey: encKey.isNotEmpty ? encKey : null,
          nostrPubkey: nostrPubkey.isNotEmpty ? nostrPubkey : null,
        );
      },
      sendConfirmFn: (req) async {
        final meta = <String, dynamic>{
          'type': 'contact_request_accepted',
          'contact_request_data': {
            'fromPublicKey': myPublicKey,
            'fromNostrPubkey': myNostrPubkey,
          },
          if (myPublicKey.isNotEmpty) 'enc_key': myPublicKey,
        };
        final msg = NexusMessage.create(
          fromDid: myDid,
          toDid: req.fromDid,
          body: myPseudonym,
          metadata: meta,
        );
        await _manager.sendMessage(msg, recipientDid: req.fromDid);
      },
    );
  }

  /// Cancels an outgoing contact request: removes it locally and sends a
  /// cancellation DM so the recipient's pending list updates too.
  Future<void> cancelContactRequest(String requestId) async {
    final identity = IdentityService.instance.currentIdentity;
    final myDid = identity?.did ?? '';

    await ContactRequestService.instance.cancelRequest(
      requestId,
      sendCancellationFn: (toDid) async {
        final meta = <String, dynamic>{
          'type': 'contact_request_cancelled',
        };
        final msg = NexusMessage.create(
          fromDid: myDid,
          toDid: toDid,
          body: '',
          metadata: meta,
        );
        await _manager.sendMessage(msg, recipientDid: toDid);
      },
    );
  }

  // ── Sending ────────────────────────────────────────────────────────────────

  /// Sends a direct text message to [recipientDid].
  Future<void> sendMessage(
    String recipientDid,
    String text, {
    NexusMessage? replyTo,
    String? replyToSenderName,
    Map<String, dynamic>? extraMeta,
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

    final localMeta = <String, dynamic>{
      ...?baseMeta,
      if (recipientEncKey != null) 'encrypted': true,
      ...?replyMeta,
      ...?extraMeta,
    };

    // Local message (always plaintext – what we display and persist locally).
    final localMsg = NexusMessage.create(
      fromDid: myDid,
      toDid: recipientDid,
      body: text,
      metadata: localMeta.isNotEmpty ? localMeta : null,
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
        final transportMeta = <String, dynamic>{
          ...?baseMeta,
          'encrypted': true,
          ...?replyMeta,
          ...?extraMeta,
        };
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
          metadata: transportMeta,
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
    Map<String, dynamic>? extraMeta,
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

    final meta = <String, dynamic>{
      if (EncryptionKeys.instance.publicKeyHex != null)
        'enc_key': EncryptionKeys.instance.publicKeyHex!,
      ...?replyMeta,
      ...?extraMeta,
    };
    final msg = NexusMessage.create(
      fromDid: myDid,
      toDid: NexusMessage.broadcastDid,
      body: text,
      channel: '#mesh',
      metadata: meta.isNotEmpty ? meta : null,
    );

    await _manager.sendMessage(msg);

    _conversationCache.putIfAbsent(NexusMessage.broadcastDid, () => []);
    _conversationCache[NexusMessage.broadcastDid]!.add(msg);
    await _persistMessage(NexusMessage.broadcastDid, msg);
    ConversationService.instance.notifyUpdate();

    notifyListeners();
  }

  /// Sends a text message to a named group channel (e.g. "#teneriffa").
  ///
  /// For private channels the body is encrypted with the shared channelSecret.
  /// The sender always stores a plaintext copy locally.
  /// Pass [skipEncryption] = true for system messages that must be readable
  /// by all members without a shared secret (e.g. join/leave events).
  Future<void> sendToChannel(String channelName, String text,
      {Map<String, dynamic>? extraMeta, bool skipEncryption = false}) async {
    final myDid = IdentityService.instance.currentIdentity?.did ?? 'unknown';
    final name =
        channelName.startsWith('#') ? channelName : '#$channelName';

    final channel = GroupChannelService.instance.findByName(name);

    // Build wire message (possibly encrypted).
    String wireBody = text;
    bool isChEnc = false;
    if (!skipEncryption &&
        channel != null &&
        !channel.isPublic &&
        channel.channelSecret != null) {
      final enc = await ChannelEncryption.encrypt(
          text, channel.channelSecret!, channel.id);
      if (enc != null) {
        wireBody = enc;
        isChEnc = true;
      }
    }

    final wireMeta = <String, dynamic>{
      if (isChEnc) 'ch_enc': true,
      ...?extraMeta,
    };

    final wireMsg = NexusMessage.create(
      fromDid: myDid,
      toDid: NexusMessage.broadcastDid,
      body: wireBody,
      channel: name,
      metadata: wireMeta.isNotEmpty ? wireMeta : null,
    );

    await _manager.sendMessage(wireMsg);

    // Store plaintext locally so the sender can read their own messages.
    final localMeta = <String, dynamic>{
      if (isChEnc) 'ch_enc': true,
      ...?extraMeta,
    };
    final localMsg = localMeta.isNotEmpty
        ? NexusMessage(
            id: wireMsg.id,
            fromDid: wireMsg.fromDid,
            toDid: wireMsg.toDid,
            type: wireMsg.type,
            channel: wireMsg.channel,
            body: text,
            timestamp: wireMsg.timestamp,
            ttlHours: wireMsg.ttlHours,
            metadata: localMeta,
          )
        : wireMsg;

    _conversationCache.putIfAbsent(name, () => []);
    _conversationCache[name]!.add(localMsg);
    await _persistMessage(name, localMsg);
    ConversationService.instance.notifyUpdate();

    notifyListeners();
  }

  /// Joins [channel] and subscribes to its Nostr tag.
  Future<void> joinChannelAndSubscribe(GroupChannel channel) async {
    await GroupChannelService.instance.joinChannel(channel);
    _nostrTransport?.subscribeToChannel(channel.nostrTag);
  }

  /// Joins a channel received via QR code or invite link.
  ///
  /// If the channel is already known locally, its existing data is preserved
  /// and only [channelSecret] is updated when provided.
  Future<void> joinChannelFromInvite({
    required String channelId,
    required String channelName,
    required String nostrTag,
    required bool isPublic,
    bool isDiscoverable = true,
    String? channelSecret,
  }) async {
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final existing = GroupChannelService.instance.findByName(channelName);

    final channel = GroupChannel(
      id: channelId.isNotEmpty
          ? channelId
          : (existing?.id ??
              DateTime.now().millisecondsSinceEpoch.toRadixString(16)),
      name: channelName,
      description: existing?.description ?? '',
      createdBy: existing?.createdBy ?? '',
      createdAt: existing?.createdAt ?? DateTime.now().toUtc(),
      isPublic: isPublic,
      isDiscoverable: isDiscoverable,
      channelSecret: channelSecret ?? existing?.channelSecret,
      nostrTag: nostrTag,
      joinedAt: DateTime.now().toUtc(),
      members: existing?.members ?? [if (myDid.isNotEmpty) myDid],
    );

    await joinChannelAndSubscribe(channel);
    debugPrint('[CHAT] Joined channel from invite: $channelName');
  }

  /// Sends an encrypted system DM for channel access control
  /// (join request, invite, acceptance, rejection).
  Future<void> sendSystemDm(
      String recipientDid, Map<String, dynamic> data) async {
    final myDid =
        IdentityService.instance.currentIdentity?.did ?? 'unknown';
    final sysType = data['sys_type'] as String? ?? '';
    final bodyJson = jsonEncode(data);

    final baseMeta = <String, dynamic>{
      'sys_type': sysType,
      if (EncryptionKeys.instance.publicKeyHex != null)
        'enc_key': EncryptionKeys.instance.publicKeyHex!,
    };

    final recipientEncKey =
        ContactService.instance.findByDid(recipientDid)?.encryptionPublicKey;

    NexusMessage msg;
    if (recipientEncKey != null) {
      final encBody = await MessageEncryption.encrypt(
        bodyJson,
        senderKeyPair: EncryptionKeys.instance.keyPair,
        recipientPublicKeyBytes: EncryptionKeys.hexToBytes(recipientEncKey),
      );
      msg = NexusMessage.create(
        fromDid: myDid,
        toDid: recipientDid,
        type: NexusMessageType.system,
        body: encBody ?? bodyJson,
        metadata: {
          ...baseMeta,
          if (encBody != null) 'encrypted': true,
        },
      );
    } else {
      msg = NexusMessage.create(
        fromDid: myDid,
        toDid: recipientDid,
        type: NexusMessageType.system,
        body: bodyJson,
        metadata: baseMeta,
      );
    }

    await _manager.sendMessage(msg, recipientDid: recipientDid);
  }

  // ── Channel access system-message handlers ─────────────────────────────────

  Future<void> _handleChannelSystemMessage(
      String sysType, Map<String, dynamic> data, String senderDid) async {
    switch (sysType) {
      case 'channel_join_request':
      case 'channel_invite':
        ChannelAccessService.instance
            .handleIncoming(sysType, data, senderDid);
      case 'channel_join_accepted':
        await _joinChannelFromAcceptance(data, senderDid);
      case 'channel_join_rejected':
        debugPrint('[CHAT] Join request rejected for: '
            '${data['channelName'] ?? data['channelId']}');
    }
  }

  Future<void> _joinChannelFromAcceptance(
      Map<String, dynamic> data, String adminDid) async {
    final channelName = data['channelName'] as String? ?? '';
    final channelSecret = data['channelSecret'] as String? ?? '';
    final channelId = data['channelId'] as String? ?? '';
    final nostrTag = data['nostrTag'] as String? ??
        GroupChannel.nameToNostrTag(channelName);
    final description = data['description'] as String? ?? '';
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';

    final existing = GroupChannelService.instance.findByName(channelName);
    final channel = GroupChannel(
      id: channelId.isNotEmpty ? channelId : (existing?.id ?? channelId),
      name: channelName,
      description: description,
      createdBy: adminDid,
      createdAt: existing?.createdAt ?? DateTime.now().toUtc(),
      isPublic: false,
      isDiscoverable: existing?.isDiscoverable ?? true,
      channelSecret: channelSecret,
      nostrTag: nostrTag,
      joinedAt: DateTime.now().toUtc(),
      members: [adminDid, if (myDid.isNotEmpty) myDid],
    );

    await joinChannelAndSubscribe(channel);
    debugPrint('[CHAT] Joined private channel via acceptance: $channelName');
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

  /// Forwards an already-base64-encoded image to [recipientDid].
  ///
  /// Used by the forward feature to re-send an existing image without
  /// re-processing it.
  Future<void> sendImageBase64(
    String recipientDid,
    String base64Body, {
    Map<String, dynamic>? meta,
  }) async {
    final myDid = IdentityService.instance.currentIdentity?.did ?? 'unknown';
    final msg = NexusMessage.create(
      fromDid: myDid,
      toDid: recipientDid,
      type: NexusMessageType.image,
      body: base64Body,
      metadata: meta,
    );

    await _manager.sendMessage(msg, recipientDid: recipientDid);

    final convId = _conversationId(recipientDid, myDid);
    _conversationCache.putIfAbsent(convId, () => []);
    _conversationCache[convId]!.add(msg);
    await _persistMessage(convId, msg);
    ConversationService.instance.notifyUpdate();
    notifyListeners();
  }

  /// Publishes a Nostr Kind-5 deletion event for [messageId].
  ///
  /// Best-effort: relays may not honour the request, and clients that already
  /// cached the message will not remove it automatically.
  void publishNostrDeletion(String messageId) {
    _nostrTransport?.publishDeletion(messageId);
  }

  /// Publishes a Kind-5 deletion event for a cell (NIP-09 `a`-tag approach).
  void publishNostrCellDeletion(String cellId, String cellName) {
    _nostrTransport?.publishCellDeletion(cellId, cellName);
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

  /// Sends an image to a named group channel.
  Future<void> sendImageToChannel(String channelName, Uint8List imageBytes) async {
    final myDid = IdentityService.instance.currentIdentity?.did ?? 'unknown';
    final name = channelName.startsWith('#') ? channelName : '#$channelName';

    final (base64Full, base64Thumb, width, height) =
        await compute(_processImage, imageBytes);

    final msg = NexusMessage.create(
      fromDid: myDid,
      toDid: NexusMessage.broadcastDid,
      type: NexusMessageType.image,
      body: base64Full,
      channel: name,
      metadata: {
        'width': width,
        'height': height,
        'thumbnail': base64Thumb,
      },
    );

    await _manager.sendMessage(msg);

    _conversationCache.putIfAbsent(name, () => []);
    _conversationCache[name]!.add(msg);
    await _persistMessage(name, msg);
    ConversationService.instance.notifyUpdate();
    notifyListeners();
  }

  /// Sends a voice message to a named group channel.
  Future<void> sendVoiceToChannel(
    String channelName,
    String filePath,
    int durationMs, {
    NexusMessage? replyTo,
    String? replyToSenderName,
  }) async {
    final myDid = IdentityService.instance.currentIdentity?.did ?? 'unknown';
    final name = channelName.startsWith('#') ? channelName : '#$channelName';

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
      type: NexusMessageType.voice,
      body: audioBase64,
      channel: name,
      metadata: {
        'duration_ms': durationMs,
        'audio_local_path': filePath,
        ...?replyMeta,
      },
    );

    await _manager.sendMessage(msg);

    _conversationCache.putIfAbsent(name, () => []);
    _conversationCache[name]!.add(msg);
    await _persistMessage(name, msg);
    ConversationService.instance.notifyUpdate();
    notifyListeners();
  }

  /// Adds an emoji reaction to a channel message.
  Future<void> addChannelReaction(String messageId, String emoji) async {
    final myDid = IdentityService.instance.currentIdentity?.did ?? 'unknown';
    await PodDatabase.instance.upsertReaction(
      messageId: messageId,
      emoji: emoji,
      reactorDid: myDid,
    );
    _nostrTransport?.publishReaction(messageId, emoji);
    notifyListeners();
  }

  /// Removes an emoji reaction from a channel message.
  Future<void> removeChannelReaction(String messageId, String emoji) async {
    final myDid = IdentityService.instance.currentIdentity?.did ?? 'unknown';
    await PodDatabase.instance.deleteReaction(
      messageId: messageId,
      emoji: emoji,
      reactorDid: myDid,
    );
    notifyListeners();
  }

  /// Loads reactions for a message.
  Future<Map<String, List<String>>> getMessageReactions(String messageId) =>
      PodDatabase.instance.getReactionsForMessage(messageId);

  // ── Incoming reaction handler (Triggers 1 & 3) ───────────────────────────

  /// Called when a Kind-7 reaction arrives from Nostr.
  /// Checks whether the referenced event ID matches a message in the local
  /// conversation cache that was sent by me.
  Future<void> _handleIncomingReaction(Map<String, dynamic> data) async {
    // Delegate feed reactions to FeedService (Trigger 4 handled there).
    FeedService.instance.handleIncomingReaction(data);

    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final referencedId = data['referencedEventId'] as String?;
    final senderPubkey = data['senderPubkey'] as String?;
    final emoji = data['emoji'] as String? ?? '👍';
    if (referencedId == null || senderPubkey == null) return;

    final shortTarget = referencedId.length >= 8
        ? referencedId.substring(0, 8)
        : referencedId;
    final cacheSize = _conversationCache.values.fold<int>(0, (s, v) => s + v.length);
    print('[REACTION-RECV] Chat-Handler: emoji=$emoji target=$shortTarget… '
        '(searching $cacheSize msgs in ${_conversationCache.length} convs)');

    // Search conversation cache for a message authored by me with this ID.
    String? convId;
    bool isChannel = false;
    for (final entry in _conversationCache.entries) {
      final msg = entry.value.cast<NexusMessage?>().firstWhere(
            (m) => m!.id == referencedId && m.fromDid == myDid,
            orElse: () => null,
          );
      if (msg != null) {
        convId = entry.key;
        isChannel = convId.startsWith('#');
        break;
      }
    }
    if (convId == null) {
      print('[REACTION-RECV] Match found: false (no matching msg in conv cache)');
      return; // not my message
    }
    print('[REACTION-RECV] Match found: true in conv=$convId isChannel=$isChannel');

    // Resolve sender name via nostrPubkey
    final matchedContact = ContactService.instance.contacts
        .where((c) => c.nostrPubkey == senderPubkey)
        .firstOrNull;
    final senderName = matchedContact?.pseudonym ??
        (senderPubkey.length >= 8
            ? senderPubkey.substring(0, 8)
            : senderPubkey);

    if (isChannel) {
      // Trigger 3: channel reaction
      if (await NotificationSettings.channelReactions()) {
        final channelLabel = convId; // e.g. "#teneriffa"
        NotificationService.instance.showGenericNotification(
          title: '$senderName reagierte in $channelLabel',
          body: emoji,
          payload: convId,
        );
      }
    } else {
      // Trigger 1: direct message reaction
      if (await NotificationSettings.chatReactions()) {
        NotificationService.instance.showGenericNotification(
          title: '$senderName hat reagiert',
          body: '$emoji auf deine Nachricht',
          payload: convId,
        );
      }
    }
  }

  /// Sends a moderation report as a DM to the channel admin (or system admin fallback).
  Future<void> reportChannelMessage({
    required NexusMessage msg,
    required String channelName,
    required String channelAdminDid,
    required String reason,
    String? comment,
  }) async {
    final myDid = IdentityService.instance.currentIdentity?.did ?? 'unknown';
    final reportData = {
      'type': 'channel_report',
      'channel': channelName,
      'message_id': msg.id,
      'sender_did': msg.fromDid,
      'reason': reason,
      if (comment != null && comment.isNotEmpty) 'comment': comment,
      'reporter_did': myDid,
      'ts': DateTime.now().millisecondsSinceEpoch,
    };
    await sendSystemDm(channelAdminDid, reportData);
  }

  /// Deletes all messages in [conversationId] from cache and POD.
  Future<void> deleteConversation(String conversationId) async {
    _conversationCache.remove(conversationId);
    _cacheLoadedFromDb.remove(conversationId);
    await ConversationService.instance.deleteConversation(conversationId);
    notifyListeners();
  }

  /// Fully removes a group channel for this user: removes it from
  /// [GroupChannelService] (DB + memory), stops the Nostr subscription,
  /// and deletes all local messages.
  ///
  /// Used for both the admin "delete channel" and member "leave channel"
  /// actions so every exit path cleans up all three layers.
  Future<void> leaveOrDeleteChannel(String channelName) async {
    final channel = GroupChannelService.instance.findByName(channelName);
    final nostrTag = channel?.nostrTag;

    // 1. Remove from group_channels DB + _joined in-memory list.
    try {
      await GroupChannelService.instance.leaveChannel(channelName);
    } catch (_) {}

    // 2. Stop Nostr subscription so the relay stops delivering messages.
    if (nostrTag != null) {
      _nostrTransport?.unsubscribeFromChannel(nostrTag);
    }

    // 3. Delete all local messages for this channel.
    _conversationCache.remove(channelName);
    _cacheLoadedFromDb.remove(channelName);
    await ConversationService.instance.deleteConversation(channelName);
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
          final isFavorite = (row['_is_favorite'] as int? ?? 0) == 1;
          final editedBody = row['_edited_body'] as String?;
          final cleaned = Map<String, dynamic>.from(row)
            ..remove('sender_did')
            ..remove('_is_favorite')
            ..remove('_edited_body');
          var msg = NexusMessage.fromJson(cleaned);
          // Merge local-state into metadata so the UI can use them.
          if (isFavorite || editedBody != null) {
            final meta = Map<String, dynamic>.from(msg.metadata ?? {});
            if (isFavorite) meta['local_favorite'] = true;
            if (editedBody != null) meta['local_edited_body'] = editedBody;
            msg = msg.copyWith(
              body: editedBody ?? msg.body,
              metadata: meta,
            );
          }
          return msg;
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

  // ── Message actions (favorite, delete, edit) ──────────────────────────────

  /// Toggles the favorite state of [msg] and refreshes the in-memory cache.
  Future<void> toggleFavorite(NexusMessage msg, String convId) async {
    final isFav = msg.metadata?['local_favorite'] == true;
    final newFav = !isFav;
    await PodDatabase.instance.setMessageFavorite(msg.id, isFavorite: newFav);
    _updateCachedMessage(convId, msg.id, (m) {
      final meta = Map<String, dynamic>.from(m.metadata ?? {});
      if (newFav) {
        meta['local_favorite'] = true;
      } else {
        meta.remove('local_favorite');
      }
      return m.copyWith(metadata: meta);
    });
    notifyListeners();
  }

  /// Deletes [msg] locally (soft delete – hidden from UI, stays in DB).
  Future<void> deleteMessageLocally(NexusMessage msg, String convId) async {
    await PodDatabase.instance.softDeleteMessage(msg.id);
    _conversationCache[convId]?.removeWhere((m) => m.id == msg.id);
    ConversationService.instance.notifyUpdate();
    notifyListeners();
  }

  /// Saves the edited body for [msg] locally and updates the in-memory cache.
  Future<void> editMessage(
      NexusMessage msg, String convId, String newBody) async {
    await PodDatabase.instance.setEditedBody(msg.id, newBody);
    _updateCachedMessage(convId, msg.id, (m) {
      final meta = Map<String, dynamic>.from(m.metadata ?? {});
      meta['local_edited_body'] = newBody;
      return m.copyWith(body: newBody, metadata: meta);
    });
    notifyListeners();
  }

  /// Returns all favorited messages in [convId].
  Future<List<NexusMessage>> getFavoriteMessages(String convId) async {
    final rows = await PodDatabase.instance.listFavoriteMessages(convId);
    return rows.map((row) {
      try {
        final editedBody = row['_edited_body'] as String?;
        final cleaned = Map<String, dynamic>.from(row)
          ..remove('sender_did')
          ..remove('_is_favorite')
          ..remove('_edited_body');
        var msg = NexusMessage.fromJson(cleaned);
        final meta = Map<String, dynamic>.from(msg.metadata ?? {});
        meta['local_favorite'] = true;
        if (editedBody != null) {
          meta['local_edited_body'] = editedBody;
          msg = msg.copyWith(body: editedBody, metadata: meta);
        } else {
          msg = msg.copyWith(metadata: meta);
        }
        return msg;
      } catch (_) {
        return null;
      }
    }).whereType<NexusMessage>().toList();
  }

  void _updateCachedMessage(
      String convId, String msgId, NexusMessage Function(NexusMessage) update) {
    final cache = _conversationCache[convId];
    if (cache == null) return;
    final idx = cache.indexWhere((m) => m.id == msgId);
    if (idx == -1) return;
    cache[idx] = update(cache[idx]);
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
    _muteExpiryTimer?.cancel();
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
