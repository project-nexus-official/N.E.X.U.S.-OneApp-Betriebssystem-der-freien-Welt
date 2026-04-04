import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random, min;

import 'package:flutter/foundation.dart' show compute;

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/contacts/contact_service.dart';
import '../../core/contacts/contact.dart';
import '../../core/storage/pod_database.dart';
import '../../core/crypto/encryption_keys.dart';
import '../../core/identity/identity_service.dart';
import '../../services/contact_request_service.dart';
import '../contacts/contact_request.dart';
import '../../core/storage/retention_service.dart';
import '../../core/transport/message_transport.dart';
import '../../core/transport/nexus_message.dart';
import '../../core/transport/nexus_peer.dart';
import '../../services/notification_service.dart';
import '../../services/role_service.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/linkified_text.dart';
import '../contacts/contact_detail_screen.dart';
import '../contacts/widgets/trust_badge.dart';
import 'chat_provider.dart';
import 'conversation.dart';
import 'conversation_service.dart';
import 'voice_player.dart';
import 'voice_recorder.dart';

/// Direkt-Chat-Bildschirm mit einem einzelnen Peer oder dem #mesh Kanal.
class ConversationScreen extends StatefulWidget {
  const ConversationScreen({
    super.key,
    required this.peerDid,
    required this.peerPseudonym,
    this.isBroadcast = false,
    this.peer,
    this.scrollToMessageId,
    this.initialDraftText,
  });

  final String peerDid;
  final String peerPseudonym;

  /// True when this is the #mesh broadcast channel.
  final bool isBroadcast;

  /// Currently-online peer, if available (used for transport info).
  final NexusPeer? peer;

  /// When set (e.g. from global search), scroll to and highlight this message
  /// after loading the conversation.
  final String? scrollToMessageId;

  /// When set, pre-populates the message input field with this text.
  final String? initialDraftText;

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
  RetentionPeriod? _perChatRetention; // null = use global setting

  // ── Reply state ─────────────────────────────────────────────────────────────
  NexusMessage? _replyToMessage;
  String? _replyToSenderName;

  // ── Edit state ───────────────────────────────────────────────────────────────
  NexusMessage? _editingMessage;

  // ── Highlight state (for scroll-to-original) ────────────────────────────────
  final ValueNotifier<String?> _highlightedId = ValueNotifier(null);
  final Map<String, GlobalKey> _messageKeys = {};

  // ── In-conversation search state ─────────────────────────────────────────────
  bool _searchMode = false;
  final _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  List<String> _searchMatchIds = []; // message IDs that match current query
  int _searchCursor = 0;             // index into _searchMatchIds (current match)
  /// Notifier holding the active set of search matches + current match ID.
  /// Used by _MessageList to highlight without rebuilding the whole list.
  final ValueNotifier<_SearchHighlight> _searchHighlight =
      ValueNotifier(const _SearchHighlight());

  // Stored reference to ChatProvider so we can safely call it in dispose().
  ChatProvider? _chatProvider;

  // ── Contact request gate ──────────────────────────────────────────────────
  StreamSubscription<List<ContactRequest>>? _requestSub;
  StreamSubscription<void>? _contactsSub;

  /// True when the peer is unknown / only discovered and a contact request
  /// must be sent before chatting.
  bool get _needsContactRequest {
    if (widget.isBroadcast) return false;
    final contact = ContactService.instance.findByDid(widget.peerDid);
    return contact == null ||
        contact.trustLevel == TrustLevel.discovered;
  }

  String get _convId {
    if (widget.isBroadcast) return NexusMessage.broadcastDid;
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final sorted = [widget.peerDid, myDid]..sort();
    return '${sorted[0]}:${sorted[1]}';
  }

  /// #hotnews is an announcement channel — only system-admins/superadmins may post.
  bool get _canPostInHotnews {
    if (!widget.isBroadcast) return true;
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    return RoleService.instance.isSystemAdmin(myDid);
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
    _loadRetention();
    _scrollCtrl.addListener(_onScroll);
    if (widget.initialDraftText != null) {
      _textCtrl.text = widget.initialDraftText!;
      _textCtrl.selection =
          TextSelection.collapsed(offset: _textCtrl.text.length);
    }
    // Listen for contact request status changes (e.g. when request accepted).
    _requestSub = ContactRequestService.instance.stream.listen((_) {
      if (mounted) setState(() {});
    });
    _contactsSub = ContactService.instance.contactsChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Store the provider reference here so it is available in dispose().
    _chatProvider ??= context.read<ChatProvider>();
    _chatProvider!.setActiveConversation(_convId);
    // Cancel any existing system notification for this sender when opening chat.
    if (!widget.isBroadcast) {
      NotificationService.instance.cancelForSender(widget.peerDid);
    }
  }

