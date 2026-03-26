import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/contacts/contact_service.dart';
import '../../core/transport/message_transport.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/identicon.dart';
import '../contacts/widgets/trust_badge.dart';
import 'chat_provider.dart';
import 'chat_screen.dart' show RadarScreen;
import 'conversation.dart';
import 'conversation_screen.dart';
import 'conversation_service.dart';

/// Chat-Tab: Postfach mit allen Konversationen (wie WhatsApp/Telegram).
///
/// - #mesh Broadcast-Kanal ist immer angepinnt ganz oben.
/// - Direkt-Konversationen sortiert nach letzter Nachricht (neueste oben).
/// - FAB (unten rechts) öffnet den Radar/Peer-Discovery-Screen.
/// - Swipe nach links → Konversation löschen.
class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({super.key});

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  List<Conversation> _conversations = [];
  bool _loading = true;
  StreamSubscription<List<Conversation>>? _sub;

  @override
  void initState() {
    super.initState();
    // Initialise transport (safe to call multiple times).
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
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _loadConversations() async {
    final convs =
        await ConversationService.instance.getConversationsWithMesh();
    if (mounted) {
      setState(() {
        _conversations = convs;
        _loading = false;
      });
    }
  }

  void _openConversation(Conversation conv) {
    // Mark as read immediately
    ConversationService.instance.markAsRead(conv.id);

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

  Future<void> _deleteConversation(Conversation conv) async {
    await context.read<ChatProvider>().deleteConversation(conv.id);
    await _loadConversations();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nachrichten'),
        actions: [
          Consumer<ChatProvider>(
            builder: (context, provider, child) => _MeshDot(
              running: provider.running,
              hasPeers: provider.peers.isNotEmpty,
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _conversations.isEmpty
              ? _EmptyState(onDiscover: _openRadar)
              : _ConversationList(
                  conversations: _conversations,
                  onTap: _openConversation,
                  onDelete: _deleteConversation,
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openRadar,
        backgroundColor: AppColors.gold,
        foregroundColor: AppColors.deepBlue,
        tooltip: 'Peers entdecken',
        child: const Icon(Icons.radar),
      ),
    );
  }
}

// ── Conversation list ─────────────────────────────────────────────────────────

class _ConversationList extends StatelessWidget {
  const _ConversationList({
    required this.conversations,
    required this.onTap,
    required this.onDelete,
  });

  final List<Conversation> conversations;
  final void Function(Conversation) onTap;
  final Future<void> Function(Conversation) onDelete;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: conversations.length,
      separatorBuilder: (context, index) =>
          const Divider(height: 1, indent: 72, color: AppColors.surfaceVariant),
      itemBuilder: (context, i) {
        final conv = conversations[i];
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
          child: _ConversationTile(conv: conv, onTap: () => onTap(conv)),
        );
      },
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.conv, required this.onTap});
  final Conversation conv;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: _Avatar(conv: conv),
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
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
                if (!conv.isBroadcast) ...[
                  const SizedBox(width: 6),
                  _TrustBadgeInline(peerDid: conv.peerDid),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (conv.transportType != null)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: _TransportIcon(type: conv.transportType!),
                ),
              Text(
                _formatTime(conv.lastMessageTime),
                style: TextStyle(
                  fontSize: 11,
                  color: conv.unreadCount > 0
                      ? AppColors.gold
                      : Colors.grey,
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
                color: conv.unreadCount > 0
                    ? AppColors.onDark
                    : Colors.grey,
                fontSize: 13,
              ),
            ),
          ),
          if (conv.unreadCount > 0)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
      final h = local.hour.toString().padLeft(2, '0');
      final m = local.minute.toString().padLeft(2, '0');
      return '$h:$m';
    }
    if (now.difference(local).inDays < 7) {
      const days = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
      return days[local.weekday - 1];
    }
    return '${local.day.toString().padLeft(2, '0')}.'
        '${local.month.toString().padLeft(2, '0')}.';
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.conv});
  final Conversation conv;

  @override
  Widget build(BuildContext context) {
    if (conv.isBroadcast) {
      return Container(
        width: 48,
        height: 48,
        decoration: const BoxDecoration(
          color: AppColors.surfaceVariant,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.hub, color: AppColors.gold, size: 26),
      );
    }

    if (conv.peerProfileImage != null) {
      // TODO: load from local file path when profile image caching is added.
    }

    // Deterministic identicon from the peer DID bytes
    final didBytes = conv.peerDid.codeUnits;
    return ClipOval(
      child: Identicon(bytes: didBytes, size: 48),
    );
  }
}

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
      _ =>
        const Icon(Icons.cloud_queue, size: 12, color: Colors.grey),
    };
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onDiscover});
  final VoidCallback onDiscover;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.chat_bubble_outline,
                size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'Noch keine Nachrichten.\nFinde Peers in der Nähe!',
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

// ── Inline trust badge (for conversation list) ────────────────────────────────

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

// ── Mesh status dot ───────────────────────────────────────────────────────────

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
