import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/transport/nexus_message.dart';
import '../../core/transport/nexus_peer.dart';
import '../../shared/theme/app_theme.dart';
import '../../core/identity/identity_service.dart';
import 'chat_provider.dart';

/// Direkt-Chat-Bildschirm mit einem einzelnen Peer.
class ConversationScreen extends StatefulWidget {
  const ConversationScreen({super.key, required this.peer});
  final NexusPeer peer;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  List<NexusMessage> _messages = [];
  bool _loading = true;

  String get _convId {
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final sorted = [widget.peer.did, myDid]..sort();
    return '${sorted[0]}:${sorted[1]}';
  }

  @override
  void initState() {
    super.initState();
    _loadMessages();
  }

  Future<void> _loadMessages() async {
    final provider = context.read<ChatProvider>();
    final msgs = await provider.getMessages(_convId);
    if (mounted) {
      setState(() {
        _messages = List.from(msgs);
        _loading = false;
      });
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    _textCtrl.clear();

    final provider = context.read<ChatProvider>();
    try {
      await provider.sendMessage(widget.peer.did, text);
      final msgs = await provider.getMessages(_convId);
      if (mounted) {
        setState(() => _messages = List.from(msgs));
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Senden fehlgeschlagen: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        // Listen for new messages in this conversation
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          final fresh = await provider.getMessages(_convId);
          if (mounted && fresh.length != _messages.length) {
            setState(() => _messages = List.from(fresh));
            _scrollToBottom();
          }
        });

        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.peer.pseudonym),
                Text(
                  widget.peer.transportType.name.toUpperCase(),
                  style: const TextStyle(fontSize: 11, color: AppColors.gold),
                ),
              ],
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: _ConnectionIndicator(peer: widget.peer),
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _MessageList(
                        messages: _messages,
                        scrollCtrl: _scrollCtrl,
                      ),
              ),
              _InputBar(
                ctrl: _textCtrl,
                onSend: _sendMessage,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Message list ─────────────────────────────────────────────────────────────

class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.messages,
    required this.scrollCtrl,
  });
  final List<NexusMessage> messages;
  final ScrollController scrollCtrl;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return const Center(
        child: Text(
          'Noch keine Nachrichten.\nSchreib etwas!',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    final myDid = IdentityService.instance.currentIdentity?.did ?? '';

    return ListView.builder(
      controller: scrollCtrl,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: messages.length,
      itemBuilder: (context, i) {
        final msg = messages[i];
        final isMe = msg.fromDid == myDid;
        return _MessageBubble(message: msg, isMe: isMe);
      },
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.isMe});
  final NexusMessage message;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    final time = _formatTime(message.timestamp.toLocal());

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: isMe ? AppColors.gold : AppColors.surfaceVariant,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              message.body,
              style: TextStyle(
                color: isMe ? AppColors.deepBlue : AppColors.onDark,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  time,
                  style: TextStyle(
                    color: isMe
                        ? AppColors.deepBlue.withValues(alpha: 0.6)
                        : Colors.grey,
                    fontSize: 10,
                  ),
                ),
                if (message.signature != null) ...[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.verified,
                    size: 10,
                    color: isMe
                        ? AppColors.deepBlue.withValues(alpha: 0.6)
                        : Colors.greenAccent,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

// ── Input bar ────────────────────────────────────────────────────────────────

class _InputBar extends StatelessWidget {
  const _InputBar({required this.ctrl, required this.onSend});
  final TextEditingController ctrl;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        color: AppColors.surface,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: ctrl,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Nachricht schreiben…',
                  hintStyle: const TextStyle(color: Colors.grey),
                  filled: true,
                  fillColor: AppColors.surfaceVariant,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
                onSubmitted: (_) => onSend(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: onSend,
              icon: const Icon(Icons.send_rounded),
              color: AppColors.gold,
              style: IconButton.styleFrom(
                backgroundColor: AppColors.surfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Connection indicator ──────────────────────────────────────────────────────

class _ConnectionIndicator extends StatelessWidget {
  const _ConnectionIndicator({required this.peer});
  final NexusPeer peer;

  @override
  Widget build(BuildContext context) {
    final color = switch (peer.signalLevel) {
      SignalLevel.excellent || SignalLevel.good => Colors.greenAccent,
      SignalLevel.fair => Colors.amber,
      SignalLevel.poor => Colors.redAccent,
      SignalLevel.unknown => Colors.grey,
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          peer.signalLabel,
          style: TextStyle(color: color, fontSize: 11),
        ),
      ],
    );
  }
}

