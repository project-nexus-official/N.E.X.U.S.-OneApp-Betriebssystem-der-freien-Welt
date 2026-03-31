import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/contacts/contact_service.dart';
import '../../core/identity/identity_service.dart';
import '../../core/identity/profile_service.dart';
import 'group_channel.dart';
import 'group_channel_service.dart';

// ── Data classes ───────────────────────────────────────────────────────────────

/// A pending join request that I (as channel admin) need to handle.
class ChannelJoinRequest {
  final String id;
  final String channelId;
  final String channelName;
  final String requesterDid;
  final String requesterPseudonym;
  final DateTime receivedAt;

  const ChannelJoinRequest({
    required this.id,
    required this.channelId,
    required this.channelName,
    required this.requesterDid,
    required this.requesterPseudonym,
    required this.receivedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'channelId': channelId,
        'channelName': channelName,
        'requesterDid': requesterDid,
        'requesterPseudonym': requesterPseudonym,
        'receivedAt': receivedAt.millisecondsSinceEpoch,
      };

  factory ChannelJoinRequest.fromJson(Map<String, dynamic> j) =>
      ChannelJoinRequest(
        id: j['id'] as String,
        channelId: j['channelId'] as String,
        channelName: j['channelName'] as String,
        requesterDid: j['requesterDid'] as String,
        requesterPseudonym: (j['requesterPseudonym'] as String?) ?? '',
        receivedAt: DateTime.fromMillisecondsSinceEpoch(
            (j['receivedAt'] as num).toInt()),
      );
}

/// A pending channel invitation that I received and haven't acted on yet.
class ChannelInvitation {
  final String id;
  final String channelId;
  final String channelName;
  final String channelSecret;
  final String nostrTag;
  final String adminDid;
  final String adminPseudonym;
  final DateTime receivedAt;

  const ChannelInvitation({
    required this.id,
    required this.channelId,
    required this.channelName,
    required this.channelSecret,
    required this.nostrTag,
    required this.adminDid,
    required this.adminPseudonym,
    required this.receivedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'channelId': channelId,
        'channelName': channelName,
        'channelSecret': channelSecret,
        'nostrTag': nostrTag,
        'adminDid': adminDid,
        'adminPseudonym': adminPseudonym,
        'receivedAt': receivedAt.millisecondsSinceEpoch,
      };

  factory ChannelInvitation.fromJson(Map<String, dynamic> j) =>
      ChannelInvitation(
        id: j['id'] as String,
        channelId: j['channelId'] as String,
        channelName: j['channelName'] as String,
        channelSecret: (j['channelSecret'] as String?) ?? '',
        nostrTag: (j['nostrTag'] as String?) ??
            GroupChannel.nameToNostrTag(j['channelName'] as String),
        adminDid: (j['adminDid'] as String?) ?? '',
        adminPseudonym: (j['adminPseudonym'] as String?) ?? '',
        receivedAt: DateTime.fromMillisecondsSinceEpoch(
            (j['receivedAt'] as num).toInt()),
      );
}

// ── Service ────────────────────────────────────────────────────────────────────

/// Manages private-channel access control:
///   • pending join requests the local user (as admin) needs to handle
///   • pending invitations the local user received and can accept/decline
///
/// Persistence: SharedPreferences (two JSON lists).
/// The service is instantiated lazily; call [load()] once after app start.
class ChannelAccessService {
  ChannelAccessService._();
  static final instance = ChannelAccessService._();

  static const _reqKey = 'nexus_channel_join_requests_v1';
  static const _invKey = 'nexus_channel_invitations_v1';

  final List<ChannelJoinRequest> _requests = [];
  final List<ChannelInvitation> _invitations = [];

  final _controller = StreamController<void>.broadcast();

  /// Emits whenever the pending lists change.
  Stream<void> get onChanged => _controller.stream;

  List<ChannelJoinRequest> get pendingRequests =>
      List.unmodifiable(_requests);
  List<ChannelInvitation> get pendingInvitations =>
      List.unmodifiable(_invitations);

  /// Total badge count (requests + invitations).
  int get pendingCount => _requests.length + _invitations.length;

