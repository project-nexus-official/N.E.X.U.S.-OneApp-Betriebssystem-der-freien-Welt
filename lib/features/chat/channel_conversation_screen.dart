import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/contacts/contact_service.dart';
import '../../core/identity/identity_service.dart';
import '../../core/roles/permission_helper.dart';
import '../../core/roles/role_enums.dart';
import '../../core/storage/pod_database.dart';
import '../../core/transport/nexus_message.dart';
import '../../services/role_service.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/linkified_text.dart';
import 'channel_access_service.dart';
import 'channel_share_sheet.dart';
import 'chat_provider.dart';
import 'conversation_screen.dart';
import 'conversation_service.dart';
import 'group_channel.dart';
import 'group_channel_service.dart';
import 'voice_player.dart';
import 'voice_recorder.dart';

/// Chat screen for a named group channel (e.g. #teneriffa).
class ChannelConversationScreen extends StatefulWidget {
  const ChannelConversationScreen({super.key, required this.channel});
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
  final _picker = ImagePicker();

  List<NexusMessage> _messages = [];
  bool _loading = true;
  bool _showEmojiPicker = false;

  // Reply state
  NexusMessage? _replyToMessage;
  String? _replyToSenderName;

  // Edit state
  NexusMessage? _editingMessage;

  @override
  void initState() {
    super.initState();
    ConversationService.instance.markAsRead(widget.channel.conversationId);
    _loadMessages();
    context
        .read<ChatProvider>()
        .setActiveConversation(widget.channel.conversationId);
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

  Future<void> _refreshMessages() async {
    final msgs = await context
        .read<ChatProvider>()
        .getMessages(widget.channel.conversationId);
    if (mounted) {
      setState(() => _messages = List.from(msgs));
      _scrollToBottom();
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

  String get _myDid =>
      IdentityService.instance.currentIdentity?.did ?? '';

  bool get _canPost => PermissionHelper.canPostInChannel(
        channelId: widget.channel.conversationId,
        did: _myDid,
        channelMode: widget.channel.channelMode,
        channelAdminDid: widget.channel.createdBy,
      );

  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    final reply = _replyToMessage;
    final replyName = _replyToSenderName;
    if (mounted) {
      setState(() {
        _replyToMessage = null;
        _replyToSenderName = null;
      });
    }
    final provider = context.read<ChatProvider>();
    await provider.sendToChannel(
      widget.channel.name,
      text,
      extraMeta: _buildReplyMeta(reply, replyName),
    );
    await _refreshMessages();
  }

  Map<String, dynamic>? _buildReplyMeta(
      NexusMessage? reply, String? replyName) {
    if (reply == null) return null;
    final isImg = reply.type == NexusMessageType.image;
    final isVoice = reply.type == NexusMessageType.voice;
    return {
      'reply_to_id': reply.id,
      'reply_to_sender': replyName ?? reply.fromDid,
      'reply_to_preview': isImg
          ? 'Foto'
          : isVoice
              ? 'Sprachnachricht'
              : reply.body.substring(0, reply.body.length.clamp(0, 100)),
      if (isImg) 'reply_to_image': true,
      if (isVoice) 'reply_to_voice': true,
    };
  }

  Future<void> _pickAndSendImage() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.camera_alt, color: AppColors.gold),
            title: const Text('Kamera'),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library, color: AppColors.gold),
            title: const Text('Galerie'),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
        ]),
      ),
    );
    if (source == null) return;
    final file = await _picker.pickImage(source: source);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    await context
        .read<ChatProvider>()
        .sendImageToChannel(widget.channel.name, bytes);
    await _refreshMessages();
  }

  Future<void> _sendVoice(String filePath, int durationMs) async {
    final reply = _replyToMessage;
    final replyName = _replyToSenderName;
    if (mounted) {
      setState(() {
        _replyToMessage = null;
        _replyToSenderName = null;
      });
    }
    await context.read<ChatProvider>().sendVoiceToChannel(
          widget.channel.name,
          filePath,
          durationMs,
          replyTo: reply,
          replyToSenderName: replyName,
        );
    await _refreshMessages();
  }

  void _toggleEmojiPicker() {
    if (_showEmojiPicker) {
      setState(() => _showEmojiPicker = false);
      _focusNode.requestFocus();
    } else {
      _focusNode.unfocus();
      setState(() => _showEmojiPicker = true);
    }
  }

  void _onEmojiSelected(String emoji) {
    final cursor = _textController.selection.baseOffset;
    final text = _textController.text;
    final offset = cursor < 0 ? text.length : cursor;
    final newText =
        text.substring(0, offset) + emoji + text.substring(offset);
    _textController.value = TextEditingValue(
      text: newText,
      selection:
          TextSelection.collapsed(offset: offset + emoji.length),
    );
  }

  void _startReply(NexusMessage msg) {
    final senderName = ContactService.instance.getDisplayName(msg.fromDid);
    setState(() {
      _replyToMessage = msg;
      _replyToSenderName = senderName;
    });
    _focusNode.requestFocus();
  }

  void _cancelReply() {
    setState(() {
      _replyToMessage = null;
      _replyToSenderName = null;
    });
  }

  // ── Edit ─────────────────────────────────────────────────────────────────

  void _startEdit(NexusMessage msg) {
    setState(() {
      _editingMessage = msg;
      _textController.text = msg.body;
      _textController.selection =
          TextSelection.collapsed(offset: _textController.text.length);
    });
    _focusNode.requestFocus();
  }

  void _cancelEdit() {
    setState(() {
      _editingMessage = null;
      _textController.clear();
    });
  }

  Future<void> _saveEdit() async {
    final newBody = _textController.text.trim();
    if (newBody.isEmpty || _editingMessage == null) return;
    final msg = _editingMessage!;
    _textController.clear();
    setState(() => _editingMessage = null);
    await context
        .read<ChatProvider>()
        .editMessage(msg, widget.channel.conversationId, newBody);
    await _refreshMessages();
  }

  // ── Context menu ─────────────────────────────────────────────────────────

  static const _quickReactions = ['👍', '❤️', '😂', '😮', '😢', '👎'];

  void _showMessageMenu(NexusMessage msg) {
    final myDid = _myDid;
    final isMe = msg.fromDid == myDid;
    final isFav = msg.metadata?['local_favorite'] == true;
    final canPost = _canPost;
    final canDelete = PermissionHelper.canDeleteMessage(
      channelId: widget.channel.conversationId,
      messageSenderDid: msg.fromDid,
      requesterDid: myDid,
      channelAdminDid: widget.channel.createdBy,
    );
    final isDiscussion =
        widget.channel.channelMode == ChannelMode.discussion;
    final canReply = isDiscussion || canPost;

    final hasLink = _extractLink(msg.body) != null;
    final provider = context.read<ChatProvider>();

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Quick emoji reaction row
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: _quickReactions.map((e) {
                  return GestureDetector(
                    onTap: () {
                      Navigator.pop(ctx);
                      _toggleReaction(msg, e);
                    },
                    child: Text(e, style: const TextStyle(fontSize: 28)),
                  );
                }).toList(),
              ),
            ),
            const Divider(height: 1),
            // Antworten
            if (canReply)
              ListTile(
                leading: const Icon(Icons.reply, color: AppColors.gold),
                title: const Text('Antworten'),
                onTap: () {
                  Navigator.pop(ctx);
                  _startReply(msg);
                },
              ),
            // Kopieren
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
            // Link kopieren
            if (hasLink)
              ListTile(
                leading: const Icon(Icons.link, color: AppColors.gold),
                title: const Text('Link kopieren'),
                onTap: () {
                  final link = _extractLink(msg.body);
                  if (link != null) {
                    Clipboard.setData(ClipboardData(text: link));
                  }
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Link kopiert')),
                  );
                },
              ),
            // Weiterleiten
            ListTile(
              leading: const Icon(Icons.forward, color: AppColors.gold),
              title: const Text('Weiterleiten'),
              onTap: () {
                Navigator.pop(ctx);
                _showForwardSheet(msg);
              },
            ),
            // Bearbeiten (nur eigene Textnachrichten, wenn canPost)
            if (isMe && msg.type == NexusMessageType.text && canPost)
              ListTile(
                leading: const Icon(Icons.edit, color: AppColors.gold),
                title: const Text('Bearbeiten'),
                onTap: () {
                  Navigator.pop(ctx);
                  _startEdit(msg);
                },
              ),
            // Favorisieren
            ListTile(
              leading: Icon(
                  isFav ? Icons.star : Icons.star_border,
                  color: AppColors.gold),
              title: Text(isFav ? 'Favorit entfernen' : 'Favorisieren'),
              onTap: () async {
                Navigator.pop(ctx);
                await provider.toggleFavorite(
                    msg, widget.channel.conversationId);
                await _refreshMessages();
              },
            ),
            // Ersteller privat anschreiben
            if (!isMe)
              ListTile(
                leading: const Icon(Icons.message_outlined,
                    color: AppColors.gold),
                title: const Text('Privat anschreiben'),
                onTap: () {
                  Navigator.pop(ctx);
                  _openDirectChat(msg.fromDid);
                },
              ),
            // Löschen
            ListTile(
              leading: const Icon(Icons.delete_outline,
                  color: Colors.redAccent),
              title: Text(
                canDelete && !isMe
                    ? 'Für alle löschen'
                    : isMe
                        ? 'Löschen'
                        : 'Für mich löschen',
                style: const TextStyle(color: Colors.redAccent),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _showDeleteDialog(msg, isMe, canDelete);
              },
            ),
            // Melden (nur fremde Nachrichten)
            if (!isMe)
              ListTile(
                leading:
                    const Icon(Icons.flag_outlined, color: Colors.orange),
                title: const Text('Melden',
                    style: TextStyle(color: Colors.orange)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showReportDialog(msg);
                },
              ),
          ],
        ),
      ),
    );
  }

  String? _extractLink(String text) {
    final re = RegExp(r'https?://\S+');
    final m = re.firstMatch(text);
    return m?.group(0);
  }

  // ── Reactions ─────────────────────────────────────────────────────────────

  Future<void> _toggleReaction(NexusMessage msg, String emoji) async {
    final myDid = _myDid;
    final reactions =
        await PodDatabase.instance.getReactionsForMessage(msg.id);
    final reactors = reactions[emoji] ?? [];
    final provider = context.read<ChatProvider>();
    if (reactors.contains(myDid)) {
      await provider.removeChannelReaction(msg.id, emoji);
    } else {
      await provider.addChannelReaction(msg.id, emoji);
    }
    if (mounted) setState(() {}); // trigger rebuild so reaction badges reload
  }

  // ── Forward ───────────────────────────────────────────────────────────────

  Future<void> _showForwardSheet(NexusMessage msg) async {
    final conversations =
        await ConversationService.instance.getConversationsWithMesh();
    if (!mounted) return;

    final selected = <String>{};
    final searchCtrl = TextEditingController();

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final query = searchCtrl.text.toLowerCase();
          final filtered = conversations
              .where((c) =>
                  c.peerPseudonym.toLowerCase().contains(query) ||
                  c.id.toLowerCase().contains(query))
              .toList();

          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.65,
            minChildSize: 0.4,
            maxChildSize: 0.9,
            builder: (_, scrollCtrl) => Column(children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text('Weiterleiten an…',
                    style: TextStyle(
                        color: AppColors.gold,
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: TextField(
                  controller: searchCtrl,
                  onChanged: (_) => setSheet(() {}),
                  style: const TextStyle(color: AppColors.onDark),
                  decoration: InputDecoration(
                    hintText: 'Suchen…',
                    hintStyle: const TextStyle(color: Colors.grey),
                    prefixIcon:
                        const Icon(Icons.search, color: Colors.grey),
                    filled: true,
                    fillColor: AppColors.surfaceVariant,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: scrollCtrl,
                  itemCount: filtered.length,
                  itemBuilder: (_, i) {
                    final conv = filtered[i];
                    final sel = selected.contains(conv.id);
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: AppColors.surfaceVariant,
                        child: Text(
                          conv.peerPseudonym.isNotEmpty
                              ? conv.peerPseudonym[0].toUpperCase()
                              : '?',
                          style: const TextStyle(color: AppColors.gold),
                        ),
                      ),
                      title: Text(conv.peerPseudonym),
                      trailing: sel
                          ? const Icon(Icons.check_circle,
                              color: AppColors.gold)
                          : const Icon(Icons.circle_outlined,
                              color: Colors.grey),
                      onTap: () => setSheet(() {
                        if (sel) {
                          selected.remove(conv.id);
                        } else {
                          selected.add(conv.id);
                        }
                      }),
                    );
                  },
                ),
              ),
              if (selected.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.gold,
                        foregroundColor: AppColors.deepBlue,
                      ),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        final provider = context.read<ChatProvider>();
                        for (final convId in selected) {
                          final conv = conversations.firstWhere(
                              (c) => c.id == convId,
                              orElse: () => conversations.first);
                          if (msg.type == NexusMessageType.text) {
                            if (conv.isGroup) {
                              await provider.sendToChannel(
                                  conv.id, msg.body);
                            } else {
                              await provider.sendMessage(
                                  conv.peerDid, msg.body);
                            }
                          }
                        }
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Weitergeleitet')),
                          );
                        }
                      },
                      child: Text(
                        selected.length == 1
                            ? 'Senden'
                            : 'An ${selected.length} senden',
                      ),
                    ),
                  ),
                ),
            ]),
          );
        },
      ),
    );
    searchCtrl.dispose();
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  Future<void> _showDeleteDialog(
      NexusMessage msg, bool isMe, bool canDeleteForAll) async {
    final provider = context.read<ChatProvider>();

    if (!isMe && !canDeleteForAll) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Nachricht löschen'),
          content: const Text('Nachricht nur für dich löschen?',
              style: TextStyle(color: Colors.grey)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Abbrechen',
                  style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white),
              onPressed: () async {
                Navigator.pop(ctx);
                await provider.deleteMessageLocally(
                    msg, widget.channel.conversationId);
                await _refreshMessages();
              },
              child: const Text('Löschen'),
            ),
          ],
        ),
      );
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Nachricht löschen'),
        content: const Text(
          'Wie soll die Nachricht gelöscht werden?',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen',
                style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await provider.deleteMessageLocally(
                  msg, widget.channel.conversationId);
              await _refreshMessages();
            },
            child: const Text('Für mich löschen',
                style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white),
            onPressed: () async {
              Navigator.pop(ctx);
              await provider.deleteMessageLocally(
                  msg, widget.channel.conversationId);
              provider.publishNostrDeletion(msg.id);
              await _refreshMessages();
            },
            child: const Text('Für alle löschen'),
          ),
        ],
      ),
    );
  }

  // ── Direct chat ──────────────────────────────────────────────────────────

  void _openDirectChat(String did) {
    final displayName = ContactService.instance.getDisplayName(did);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChangeNotifierProvider.value(
          value: context.read<ChatProvider>(),
          child: ConversationScreen(
              peerDid: did, peerPseudonym: displayName),
        ),
      ),
    );
  }

  // ── Report ────────────────────────────────────────────────────────────────

  Future<void> _showReportDialog(NexusMessage msg) async {
    String? selectedReason;
    final commentCtrl = TextEditingController();
    final reasons = [
      'Spam',
      'Beleidigung',
      'Unangemessener Inhalt',
      'Sonstiges'
    ];

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Nachricht melden',
              style: TextStyle(color: AppColors.gold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Grund auswählen:',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 8),
              ...reasons.map((r) => RadioListTile<String>(
                    value: r,
                    groupValue: selectedReason,
                    onChanged: (v) => setInner(() => selectedReason = v),
                    title: Text(r,
                        style:
                            const TextStyle(color: AppColors.onDark)),
                    activeColor: AppColors.gold,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  )),
              const SizedBox(height: 8),
              TextField(
                controller: commentCtrl,
                style: const TextStyle(color: AppColors.onDark),
                maxLines: 3,
                decoration: InputDecoration(
                  hintText: 'Kommentar (optional)',
                  hintStyle: const TextStyle(color: Colors.grey),
                  filled: true,
                  fillColor: AppColors.surfaceVariant,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Abbrechen',
                  style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.gold,
                  foregroundColor: AppColors.deepBlue),
              onPressed: selectedReason == null
                  ? null
                  : () async {
                      Navigator.pop(ctx);
                      await context
                          .read<ChatProvider>()
                          .reportChannelMessage(
                            msg: msg,
                            channelName: widget.channel.name,
                            channelAdminDid: widget.channel.createdBy,
                            reason: selectedReason!,
                            comment: commentCtrl.text.trim(),
                          );
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                                'Meldung gesendet. Der Admin wird benachrichtigt.'),
                          ),
                        );
                      }
                    },
              child: const Text('Melden'),
            ),
          ],
        ),
      ),
    );
    commentCtrl.dispose();
  }

  // ── Channel info / share / leave ─────────────────────────────────────────

  void _shareChannel() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => ChannelShareSheet(channel: widget.channel),
    );
  }

  String _channelTypeLabel() {
    final isPublic = widget.channel.isPublic;
    final mode = widget.channel.channelMode;
    if (mode == ChannelMode.announcement) {
      return isPublic ? 'Öffentlicher Kanal' : 'Privater Kanal';
    } else {
      return isPublic ? 'Öffentliche Gruppe' : 'Private Gruppe';
    }
  }

  void _showChannelInfo() {
    final myDid = _myDid;
    final isAdmin = widget.channel.createdBy == myDid;
    final isPrivate = !widget.channel.isPublic;
    final members = widget.channel.members;
    final pendingCount = isAdmin
        ? ChannelAccessService.instance.pendingRequests
            .where((r) => r.channelName == widget.channel.name)
            .length
        : 0;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
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
              Row(children: [
                Icon(
                  isPrivate ? Icons.lock : Icons.tag,
                  color: AppColors.gold,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(widget.channel.name,
                    style: const TextStyle(
                        color: AppColors.gold,
                        fontSize: 20,
                        fontWeight: FontWeight.bold)),
              ]),
              if (widget.channel.description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(widget.channel.description,
                    style: const TextStyle(color: AppColors.onDark)),
              ],
              const SizedBox(height: 4),
              Text(
                _channelTypeLabel(),
                style: TextStyle(color: Colors.grey[600], fontSize: 12),
              ),
              if (isPrivate && members.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  '${members.length} Mitglied${members.length == 1 ? "" : "er"}',
                  style:
                      TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
              ],
              const SizedBox(height: 20),
              if (isAdmin && isPrivate) ...[
                if (pendingCount > 0)
                  _InfoRow(
                    icon: Icons.pending_actions,
                    label:
                        '$pendingCount offene Beitrittsanfrage${pendingCount == 1 ? "" : "n"}',
                    color: AppColors.gold,
                  ),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.person_add),
                    label: const Text('Mitglieder einladen'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.gold,
                      foregroundColor: AppColors.deepBlue,
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _inviteMembers();
                    },
                  ),
                ),
                const SizedBox(height: 8),
              ],
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.exit_to_app,
                      color: Colors.redAccent),
                  label: const Text('Kanal verlassen',
                      style: TextStyle(color: Colors.redAccent)),
                  style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.redAccent)),
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

  Future<void> _inviteMembers() async {
    final contacts = ContactService.instance.contacts;
    if (!mounted) return;

    final selected = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => _ContactPickerDialog(
        contacts: contacts
            .where((c) => !widget.channel.members.contains(c.did))
            .toList(),
      ),
    );

    if (selected == null || selected.isEmpty) return;
    if (!mounted) return;

    final provider = context.read<ChatProvider>();
    for (final did in selected) {
      await ChannelAccessService.instance.sendInvitation(
        widget.channel,
        did,
        provider.sendSystemDm,
      );
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '${selected.length} Einladung${selected.length == 1 ? "" : "en"} gesendet.'),
        backgroundColor: AppColors.gold,
      ));
    }
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
            child: const Text('Abbrechen',
                style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Verlassen'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await GroupChannelService.instance.leaveChannel(widget.channel.name);
      if (mounted) Navigator.of(context).pop();
    }
  }

  // ── Send wrapper (handles edit mode) ────────────────────────────────────

  Future<void> _onSendPressed() async {
    if (_editingMessage != null) {
      await _saveEdit();
    } else {
      await _send();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_showEmojiPicker,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _showEmojiPicker) {
          setState(() => _showEmojiPicker = false);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: GestureDetector(
            onTap: _showChannelInfo,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(
                    widget.channel.channelMode == ChannelMode.announcement
                        ? Icons.campaign
                        : Icons.group,
                    color: AppColors.gold,
                    size: 16,
                  ),
                  const SizedBox(width: 4),
                  Text(widget.channel.name,
                      style: const TextStyle(
                          color: AppColors.gold,
                          fontWeight: FontWeight.bold)),
                  if (widget.channel.channelMode ==
                      ChannelMode.announcement) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.gold.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                            color:
                                AppColors.gold.withValues(alpha: 0.4)),
                      ),
                      child: const Text('Ankündigung',
                          style: TextStyle(
                              color: AppColors.gold,
                              fontSize: 9,
                              fontWeight: FontWeight.w600)),
                    ),
                  ],
                ]),
                Text(
                  _channelTypeLabel(),
                  style: TextStyle(color: Colors.grey[500], fontSize: 11),
                ),
              ],
            ),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: 'Kanal teilen',
              onPressed: _shareChannel,
            ),
            IconButton(
              icon: const Icon(Icons.info_outline),
              tooltip: 'Kanal-Info',
              onPressed: _showChannelInfo,
            ),
          ],
        ),
        body: Column(children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? const _EmptyChannelHint()
                    : Consumer<ChatProvider>(
                        builder: (context2, provider, _) {
                          provider
                              .getMessages(widget.channel.conversationId)
                              .then((msgs) {
                            if (mounted &&
                                msgs.length != _messages.length) {
                              setState(
                                  () => _messages = List.from(msgs));
                              WidgetsBinding.instance
                                  .addPostFrameCallback(
                                      (_) => _scrollToBottom());
                            }
                          });
                          return ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            itemCount: _messages.length,
                            itemBuilder: (ctx, i) =>
                                _ChannelMessageBubble(
                              msg: _messages[i],
                              channelAdminDid: widget.channel.createdBy,
                              channelId: widget.channel.conversationId,
                              onLongPress: () =>
                                  _showMessageMenu(_messages[i]),
                              onReactionToggle: (emoji) =>
                                  _toggleReaction(_messages[i], emoji),
                            ),
                          );
                        },
                      ),
          ),
          // Edit banner
          if (_editingMessage != null) _EditBanner(onCancel: _cancelEdit),
          // Reply banner
          if (_replyToMessage != null && _editingMessage == null)
            _ReplyBanner(
              message: _replyToMessage!,
              senderName: _replyToSenderName ?? '',
              onCancel: _cancelReply,
            ),
          // Input bar
          _ChannelInputBar(
            controller: _textController,
            focusNode: _focusNode,
            onSend: _onSendPressed,
            onEmojiToggle: _toggleEmojiPicker,
            onAttach: _pickAndSendImage,
            showEmojiIcon: !_showEmojiPicker,
            onSendVoice: _sendVoice,
            channelName: widget.channel.name,
            canPost: _canPost,
            isEditing: _editingMessage != null,
          ),
          // Emoji picker
          if (_showEmojiPicker)
            SizedBox(
              height: 280,
              child: EmojiPicker(
                onEmojiSelected: (_, emoji) =>
                    _onEmojiSelected(emoji.emoji),
                onBackspacePressed: () {
                  _textController
                    ..text = _textController.text.characters
                        .skipLast(1)
                        .string
                    ..selection = TextSelection.fromPosition(
                        TextPosition(
                            offset: _textController.text.length));
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
        ]),
      ),
    );
  }
}

