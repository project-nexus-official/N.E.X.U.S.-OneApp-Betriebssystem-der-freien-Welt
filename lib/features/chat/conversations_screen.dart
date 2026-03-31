import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/contacts/contact_service.dart';
import '../../core/transport/message_transport.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/identicon.dart';
import '../contacts/contacts_screen.dart';
import '../contacts/widgets/trust_badge.dart';
import 'channel_conversation_screen.dart';
import 'chat_provider.dart';
import 'chat_screen.dart' show RadarScreen;
import 'conversation.dart';
import 'conversation_screen.dart';
import 'conversation_service.dart';
import 'channel_access_service.dart';
import 'channel_requests_screen.dart';
import 'create_channel_screen.dart';
import 'group_channel_service.dart';
import 'join_channel_screen.dart';
import 'message_search_screen.dart';

/// Chat-Tab: Postfach mit Chats und Kanälen in separaten Tabs.
///
/// Tab 0 – "Chats": #mesh angepinnt + alle DM-Konversationen.
/// Tab 1 – "Kanäle": alle beigetretenen Gruppenkanäle.
///
/// Swipe und Tab-Tap wechseln zwischen den Tabs.
/// FAB zeigt kontextabhängige Aktionen je nach aktivem Tab.
class ConversationsScreen extends StatefulWidget {
  /// Which inner tab to show on first render: 0 = Chats, 1 = Kanäle.
  final int initialTabIndex;