  // ── Initialisation ──────────────────────────────────────────────────────────

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final reqJson = prefs.getString(_reqKey);
      final invJson = prefs.getString(_invKey);
      if (reqJson != null) {
        final list = jsonDecode(reqJson) as List<dynamic>;
        _requests
          ..clear()
          ..addAll(list.map((e) =>
              ChannelJoinRequest.fromJson(e as Map<String, dynamic>)));
      }
      if (invJson != null) {
        final list = jsonDecode(invJson) as List<dynamic>;
        _invitations
          ..clear()
          ..addAll(list.map((e) =>
              ChannelInvitation.fromJson(e as Map<String, dynamic>)));
      }
      if (_requests.isNotEmpty || _invitations.isNotEmpty) {
        _controller.add(null);
      }
    } catch (e) {
      debugPrint('[CHAN_ACCESS] load failed: $e');
    }
  }

  // ── Incoming system message routing ────────────────────────────────────────

  /// Called by ChatProvider when a system DM with a channel-related [sysType]
  /// arrives. [data] is the decoded JSON body; [senderDid] is the message sender.
  ///
  /// Returns true if [sysType] was a channel message (caller should not store
  /// the raw DM in the conversation cache).
  bool handleIncoming(String sysType, Map<String, dynamic> data,
      String senderDid) {
    switch (sysType) {
      case 'channel_join_request':
        _onJoinRequest(data, senderDid);
        return true;
      case 'channel_invite':
        _onInvite(data, senderDid);
        return true;
      default:
        return false;
    }
  }

  // ── Sending ─────────────────────────────────────────────────────────────────

  /// Sends a join-request DM to the channel's admin.
  ///
  /// [sendSystemDm] is a callback provided by ChatProvider to keep this service
  /// free of Flutter/Provider dependencies.
  Future<void> sendJoinRequest(
    GroupChannel channel,
    Future<void> Function(String recipientDid, Map<String, dynamic> data)
        sendSystemDm,
  ) async {
    final myDid =
        IdentityService.instance.currentIdentity?.did ?? 'unknown';
    final myPseudonym =
        ProfileService.instance.currentProfile?.pseudonym.value ??
            IdentityService.instance.currentIdentity?.pseudonym ??
            myDid;

    await sendSystemDm(channel.createdBy, {
      'sys_type': 'channel_join_request',
      'requestId': _newId(),
      'channelId': channel.id,
      'channelName': channel.name,
      'requesterDid': myDid,
      'requesterPseudonym': myPseudonym,
    });
  }

  /// Accepts a join request: updates members, sends the channelSecret to the
  /// requester, removes the request from the pending list.
  Future<void> acceptRequest(
    ChannelJoinRequest request,
    Future<void> Function(String recipientDid, Map<String, dynamic> data)
        sendSystemDm,
  ) async {
    final channel =
        GroupChannelService.instance.findByName(request.channelName);
    if (channel == null) return;

    // Add member locally.
    final updated = [...channel.members];
    if (!updated.contains(request.requesterDid)) {
      updated.add(request.requesterDid);
    }
    await GroupChannelService.instance
        .updateMembers(channel.name, updated);

    // Send acceptance DM with the channelSecret.
    await sendSystemDm(request.requesterDid, {
      'sys_type': 'channel_join_accepted',
      'channelId': channel.id,
      'channelName': channel.name,
      'channelSecret': channel.channelSecret ?? '',
      'nostrTag': channel.nostrTag,
      'description': channel.description,
    });

    _requests.removeWhere((r) => r.id == request.id);
    await _save();
    _controller.add(null);
  }

  /// Rejects a join request: notifies the requester and removes from list.
  Future<void> rejectRequest(
    ChannelJoinRequest request,
    Future<void> Function(String recipientDid, Map<String, dynamic> data)
        sendSystemDm,
  ) async {
    await sendSystemDm(request.requesterDid, {
      'sys_type': 'channel_join_rejected',
      'channelId': request.channelId,
      'channelName': request.channelName,
    });
    _requests.removeWhere((r) => r.id == request.id);
    await _save();
    _controller.add(null);
  }

  /// Sends a channel invitation to [recipientDid].
  Future<void> sendInvitation(
    GroupChannel channel,
    String recipientDid,
    Future<void> Function(String recipientDid, Map<String, dynamic> data)
        sendSystemDm,
  ) async {
    final myDid =
        IdentityService.instance.currentIdentity?.did ?? 'unknown';
    final myPseudonym =
        ProfileService.instance.currentProfile?.pseudonym.value ??
            IdentityService.instance.currentIdentity?.pseudonym ??
            myDid;

    // Add invitee to members list immediately (optimistic).
    final updated = [...channel.members];
    if (!updated.contains(recipientDid)) updated.add(recipientDid);
    await GroupChannelService.instance
        .updateMembers(channel.name, updated);

    await sendSystemDm(recipientDid, {
      'sys_type': 'channel_invite',
      'inviteId': _newId(),
      'channelId': channel.id,
      'channelName': channel.name,
      'channelSecret': channel.channelSecret ?? '',
      'nostrTag': channel.nostrTag,
      'description': channel.description,
      'adminDid': myDid,
      'adminPseudonym': myPseudonym,
    });
  }

