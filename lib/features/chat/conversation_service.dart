import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/contacts/contact.dart';
import '../../core/contacts/contact_service.dart';
import '../../core/identity/identity_service.dart';
import '../../core/storage/pod_database.dart';
import '../../core/transport/nexus_message.dart';
import 'conversation.dart';
import 'group_channel_service.dart';

// ignore_for_file: cancel_subscriptions

/// Manages the conversation list (inbox).
///
/// Reads from [PodDatabase] and provides a reactive [stream] of sorted
/// [Conversation] objects. Call [notifyUpdate] whenever new messages arrive or
/// are sent so the stream emits fresh data.
class ConversationService {
  ConversationService._();
  static final instance = ConversationService._();

  final _controller = StreamController<List<Conversation>>.broadcast();

  /// Live stream of conversations, sorted by lastMessageTime (pinned first).
  Stream<List<Conversation>> get stream => _controller.stream;

  /// Millisecond timestamps of the last-read message per conversationId.
  final Map<String, int> _lastRead = {};

  StreamSubscription<void>? _contactsChangedSub;

  // ── Initialisation ──────────────────────────────────────────────────────

  /// Loads persisted last-read timestamps from the POD and subscribes to
  /// contact name changes so the conversation list refreshes automatically.
  Future<void> load() async {
    try {
      final data =
          await PodDatabase.instance.getIdentityValue('conv_last_read');
      if (data != null) {
        for (final entry in data.entries) {
          _lastRead[entry.key] = (entry.value as num).toInt();
        }
      }
    } catch (_) {
      // POD might not be open yet; ignore on startup.
    }

    // When a contact's display name changes (e.g. Kind-0 sync), refresh the
    // conversation list so the new name appears immediately in the UI.
    _contactsChangedSub?.cancel();
    _contactsChangedSub =
        ContactService.instance.contactsChanged.listen((_) => notifyUpdate());
  }

  // ── Public API ──────────────────────────────────────────────────────────

  /// Returns all conversations sorted: pinned first, then by lastMessageTime
  /// descending.
  Future<List<Conversation>> getConversations() async {
    try {
      final summaries =
          await PodDatabase.instance.listConversationSummaries();

      final myDid =
          IdentityService.instance.currentIdentity?.did ?? '';

      final conversations = <Conversation>[];

      for (final summary in summaries) {
        final convId = summary['conversation_id'] as String;
        final lastTs = (summary['last_ts'] as num).toInt();

        final lastMsgs =
            await PodDatabase.instance.listLastMessages(convId, limit: 1);
        final lastMsg = lastMsgs.isNotEmpty ? lastMsgs.first : null;

        final lastBody = _previewBody(lastMsg);
        final lastTime =
            DateTime.fromMillisecondsSinceEpoch(lastTs, isUtc: true);

        final lastReadTs = _lastRead[convId] ?? 0;
        final unread =
            await PodDatabase.instance.countMessagesAfter(convId, lastReadTs);

        if (convId == NexusMessage.broadcastDid) {
          conversations.add(Conversation(
            id: convId,
            peerDid: NexusMessage.broadcastDid,
            peerPseudonym: '#mesh',
            lastMessage: lastBody,
            lastMessageTime: lastTime,
            unreadCount: unread,
            isPinned: true,
          ));
        } else if (convId.startsWith('#')) {
          // Named group channel.
          final channel = GroupChannelService.instance.findByName(convId);
          final name = channel?.name ?? convId;
          conversations.add(Conversation(
            id: convId,
            peerDid: convId,
            peerPseudonym: name,
            lastMessage: lastBody,
            lastMessageTime: lastTime,
            unreadCount: unread,
          ));
        } else {
          final peerDid = Conversation.peerDidFrom(convId, myDid);
          if (peerDid == null) continue;

          // Skip conversations with blocked peers.
          if (ContactService.instance.isBlocked(peerDid)) continue;

          // Look up display name via central resolver (contact → live peer → DID fragment).
          final pseudonym = ContactService.instance.getDisplayName(peerDid);
          final contact = _findContact(peerDid);
          final profileImage = contact?.profileImage;

          conversations.add(Conversation(
            id: convId,
            peerDid: peerDid,
            peerPseudonym: pseudonym,
            peerProfileImage: profileImage,
            lastMessage: lastBody,
            lastMessageTime: lastTime,
            unreadCount: unread,
          ));
        }
      }

      // Sort: pinned first, then by lastMessageTime descending.
      conversations.sort((a, b) {
        if (a.isPinned && !b.isPinned) return -1;
        if (!a.isPinned && b.isPinned) return 1;
        return b.lastMessageTime.compareTo(a.lastMessageTime);
      });

      return conversations;
    } catch (_) {
      return [];
    }
  }

