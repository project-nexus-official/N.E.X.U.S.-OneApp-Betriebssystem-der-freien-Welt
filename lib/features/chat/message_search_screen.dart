import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/contacts/contact_service.dart';
import '../../core/identity/identity_service.dart';
import '../../core/storage/pod_database.dart';
import '../../core/transport/nexus_message.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/highlighted_text.dart';
import 'chat_provider.dart';
import 'conversation_screen.dart';

/// Extracts the peer DID from a DM conversation ID.
/// Exposed at library level for unit tests.
String? searchScreenPeerDidFromConvId(String convId, String myDid) =>
    _peerDidFromConvId(convId, myDid);

String? _peerDidFromConvId(String convId, String myDid) {
  // convId format: "${sorted[0]}:${sorted[1]}" where sorted are two DIDs.
  // DIDs look like "did:key:z6M…", separator ':' found via ':did:' after pos 4.
  final sepIdx = convId.indexOf(':did:', 4);
  if (sepIdx == -1) return null;
  final did1 = convId.substring(0, sepIdx);
  final did2 = convId.substring(sepIdx + 1);
  return did1 == myDid ? did2 : did1;
}

/// Full-screen global message search.
///
/// Reached via the search icon in the ConversationsScreen AppBar.
/// Searches across all conversations (decrypt-and-filter in Dart).
class MessageSearchScreen extends StatefulWidget {
  const MessageSearchScreen({super.key});

  @override
  State<MessageSearchScreen> createState() => _MessageSearchScreenState();
}

class _MessageSearchScreenState extends State<MessageSearchScreen> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;

  List<Map<String, dynamic>> _results = [];
  bool _loading = false;
  bool _hasSearched = false;
  String _lastQuery = '';
  bool _hasMore = false;

  static const _pageSize = 50;

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _search(value.trim());
    });
  }

  Future<void> _search(String query, {int offset = 0}) async {
    if (query.isEmpty) {
      setState(() {
        _results = [];
        _hasSearched = false;
        _hasMore = false;
        _lastQuery = '';
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final results = await PodDatabase.instance.searchMessages(
        query,
        limit: _pageSize,
        offset: offset,
      );
      if (!mounted) return;
      setState(() {
        _lastQuery = query;
        _results = offset == 0 ? results : [..._results, ...results];
        _hasMore = results.length == _pageSize;
        _hasSearched = true;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openResult(Map<String, dynamic> result) {
    final convId = result['conversation_id'] as String? ?? '';
    final msgId = result['id'] as String?;
    final provider = context.read<ChatProvider>();

    Widget screen;
    if (convId == NexusMessage.broadcastDid) {
      screen = ConversationScreen(
        peerDid: NexusMessage.broadcastDid,
        peerPseudonym: '#hotnews',
        isBroadcast: true,
        scrollToMessageId: msgId,
      );
    } else {
      final myDid = IdentityService.instance.currentIdentity?.did ?? '';
      final peerDid = _peerDidFromConvId(convId, myDid);
      if (peerDid == null) return;
      final contact = ContactService.instance.findByDid(peerDid);
      final pseudonym = contact?.pseudonym ??
          (peerDid.length > 16 ? '…${peerDid.substring(peerDid.length - 14)}' : peerDid);
      screen = ConversationScreen(
        peerDid: peerDid,
        peerPseudonym: pseudonym,
        scrollToMessageId: msgId,
      );
    }

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChangeNotifierProvider.value(
          value: provider,
          child: screen,
        ),
      ),
    );
  }

  String _senderName(Map<String, dynamic> result) {
    final senderDid = (result['fromDid'] as String?) ??
        (result['sender_did'] as String?) ?? '';
    final contact = ContactService.instance.findByDid(senderDid);
    if (contact != null) return contact.pseudonym;
    if (senderDid.length > 12) return '…${senderDid.substring(senderDid.length - 10)}';
    return senderDid;
  }

  String _convName(Map<String, dynamic> result) {
    final convId = result['conversation_id'] as String? ?? '';
    if (convId == NexusMessage.broadcastDid) return '#hotnews';
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final peerDid = _peerDidFromConvId(convId, myDid) ?? convId;
    final contact = ContactService.instance.findByDid(peerDid);
    if (contact != null) return contact.pseudonym;
    if (peerDid.length > 16) return '…${peerDid.substring(peerDid.length - 14)}';
    return peerDid;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _ctrl,
          focusNode: _focus,
          autofocus: true,
          onChanged: _onChanged,
          style: const TextStyle(color: AppColors.onDark),
          decoration: InputDecoration(
            hintText: 'Nachrichten durchsuchen…',
            hintStyle: const TextStyle(color: Colors.grey),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            suffixIcon: _ctrl.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, color: Colors.grey),
                    onPressed: () {
                      _ctrl.clear();
                      _onChanged('');
                    },
                  )
                : null,
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_hasSearched || _ctrl.text.trim().isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search, size: 48, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              'Suche in allen Nachrichten…',
              style: TextStyle(color: Colors.grey, fontSize: 16),
            ),
          ],
        ),
      );
    }

    if (_results.isEmpty) {
      return const Center(
        child: Text(
          'Keine Nachrichten gefunden',
          style: TextStyle(color: Colors.grey, fontSize: 16),
        ),
      );
    }

    return ListView.separated(
      itemCount: _results.length + (_hasMore ? 1 : 0),
      separatorBuilder: (_, __) =>
          const Divider(height: 1, color: AppColors.surfaceVariant),
      itemBuilder: (context, i) {
        if (i == _results.length) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _loading
                  ? const CircularProgressIndicator()
                  : TextButton(
                      onPressed: () => _search(_lastQuery, offset: _results.length),
                      child: const Text(
                        'Mehr laden',
                        style: TextStyle(color: AppColors.gold),
                      ),
                    ),
            ),
          );
        }
        final result = _results[i];
        return _SearchResultTile(
          result: result,
          query: _ctrl.text.trim(),
          senderName: _senderName(result),
          convName: _convName(result),
          onTap: () => _openResult(result),
        );
      },
    );
  }
}

// ── Result tile ───────────────────────────────────────────────────────────────

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({
    required this.result,
    required this.query,
    required this.senderName,
    required this.convName,
    required this.onTap,
  });

  final Map<String, dynamic> result;
  final String query;
  final String senderName;
  final String convName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final type = result['type'] as String? ?? 'text';
    final isVoice = type == 'voice';
    final body = isVoice ? '🎤 Sprachnachricht' : (result['body'] as String? ?? '');
    final tsMs = result['ts'] as int? ?? 0;
    final dt = DateTime.fromMillisecondsSinceEpoch(tsMs).toLocal();
    final timeStr = _formatDateTime(dt);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Text(
              senderName,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: AppColors.onDark,
                fontSize: 14,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(timeStr, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          HighlightedText(
            text: body,
            query: query,
            style: const TextStyle(color: AppColors.onDark, fontSize: 13),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 3),
          Row(
            children: [
              const Icon(Icons.chat_bubble_outline, size: 11, color: AppColors.gold),
              const SizedBox(width: 4),
              Text(
                convName,
                style: const TextStyle(fontSize: 11, color: AppColors.gold),
              ),
            ],
          ),
        ],
      ),
      onTap: onTap,
    );
  }

  String _formatDateTime(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    if (now.difference(dt).inDays < 7) {
      const days = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
      return days[dt.weekday - 1];
    }
    return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
  }
}