  @override
  void dispose() {
    _chatProvider?.setActiveConversation(null);
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    _textFocus.dispose();
    _highlightedId.dispose();
    _searchCtrl.dispose();
    _searchDebounce?.cancel();
    _searchHighlight.dispose();
    _requestSub?.cancel();
    _contactsSub?.cancel();
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
      if (widget.scrollToMessageId != null) {
        _scrollToMessageFromExternal(widget.scrollToMessageId!);
      } else {
        _scrollToBottom();
      }
    }
  }

  /// Scrolls to and highlights a message that was selected from global search.
  /// Uses a two-step approach: first jump to approximate position so
  /// ListView.builder renders the item, then use ensureVisible.
  void _scrollToMessageFromExternal(String messageId) {
    final idx = _messages.indexWhere((m) => m.id == messageId);
    if (idx == -1) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      // Jump to approximate scroll position so the item is rendered.
      final total = _scrollCtrl.position.maxScrollExtent;
      if (_messages.isNotEmpty) {
        final approx = (idx / _messages.length * total).clamp(0.0, total);
        _scrollCtrl.jumpTo(approx);
      }
      // Then ensure visible + gold flash.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToMessage(messageId);
      });
    });
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
    // Editing mode: save the edit instead of sending a new message.
    if (_editingMessage != null) {
      await _saveEdit();
      return;
    }

    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    _textCtrl.clear();

    // Capture and clear reply state before async gap
    final reply = _replyToMessage;
    final replyName = _replyToSenderName;
    if (mounted) setState(() { _replyToMessage = null; _replyToSenderName = null; });

    final provider = context.read<ChatProvider>();
    try {
      if (widget.isBroadcast) {
        await provider.sendBroadcast(text, replyTo: reply, replyToSenderName: replyName);
      } else {
        await provider.sendMessage(widget.peerDid, text, replyTo: reply, replyToSenderName: replyName);
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

  Future<void> _sendVoice(String filePath, int durationMs) async {
    final reply = _replyToMessage;
    final replyName = _replyToSenderName;
    if (mounted) setState(() { _replyToMessage = null; _replyToSenderName = null; });

    final provider = context.read<ChatProvider>();
    try {
      if (widget.isBroadcast) {
        await provider.sendVoiceBroadcast(
          filePath, durationMs,
          replyTo: reply, replyToSenderName: replyName,
        );
      } else {
        await provider.sendVoice(
          widget.peerDid, filePath, durationMs,
          replyTo: reply, replyToSenderName: replyName,
        );
      }
      await _refreshMessages();
    } catch (e) {
      _showError('Senden fehlgeschlagen: $e');
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

  // ── Reply / scroll helpers ──────────────────────────────────────────────────

  void _startReply(NexusMessage msg) {
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final isMe = msg.fromDid == myDid;
    final String senderName;
    if (isMe) {
      senderName = 'Du';
    } else {
      final contact = ContactService.instance.findByDid(msg.fromDid);
      senderName = contact?.pseudonym ?? widget.peerPseudonym;
    }
    setState(() {
      _replyToMessage = msg;
      _replyToSenderName = senderName;
    });
    _textFocus.requestFocus();
  }

  void _cancelReply() {
    setState(() {
      _replyToMessage = null;
      _replyToSenderName = null;
    });
  }

  // ── Edit helpers ──────────────────────────────────────────────────────────

  void _startEdit(NexusMessage msg) {
    setState(() {
      _editingMessage = msg;
      _textCtrl.text = msg.body;
      _textCtrl.selection =
          TextSelection.collapsed(offset: _textCtrl.text.length);
    });
    _textFocus.requestFocus();
  }

  void _cancelEdit() {
    setState(() {
      _editingMessage = null;
      _textCtrl.clear();
    });
  }

  Future<void> _saveEdit() async {
    final newBody = _textCtrl.text.trim();
    if (newBody.isEmpty || _editingMessage == null) return;
    final msg = _editingMessage!;
    _textCtrl.clear();
    setState(() => _editingMessage = null);
    final provider = context.read<ChatProvider>();
    await provider.editMessage(msg, _convId, newBody);
    await _refreshMessages();
  }

  void _scrollToMessage(String messageId) {
    final key = _messageKeys[messageId];
    if (key?.currentContext == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Originalnachricht nicht mehr verfügbar'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    Scrollable.ensureVisible(
      key!.currentContext!,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
      alignment: 0.5,
    );
    _highlightedId.value = messageId;
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) _highlightedId.value = null;
    });
  }

  void _openContactDetail(BuildContext context) {
    final contact = ContactService.instance.findByDid(widget.peerDid);
    if (contact == null) return; // banner handles unknown peers
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ContactDetailScreen(did: widget.peerDid),
      ),
    );
  }

  // ── In-conversation search ─────────────────────────────────────────────────

  void _startSearch() {
    setState(() {
      _searchMode = true;
      _searchMatchIds = [];
      _searchCursor = 0;
    });
    _searchHighlight.value = const _SearchHighlight();
  }

  void _stopSearch() {
    setState(() {
      _searchMode = false;
      _searchMatchIds = [];
      _searchCursor = 0;
    });
    _searchCtrl.clear();
    _searchDebounce?.cancel();
    _searchHighlight.value = const _SearchHighlight();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      _runSearch(value.trim());
    });
  }

  void _runSearch(String query) {
    if (query.isEmpty) {
      setState(() {
        _searchMatchIds = [];
        _searchCursor = 0;
      });
      _searchHighlight.value = const _SearchHighlight();
      return;
    }
    final lower = query.toLowerCase();
    final ids = _messages
        .where((m) =>
            m.type != NexusMessageType.image &&
            m.type != NexusMessageType.voice &&
            m.body.toLowerCase().contains(lower))
        .map((m) => m.id)
        .toList();
    // Start at the newest match (last in list).
    final cursor = ids.isEmpty ? 0 : ids.length - 1;
    setState(() {
      _searchMatchIds = ids;
      _searchCursor = cursor;
    });
    _updateSearchHighlight(ids, cursor);
    if (ids.isNotEmpty) _scrollToSearchMatch(cursor);
  }

  void _updateSearchHighlight(List<String> ids, int cursor) {
    _searchHighlight.value = _SearchHighlight(
      matchIds: ids.toSet(),
      currentId: ids.isEmpty ? null : ids[cursor],
    );
  }

  void _nextMatch() {
    if (_searchMatchIds.isEmpty) return;
    final next = (_searchCursor + 1) % _searchMatchIds.length;
    setState(() => _searchCursor = next);
    _updateSearchHighlight(_searchMatchIds, next);
    _scrollToSearchMatch(next);
  }

  void _prevMatch() {
    if (_searchMatchIds.isEmpty) return;
    final prev = (_searchCursor - 1 + _searchMatchIds.length) % _searchMatchIds.length;
    setState(() => _searchCursor = prev);
    _updateSearchHighlight(_searchMatchIds, prev);
    _scrollToSearchMatch(prev);
  }

  void _scrollToSearchMatch(int cursor) {
    if (_searchMatchIds.isEmpty) return;
    final msgId = _searchMatchIds[cursor];
    final idx = _messages.indexWhere((m) => m.id == msgId);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      if (idx != -1 && _messages.isNotEmpty) {
        final total = _scrollCtrl.position.maxScrollExtent;
        final approx = (idx / _messages.length * total).clamp(0.0, total);
        _scrollCtrl.jumpTo(approx);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final key = _messageKeys[msgId];
        if (key?.currentContext != null) {
          Scrollable.ensureVisible(
            key!.currentContext!,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            alignment: 0.5,
          );
        }
      });
    });
  }

  Future<void> _loadRetention() async {
    final period =
        await RetentionService.instance.getForConversation(_convId);
    if (mounted) setState(() => _perChatRetention = period);
  }

  // ── Mute ────────────────────────────────────────────────────────────────────

  static const _muteOptions = [
    ('1 Stunde', Duration(hours: 1)),
    ('8 Stunden', Duration(hours: 8)),
    ('24 Stunden', Duration(hours: 24)),
    ('7 Tage', Duration(days: 7)),
    ('Dauerhaft', null),
  ];

  Future<void> _showMuteDialog() async {
    final contactName =
        ContactService.instance.getDisplayName(widget.peerDid);
    int selectedIndex = 0;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Stummschalten'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Benachrichtigungen für $contactName pausieren',
                style:
                    const TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 8),
              ...List.generate(_muteOptions.length, (i) {
                final selected = selectedIndex == i;
                return InkWell(
                  onTap: () => setInner(() => selectedIndex = i),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Icon(
                          selected
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          color:
                              selected ? AppColors.gold : Colors.grey,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _muteOptions[i].$1,
                          style: const TextStyle(
                              color: AppColors.onDark),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen',
                  style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.gold,
                foregroundColor: AppColors.deepBlue,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Stummschalten'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true && mounted) {
      final duration = _muteOptions[selectedIndex].$2;
      await ContactService.instance.muteContact(widget.peerDid, duration);
      setState(() {});
    }
  }

  Future<void> _unmute() async {
    final contactName =
        ContactService.instance.getDisplayName(widget.peerDid);
    await ContactService.instance.unmuteContact(widget.peerDid);
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text('Benachrichtigungen für $contactName wieder aktiv'),
        backgroundColor: AppColors.gold,
      ));
    }
  }

  void _showRetentionSheet() {
    final global = RetentionService.instance.global;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
                child: const Text(
                  'Aufbewahrung für diesen Chat',
                  style: TextStyle(
                    color: AppColors.gold,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Global: ${global.label}',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ),
              // "Standard" = follow global setting
              ListTile(
                title: const Text('Standard (globale Einstellung)'),
                subtitle: Text(global.label),
                trailing: _perChatRetention == null
                    ? const Icon(Icons.check, color: AppColors.gold)
                    : null,
                onTap: () async {
                  Navigator.pop(sheetCtx);
                  await RetentionService.instance
                      .setForConversation(_convId, null);
                  if (mounted) setState(() => _perChatRetention = null);
                },
              ),
              const Divider(height: 1),
              ...RetentionPeriod.values.map((p) => ListTile(
                    title: Text(p.label),
                    trailing: _perChatRetention == p
                        ? const Icon(Icons.check, color: AppColors.gold)
                        : null,
                    onTap: () async {
                      Navigator.pop(sheetCtx);
                      await RetentionService.instance
                          .setForConversation(_convId, p);
                      if (mounted) setState(() => _perChatRetention = p);
                    },
                  )),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  // ── Context menu (long press) ───────────────────────────────────────────

  static const _quickReactions = ['👍', '❤️', '😂', '😮', '😢', '👎'];

  Future<void> _toggleReaction(NexusMessage msg, String emoji) async {
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final reactions =
        await PodDatabase.instance.getReactionsForMessage(msg.id);
    final reactors = reactions[emoji] ?? [];
    final provider = context.read<ChatProvider>();
    if (reactors.contains(myDid)) {
      await provider.removeChannelReaction(msg.id, emoji);
    } else {
      await provider.addChannelReaction(msg.id, emoji);
    }
    if (mounted) setState(() {});
  }

  void _showMessageMenu(BuildContext context, NexusMessage msg) {
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final isMe = msg.fromDid == myDid;
    final isFav = msg.metadata?['local_favorite'] == true;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Quick emoji reactions ──
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
            // ── Antworten ──
            ListTile(
              leading: const Icon(Icons.reply, color: AppColors.gold),
              title: const Text('Antworten'),
              onTap: () {
                Navigator.pop(ctx);
                _startReply(msg);
              },
            ),
            // ── Kopieren (text only) ──
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
            // ── Weiterleiten ──
            ListTile(
              leading: const Icon(Icons.forward, color: AppColors.gold),
              title: const Text('Weiterleiten'),
              onTap: () {
                Navigator.pop(ctx);
                _showForwardSheet(msg);
              },
            ),
            // ── Bearbeiten (nur eigene Textnachrichten) ──
            if (isMe && msg.type == NexusMessageType.text)
              ListTile(
                leading: const Icon(Icons.edit, color: AppColors.gold),
                title: const Text('Bearbeiten'),
                onTap: () {
                  Navigator.pop(ctx);
                  _startEdit(msg);
                },
              ),
            // ── Favorisieren / Favorit entfernen ──
            ListTile(
              leading: Icon(
                isFav ? Icons.star : Icons.star_border,
                color: AppColors.gold,
              ),
              title: Text(isFav ? 'Favorit entfernen' : 'Favorisieren'),
              onTap: () async {
                Navigator.pop(ctx);
                final provider = context.read<ChatProvider>();
                await provider.toggleFavorite(msg, _convId);
                await _refreshMessages();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(isFav
                        ? 'Aus Favoriten entfernt'
                        : 'Zu Favoriten hinzugefügt'),
                    duration: const Duration(seconds: 2),
                  ));
                }
              },
            ),
            // ── Löschen ──
            ListTile(
              leading:
                  const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text('Löschen',
                  style: TextStyle(color: Colors.redAccent)),
              onTap: () {
                Navigator.pop(ctx);
                _showDeleteDialog(msg, isMe);
              },
            ),
            // ── Info ──
            ListTile(
              leading: const Icon(Icons.info_outline, color: AppColors.gold),
              title: const Text('Info'),
              onTap: () {
                Navigator.pop(ctx);
                _showInfoSheet(msg, isMe);
              },
            ),
          ],
        ),
      ),
    );
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
            builder: (_, scrollCtrl) => Column(
              children: [
                Padding(
                  padding:
                      const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: const Text(
                    'Weiterleiten an…',
                    style: TextStyle(
                      color: AppColors.gold,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 4),
                  child: TextField(
                    controller: searchCtrl,
                    onChanged: (_) => setSheet(() {}),
                    style:
                        const TextStyle(color: AppColors.onDark),
                    decoration: InputDecoration(
                      hintText: 'Suchen…',
                      hintStyle:
                          const TextStyle(color: Colors.grey),
                      prefixIcon: const Icon(Icons.search,
                          color: Colors.grey),
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
                            style: const TextStyle(
                                color: AppColors.gold),
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
                    padding:
                        const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.gold,
                          foregroundColor: AppColors.deepBlue,
                        ),
                        onPressed: () async {
                          Navigator.pop(ctx);
                          await _forwardMessage(
                              msg, selected, conversations);
                        },
                        child: Text(
                          selected.length == 1
                              ? 'Senden'
                              : 'An ${selected.length} senden',
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
    searchCtrl.dispose();
  }

  Future<void> _forwardMessage(NexusMessage msg,
      Set<String> targetConvIds, List<Conversation> allConvs) async {
    final provider = context.read<ChatProvider>();

    // Build forwarded metadata (strip local-state keys, add forwarded flag).
    final fwdMeta = <String, dynamic>{
      'forwarded': true,
      'forwarded_from':
          ContactService.instance.getDisplayName(msg.fromDid),
    };

    for (final convId in targetConvIds) {
      final conv =
          allConvs.firstWhere((c) => c.id == convId, orElse: () {
        return Conversation(
          id: convId,
          peerDid: convId,
          peerPseudonym: convId,
          lastMessage: '',
          lastMessageTime: DateTime.now().toUtc(),
        );
      });

      try {
        if (msg.type == NexusMessageType.text) {
          if (conv.id == NexusMessage.broadcastDid) {
            await provider.sendBroadcast(msg.body,
                extraMeta: fwdMeta);
          } else if (conv.isGroup) {
            await provider.sendToChannel(conv.id, msg.body,
                extraMeta: fwdMeta);
          } else {
            await provider.sendMessage(conv.peerDid, msg.body,
                extraMeta: fwdMeta);
          }
        } else if (msg.type == NexusMessageType.image) {
          // Forward image as-is (base64 body).
          if (!conv.isGroup && conv.id != NexusMessage.broadcastDid) {
            await provider.sendImageBase64(conv.peerDid, msg.body,
                meta: {
                  ...?msg.metadata,
                  ...fwdMeta,
                });
          }
        }
        // Voice forwarding skipped (too heavy to re-encode).
      } catch (e) {
        debugPrint('[FORWARD] Failed to forward to $convId: $e');
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          targetConvIds.length == 1
              ? 'Weitergeleitet'
              : 'An ${targetConvIds.length} Chats weitergeleitet',
        ),
        duration: const Duration(seconds: 2),
      ));
    }
  }

  // ── Delete dialog ─────────────────────────────────────────────────────────

  Future<void> _showDeleteDialog(NexusMessage msg, bool isMe) async {
    final provider = context.read<ChatProvider>();

    if (!isMe) {
      // Foreign message: only "for me" option
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Nachricht löschen'),
          content: const Text(
            'Nachricht nur für dich löschen?',
            style: TextStyle(color: Colors.grey),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Abbrechen',
                  style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                Navigator.pop(ctx);
                await provider.deleteMessageLocally(msg, _convId);
                await _refreshMessages();
              },
              child: const Text('Löschen'),
            ),
          ],
        ),
      );
      return;
    }

    // Own message: two options
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Nachricht löschen'),
        content: const Text(
          'Bereits zugestellte Nachrichten können nicht von fremden Geräten entfernt werden.',
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
              await provider.deleteMessageLocally(msg, _convId);
              await _refreshMessages();
            },
            child: const Text('Für mich löschen',
                style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              await provider.deleteMessageLocally(msg, _convId);
              // Send Nostr Kind-5 deletion event
              provider.publishNostrDeletion(msg.id);
              await _refreshMessages();
            },
            child: const Text('Für alle löschen'),
          ),
        ],
      ),
    );
  }

  // ── Info sheet ────────────────────────────────────────────────────────────

  void _showInfoSheet(NexusMessage msg, bool isMe) {
    final local = msg.timestamp.toLocal();
    final dateStr = _formatFullDate(local);
    final isEncrypted = msg.metadata?['encrypted'] == true;
    final transport = _detectTransport(msg);
    final shortId = msg.id.length > 12 ? msg.id.substring(0, 12) : msg.id;
    final isEdited = msg.metadata?['local_edited_body'] != null;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Nachrichten-Info',
                style: TextStyle(
                  color: AppColors.gold,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 16),
              _InfoRow(
                icon: Icons.schedule,
                label: isMe ? 'Gesendet' : 'Empfangen',
                value: dateStr,
              ),
              _InfoRow(
                icon: isEncrypted ? Icons.lock : Icons.lock_open,
                label: 'Verschlüsselung',
                value: isEncrypted
                    ? 'Ende-zu-Ende verschlüsselt'
                    : 'Unverschlüsselt',
                valueColor: isEncrypted ? Colors.greenAccent : Colors.orange,
              ),
              _InfoRow(
                icon: Icons.router,
                label: 'Transport',
                value: transport,
              ),
              if (isEdited)
                const _InfoRow(
                  icon: Icons.edit,
                  label: 'Bearbeitet',
                  value: 'Lokal bearbeitet',
                ),
              _InfoRow(
                icon: Icons.tag,
                label: 'Nachrichten-ID',
                value: '$shortId…',
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatFullDate(DateTime dt) {
    final months = [
      'Jan', 'Feb', 'Mär', 'Apr', 'Mai', 'Jun',
      'Jul', 'Aug', 'Sep', 'Okt', 'Nov', 'Dez',
    ];
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '${dt.day}. ${months[dt.month - 1]} ${dt.year}, $h:$m:$s';
  }

  String _detectTransport(NexusMessage msg) {
    // Heuristic: if the peer is in the local peer list via BLE/LAN use that,
    // otherwise assume Nostr (internet).
    final peer = widget.peer;
    if (peer != null) {
      final types = peer.availableTransports;
      if (types.contains(TransportType.ble)) return 'BLE Mesh';
      if (types.contains(TransportType.lan)) return 'LAN';
    }
    return 'Nostr (Internet)';
  }

  // ── Favorites sheet ───────────────────────────────────────────────────────

  Future<void> _showFavoritesSheet() async {
    final provider = context.read<ChatProvider>();
    final favs = await provider.getFavoriteMessages(_convId);
    if (!mounted) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.35,
        maxChildSize: 0.9,
        builder: (_, scrollCtrl) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: const [
                  Icon(Icons.star, color: AppColors.gold, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Favoriten',
                    style: TextStyle(
                      color: AppColors.gold,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: favs.isEmpty
                  ? const Center(
                      child: Text(
                        'Noch keine Favoriten in diesem Chat.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      controller: scrollCtrl,
                      itemCount: favs.length,
                      itemBuilder: (_, i) {
                        final m = favs[i];
                        final local = m.timestamp.toLocal();
                        final h = local.hour.toString().padLeft(2, '0');
                        final min =
                            local.minute.toString().padLeft(2, '0');
                        final preview = m.type == NexusMessageType.image
                            ? '📷 Foto'
                            : m.type == NexusMessageType.voice
                                ? '🎤 Sprachnachricht'
                                : m.body;
                        return ListTile(
                          leading: const Icon(Icons.star,
                              color: AppColors.gold, size: 20),
                          title: Text(
                            preview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '$h:$min',
                            style: const TextStyle(
                                color: Colors.grey, fontSize: 11),
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            _scrollToMessage(m.id);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Show the contact request gate when the peer is not yet a proper contact.
    if (_needsContactRequest) {
      return _ContactRequestGateScreen(
        peerDid: widget.peerDid,
        peerPseudonym: widget.peerPseudonym,
      );
    }

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
          canPop: !_showEmojiPicker && !_searchMode,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              if (_showEmojiPicker) {
                setState(() => _showEmojiPicker = false);
              } else if (_searchMode) {
                _stopSearch();
              }
            }
          },
          child: Scaffold(
            appBar: AppBar(
              automaticallyImplyLeading: !_searchMode,
              leading: _searchMode
                  ? IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: _stopSearch,
                    )
                  : null,
              title: _searchMode
                  ? TextField(
                      controller: _searchCtrl,
                      autofocus: true,
                      onChanged: _onSearchChanged,
                      style: const TextStyle(color: AppColors.onDark),
                      decoration: const InputDecoration(
                        hintText: 'Im Chat suchen…',
                        hintStyle: TextStyle(color: Colors.grey),
                        border: InputBorder.none,
                      ),
                    )
                  : GestureDetector(
                      onTap: widget.isBroadcast
                          ? null
                          : () => _openContactDetail(context),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  widget.isBroadcast
                                      ? '#hotnews'
                                      : ContactService.instance
                                          .getDisplayName(widget.peerDid),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (!widget.isBroadcast) ...[
                                const SizedBox(width: 8),
                                _HeaderTrustBadge(peerDid: widget.peerDid),
                                if (ContactService.instance
                                    .isMuted(widget.peerDid))
                                  const Padding(
                                    padding: EdgeInsets.only(left: 4),
                                    child: Icon(
                                      Icons.notifications_off,
                                      size: 14,
                                      color: Colors.grey,
                                    ),
                                  ),
                              ],
                            ],
                          ),
                          if (widget.peer != null)
                            Text(
                              widget.peer!.transportType.name.toUpperCase(),
                              style: const TextStyle(
                                  fontSize: 11, color: AppColors.gold),
                            ),
                          if (widget.isBroadcast)
                            const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.campaign,
                                    size: 12, color: AppColors.gold),
                                SizedBox(width: 3),
                                Text(
                                  'Ankündigungskanal',
                                  style: TextStyle(
                                      fontSize: 11, color: AppColors.gold),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
              actions: _searchMode
                  ? [
                      if (_searchMatchIds.isNotEmpty) ...[
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Text(
                              '${_searchCursor + 1}/${_searchMatchIds.length}',
                              style: const TextStyle(
                                  color: Colors.grey, fontSize: 13),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.keyboard_arrow_up),
                          tooltip: 'Vorheriger Treffer',
                          onPressed: _prevMatch,
                        ),
                        IconButton(
                          icon: const Icon(Icons.keyboard_arrow_down),
                          tooltip: 'Nächster Treffer',
                          onPressed: _nextMatch,
                        ),
                      ],
                    ]
                  : [
                      IconButton(
                        icon: const Icon(Icons.search),
                        tooltip: 'Im Chat suchen',
                        onPressed: _startSearch,
                      ),
                      if (widget.peer != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: _ConnectionIndicator(peer: widget.peer!),
                        ),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert),
                        onSelected: (value) {
                          if (value == 'retention') _showRetentionSheet();
                          if (value == 'mute') _showMuteDialog();
                          if (value == 'unmute') _unmute();
                          if (value == 'favorites') _showFavoritesSheet();
                        },
                        itemBuilder: (_) {
                          final muted = !widget.isBroadcast &&
                              ContactService.instance
                                  .isMuted(widget.peerDid);
                          return [
                            const PopupMenuItem(
                              value: 'favorites',
                              child: Row(
                                children: [
                                  Icon(Icons.star,
                                      size: 18, color: AppColors.gold),
                                  SizedBox(width: 12),
                                  Text('Favoriten'),
                                ],
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'retention',
                              child: Text('Aufbewahrung'),
                            ),
                            if (!widget.isBroadcast)
                              PopupMenuItem(
                                value: muted ? 'unmute' : 'mute',
                                child: Row(
                                  children: [
                                    Icon(
                                      muted
                                          ? Icons.notifications_active
                                          : Icons.notifications_off,
                                      size: 18,
                                      color: AppColors.onDark,
                                    ),
                                    const SizedBox(width: 12),
                                    Text(muted
                                        ? 'Stummschaltung aufheben'
                                        : 'Stummschalten'),
                                  ],
                                ),
                              ),
                          ];
                        },
                      ),
                    ],
            ),
            body: Column(
              children: [
                // #hotnews announcement banner
                if (widget.isBroadcast)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 5),
                    color: AppColors.surfaceVariant,
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.campaign, size: 13, color: AppColors.gold),
                        SizedBox(width: 6),
                        Text(
                          'Offizielle Ankündigungen der Menschheitsfamilie',
                          style: TextStyle(
                              fontSize: 11, color: AppColors.gold),
                        ),
                      ],
                    ),
                  ),
                // E2E encryption banner
                if (!widget.isBroadcast) _E2EBanner(peerDid: widget.peerDid),
                // Key change warning
                if (!widget.isBroadcast)
                  _KeyChangeBanner(
                    peerDid: widget.peerDid,
                    onAcknowledge: () => setState(() {}),
                  ),
                // Unknown-peer banner
                if (!widget.isBroadcast)
                  _UnknownPeerBanner(
                    peerDid: widget.peerDid,
                    peerPseudonym: widget.peerPseudonym,
                    onAdded: () => setState(() {}),
                  ),
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
                              onSwipeReply: _startReply,
                              onTapQuote: _scrollToMessage,
                              onReactionToggle: (msg, emoji) =>
                                  _toggleReaction(msg, emoji),
                              highlightedId: _highlightedId,
                              messageKeys: _messageKeys,
                              searchHighlight: _searchHighlight,
                              searchQuery: _searchCtrl.text.trim(),
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
                // Edit banner
                if (_editingMessage != null)
                  _EditBanner(onCancel: _cancelEdit),
                // Reply banner (only when not editing)
                if (_replyToMessage != null && _editingMessage == null)
                  _ReplyBanner(
                    message: _replyToMessage!,
                    senderName: _replyToSenderName ?? '',
                    onCancel: _cancelReply,
                  ),
                // Input bar — locked for non-admins in #hotnews
                if (!_canPostInHotnews)
                  SafeArea(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        border: Border(
                            top: BorderSide(color: AppColors.surfaceVariant)),
                      ),
                      child: Row(children: [
                        const Icon(Icons.campaign,
                            color: Colors.grey, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Nur Admins können hier posten',
                            style: TextStyle(
                                color: Colors.grey[600], fontSize: 13),
                          ),
                        ),
                      ]),
                    ),
                  )
                else
                  _InputBar(
                    ctrl: _textCtrl,
                    focus: _textFocus,
                    onSend: _sendText,
                    onEmojiToggle: _toggleEmojiPicker,
                    onAttach: _pickAndSendImage,
                    showEmojiIcon: !_showEmojiPicker,
                    attachEnabled: !_isBleBleOnly && _editingMessage == null,
                    onSendVoice: _sendVoice,
                    voiceEnabled: !_isBleBleOnly && _editingMessage == null,
                    isEditing: _editingMessage != null,
                  ),
                // Emoji picker panel
                if (_showEmojiPicker)
                  SizedBox(
                    height: 280,
                    child: EmojiPicker(
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
    required this.onSwipeReply,
    required this.onTapQuote,
    required this.onReactionToggle,
    required this.highlightedId,
    required this.messageKeys,
    required this.searchHighlight,
    required this.searchQuery,
  });

  final List<NexusMessage> messages;
  final ScrollController scrollCtrl;
  final bool isBroadcast;
  final void Function(NexusMessage) onLongPress;
  final void Function(NexusMessage) onSwipeReply;
  final void Function(String) onTapQuote;
  final void Function(NexusMessage, String) onReactionToggle;
  final ValueNotifier<String?> highlightedId;
  final Map<String, GlobalKey> messageKeys;
  final ValueNotifier<_SearchHighlight> searchHighlight;
  final String searchQuery;

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
        // Assign a stable GlobalKey for scroll-to support
        messageKeys.putIfAbsent(msg.id, () => GlobalKey());
        final bubble = _SwipeableMessageBubble(
          key: messageKeys[msg.id],
          message: msg,
          isMe: isMe,
          showSender: isBroadcast && !isMe,
          onLongPress: () => onLongPress(msg),
          onSwipeReply: () => onSwipeReply(msg),
          onTapQuote: onTapQuote,
          onReactionToggle: (emoji) => onReactionToggle(msg, emoji),
          highlightQuery: searchQuery,
        );
        return ListenableBuilder(
          listenable: Listenable.merge([highlightedId, searchHighlight]),
          builder: (context, _) {
            final hlId = highlightedId.value;
            final sh = searchHighlight.value;
            final Color bg;
            if (hlId == msg.id) {
              bg = AppColors.gold.withValues(alpha: 0.18);
            } else if (sh.currentId == msg.id) {
              bg = AppColors.gold.withValues(alpha: 0.22);
            } else if (sh.matchIds.contains(msg.id)) {
              bg = AppColors.gold.withValues(alpha: 0.08);
            } else {
              bg = Colors.transparent;
            }
            return AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              color: bg,
              child: bubble,
            );
          },
        );
      },
    );
  }
}