  const ConversationsScreen({super.key, this.initialTabIndex = 0});

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen>
    with SingleTickerProviderStateMixin {
  List<Conversation> _conversations = [];
  bool _loading = true;
  StreamSubscription<List<Conversation>>? _sub;

  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTabIndex.clamp(0, 1),
    );
    _tabController.addListener(() => setState(() {})); // rebuild FAB on tab change

    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatProvider>().initialize();
    });
    _loadConversations();
    _sub = ConversationService.instance.stream.listen((convs) {
      if (mounted) setState(() => _conversations = convs);
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _loadConversations() async {
    final convs = await ConversationService.instance.getConversationsWithMesh();
    if (mounted) {
      setState(() {
        _conversations = convs;
        _loading = false;
      });
    }
  }

  // ── Filtered views ──────────────────────────────────────────────────────────

  /// Conversations shown in the "Chats" tab: #mesh + DMs (no group channels).
  List<Conversation> get _chatConversations =>
      _conversations.where((c) => !c.isGroup).toList();

  /// Conversations shown in the "Kanäle" tab: group channels only,
  /// #nexus-global pinned first, then by lastMessageTime desc.
  List<Conversation> get _channelConversations {
    final channels = _conversations.where((c) => c.isGroup).toList();
    channels.sort((a, b) {
      if (a.id == '#nexus-global') return -1;
      if (b.id == '#nexus-global') return 1;
      return b.lastMessageTime.compareTo(a.lastMessageTime);
    });
    return channels;
  }

  /// Total unread count across all channel conversations (for tab badge).
  int get _channelUnreadCount =>
      _channelConversations.fold(0, (sum, c) => sum + c.unreadCount);

  // ── Navigation ──────────────────────────────────────────────────────────────

  void _openConversation(Conversation conv) {
    ConversationService.instance.markAsRead(conv.id);

    if (conv.isGroup) {
      final channel = GroupChannelService.instance.findByName(conv.id);
      if (channel == null) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChangeNotifierProvider.value(
            value: context.read<ChatProvider>(),
            child: ChannelConversationScreen(channel: channel),
          ),
        ),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChangeNotifierProvider.value(
          value: context.read<ChatProvider>(),
          child: ConversationScreen(
            peerDid: conv.peerDid,
            peerPseudonym: conv.peerPseudonym,
            isBroadcast: conv.isBroadcast,
          ),
        ),
      ),
    );
  }

  void _openRadar() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChangeNotifierProvider.value(
          value: context.read<ChatProvider>(),
          child: const RadarScreen(),
        ),
      ),
    );
  }

  void _openContacts() {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => const ContactsScreen()),
    );
  }

  void _createChannel() {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => ChangeNotifierProvider.value(
          value: context.read<ChatProvider>(),
          child: const CreateChannelScreen(),
        ),
      ),
    ).then((_) => _loadConversations());
  }

  void _joinChannel() {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => ChangeNotifierProvider.value(
          value: context.read<ChatProvider>(),
          child: const JoinChannelScreen(),
        ),
      ),
    ).then((_) => _loadConversations());
  }

  Future<void> _deleteConversation(Conversation conv) async {
    await context.read<ChatProvider>().deleteConversation(conv.id);
    await _loadConversations();
  }

  // ── FAB menus ───────────────────────────────────────────────────────────────

  void _showChatsMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Text(
                'Neue Konversation',
                style: const TextStyle(
                  color: AppColors.gold,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.qr_code_scanner, color: AppColors.gold),
              title: const Text('QR-Code scannen'),
              onTap: () {
                Navigator.pop(ctx);
                context.push('/qr-scanner');
              },
            ),
            ListTile(
              leading: const Icon(Icons.radar, color: AppColors.gold),
              title: const Text('Peers im Netzwerk'),
              onTap: () {
                Navigator.pop(ctx);
                _openRadar();
              },
            ),
            ListTile(
              leading: const Icon(Icons.people_outline, color: AppColors.gold),
              title: const Text('Kontakte anzeigen'),
              onTap: () {
                Navigator.pop(ctx);
                _openContacts();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showChannelsMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Text(
                'Kanäle',
                style: const TextStyle(
                  color: AppColors.gold,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.add_box_outlined, color: AppColors.gold),
              title: const Text('Kanal erstellen'),
              onTap: () {
                Navigator.pop(ctx);
                _createChannel();
              },
            ),
            ListTile(
              leading: const Icon(Icons.explore, color: AppColors.gold),
              title: const Text('Kanäle entdecken'),
              onTap: () {
                Navigator.pop(ctx);
                _joinChannel();
              },
            ),
            StreamBuilder<void>(
              stream: ChannelAccessService.instance.onChanged,
              builder: (ctx2, _) {
                final count =
                    ChannelAccessService.instance.pendingCount;
                return ListTile(
                  leading: const Icon(Icons.pending_actions,
                      color: AppColors.gold),
                  title: const Text('Kanal-Anfragen'),
                  trailing: count > 0
                      ? Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: const BoxDecoration(
                            color: AppColors.gold,
                            borderRadius:
                                BorderRadius.all(Radius.circular(10)),
                          ),
                          child: Text(
                            '$count',
                            style: const TextStyle(
                              color: AppColors.deepBlue,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        )
                      : null,
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.of(context, rootNavigator: true).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            ChangeNotifierProvider.value(
                          value: context.read<ChatProvider>(),
                          child: const ChannelRequestsScreen(),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isChannelsTab = _tabController.index == 1;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nachrichten'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Suchen',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ChangeNotifierProvider.value(
                  value: context.read<ChatProvider>(),
                  child: const MessageSearchScreen(),
                ),
              ),
            ),
          ),
          Consumer<ChatProvider>(
            builder: (context, provider, child) => _MeshDot(
              running: provider.running,
              hasPeers: provider.peers.isNotEmpty,
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppColors.gold,
          indicatorWeight: 2.5,
          labelColor: AppColors.gold,
          unselectedLabelColor: Colors.grey,
          labelStyle: const TextStyle(fontWeight: FontWeight.w600),
          tabs: [
            const Tab(text: 'Chats'),
            Tab(
              child: _channelUnreadCount > 0
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Kanäle'),
                        const SizedBox(width: 6),
                        _UnreadBadge(count: _channelUnreadCount),
                      ],
                    )
                  : const Text('Kanäle'),
            ),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                // ── Chats tab ─────────────────────────────────────────────
                _chatConversations.isEmpty
                    ? _EmptyChatsState(onDiscover: _openRadar)
                    : _ConversationList(
                        conversations: _chatConversations,
                        onTap: _openConversation,
                        onDelete: _deleteConversation,
                      ),

                // ── Kanäle tab ────────────────────────────────────────────
                _channelConversations.isEmpty
                    ? _EmptyChannelsState(onDiscover: _joinChannel)
                    : _ConversationList(
                        conversations: _channelConversations,
                        onTap: _openConversation,
                        onDelete: _deleteConversation,
                        pinnedId: '#nexus-global',
                      ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: isChannelsTab ? _showChannelsMenu : _showChatsMenu,
        backgroundColor: AppColors.gold,
        foregroundColor: AppColors.deepBlue,
        tooltip: isChannelsTab ? 'Kanal-Aktionen' : 'Neue Konversation',
        child: const Icon(Icons.add),
      ),
    );
  }
}

// ── Conversation list ──────────────────────────────────────────────────────────

class _ConversationList extends StatelessWidget {
  const _ConversationList({
    required this.conversations,
    required this.onTap,
    required this.onDelete,
    this.pinnedId,
  });

  final List<Conversation> conversations;
  final void Function(Conversation) onTap;
  final Future<void> Function(Conversation) onDelete;

  /// ID of a conversation that should show a pin indicator (always first).
  final String? pinnedId;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: conversations.length,
      separatorBuilder: (context, index) =>
          const Divider(height: 1, indent: 72, color: AppColors.surfaceVariant),
      itemBuilder: (context, i) {
        final conv = conversations[i];
        final isPinned = pinnedId != null && conv.id == pinnedId;
        return Dismissible(
          key: ValueKey(conv.id),
          direction: DismissDirection.endToStart,
          background: Container(
            color: Colors.redAccent,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            child: const Icon(Icons.delete_outline, color: Colors.white),
          ),
          confirmDismiss: (_) async {
            return await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: AppColors.surface,
                title: const Text('Konversation löschen?'),
                content: Text(
                  'Alle Nachrichten mit ${conv.peerPseudonym} werden '
                  'unwiderruflich gelöscht.',
                  style: const TextStyle(color: AppColors.onDark),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Abbrechen',
                        style: TextStyle(color: Colors.grey)),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Löschen'),
                  ),
                ],
              ),
            ) ??
                false;
          },
          onDismissed: (_) => onDelete(conv),
          child: _ConversationTile(
            conv: conv,
            isPinned: isPinned,
            onTap: () => onTap(conv),
          ),
        );
      },
    );
  }
}

