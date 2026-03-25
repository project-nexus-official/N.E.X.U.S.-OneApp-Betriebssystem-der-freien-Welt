import 'dart:convert';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/transport/message_transport.dart';
import '../../core/transport/nexus_message.dart';
import '../../core/transport/nexus_peer.dart';
import '../../core/identity/identity_service.dart';
import '../../shared/theme/app_theme.dart';
import 'chat_provider.dart';
import 'conversation_service.dart';

/// Direkt-Chat-Bildschirm mit einem einzelnen Peer oder dem #mesh Kanal.
class ConversationScreen extends StatefulWidget {
  const ConversationScreen({
    super.key,
    required this.peerDid,
    required this.peerPseudonym,
    this.isBroadcast = false,
    this.peer,
  });

  final String peerDid;
  final String peerPseudonym;

  /// True when this is the #mesh broadcast channel.
  final bool isBroadcast;

  /// Currently-online peer, if available (used for transport info).
  final NexusPeer? peer;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _textFocus = FocusNode();
  final _picker = ImagePicker();

  List<NexusMessage> _messages = [];
  bool _loading = true;
  bool _showEmojiPicker = false;
  bool _showScrollDown = false;

  String get _convId {
    if (widget.isBroadcast) return NexusMessage.broadcastDid;
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final sorted = [widget.peerDid, myDid]..sort();
    return '${sorted[0]}:${sorted[1]}';
  }

  bool get _isBleBleOnly {
    final p = widget.peer;
    if (p == null) return false;
    return p.availableTransports.length == 1 &&
        p.availableTransports.contains(TransportType.ble);
  }

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  void _onScroll() {
    final atBottom = _scrollCtrl.position.pixels >=
        _scrollCtrl.position.maxScrollExtent - 80;
    if (atBottom != !_showScrollDown) {
      setState(() => _showScrollDown = !atBottom);
    }
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

  Future<void> _sendText() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    _textCtrl.clear();

    final provider = context.read<ChatProvider>();
    try {
      if (widget.isBroadcast) {
        await provider.sendBroadcast(text);
      } else {
        await provider.sendMessage(widget.peerDid, text);
      }
      await _refreshMessages();
    } catch (e) {
      _showError('Senden fehlgeschlagen: $e');
    }
  }

  Future<void> _pickAndSendImage() async {
    if (_isBleBleOnly) {
      _showError(
        'Bilder können nur über LAN oder Internet gesendet werden.',
      );
      return;
    }

    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt, color: AppColors.gold),
              title: const Text('Kamera'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading:
                  const Icon(Icons.photo_library, color: AppColors.gold),
              title: const Text('Galerie'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final file = await _picker.pickImage(source: source);
    if (file == null) return;

    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final provider = context.read<ChatProvider>();
    try {
      await provider.sendImage(widget.peerDid, bytes);
      await _refreshMessages();
    } catch (e) {
      _showError('Bild senden fehlgeschlagen: $e');
    }
  }

  Future<void> _refreshMessages() async {
    final provider = context.read<ChatProvider>();
    final msgs = await provider.getMessages(_convId);
    if (mounted) {
      setState(() => _messages = List.from(msgs));
      _scrollToBottom();
    }
  }

  void _toggleEmojiPicker() {
    if (_showEmojiPicker) {
      setState(() => _showEmojiPicker = false);
      _textFocus.requestFocus();
    } else {
      _textFocus.unfocus();
      setState(() => _showEmojiPicker = true);
    }
  }

  void _onEmojiSelected(String emoji) {
    final cursor = _textCtrl.selection.baseOffset;
    final text = _textCtrl.text;
    final safeOffset = cursor < 0 ? text.length : cursor;
    final newText =
        text.substring(0, safeOffset) + emoji + text.substring(safeOffset);
    _textCtrl.value = TextEditingValue(
      text: newText,
      selection:
          TextSelection.collapsed(offset: safeOffset + emoji.length),
    );
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── Context menu (long press) ───────────────────────────────────────────

  void _showMessageMenu(BuildContext context, NexusMessage msg) {
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final isMe = msg.fromDid == myDid;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (msg.type == NexusMessageType.text)
              ListTile(
                leading: const Icon(Icons.copy, color: AppColors.gold),
                title: const Text('Kopieren'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: msg.body));
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Kopiert')),
                  );
                },
              ),
            if (isMe)
              ListTile(
                leading:
                    const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text('Löschen',
                    style: TextStyle(color: Colors.redAccent)),
                onTap: () async {
                  Navigator.pop(ctx);
                  // Local removal only (no protocol-level delete yet).
                  setState(() => _messages.remove(msg));
                  ConversationService.instance.notifyUpdate();
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        // Refresh when new messages arrive
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          final fresh = await provider.getMessages(_convId);
          if (mounted && fresh.length != _messages.length) {
            setState(() => _messages = List.from(fresh));
            if (!_showScrollDown) _scrollToBottom();
          }
        });