  /// Ensures the #mesh broadcast conversation always appears even before any
  /// broadcast message has been received, and that all joined group channels
  /// appear even if they have no messages yet.
  Future<List<Conversation>> getConversationsWithMesh() async {
    final conversations = await getConversations();

    final hasMesh =
        conversations.any((c) => c.id == NexusMessage.broadcastDid);
    if (!hasMesh) {
      conversations.insert(
        0,
        Conversation(
          id: NexusMessage.broadcastDid,
          peerDid: NexusMessage.broadcastDid,
          peerPseudonym: '#mesh',
          lastMessage: 'Broadcast-Kanal für alle in Reichweite',
          lastMessageTime: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          isPinned: true,
        ),
      );
    }

    // Inject joined channels that have no messages yet (not in pod_messages).
    final existingGroupIds =
        conversations.where((c) => c.isGroup).map((c) => c.id).toSet();
    final joined = GroupChannelService.instance.joinedChannels;
    debugPrint('[CHANNELS] Loaded ${joined.length} joined channels from DB');
    for (final ch in joined) {
      if (!existingGroupIds.contains(ch.name)) {
        conversations.add(Conversation(
          id: ch.name,
          peerDid: ch.name,
          peerPseudonym: ch.name,
          lastMessage:
              ch.description.isNotEmpty ? ch.description : 'Kanal beigetreten',
          lastMessageTime: ch.joinedAt ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        ));
      }
    }

    return conversations;
  }

  /// Finds or synthesises a [Conversation] for [peerDid].
  Future<Conversation> getOrCreateConversation(
    String peerDid,
    String peerPseudonym,
  ) async {
    final myDid =
        IdentityService.instance.currentIdentity?.did ?? '';
    final convId = peerDid == NexusMessage.broadcastDid
        ? NexusMessage.broadcastDid
        : Conversation.directId(peerDid, myDid);

    final conversations = await getConversations();
    return conversations.firstWhere(
      (c) => c.id == convId,
      orElse: () => Conversation(
        id: convId,
        peerDid: peerDid,
        peerPseudonym: peerPseudonym,
        lastMessage: '',
        lastMessageTime: DateTime.now().toUtc(),
      ),
    );
  }

  /// Records that the user has read all messages in [conversationId].
  Future<void> markAsRead(String conversationId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastRead[conversationId] = now;
    await _persistLastRead();
    notifyUpdate();
  }

  /// Returns the number of unread messages in [conversationId].
  Future<int> getUnreadCount(String conversationId) async {
    final lastReadTs = _lastRead[conversationId] ?? 0;
    return PodDatabase.instance.countMessagesAfter(conversationId, lastReadTs);
  }

  /// Deletes all messages in [conversationId] from the POD.
  Future<void> deleteConversation(String conversationId) async {
    await PodDatabase.instance.deleteConversation(conversationId);
    _lastRead.remove(conversationId);
    await _persistLastRead();
    notifyUpdate();
  }

  /// Triggers a fresh load and emits on [stream].
  /// Called by [ChatProvider] whenever a message is sent or received.
  void notifyUpdate() {
    getConversationsWithMesh().then((convs) {
      if (!_controller.isClosed) _controller.add(convs);
    });
  }

  // ── Internals ───────────────────────────────────────────────────────────

  String _previewBody(Map<String, dynamic>? msg) {
    if (msg == null) return '…';
    final type = msg['type'] as String? ?? 'text';
    if (type == 'image') return '📷 Foto';
    if (type == 'voice') return '🎤 Sprachnachricht';
    final body = msg['body'] as String? ?? '';
    return body.length > 60 ? body.substring(0, 60) : body;
  }

  Contact? _findContact(String did) {
    try {
      return ContactService.instance.contacts.firstWhere((c) => c.did == did);
    } catch (_) {
      return null;
    }
  }

  Future<void> _persistLastRead() async {
    try {
      await PodDatabase.instance.setIdentityValue(
        'conv_last_read',
        Map<String, dynamic>.from(
          _lastRead.map((k, v) => MapEntry(k, v)),
        ),
      );
    } catch (_) {}
  }
}