// ── Message bubble ────────────────────────────────────────────────────────────

class _ChannelMessageBubble extends StatelessWidget {
  const _ChannelMessageBubble({
    required this.msg,
    this.channelAdminDid,
    this.channelId,
    required this.onLongPress,
    required this.onReactionToggle,
  });

  final NexusMessage msg;
  final String? channelAdminDid;
  final String? channelId;
  final VoidCallback onLongPress;
  final void Function(String emoji) onReactionToggle;

  @override
  Widget build(BuildContext context) {
    final senderName = ContactService.instance.getDisplayName(msg.fromDid);
    final sysRole = RoleService.instance.getSystemRole(msg.fromDid);
    final chRole = (channelId != null)
        ? RoleService.instance.getChannelRole(
            channelId!,
            msg.fromDid,
            channelAdminDid: channelAdminDid,
          )
        : null;

    Widget? roleBadge;
    if (sysRole == SystemRole.superadmin) {
      roleBadge = const _RoleBadge(label: 'Superadmin', icon: Icons.shield);
    } else if (sysRole == SystemRole.systemAdmin) {
      roleBadge =
          const _RoleBadge(label: 'Admin', icon: Icons.shield_outlined);
    } else if (chRole == ChannelRole.channelAdmin) {
      roleBadge = const _RoleBadge(
          label: 'Kanal-Admin',
          icon: Icons.manage_accounts,
          small: true);
    } else if (chRole == ChannelRole.channelModerator) {
      roleBadge = const _RoleBadge(
          label: 'Mod',
          icon: Icons.verified_user_outlined,
          small: true);
    }

    final hasReply = msg.metadata?['reply_to_id'] != null;

    return GestureDetector(
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Sender name + role
            Row(children: [
              Text(senderName,
                  style: const TextStyle(
                      color: AppColors.gold,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
              if (roleBadge != null) ...[
                const SizedBox(width: 4),
                roleBadge,
              ],
            ]),
            const SizedBox(height: 2),
            // Reply quote
            if (hasReply)
              Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  border: const Border(
                      left:
                          BorderSide(color: AppColors.gold, width: 3)),
                  color: AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      msg.metadata?['reply_to_sender'] as String? ??
                          '…',
                      style: const TextStyle(
                          color: AppColors.gold,
                          fontSize: 11,
                          fontWeight: FontWeight.w600),
                    ),
                    Text(
                      msg.metadata?['reply_to_image'] == true
                          ? '📷 Foto'
                          : msg.metadata?['reply_to_voice'] == true
                              ? '🎤 Sprachnachricht'
                              : msg.metadata?['reply_to_preview']
                                      as String? ??
                                  '',
                      style: const TextStyle(
                          color: Colors.grey, fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            // Message bubble
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(12),
              ),
              child: _buildContent(context),
            ),
            // Timestamp
            const SizedBox(height: 2),
            Text(
              _formatTime(msg.timestamp),
              style: TextStyle(color: Colors.grey[600], fontSize: 11),
            ),
            // Reactions
            _ReactionsRow(
              messageId: msg.id,
              onToggle: onReactionToggle,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (msg.type == NexusMessageType.image) {
      try {
        final bytes = Uint8List.fromList(base64Decode(msg.body));
        return GestureDetector(
          onTap: () =>
              Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => _FullscreenImage(bytes: bytes),
          )),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(bytes,
                width: 200, height: 200, fit: BoxFit.cover),
          ),
        );
      } catch (_) {
        return const Text('📷 Bild',
            style: TextStyle(color: AppColors.onDark));
      }
    } else if (msg.type == NexusMessageType.voice) {
      return _VoiceBubble(message: msg);
    } else {
      return LinkifiedText(
        text: msg.body,
        style: const TextStyle(color: AppColors.onDark),
      );
    }
  }