// ── Swipeable wrapper for reply gesture ───────────────────────────────────────

class _SwipeableMessageBubble extends StatefulWidget {
  const _SwipeableMessageBubble({
    super.key,
    required this.message,
    required this.isMe,
    required this.showSender,
    required this.onLongPress,
    required this.onSwipeReply,
    required this.onTapQuote,
    required this.onReactionToggle,
    this.highlightQuery = '',
  });

  final NexusMessage message;
  final bool isMe;
  final bool showSender;
  final VoidCallback onLongPress;
  final VoidCallback onSwipeReply;
  final void Function(String) onTapQuote;
  final void Function(String emoji) onReactionToggle;
  final String highlightQuery;

  @override
  State<_SwipeableMessageBubble> createState() =>
      _SwipeableMessageBubbleState();
}

class _SwipeableMessageBubbleState extends State<_SwipeableMessageBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  double _dragExtent = 0;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (d.delta.dx > 0) {
      _dragExtent = (_dragExtent + d.delta.dx).clamp(0, 80);
      _anim.value = _dragExtent / 80;
    }
  }

  void _onDragEnd(DragEndDetails _) {
    if (_dragExtent >= 40) {
      HapticFeedback.mediumImpact();
      widget.onSwipeReply();
    }
    _dragExtent = 0;
    _anim.animateTo(0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, child) {
          return Stack(
            clipBehavior: Clip.none,
            children: [
              // Reply icon (fades in as you swipe)
              if (_anim.value > 0)
                Positioned(
                  left: 8,
                  top: 0,
                  bottom: 0,
                  child: Opacity(
                    opacity: _anim.value,
                    child: const Align(
                      alignment: Alignment.centerLeft,
                      child: Icon(Icons.reply, color: AppColors.gold, size: 20),
                    ),
                  ),
                ),
              Transform.translate(
                offset: Offset(_anim.value * 40, 0),
                child: child,
              ),
            ],
          );
        },
        child: Column(
          crossAxisAlignment: widget.isMe
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _MessageBubble(
              message: widget.message,
              isMe: widget.isMe,
              showSender: widget.showSender,
              onLongPress: widget.onLongPress,
              onTapQuote: widget.onTapQuote,
              highlightQuery: widget.highlightQuery,
            ),
            _ReactionsRow(
              messageId: widget.message.id,
              onToggle: widget.onReactionToggle,
            ),
          ],
        ),
      ),
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
    required this.onTapQuote,
    this.highlightQuery = '',
  });

  final NexusMessage message;
  final bool isMe;
  final bool showSender; // show sender name above bubble in broadcast channel
  final VoidCallback onLongPress;
  final void Function(String) onTapQuote;
  final String highlightQuery;

  @override
  Widget build(BuildContext context) {
    final hasReply = message.metadata?['reply_to_id'] != null;
    final isForwarded = message.metadata?['forwarded'] == true;
    final forwardedFrom =
        message.metadata?['forwarded_from'] as String?;

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
            color: isMe ? AppColors.sentBubble : AppColors.surfaceVariant,
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
              // ── Forwarded label ───────────────────────────────────────────
              if (isForwarded)
                Padding(
                  padding:
                      const EdgeInsets.only(left: 12, right: 12, top: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.forward,
                          size: 12,
                          color: isMe
                              ? AppColors.deepBlue.withValues(alpha: 0.6)
                              : Colors.grey),
                      const SizedBox(width: 3),
                      Text(
                        forwardedFrom != null
                            ? 'Weitergeleitet von $forwardedFrom'
                            : 'Weitergeleitet',
                        style: TextStyle(
                          fontSize: 11,
                          color: isMe
                              ? AppColors.deepBlue.withValues(alpha: 0.6)
                              : Colors.grey,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ),
                ),
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
              // ── Quoted message block ──────────────────────────────────────
              if (hasReply)
                _ReplyQuoteBlock(
                  replyToId:
                      message.metadata!['reply_to_id'] as String,
                  senderName:
                      (message.metadata!['reply_to_sender'] as String?) ??
                          '…',
                  preview:
                      (message.metadata!['reply_to_preview'] as String?) ??
                          '',
                  isImage:
                      message.metadata!['reply_to_image'] as bool? ?? false,
                  isVoice:
                      message.metadata!['reply_to_voice'] as bool? ?? false,
                  isMe: isMe,
                  onTap: onTapQuote,
                ),
              // ── Message content ───────────────────────────────────────────
              if (message.type == NexusMessageType.image)
                _ImageContent(message: message)
              else if (message.type == NexusMessageType.voice)
                _VoiceContent(message: message, isMe: isMe)
              else
                _TextContent(
                  message: message,
                  isMe: isMe,
                  highlightQuery: highlightQuery,
                ),
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
  const _TextContent({
    required this.message,
    required this.isMe,
    this.highlightQuery = '',
  });
  final NexusMessage message;
  final bool isMe;
  final String highlightQuery;

  @override
  Widget build(BuildContext context) {
    final time = _formatTime(message.timestamp.toLocal());
    final isEdited = message.metadata?['local_edited_body'] != null;
    final isFav = message.metadata?['local_favorite'] == true;
    final textStyle = TextStyle(
      color: AppColors.onDark,
      fontSize: 15,
    );
    final metaColor =
        isMe ? AppColors.onDark.withValues(alpha: 0.55) : Colors.grey;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          LinkifiedText(
            text: message.body,
            query: highlightQuery,
            style: textStyle,
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                time,
                style: TextStyle(color: metaColor, fontSize: 10),
              ),
              if (isEdited) ...[
                const SizedBox(width: 3),
                Text(
                  '(bearbeitet)',
                  style: TextStyle(color: metaColor, fontSize: 10),
                ),
              ],
              if (isFav) ...[
                const SizedBox(width: 3),
                Icon(Icons.star, size: 10, color: AppColors.gold),
              ],
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
              if (message.metadata?['encrypted'] == true) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.lock,
                  size: 10,
                  color: isMe
                      ? AppColors.deepBlue.withValues(alpha: 0.6)
                      : AppColors.gold,
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

// Top-level so it can be passed to compute().
Uint8List _decodeBase64Isolate(String b64) => base64Decode(b64);

class _ImageContent extends StatefulWidget {
  const _ImageContent({required this.message});

  final NexusMessage message;

  @override
  State<_ImageContent> createState() => _ImageContentState();
}

class _ImageContentState extends State<_ImageContent> {
  Uint8List? _previewBytes;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  Future<void> _loadPreview() async {
    // Prefer thumbnail; fall back to full image body.
    final thumbB64 = widget.message.metadata?['thumbnail'] as String?;
    final b64 = thumbB64 ?? widget.message.body;
    try {
      // Decode in a background isolate so the UI thread is never blocked.
      final bytes = await compute(_decodeBase64Isolate, b64);
      if (mounted) setState(() { _previewBytes = bytes; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openFullscreen() async {
    Uint8List? bytes;
    try {
      bytes = await compute(_decodeBase64Isolate, widget.message.body);
    } catch (_) {}
    if (bytes == null || !mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _FullscreenImageScreen(bytes: bytes!),
      ),
    );
  }

  /// Calculates display height from image metadata aspect ratio,
  /// clamped between 80 and 280 logical pixels.
  double _displayHeight(double? imgW, double? imgH, double maxW) {
    if (imgW != null && imgH != null && imgW > 0) {
      return (maxW * imgH / imgW).clamp(80.0, 280.0);
    }
    return 180.0; // fallback when metadata is missing
  }

  @override
  Widget build(BuildContext context) {
    final imgW = (widget.message.metadata?['width'] as num?)?.toDouble();
    final imgH = (widget.message.metadata?['height'] as num?)?.toDouble();
    final time = _formatTime(widget.message.timestamp.toLocal());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        GestureDetector(
          onTap: _openFullscreen,
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final maxW = constraints.maxWidth.isFinite
                    ? constraints.maxWidth
                    : 250.0;
                final displayH = _displayHeight(imgW, imgH, maxW);
                return SizedBox(
                  width: maxW,
                  height: displayH,
                  child: _buildContent(),
                );
              },
            ),
          ),
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

  Widget _buildContent() {
    if (_loading) {
      return const ColoredBox(
        color: AppColors.surfaceVariant,
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.gold,
            ),
          ),
        ),
      );
    }
    if (_previewBytes == null) return const _BrokenImage();
    return Image.memory(
      _previewBytes!,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stack) => const _BrokenImage(),
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

// ── Voice message content ─────────────────────────────────────────────────────

class _VoiceContent extends StatelessWidget {
  const _VoiceContent({required this.message, required this.isMe});

  final NexusMessage message;
  final bool isMe;

  static String _fmt(Duration d) {
    final m = d.inMinutes.toString();
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final durationMs =
        (message.metadata?['duration_ms'] as num?)?.toInt() ?? 0;

    return ListenableBuilder(
      listenable: VoicePlayer.instance,
      builder: (context, _) {
        final player = VoicePlayer.instance;
        final isActive = player.isActiveMessage(message.id);
        final isPlaying = player.isPlayingMessage(message.id);
        final position = isActive ? player.position : Duration.zero;
        final total = isActive && player.total.inMilliseconds > 0
            ? player.total
            : Duration(milliseconds: durationMs);
        final speed = isActive ? player.speed : 1.0;
        final progress = total.inMilliseconds > 0
            ? (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
            : 0.0;

        const fgColor = AppColors.onDark;
        const accentColor = AppColors.gold;
        final muteColor = isMe
            ? AppColors.onDark.withValues(alpha: 0.4)
            : Colors.grey.shade600;

        return Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Play / Pause button
                  GestureDetector(
                    onTap: () =>
                        player.togglePlayPause(message),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isPlaying ? Icons.pause : Icons.play_arrow,
                        color: accentColor,
                        size: 24,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Waveform bars
                  SizedBox(
                    width: 120,
                    child: _WaveformBars(
                      messageId: message.id,
                      progress: progress,
                      activeColor: accentColor,
                      inactiveColor: muteColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Time + speed + lock icon row
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(width: 50), // align with waveform
                  Text(
                    isActive && isPlaying
                        ? _fmt(position)
                        : _fmt(Duration(milliseconds: durationMs)),
                    style: TextStyle(fontSize: 11, color: fgColor.withValues(alpha: 0.7)),
                  ),
                  if (isActive) ...[
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: player.cycleSpeed,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: accentColor.withValues(alpha: 0.5),
                              width: 0.8),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          speed == speed.truncate()
                              ? '${speed.toInt()}×'
                              : '${speed}×',
                          style: TextStyle(
                              fontSize: 10,
                              color: accentColor),
                        ),
                      ),
                    ),
                  ],
                  if (message.metadata?['encrypted'] == true) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.lock,
                        size: 10,
                        color: fgColor.withValues(alpha: 0.6)),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Waveform bars ─────────────────────────────────────────────────────────────

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
    // Deterministic pseudo-random heights derived from message ID.
    final seed = messageId.codeUnits
        .fold<int>(0, (acc, b) => acc ^ (b * 2654435761) & 0x7fffffff);
    final rng = Random(seed);
    return List.generate(
        _barCount, (_) => 0.15 + rng.nextDouble() * 0.85);
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

class _InputBar extends StatefulWidget {
  const _InputBar({
    required this.ctrl,
    required this.focus,
    required this.onSend,
    required this.onEmojiToggle,
    required this.onAttach,
    required this.showEmojiIcon,
    required this.attachEnabled,
    required this.onSendVoice,
    required this.voiceEnabled,
    this.isEditing = false,
  });

  final TextEditingController ctrl;
  final FocusNode focus;
  final VoidCallback onSend;
  final VoidCallback onEmojiToggle;
  final VoidCallback onAttach;
  final bool showEmojiIcon;
  final bool attachEnabled;
  final Future<void> Function(String filePath, int durationMs) onSendVoice;
  final bool voiceEnabled;
  /// When true, the send button becomes a checkmark (confirm edit).
  final bool isEditing;

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> with TickerProviderStateMixin {
  final _recorder = VoiceRecorder();

  bool _isRecording = false;
  Duration _recordDuration = Duration.zero;
  double _dragOffset = 0;
  Timer? _durationTimer;

  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;

  bool get _hasText => widget.ctrl.text.isNotEmpty;

  @override
  void initState() {
    super.initState();
    widget.ctrl.addListener(_onTextChanged);
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _pulseAnim = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void didUpdateWidget(_InputBar old) {
    super.didUpdateWidget(old);
    if (old.ctrl != widget.ctrl) {
      old.ctrl.removeListener(_onTextChanged);
      widget.ctrl.addListener(_onTextChanged);
    }
  }

  @override
  void dispose() {
    widget.ctrl.removeListener(_onTextChanged);
    _pulseCtrl.dispose();
    _durationTimer?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  // ── Recording lifecycle ──────────────────────────────────────────────────

  Future<void> _startRecording() async {
    if (!widget.voiceEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sprachnachrichten nur über LAN/Internet verfügbar'),
        ),
      );
      return;
    }

    final hasPerm = await _recorder.hasPermission();
    if (!hasPerm) {
      final granted = await _recorder.requestPermission();
      if (!granted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Mikrofon-Berechtigung benötigt')),
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
      // Auto-send after 5 minutes
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

  // ── UI ───────────────────────────────────────────────────────────────────

  static String _formatDuration(Duration d) {
    final m = d.inMinutes.toString();
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        color: AppColors.surface,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            // Left section: recording indicator OR (emoji + text field)
            Expanded(
              child: _isRecording
                  ? _buildRecordingRow()
                  : Row(
                      children: [
                        IconButton(
                          onPressed: widget.onEmojiToggle,
                          icon: Icon(widget.showEmojiIcon
                              ? Icons.emoji_emotions_outlined
                              : Icons.keyboard),
                          color: AppColors.gold,
                          iconSize: 22,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 36),
                        ),
                        Expanded(
                          child: Focus(
                            // Desktop: Enter = send, Shift+Enter = newline.
                            // Mobile: Enter key is handled by the keyboard
                            // action button; the send button submits.
                            onKeyEvent: (_, event) {
                              if (Platform.isAndroid || Platform.isIOS) {
                                return KeyEventResult.ignored;
                              }
                              if (event is KeyDownEvent &&
                                  event.logicalKey ==
                                      LogicalKeyboardKey.enter &&
                                  !HardwareKeyboard.instance.isShiftPressed) {
                                widget.onSend();
                                return KeyEventResult.handled;
                              }
                              return KeyEventResult.ignored;
                            },
                            child: TextField(
                              controller: widget.ctrl,
                              focusNode: widget.focus,
                              maxLines: 5,
                              minLines: 1,
                              keyboardType: TextInputType.multiline,
                              textCapitalization:
                                  TextCapitalization.sentences,
                              // Mobile: Enter key inserts a newline;
                              // send button submits the message.
                              // Desktop: Enter is intercepted above.
                              textInputAction:
                                  (Platform.isAndroid || Platform.isIOS)
                                      ? TextInputAction.newline
                                      : TextInputAction.newline,
                              decoration: InputDecoration(
                                hintText: 'Nachricht schreiben…',
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
                                  horizontal: 16,
                                  vertical: 10,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
            // Attachment button (hidden while recording)
            if (!_isRecording) ...[
              IconButton(
                onPressed: widget.attachEnabled ? widget.onAttach : null,
                icon: const Icon(Icons.attach_file),
                color:
                    widget.attachEnabled ? AppColors.gold : Colors.grey,
                iconSize: 22,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36),
                tooltip: widget.attachEnabled
                    ? 'Bild senden'
                    : 'Nur über LAN/Internet verfügbar',
              ),
              const SizedBox(width: 4),
            ],
            // Right button: send (has text) OR mic (no text / recording)
            if (_hasText && !_isRecording || widget.isEditing)
              IconButton(
                onPressed: widget.onSend,
                icon: Icon(widget.isEditing
                    ? Icons.check_rounded
                    : Icons.send_rounded),
                color: AppColors.gold,
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.surfaceVariant,
                ),
              )
            else
              GestureDetector(
                onLongPressStart: (_) => _startRecording(),
                onLongPressMoveUpdate: (d) {
                  setState(() => _dragOffset = d.offsetFromOrigin.dx);
                },
                onLongPressEnd: (_) {
                  if (_isRecording) {
                    if (_dragOffset < -80) {
                      _cancelRecording();
                    } else {
                      _stopAndSend();
                    }
                  }
                },
                onLongPressCancel: _cancelRecording,
                child: AnimatedBuilder(
                  animation: _pulseAnim,
                  builder: (context, _) {
                    return Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: _isRecording
                            ? Colors.redAccent.withValues(alpha: 0.15)
                            : AppColors.surfaceVariant,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.mic,
                        color: _isRecording
                            ? Colors.redAccent
                                .withValues(alpha: _pulseAnim.value)
                            : AppColors.gold,
                        size: 22,
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecordingRow() {
    final isCancel = _dragOffset < -80;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          // Pulsing red dot
          AnimatedBuilder(
            animation: _pulseAnim,
            builder: (context, _) => Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color:
                    Colors.redAccent.withValues(alpha: _pulseAnim.value),
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatDuration(_recordDuration),
            style: const TextStyle(
              color: Colors.redAccent,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              isCancel
                  ? '← Abbrechen'
                  : '← Wischen zum Abbrechen',
              style: TextStyle(
                color: isCancel ? Colors.redAccent : Colors.grey,
                fontSize: 13,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Reply quote block (inside message bubble) ─────────────────────────────────

class _ReplyQuoteBlock extends StatelessWidget {
  const _ReplyQuoteBlock({
    required this.replyToId,
    required this.senderName,
    required this.preview,
    required this.isImage,
    required this.isMe,
    required this.onTap,
    this.isVoice = false,
  });

  final String replyToId;
  final String senderName;
  final String preview;
  final bool isImage;
  final bool isVoice;
  final bool isMe;
  final void Function(String) onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onTap(replyToId),
      child: Container(
        margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
        padding: const EdgeInsets.fromLTRB(0, 6, 8, 6),
        decoration: BoxDecoration(
          color: isMe
              ? AppColors.deepBlue.withValues(alpha: 0.25)
              : AppColors.surface.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Gold accent line
            Container(
              width: 3,
              height: (isImage || isVoice) ? 44 : 36,
              decoration: BoxDecoration(
                color: AppColors.gold,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            if (isVoice) ...[
              const Icon(Icons.mic, color: AppColors.gold, size: 22),
              const SizedBox(width: 8),
            ],
            if (isImage) ...[
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Icon(Icons.image, color: Colors.grey, size: 20),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    senderName,
                    style: const TextStyle(
                      color: AppColors.gold,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                  Text(
                    isImage ? 'Foto' : preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isMe
                          ? AppColors.deepBlue.withValues(alpha: 0.7)
                          : Colors.grey,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Reply banner (shown above input bar when reply mode is active) ─────────────

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
    final isImage = message.type == NexusMessageType.image;
    final isVoice = message.type == NexusMessageType.voice;
    final preview = isImage
        ? 'Foto'
        : isVoice
            ? 'Sprachnachricht'
            : message.body.substring(0, min(message.body.length, 80));

    return Container(
      color: AppColors.surfaceVariant,
      padding: const EdgeInsets.only(left: 0, right: 4, top: 6, bottom: 6),
      child: Row(
        children: [
          // Gold accent line
          Container(
            width: 3,
            height: 40,
            color: AppColors.gold,
          ),
          const SizedBox(width: 10),
          // Thumbnail if image or mic icon if voice
          if (isVoice) ...[
            const Icon(Icons.mic, color: AppColors.gold, size: 20),
            const SizedBox(width: 8),
          ],
          if (isImage) ...[
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Icon(Icons.image, color: Colors.grey, size: 18),
            ),
            const SizedBox(width: 8),
          ],
          // Sender + preview
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  senderName,
                  style: const TextStyle(
                    color: AppColors.gold,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
          // Cancel button
          IconButton(
            onPressed: onCancel,
            icon: const Icon(Icons.close, color: Colors.grey, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
        ],
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
      color: AppColors.surfaceVariant,
      padding: const EdgeInsets.only(left: 0, right: 4, top: 6, bottom: 6),
      child: Row(
        children: [
          Container(width: 3, height: 40, color: AppColors.gold),
          const SizedBox(width: 10),
          const Icon(Icons.edit, color: AppColors.gold, size: 18),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Nachricht bearbeiten',
              style: TextStyle(
                color: AppColors.gold,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ),
          IconButton(
            onPressed: onCancel,
            icon: const Icon(Icons.close, color: Colors.grey, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
        ],
      ),
    );
  }
}

// ── Info row (for info bottom sheet) ─────────────────────────────────────────

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.gold, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style:
                        const TextStyle(color: Colors.grey, fontSize: 11)),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    color: valueColor ?? AppColors.onDark,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Header trust badge ────────────────────────────────────────────────────────

class _HeaderTrustBadge extends StatelessWidget {
  const _HeaderTrustBadge({required this.peerDid});
  final String peerDid;

  @override
  Widget build(BuildContext context) {
    final contact = ContactService.instance.findByDid(peerDid);
    if (contact == null) return const SizedBox.shrink();
    return TrustBadge(level: contact.trustLevel, small: true);
  }
}

// ── Unknown-peer banner ───────────────────────────────────────────────────────

class _UnknownPeerBanner extends StatefulWidget {
  const _UnknownPeerBanner({
    required this.peerDid,
    required this.peerPseudonym,
    required this.onAdded,
  });

  final String peerDid;
  final String peerPseudonym;
  final VoidCallback onAdded;

  @override
  State<_UnknownPeerBanner> createState() => _UnknownPeerBannerState();
}

class _UnknownPeerBannerState extends State<_UnknownPeerBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    final isKnown = ContactService.instance.findByDid(widget.peerDid) != null;
    if (isKnown || _dismissed) return const SizedBox.shrink();

    // Use the best available name (live peer > contact > DID fragment).
    final displayName =
        ContactService.instance.getDisplayName(widget.peerDid);

    return Container(
      color: AppColors.surfaceVariant,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.person_add_outlined, size: 18, color: Colors.grey),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$displayName ist noch kein Kontakt',
              style: const TextStyle(color: Colors.grey, fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              await ContactService.instance
                  .addContact(widget.peerDid, displayName);
              if (mounted) {
                setState(() {});
                widget.onAdded();
                messenger.showSnackBar(
                  SnackBar(
                    content:
                        Text('$displayName zu Kontakten hinzugefügt.'),
                  ),
                );
              }
            },
            child: const Text('Hinzufügen',
                style: TextStyle(color: AppColors.gold, fontSize: 12)),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16, color: Colors.grey),
            onPressed: () => setState(() => _dismissed = true),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }
}

// ── E2E banner ────────────────────────────────────────────────────────────────

class _E2EBanner extends StatelessWidget {
  const _E2EBanner({required this.peerDid});
  final String peerDid;

  @override
  Widget build(BuildContext context) {
    final contact = ContactService.instance.findByDid(peerDid);
    final isEncrypted = contact?.encryptionPublicKey != null &&
        EncryptionKeys.instance.isInitialized;

    if (!isEncrypted) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: AppColors.surfaceVariant,
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.lock, size: 12, color: AppColors.gold),
          SizedBox(width: 6),
          Text(
            'Ende-zu-Ende verschlüsselt',
            style: TextStyle(color: AppColors.gold, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

// ── Key change warning ────────────────────────────────────────────────────────

class _KeyChangeBanner extends StatelessWidget {
  const _KeyChangeBanner({
    required this.peerDid,
    required this.onAcknowledge,
  });
  final String peerDid;
  final VoidCallback onAcknowledge;

  @override
  Widget build(BuildContext context) {
    final contact = ContactService.instance.findByDid(peerDid);
    if (contact?.previousEncryptionPublicKey == null) {
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Colors.orange.withValues(alpha: 0.15),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, color: Colors.orange, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Der Sicherheitsschlüssel von ${contact!.pseudonym} hat sich '
              'geändert. Verifiziere den Kontakt.',
              style: const TextStyle(color: Colors.orange, fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: () async {
              await ContactService.instance.acknowledgeKeyChange(peerDid);
              onAcknowledge();
            },
            child: const Text('OK',
                style: TextStyle(color: Colors.orange, fontSize: 12)),
          ),
        ],
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

// ── Search highlight state ────────────────────────────────────────────────────

/// Immutable snapshot of which messages are search matches and which is active.
class _SearchHighlight {
  const _SearchHighlight({this.matchIds = const {}, this.currentId});
  final Set<String> matchIds;
  final String? currentId;
}

// ── Contact-request gate ──────────────────────────────────────────────────────

/// Shown instead of the normal chat when the peer is not yet a confirmed contact.
///
/// Allows the user to send a contact request with an intro message, and shows a
/// "pending" view once the request has been sent.
class _ContactRequestGateScreen extends StatefulWidget {
  const _ContactRequestGateScreen({
    required this.peerDid,
    required this.peerPseudonym,
  });

  final String peerDid;
  final String peerPseudonym;

  @override
  State<_ContactRequestGateScreen> createState() =>
      _ContactRequestGateScreenState();
}

class _ContactRequestGateScreenState
    extends State<_ContactRequestGateScreen> {
  final _messageCtrl = TextEditingController();
  bool _sending = false;
  String? _error;

  bool get _hasSentRequest =>
      ContactRequestService.instance.hasSentRequestTo(widget.peerDid);

  @override
  void dispose() {
    _messageCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendRequest() async {
    final text = _messageCtrl.text.trim();
    setState(() {
      _sending = true;
      _error = null;
    });

    final provider = context.read<ChatProvider>();
    final err = await provider.sendContactRequest(widget.peerDid, text);

    if (!mounted) return;
    if (err != null) {
      setState(() {
        _sending = false;
        _error = err;
      });
    } else {
      setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ContactRequest>>(
      stream: ContactRequestService.instance.stream,
      initialData: const [],
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: Text(widget.peerPseudonym)),
          body: _hasSentRequest ? _buildPendingView() : _buildRequestForm(),
        );
      },
    );
  }

  Widget _buildPendingView() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.hourglass_empty,
              color: AppColors.gold, size: 64),
          const SizedBox(height: 24),
          const Text(
            'Anfrage ausstehend',
            style: TextStyle(
              color: AppColors.gold,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Du hast ${widget.peerPseudonym} eine Kontaktanfrage gesendet. '
            'Sobald sie angenommen wird, könnt ihr chatten.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 24),
          TextButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const _SentRequestsProxy(),
                ),
              );
            },
            child: const Text(
              'Gesendete Anfragen',
              style: TextStyle(color: AppColors.gold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRequestForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          const Icon(Icons.person_add_alt_1,
              color: AppColors.gold, size: 56),
          const SizedBox(height: 20),
          Text(
            'Du bist noch nicht mit ${widget.peerPseudonym} verbunden.',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: AppColors.onDark,
                fontSize: 16,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Die Person entscheidet ob sie deine Anfrage annimmt. '
            'Erst danach könnt ihr chatten.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _messageCtrl,
            maxLength: 500,
            maxLines: 4,
            minLines: 3,
            decoration: const InputDecoration(
              hintText: 'Stell dich kurz vor…',
              hintStyle: TextStyle(color: Colors.grey),
              border: OutlineInputBorder(),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.grey),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: AppColors.gold),
              ),
              counterStyle: TextStyle(color: Colors.grey),
            ),
            style: const TextStyle(color: AppColors.onDark),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _sending ? null : _sendRequest,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.gold,
              foregroundColor: AppColors.deepBlue,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: _sending
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                        color: AppColors.deepBlue, strokeWidth: 2),
                  )
                : const Text(
                    'Kontaktanfrage senden',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Proxy widget that lazily imports SentRequestsScreen without circular deps.
class _SentRequestsProxy extends StatelessWidget {
  const _SentRequestsProxy();

  @override
  Widget build(BuildContext context) {
    // Import inline to avoid adding a top-level import for a rarely used screen.
    return const _SentRequestsInline();
  }
}

// Inline minimal sent-requests view accessible from the gate.
class _SentRequestsInline extends StatelessWidget {
  const _SentRequestsInline();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ContactRequest>>(
      stream: ContactRequestService.instance.stream,
      initialData: ContactRequestService.instance.sentRequests,
      builder: (context, snap) {
        final sent = ContactRequestService.instance.sentRequests;
        return Scaffold(
          appBar: AppBar(title: const Text('Gesendete Anfragen')),
          body: sent.isEmpty
              ? const Center(
                  child: Text('Keine gesendeten Anfragen',
                      style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  itemCount: sent.length,
                  itemBuilder: (_, i) {
                    final req = sent[i];
                    final chipColor = switch (req.status) {
                      ContactRequestStatus.accepted => Colors.green,
                      ContactRequestStatus.pending => Colors.orange,
                      _ => Colors.grey,
                    };
                    final chipLabel = switch (req.status) {
                      ContactRequestStatus.accepted => 'Angenommen',
                      ContactRequestStatus.pending => 'Ausstehend',
                      _ => 'Unbekannt',
                    };
                    return ListTile(
                      leading: const Icon(Icons.person_outline,
                          color: AppColors.gold),
                      title: Text(req.fromPseudonym.isNotEmpty
                          ? req.fromPseudonym
                          : req.fromDid),
                      subtitle: Text(
                        req.message,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.grey),
                      ),
                      trailing: Chip(
                        label: Text(chipLabel,
                            style:
                                const TextStyle(fontSize: 11, color: Colors.white)),
                        backgroundColor: chipColor,
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                    );
                  },
                ),
        );
      },
    );
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