// ── Conversation tile ──────────────────────────────────────────────────────────

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conv,
    required this.onTap,
    this.isPinned = false,
  });

  final Conversation conv;
  final VoidCallback onTap;
  final bool isPinned;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: _Avatar(conv: conv),
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
                if (isPinned)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(Icons.push_pin,
                        size: 12, color: AppColors.gold.withAlpha(180)),
                  ),
                Flexible(
                  child: Text(
                    conv.peerPseudonym,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: AppColors.onDark,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (conv.isGroup && !(GroupChannelService.instance.findByName(conv.id)?.isPublic ?? true))
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Icon(Icons.lock, size: 12, color: Colors.grey),
                  ),
                if (!conv.isBroadcast && !conv.isGroup) ...[
                  const SizedBox(width: 6),
                  _TrustBadgeInline(peerDid: conv.peerDid),
                  _EncryptionDotInline(peerDid: conv.peerDid),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!conv.isBroadcast &&
                  !conv.isGroup &&
                  ContactService.instance.isMuted(conv.peerDid))
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.notifications_off,
                    size: 12,
                    color: Colors.grey,
                  ),
                ),
              if (conv.transportType != null)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: _TransportIcon(type: conv.transportType!),
                ),
              Text(
                _formatTime(conv.lastMessageTime),
                style: TextStyle(
                  fontSize: 11,
                  color: conv.unreadCount > 0 ? AppColors.gold : Colors.grey,
                ),
              ),
            ],
          ),
        ],
      ),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(
              conv.lastMessage,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: conv.unreadCount > 0 ? AppColors.onDark : Colors.grey,
                fontSize: 13,
              ),
            ),
          ),
          if (conv.unreadCount > 0)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: const BoxDecoration(
                color: AppColors.gold,
                borderRadius: BorderRadius.all(Radius.circular(10)),
              ),
              child: Text(
                conv.unreadCount > 99 ? '99+' : '${conv.unreadCount}',
                style: const TextStyle(
                  color: AppColors.deepBlue,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
      onTap: onTap,
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now().toLocal();
    final local = dt.toLocal();
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
    }
    if (now.difference(local).inDays < 7) {
      const days = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
      return days[local.weekday - 1];
    }
    return '${local.day.toString().padLeft(2, '0')}.'
        '${local.month.toString().padLeft(2, '0')}.';
  }
}