        return PopScope(
          canPop: !_showEmojiPicker,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && _showEmojiPicker) {
              setState(() => _showEmojiPicker = false);
            }
          },
          child: Scaffold(
            appBar: AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.isBroadcast
                        ? '#mesh'
                        : widget.peerPseudonym,
                  ),
                  if (widget.peer != null)
                    Text(
                      widget.peer!.transportType.name.toUpperCase(),
                      style:
                          const TextStyle(fontSize: 11, color: AppColors.gold),
                    ),
                  if (widget.isBroadcast)
                    const Text(
                      'Broadcast-Kanal',
                      style:
                          TextStyle(fontSize: 11, color: AppColors.gold),
                    ),
                ],
              ),
              actions: [
                if (widget.peer != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: _ConnectionIndicator(peer: widget.peer!),
                  ),
              ],
            ),
            body: Column(
              children: [
                // Message list
                Expanded(
                  child: Stack(
                    children: [
                      _loading
                          ? const Center(child: CircularProgressIndicator())
                          : _MessageList(
                              messages: _messages,
                              scrollCtrl: _scrollCtrl,
                              isBroadcast: widget.isBroadcast,
                              onLongPress: (msg) =>
                                  _showMessageMenu(context, msg),
                            ),
                      // Scroll-to-bottom FAB
                      if (_showScrollDown)
                        Positioned(
                          right: 12,
                          bottom: 8,
                          child: FloatingActionButton.small(
                            heroTag: 'scroll_down',
                            onPressed: _scrollToBottom,
                            backgroundColor: AppColors.surfaceVariant,
                            child: const Icon(
                              Icons.keyboard_arrow_down,
                              color: AppColors.gold,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                // Input bar
                _InputBar(
                  ctrl: _textCtrl,
                  focus: _textFocus,
                  onSend: _sendText,
                  onEmojiToggle: _toggleEmojiPicker,
                  onAttach: _pickAndSendImage,
                  showEmojiIcon: !_showEmojiPicker,
                  attachEnabled: !_isBleBleOnly,
                ),
                // Emoji picker panel
                if (_showEmojiPicker)
                  SizedBox(
                    height: 280,
                    child: EmojiPicker(
                      textEditingController: _textCtrl,
                      onEmojiSelected: (_, emoji) =>
                          _onEmojiSelected(emoji.emoji),
                      onBackspacePressed: () {
                        _textCtrl
                          ..text = _textCtrl.text.characters.skipLast(1).string
                          ..selection = TextSelection.fromPosition(
                            TextPosition(offset: _textCtrl.text.length),
                          );
                      },
                      config: Config(
                        height: 280,
                        checkPlatformCompatibility: true,
                        emojiViewConfig: EmojiViewConfig(
                          emojiSizeMax: 28,
                          backgroundColor: AppColors.surface,
                        ),
                        categoryViewConfig: const CategoryViewConfig(
                          backgroundColor: AppColors.surface,
                          indicatorColor: AppColors.gold,
                          iconColorSelected: AppColors.gold,
                          iconColor: Colors.grey,
                        ),
                        bottomActionBarConfig: const BottomActionBarConfig(
                          backgroundColor: AppColors.surface,
                          buttonIconColor: AppColors.gold,
                        ),
                        searchViewConfig: const SearchViewConfig(
                          backgroundColor: AppColors.surface,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ── Message list ──────────────────────────────────────────────────────────────

class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.messages,
    required this.scrollCtrl,
    required this.isBroadcast,
    required this.onLongPress,
  });

  final List<NexusMessage> messages;
  final ScrollController scrollCtrl;
  final bool isBroadcast;
  final void Function(NexusMessage) onLongPress;

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
        return _MessageBubble(
          message: msg,
          isMe: isMe,
          showSender: isBroadcast && !isMe,
          onLongPress: () => onLongPress(msg),
        );
      },
    );
  }
}

// ── Message bubble ────────────────────────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.isMe,
    required this.showSender,
    required this.onLongPress,
  });

  final NexusMessage message;
  final bool isMe;
  final bool showSender; // show sender name above bubble in broadcast channel
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showSender)
                Padding(
                  padding:
                      const EdgeInsets.only(left: 12, right: 12, top: 8),
                  child: Text(
                    _senderName(),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.gold,
                    ),
                  ),
                ),
              if (message.type == NexusMessageType.image)
                _ImageContent(message: message)
              else
                _TextContent(message: message, isMe: isMe),
            ],
          ),
        ),
      ),
    );
  }

  String _senderName() {
    final did = message.fromDid;
    // Use last 8 chars of DID as short name when no contact found
    return did.length > 8 ? did.substring(did.length - 8) : did;
  }
}