  /// Accepts an invitation: joins the channel, subscribes, removes invite.
  ///
  /// [joinAndSubscribe] is a callback that joins the GroupChannel and
  /// subscribes to its Nostr tag (provided by ChatProvider).
  Future<void> acceptInvitation(
    ChannelInvitation invitation,
    Future<void> Function(GroupChannel channel) joinAndSubscribe,
  ) async {
    final myDid =
        IdentityService.instance.currentIdentity?.did ?? 'unknown';
    final channel = GroupChannel(
      id: invitation.channelId,
      name: invitation.channelName,
      description: '',
      createdBy: invitation.adminDid,
      createdAt: DateTime.now().toUtc(),
      isPublic: false,
      isDiscoverable: false, // we joined via invite, treat as hidden
      channelSecret: invitation.channelSecret,
      nostrTag: invitation.nostrTag,
      joinedAt: DateTime.now().toUtc(),
      members: [invitation.adminDid, myDid],
    );
    await joinAndSubscribe(channel);
    _invitations.removeWhere((i) => i.id == invitation.id);
    await _save();
    _controller.add(null);
  }

  /// Declines an invitation.
  Future<void> declineInvitation(ChannelInvitation invitation) async {
    _invitations.removeWhere((i) => i.id == invitation.id);
    await _save();
    _controller.add(null);
  }

  // ── Private ─────────────────────────────────────────────────────────────────

  void _onJoinRequest(Map<String, dynamic> data, String senderDid) {
    final myDid =
        IdentityService.instance.currentIdentity?.did ?? '';
    final channelId = data['channelId'] as String? ?? '';
    final channel = GroupChannelService.instance.findById(channelId);
    // Only handle if I'm the admin of this channel.
    if (channel == null || channel.createdBy != myDid) return;
    // Deduplicate: ignore if we already have a request from this DID.
    if (_requests.any((r) =>
        r.channelId == channelId &&
        r.requesterDid == (data['requesterDid'] as String? ?? senderDid))) {
      return;
    }
    _requests.add(ChannelJoinRequest(
      id: (data['requestId'] as String?) ?? _newId(),
      channelId: channelId,
      channelName: (data['channelName'] as String?) ?? '',
      requesterDid: (data['requesterDid'] as String?) ?? senderDid,
      requesterPseudonym: (data['requesterPseudonym'] as String?) ??
          ContactService.instance.getDisplayName(senderDid),
      receivedAt: DateTime.now(),
    ));
    _save();
    _controller.add(null);
  }

  void _onInvite(Map<String, dynamic> data, String senderDid) {
    final inviteId = (data['inviteId'] as String?) ?? _newId();
    final channelId = data['channelId'] as String? ?? '';
    // Deduplicate.
    if (_invitations.any((i) => i.id == inviteId || i.channelId == channelId)) {
      return;
    }
    // Skip if already joined.
    if (GroupChannelService.instance
        .findById(channelId) != null &&
        GroupChannelService.instance
            .isJoined(data['channelName'] as String? ?? '')) {
      return;
    }
    _invitations.add(ChannelInvitation(
      id: inviteId,
      channelId: channelId,
      channelName: (data['channelName'] as String?) ?? '',
      channelSecret: (data['channelSecret'] as String?) ?? '',
      nostrTag: (data['nostrTag'] as String?) ??
          GroupChannel.nameToNostrTag(data['channelName'] as String? ?? ''),
      adminDid: (data['adminDid'] as String?) ?? senderDid,
      adminPseudonym: (data['adminPseudonym'] as String?) ??
          ContactService.instance.getDisplayName(senderDid),
      receivedAt: DateTime.now(),
    ));
    _save();
    _controller.add(null);
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _reqKey, jsonEncode(_requests.map((r) => r.toJson()).toList()));
      await prefs.setString(
          _invKey, jsonEncode(_invitations.map((i) => i.toJson()).toList()));
    } catch (e) {
      debugPrint('[CHAN_ACCESS] save failed: $e');
    }
  }

  static String _newId() {
    final rng = Random.secure();
    final bytes = List.generate(8, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
