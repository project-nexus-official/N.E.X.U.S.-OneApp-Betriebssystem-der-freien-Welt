import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/contacts/contact_service.dart';
import '../../core/transport/nexus_message.dart';
import '../../shared/theme/app_theme.dart';
import 'chat_provider.dart';
import 'conversation_service.dart';
import 'group_channel.dart';
import 'group_channel_service.dart';

/// Chat screen for a named group channel (e.g. #teneriffa).
///
/// - Messages are unencrypted (public channel).
/// - Sender pseudonym is shown above each message.
/// - Header tap → channel info bottom sheet with description and leave button.
class ChannelConversationScreen extends StatefulWidget {
  const ChannelConversationScreen({
    super.key,
    required this.channel,
  });

  final GroupChannel channel;

  @override
  State<ChannelConversationScreen> createState() =>
      _ChannelConversationScreenState();
}

class _ChannelConversationScreenState
    extends State<ChannelConversationScreen> {
  final _scrollController = ScrollController();
  final _textController = TextEditingController();
  final _focusNode = FocusNode();

  List<NexusMessage> _messages = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    ConversationService.instance
        .markAsRead(widget.channel.conversationId);
    _loadMessages();
    context.read<ChatProvider>().setActiveConversation(
          widget.channel.conversationId,
        );
  }

  @override
  void dispose() {
    context.read<ChatProvider>().setActiveConversation(null);
    _scrollController.dispose();
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    final msgs = await context
        .read<ChatProvider>()
        .getMessages(widget.channel.conversationId);
    if (mounted) {
      setState(() {
        _messages = List.from(msgs);
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    await context
        .read<ChatProvider>()
        .sendToChannel(widget.channel.name, text);
    await _loadMessages();
  }

  void _showChannelInfo() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.channel.name,
                style: const TextStyle(
                  color: AppColors.gold,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (widget.channel.description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  widget.channel.description,
                  style: const TextStyle(color: AppColors.onDark),
                ),
              ],
              const SizedBox(height: 4),
              Text(
                'Öffentlicher Kanal',
                style: TextStyle(color: Colors.grey[600], fontSize: 12),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.exit_to_app, color: Colors.redAccent),
                  label: const Text(
                    'Kanal verlassen',
                    style: TextStyle(color: Colors.redAccent),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.redAccent),
                  ),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await _leaveChannel();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _leaveChannel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('${widget.channel.name} verlassen?'),
        content: const Text(
          'Du verlässt diesen Kanal. Du kannst ihm jederzeit wieder beitreten.',
          style: TextStyle(color: AppColors.onDark),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:
                const Text('Abbrechen', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Verlassen'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await GroupChannelService.instance
          .leaveChannel(widget.channel.name);
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: _showChannelInfo,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.channel.name,
                style: const TextStyle(
                  color: AppColors.gold,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                'Öffentlicher Kanal',
                style: TextStyle(color: Colors.grey[500], fontSize: 11),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'Kanal-Info',
            onPressed: _showChannelInfo,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? const _EmptyChannelHint()
                    : Consumer<ChatProvider>(
                        builder: (context2, provider, child2) {
                          // React to new messages.
                          provider
                              .getMessages(widget.channel.conversationId)
                              .then((msgs) {
                            if (mounted &&
                                msgs.length != _messages.length) {
                              setState(() => _messages = List.from(msgs));
                              WidgetsBinding.instance.addPostFrameCallback(
                                  (_) => _scrollToBottom());
                            }
                          });
                          return ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            itemCount: _messages.length,
                            itemBuilder: (ctx, i) =>
                                _ChannelMessageBubble(msg: _messages[i]),
                          );
                        },
                      ),
          ),
          _InputBar(
            controller: _textController,
            focusNode: _focusNode,
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

// ── Message bubble ─────────────────────────────────────────────────────────────

class _ChannelMessageBubble extends StatelessWidget {
  const _ChannelMessageBubble({required this.msg});
  final NexusMessage msg;

  @override
  Widget build(BuildContext context) {
    final senderName = ContactService.instance.getDisplayName(msg.fromDid);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            senderName,
            style: const TextStyle(
              color: AppColors.gold,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              msg.body,
              style: const TextStyle(color: AppColors.onDark),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _formatTime(msg.timestamp),
            style: TextStyle(color: Colors.grey[600], fontSize: 11),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime ts) {
    final t = ts.toLocal();
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

// ── Input bar ──────────────────────────────────────────────────────────────────

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(
            top: BorderSide(color: AppColors.surfaceVariant),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                style: const TextStyle(color: AppColors.onDark),
                decoration: InputDecoration(
                  hintText: 'Nachricht an ${context
                      .findAncestorWidgetOfExactType<ChannelConversationScreen>()
                      ?.channel.name ?? 'Kanal'}…',
                  hintStyle: TextStyle(color: Colors.grey[600]),
                  filled: true,
                  fillColor: AppColors.surfaceVariant,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onSend,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: const BoxDecoration(
                  color: AppColors.gold,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.send,
                    color: AppColors.deepBlue, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Empty state ────────────────────────────────────────────────────────────────

class _EmptyChannelHint extends StatelessWidget {
  const _EmptyChannelHint();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.tag, size: 48, color: AppColors.gold),
          SizedBox(height: 12),
          Text(
            'Noch keine Nachrichten.',
            style: TextStyle(color: AppColors.onDark),
          ),
          SizedBox(height: 4),
          Text(
            'Schreib die erste Nachricht in diesem Kanal!',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
