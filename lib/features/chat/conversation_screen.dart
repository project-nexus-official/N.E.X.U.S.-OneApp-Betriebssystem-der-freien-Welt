import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random, min;

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/contacts/contact_service.dart';
import '../../core/crypto/encryption_keys.dart';
import '../../core/storage/retention_service.dart';
import '../../core/transport/message_transport.dart';
import '../../core/transport/nexus_message.dart';
import '../../core/transport/nexus_peer.dart';
import '../../core/identity/identity_service.dart';
import '../../services/notification_service.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/highlighted_text.dart';
import '../contacts/contact_detail_screen.dart';
import '../contacts/widgets/trust_badge.dart';
import 'chat_provider.dart';
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
    _loadRetention();
    _scrollCtrl.addListener(_onScroll);
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
            // ── Antworten (primary action) ──
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
            // ── Weiterleiten (UI only, Phase 1b) ──
            ListTile(
              leading: const Icon(Icons.forward, color: Colors.grey),
              title: const Text('Weiterleiten',
                  style: TextStyle(color: Colors.grey)),
              onTap: () => Navigator.pop(ctx),
            ),
            // ── Löschen (own messages only) ──
            if (isMe)
              ListTile(
                leading: const Icon(Icons.delete_outline,
                    color: Colors.redAccent),
                title: const Text('Löschen',
                    style: TextStyle(color: Colors.redAccent)),
                onTap: () async {
                  Navigator.pop(ctx);
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
                                      ? '#mesh'
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
                            const Text(
                              'Broadcast-Kanal',
                              style:
                                  TextStyle(fontSize: 11, color: AppColors.gold),
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
                        },
                        itemBuilder: (_) {
                          final muted = !widget.isBroadcast &&
                              ContactService.instance
                                  .isMuted(widget.peerDid);
                          return [
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
                // Reply banner
                if (_replyToMessage != null)
                  _ReplyBanner(
                    message: _replyToMessage!,
                    senderName: _replyToSenderName ?? '',
                    onCancel: _cancelReply,
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
                  onSendVoice: _sendVoice,
                  voiceEnabled: !_isBleBleOnly,
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
    this.highlightQuery = '',
  });

  final NexusMessage message;
  final bool isMe;
  final bool showSender;
  final VoidCallback onLongPress;
  final VoidCallback onSwipeReply;
  final void Function(String) onTapQuote;
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
        child: _MessageBubble(
          message: widget.message,
          isMe: widget.isMe,
          showSender: widget.showSender,
          onLongPress: widget.onLongPress,
          onTapQuote: widget.onTapQuote,
          highlightQuery: widget.highlightQuery,
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
    final textStyle = TextStyle(
      color: isMe ? AppColors.deepBlue : AppColors.onDark,
      fontSize: 15,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          highlightQuery.isNotEmpty
              ? HighlightedText(
                  text: message.body,
                  query: highlightQuery,
                  style: textStyle,
                )
              : Text(message.body, style: textStyle),
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
              if (message.metadata?['encrypted'] == true) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.lock,
                  size: 10,
                  color: isMe ? AppColors.deepBlue.withValues(alpha: 0.6) : AppColors.gold,
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

        final fgColor = isMe ? AppColors.deepBlue : AppColors.onDark;
        final accentColor = isMe ? AppColors.deepBlue : AppColors.gold;
        final muteColor = isMe
            ? AppColors.deepBlue.withValues(alpha: 0.35)
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
            if (_hasText && !_isRecording)
              IconButton(
                onPressed: widget.onSend,
                icon: const Icon(Icons.send_rounded),
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