class _TextContent extends StatelessWidget {
  const _TextContent({required this.message, required this.isMe});
  final NexusMessage message;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    final time = _formatTime(message.timestamp.toLocal());
    return Padding(
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
    );
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

class _ImageContent extends StatelessWidget {
  const _ImageContent({required this.message});
  final NexusMessage message;

  @override
  Widget build(BuildContext context) {
    // Show thumbnail if available, fall back to full image
    final thumbB64 = message.metadata?['thumbnail'] as String?;
    final b64 = thumbB64 ?? message.body;

    Uint8List? bytes;
    try {
      bytes = base64Decode(b64);
    } catch (_) {}

    final time = _formatTime(message.timestamp.toLocal());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: bytes != null
              ? GestureDetector(
                  onTap: () => _openFullscreen(context),
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: 180,
                    errorBuilder: (context, error, stack) =>
                        const _BrokenImage(),
                  ),
                )
              : const _BrokenImage(),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 10, bottom: 6, top: 4),
          child: Text(
            time,
            style: const TextStyle(color: Colors.grey, fontSize: 10),
          ),
        ),
      ],
    );
  }

  void _openFullscreen(BuildContext context) {
    Uint8List? bytes;
    try {
      bytes = base64Decode(message.body);
    } catch (_) {}
    if (bytes == null) return;

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _FullscreenImageScreen(bytes: bytes!),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

class _BrokenImage extends StatelessWidget {
  const _BrokenImage();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 100,
      child: Center(
        child: Icon(Icons.broken_image, color: Colors.grey, size: 36),
      ),
    );
  }
}

// ── Fullscreen image viewer ───────────────────────────────────────────────────

class _FullscreenImageScreen extends StatelessWidget {
  const _FullscreenImageScreen({required this.bytes});
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(
        child: InteractiveViewer(
          panEnabled: true,
          minScale: 0.5,
          maxScale: 4.0,
          child: Image.memory(bytes),
        ),
      ),
    );
  }
}

// ── Input bar ─────────────────────────────────────────────────────────────────

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.ctrl,
    required this.focus,
    required this.onSend,
    required this.onEmojiToggle,
    required this.onAttach,
    required this.showEmojiIcon,
    required this.attachEnabled,
  });

  final TextEditingController ctrl;
  final FocusNode focus;
  final VoidCallback onSend;
  final VoidCallback onEmojiToggle;
  final VoidCallback onAttach;
  final bool showEmojiIcon;
  final bool attachEnabled;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        color: AppColors.surface,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            // Emoji toggle button
            IconButton(
              onPressed: onEmojiToggle,
              icon: Icon(
                showEmojiIcon ? Icons.emoji_emotions_outlined : Icons.keyboard,
              ),
              color: AppColors.gold,
              iconSize: 22,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36),
            ),
            // Text field
            Expanded(
              child: TextField(
                controller: ctrl,
                focusNode: focus,
                textCapitalization: TextCapitalization.sentences,
                onTap: () {
                  // Dismiss emoji picker when user taps the text field
                  if (!showEmojiIcon) {
                    // showEmojiIcon == false means picker is open
                    // We do nothing here; user manages via toggle button
                  }
                },
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
            // Attachment button
            IconButton(
              onPressed: attachEnabled ? onAttach : null,
              icon: const Icon(Icons.attach_file),
              color: attachEnabled ? AppColors.gold : Colors.grey,
              iconSize: 22,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36),
              tooltip: attachEnabled
                  ? 'Bild senden'
                  : 'Nur über LAN/Internet verfügbar',
            ),
            const SizedBox(width: 4),
            // Send button
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
    // Nostr peers: blue globe
    if (peer.transportType == TransportType.nostr) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.language, size: 12, color: Colors.blueAccent),
          SizedBox(width: 4),
          Text(
            'Internet',
            style: TextStyle(color: Colors.blueAccent, fontSize: 11),
          ),
        ],
      );
    }

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