  String _formatTime(DateTime ts) {
    final t = ts.toLocal();
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

// ── Reactions row ─────────────────────────────────────────────────────────────

class _ReactionsRow extends StatefulWidget {
  const _ReactionsRow({required this.messageId, required this.onToggle});
  final String messageId;
  final void Function(String emoji) onToggle;

  @override
  State<_ReactionsRow> createState() => _ReactionsRowState();
}

class _ReactionsRowState extends State<_ReactionsRow> {
  Map<String, List<String>> _reactions = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_ReactionsRow old) {
    super.didUpdateWidget(old);
    _load();
  }

  Future<void> _load() async {
    final r =
        await PodDatabase.instance.getReactionsForMessage(widget.messageId);
    if (mounted) setState(() => _reactions = r);
  }

  @override
  Widget build(BuildContext context) {
    if (_reactions.isEmpty) return const SizedBox.shrink();
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: _reactions.entries.map((e) {
          final reacted = e.value.contains(myDid);
          return GestureDetector(
            onTap: () {
              widget.onToggle(e.key);
              _load();
            },
            onLongPress: () => _showReactorList(context, e.key, e.value),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: reacted
                    ? AppColors.gold.withValues(alpha: 0.2)
                    : AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: reacted
                      ? AppColors.gold.withValues(alpha: 0.5)
                      : Colors.transparent,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(e.key, style: const TextStyle(fontSize: 14)),
                  const SizedBox(width: 4),
                  Text(
                    '${e.value.length}',
                    style: TextStyle(
                      fontSize: 12,
                      color: reacted ? AppColors.gold : AppColors.onDark,
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  void _showReactorList(
      BuildContext context, String emoji, List<String> dids) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('$emoji Reaktionen',
                  style: const TextStyle(
                      color: AppColors.gold,
                      fontWeight: FontWeight.bold,
                      fontSize: 16)),
            ),
            const Divider(height: 1),
            ...dids.map((did) => ListTile(
                  leading:
                      const Icon(Icons.person, color: AppColors.gold),
                  title: Text(
                      ContactService.instance.getDisplayName(did)),
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ── Voice bubble ──────────────────────────────────────────────────────────────

class _VoiceBubble extends StatefulWidget {
  const _VoiceBubble({required this.message});
  final NexusMessage message;

  @override
  State<_VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<_VoiceBubble> {
  final _player = VoicePlayer.instance;

  @override
  Widget build(BuildContext context) {
    final durationMs =
        (widget.message.metadata?['duration_ms'] as int?) ?? 0;
    const fgColor = AppColors.onDark;
    const accentColor = AppColors.gold;
    const muteColor = Colors.grey;

    return ListenableBuilder(
      listenable: _player,
      builder: (_, __) {
        final isActive =
            _player.isActiveMessage(widget.message.id);
        final isPlaying = isActive && _player.isPlaying;
        final position = isActive ? _player.position : Duration.zero;
        final progress = isActive && durationMs > 0
            ? position.inMilliseconds / durationMs
            : 0.0;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: () => _player.togglePlayPause(widget.message),
              child: Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(
                  color: AppColors.gold,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isPlaying ? Icons.pause : Icons.play_arrow,
                  color: AppColors.deepBlue,
                  size: 22,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _WaveformBars(
                  messageId: widget.message.id,
                  progress: progress,
                  activeColor: accentColor,
                  inactiveColor: muteColor,
                ),
                Text(
                  _fmt(Duration(milliseconds: durationMs)),
                  style: TextStyle(
                      fontSize: 11,
                      color: fgColor.withValues(alpha: 0.7)),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString();
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _WaveformBars extends StatelessWidget {
  const _WaveformBars({
    required this.messageId,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
  });

  final String messageId;
  final double progress;
  final Color activeColor;
  final Color inactiveColor;

  static const _barCount = 28;

  List<double> _heights() {
    final seed = messageId.codeUnits
        .fold<int>(0, (acc, b) => acc ^ (b * 2654435761) & 0x7fffffff);
    final rng = Random(seed);
    return List.generate(_barCount, (_) => 0.15 + rng.nextDouble() * 0.85);
  }

  @override
  Widget build(BuildContext context) {
    final heights = _heights();
    return SizedBox(
      height: 28,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(_barCount, (i) {
          final filled = progress > 0 && (i / _barCount) <= progress;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 0.8),
              child: FractionallySizedBox(
                heightFactor: heights[i],
                child: Container(
                  decoration: BoxDecoration(
                    color: filled ? activeColor : inactiveColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ── Fullscreen image ──────────────────────────────────────────────────────────

class _FullscreenImage extends StatelessWidget {
  const _FullscreenImage({required this.bytes});
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          elevation: 0),
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

class _ChannelInputBar extends StatefulWidget {
  const _ChannelInputBar({
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.onEmojiToggle,
    required this.onAttach,
    required this.showEmojiIcon,
    required this.onSendVoice,
    required this.channelName,
    required this.canPost,
    this.isEditing = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final VoidCallback onEmojiToggle;
  final VoidCallback onAttach;
  final bool showEmojiIcon;
  final Future<void> Function(String filePath, int durationMs) onSendVoice;
  final String channelName;
  final bool canPost;
  final bool isEditing;

  @override
  State<_ChannelInputBar> createState() => _ChannelInputBarState();
}

class _ChannelInputBarState extends State<_ChannelInputBar>
    with TickerProviderStateMixin {
  final _recorder = VoiceRecorder();

  bool _isRecording = false;
  Duration _recordDuration = Duration.zero;
  double _dragOffset = 0;
  Timer? _durationTimer;

  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;

  bool get _hasText => widget.controller.text.isNotEmpty;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _pulseAnim = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void didUpdateWidget(_ChannelInputBar old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _pulseCtrl.dispose();
    _durationTimer?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  Future<void> _startRecording() async {
    final hasPerm = await _recorder.hasPermission();
    if (!hasPerm) {
      final granted = await _recorder.requestPermission();
      if (!granted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Mikrofon-Berechtigung benötigt')),
          );
        }
        return;
      }
    }

    final path = await _recorder.start();
    if (path == null) return;

    HapticFeedback.lightImpact();
    setState(() {
      _isRecording = true;
      _recordDuration = Duration.zero;
      _dragOffset = 0;
    });
    _pulseCtrl.repeat(reverse: true);

    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recordDuration += const Duration(seconds: 1));
      if (_recordDuration.inSeconds >= 300) _stopAndSend();
    });
  }

  Future<void> _stopAndSend() async {
    _durationTimer?.cancel();
    _pulseCtrl.stop();

    final path = await _recorder.stop();
    final durationMs = _recordDuration.inMilliseconds;

    setState(() {
      _isRecording = false;
      _dragOffset = 0;
    });

    if (path != null && durationMs > 0) {
      await widget.onSendVoice(path, durationMs);
    }
  }

  Future<void> _cancelRecording() async {
    if (!_isRecording) return;
    _durationTimer?.cancel();
    _pulseCtrl.stop();
    await _recorder.cancel();
    if (mounted) {
      setState(() {
        _isRecording = false;
        _dragOffset = 0;
      });
    }
    HapticFeedback.lightImpact();
  }

  static String _formatDuration(Duration d) {
    final m = d.inMinutes.toString();
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Widget _buildRecordingRow() {
    return GestureDetector(
      onHorizontalDragUpdate: (d) {
        if (d.delta.dx < 0) {
          setState(() =>
              _dragOffset = (_dragOffset - d.delta.dx).clamp(0.0, 120.0));
        }
      },
      onHorizontalDragEnd: (_) {
        if (_dragOffset >= 80) {
          _cancelRecording();
        } else {
          setState(() => _dragOffset = 0);
        }
      },
      child: Row(children: [
        AnimatedBuilder(
          animation: _pulseAnim,
          builder: (_, __) => Opacity(
            opacity: _pulseAnim.value,
            child:
                const Icon(Icons.mic, color: Colors.redAccent, size: 20),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          _formatDuration(_recordDuration),
          style: const TextStyle(color: AppColors.onDark, fontSize: 14),
        ),
        const SizedBox(width: 12),
        if (_dragOffset > 10)
          Text(
            '← Abbrechen',
            style: TextStyle(
              color: Colors.redAccent.withValues(
                  alpha: (_dragOffset / 80).clamp(0.0, 1.0)),
              fontSize: 12,
            ),
          )
        else
          Text(
            '← wischen zum Abbrechen',
            style: TextStyle(color: Colors.grey[600], fontSize: 11),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.canPost && !widget.isEditing) {
      return SafeArea(
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border(
                top: BorderSide(color: AppColors.surfaceVariant)),
          ),
          child: Row(children: [
            const Icon(Icons.campaign, color: Colors.grey, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Nur Admins können hier posten',
                style: TextStyle(color: Colors.grey[600], fontSize: 13),
              ),
            ),
          ]),
        ),
      );
    }

    return SafeArea(
      child: Container(
        color: AppColors.surface,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(children: [
          Expanded(
            child: _isRecording
                ? _buildRecordingRow()
                : Row(children: [
                    IconButton(
                      onPressed: widget.onEmojiToggle,
                      icon: Icon(widget.showEmojiIcon
                          ? Icons.emoji_emotions_outlined
                          : Icons.keyboard),
                      color: AppColors.gold,
                      iconSize: 22,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 36),
                    ),
                    Expanded(
                      child: Focus(
                        onKeyEvent: (_, event) {
                          if (Platform.isAndroid || Platform.isIOS) {
                            return KeyEventResult.ignored;
                          }
                          if (event is KeyDownEvent &&
                              event.logicalKey ==
                                  LogicalKeyboardKey.enter &&
                              !HardwareKeyboard
                                  .instance.isShiftPressed) {
                            widget.onSend();
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: TextField(
                          controller: widget.controller,
                          focusNode: widget.focusNode,
                          maxLines: 5,
                          minLines: 1,
                          keyboardType: TextInputType.multiline,
                          textCapitalization:
                              TextCapitalization.sentences,
                          textInputAction: TextInputAction.newline,
                          style: const TextStyle(
                              color: AppColors.onDark),
                          decoration: InputDecoration(
                            hintText:
                                'Nachricht an ${widget.channelName}…',
                            hintStyle:
                                const TextStyle(color: Colors.grey),
                            filled: true,
                            fillColor: AppColors.surfaceVariant,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding:
                                const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 10),
                          ),
                        ),
                      ),
                    ),
                  ]),
          ),
          if (!_isRecording) ...[
            IconButton(
              onPressed: widget.onAttach,
              icon: const Icon(Icons.attach_file),
              color: AppColors.gold,
              iconSize: 22,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36),
              tooltip: 'Bild senden',
            ),
            const SizedBox(width: 4),
          ],
          if ((_hasText && !_isRecording) || widget.isEditing)
            GestureDetector(
              onTap: widget.onSend,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: const BoxDecoration(
                    color: AppColors.gold, shape: BoxShape.circle),
                child: Icon(
                  widget.isEditing ? Icons.check : Icons.send,
                  color: AppColors.deepBlue,
                  size: 20,
                ),
              ),
            )
          else if (!_isRecording)
            GestureDetector(
              onLongPressStart: (_) => _startRecording(),
              onLongPressEnd: (_) => _stopAndSend(),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: const BoxDecoration(
                    color: AppColors.gold, shape: BoxShape.circle),
                child: const Icon(Icons.mic,
                    color: AppColors.deepBlue, size: 20),
              ),
            )
          else
            GestureDetector(
              onTap: _stopAndSend,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: const BoxDecoration(
                    color: AppColors.gold, shape: BoxShape.circle),
                child: const Icon(Icons.stop,
                    color: AppColors.deepBlue, size: 20),
              ),
            ),
        ]),
      ),
    );
  }
}

// ── Edit banner ───────────────────────────────────────────────────────────────

class _EditBanner extends StatelessWidget {
  const _EditBanner({required this.onCancel});
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: AppColors.surfaceVariant,
      child: Row(children: [
        const Icon(Icons.edit, color: AppColors.gold, size: 16),
        const SizedBox(width: 8),
        const Expanded(
          child: Text('Nachricht bearbeiten',
              style: TextStyle(color: AppColors.gold, fontSize: 13)),
        ),
        GestureDetector(
          onTap: onCancel,
          child: const Icon(Icons.close, color: Colors.grey, size: 18),
        ),
      ]),
    );
  }
}

// ── Reply banner ──────────────────────────────────────────────────────────────

class _ReplyBanner extends StatelessWidget {
  const _ReplyBanner({
    required this.message,
    required this.senderName,
    required this.onCancel,
  });

  final NexusMessage message;
  final String senderName;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final isImg = message.type == NexusMessageType.image;
    final isVoice = message.type == NexusMessageType.voice;
    final preview = isImg
        ? '📷 Foto'
        : isVoice
            ? '🎤 Sprachnachricht'
            : message.body
                .substring(0, message.body.length.clamp(0, 60));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        border: const Border(
            left: BorderSide(color: AppColors.gold, width: 3)),
      ),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(senderName,
                  style: const TextStyle(
                      color: AppColors.gold,
                      fontWeight: FontWeight.w600,
                      fontSize: 12)),
              Text(preview,
                  style: const TextStyle(
                      color: Colors.grey, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
        GestureDetector(
          onTap: onCancel,
          child:
              const Icon(Icons.close, color: Colors.grey, size: 18),
        ),
      ]),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

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
          Text('Noch keine Nachrichten.',
              style: TextStyle(color: AppColors.onDark)),
          SizedBox(height: 4),
          Text('Schreib die erste Nachricht in diesem Kanal!',
              style: TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ),
    );
  }
}

// ── Role badge ────────────────────────────────────────────────────────────────

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({
    required this.label,
    required this.icon,
    this.small = false,
  });

  final String label;
  final IconData icon;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final fontSize = small ? 9.0 : 10.0;
    final iconSize = small ? 10.0 : 11.0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.gold.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AppColors.gold, size: iconSize),
          const SizedBox(width: 2),
          Text(label,
              style: TextStyle(
                  color: AppColors.gold,
                  fontSize: fontSize,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ── Helper widgets ────────────────────────────────────────────────────────────

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    this.color = AppColors.onDark,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label, style: TextStyle(color: color, fontSize: 13)),
        ),
      ]),
    );
  }
}

// ── Contact picker dialog ─────────────────────────────────────────────────────

class _ContactPickerDialog extends StatefulWidget {
  const _ContactPickerDialog({required this.contacts});
  final List<dynamic> contacts;

  @override
  State<_ContactPickerDialog> createState() =>
      _ContactPickerDialogState();
}

class _ContactPickerDialogState extends State<_ContactPickerDialog> {
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('Mitglieder einladen',
          style: TextStyle(color: AppColors.gold)),
      content: widget.contacts.isEmpty
          ? const Text('Alle Kontakte sind bereits Mitglieder.',
              style: TextStyle(color: AppColors.onDark))
          : SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.contacts.length,
                itemBuilder: (ctx, i) {
                  final c = widget.contacts[i];
                  final did = c.did as String;
                  final name = c.pseudonym as String;
                  final selected = _selected.contains(did);
                  return CheckboxListTile(
                    value: selected,
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _selected.add(did);
                        } else {
                          _selected.remove(did);
                        }
                      });
                    },
                    title: Text(name,
                        style: const TextStyle(
                            color: AppColors.onDark)),
                    activeColor: AppColors.gold,
                    checkColor: AppColors.deepBlue,
                  );
                },
              ),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen',
              style: TextStyle(color: Colors.grey)),
        ),
        if (widget.contacts.isNotEmpty)
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.gold,
                foregroundColor: AppColors.deepBlue),
            onPressed: _selected.isEmpty
                ? null
                : () => Navigator.pop(context, _selected.toList()),
            child: const Text('Einladen'),
          ),
      ],
    );
  }
}