// ── Avatar ─────────────────────────────────────────────────────────────────────

class _Avatar extends StatelessWidget {
  const _Avatar({required this.conv});
  final Conversation conv;

  @override
  Widget build(BuildContext context) {
    if (conv.isBroadcast) {
      return _CircleIcon(icon: Icons.hub);
    }
    if (conv.isGroup) {
      final channel = GroupChannelService.instance.findByName(conv.id);
      final isPrivate = channel != null && !channel.isPublic;
      return _CircleIcon(icon: isPrivate ? Icons.lock : Icons.tag);
    }
    if (conv.peerProfileImage != null) {
      // TODO: load from local file path when profile image caching is added.
    }
    final didBytes = conv.peerDid.codeUnits;
    return ClipOval(child: Identicon(bytes: didBytes, size: 48));
  }
}

class _CircleIcon extends StatelessWidget {
  const _CircleIcon({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: const BoxDecoration(
        color: AppColors.surfaceVariant,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: AppColors.gold, size: 26),
    );
  }
}

// ── Unread badge (for tab bar) ─────────────────────────────────────────────────

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: const BoxDecoration(
        color: AppColors.gold,
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: const TextStyle(
          color: AppColors.deepBlue,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

// ── Transport icon ─────────────────────────────────────────────────────────────

class _TransportIcon extends StatelessWidget {
  const _TransportIcon({required this.type});
  final TransportType type;

  @override
  Widget build(BuildContext context) {
    return switch (type) {
      TransportType.ble =>
        const Icon(Icons.bluetooth, size: 12, color: Colors.lightBlueAccent),
      TransportType.lan =>
        const Icon(Icons.wifi, size: 12, color: Colors.greenAccent),
      _ => const Icon(Icons.cloud_queue, size: 12, color: Colors.grey),
    };
  }
}

// ── Empty states ───────────────────────────────────────────────────────────────

class _EmptyChatsState extends StatelessWidget {
  const _EmptyChatsState({required this.onDiscover});
  final VoidCallback onDiscover;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'Noch keine Nachrichten.\nFinde Peers im Netzwerk!',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 16),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: onDiscover,
              icon: const Icon(Icons.radar),
              label: const Text('Peers entdecken'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyChannelsState extends StatelessWidget {
  const _EmptyChannelsState({required this.onDiscover});
  final VoidCallback onDiscover;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.tag, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'Noch keinem Kanal beigetreten.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 16),
            ),
            const SizedBox(height: 8),
            const Text(
              'Entdecke öffentliche Kanäle oder\nerstelle deinen eigenen.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: onDiscover,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.gold,
                foregroundColor: AppColors.deepBlue,
              ),
              icon: const Icon(Icons.explore),
              label: const Text('Kanäle entdecken'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Inline trust badge ─────────────────────────────────────────────────────────

class _TrustBadgeInline extends StatelessWidget {
  const _TrustBadgeInline({required this.peerDid});
  final String peerDid;

  @override
  Widget build(BuildContext context) {
    final contact = ContactService.instance.findByDid(peerDid);
    if (contact == null) return const SizedBox.shrink();
    return TrustBadge(level: contact.trustLevel, small: true);
  }
}

// ── Inline encryption dot ──────────────────────────────────────────────────────

class _EncryptionDotInline extends StatelessWidget {
  const _EncryptionDotInline({required this.peerDid});
  final String peerDid;

  @override
  Widget build(BuildContext context) {
    final contact = ContactService.instance.findByDid(peerDid);
    if (contact?.encryptionPublicKey == null) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.only(left: 4),
      child: Icon(Icons.lock, size: 10, color: AppColors.gold),
    );
  }
}

// ── Mesh status dot ────────────────────────────────────────────────────────────

class _MeshDot extends StatelessWidget {
  const _MeshDot({required this.running, required this.hasPeers});
  final bool running;
  final bool hasPeers;

  @override
  Widget build(BuildContext context) {
    final color = !running
        ? Colors.redAccent
        : hasPeers
            ? Colors.greenAccent
            : Colors.amber;

    return Padding(
      padding: const EdgeInsets.only(right: 14),
      child: Center(
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
