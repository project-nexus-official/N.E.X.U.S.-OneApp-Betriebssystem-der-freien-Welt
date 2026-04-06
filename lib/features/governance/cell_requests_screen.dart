import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/contacts/contact_service.dart';
import '../../shared/theme/app_theme.dart';
import '../chat/chat_provider.dart';
import '../chat/conversation_screen.dart';
import 'cell_join_request.dart';
import 'cell_service.dart';

/// Shows pending join requests for a cell (founder/moderator only).
class CellRequestsScreen extends StatefulWidget {
  final String cellId;
  final String cellName;

  const CellRequestsScreen({
    super.key,
    required this.cellId,
    required this.cellName,
  });

  @override
  State<CellRequestsScreen> createState() => _CellRequestsScreenState();
}

class _CellRequestsScreenState extends State<CellRequestsScreen> {
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = CellService.instance.stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  List<CellJoinRequest> get _pending => CellService.instance
      .requestsFor(widget.cellId)
      .where((r) => r.isPending)
      .toList()
    ..sort((a, b) => a.requestedAt.compareTo(b.requestedAt));

  @override
  Widget build(BuildContext context) {
    final pending = _pending;

    return Scaffold(
      appBar: AppBar(
        title: Text('Anfragen – ${widget.cellName}'),
        backgroundColor: AppColors.deepBlue,
      ),
      backgroundColor: AppColors.deepBlue,
      body: pending.isEmpty
          ? const Center(
              child: Text(
                'Keine ausstehenden Anfragen.',
                style: TextStyle(color: AppColors.surfaceVariant),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: pending.length,
              itemBuilder: (context, i) =>
                  _RequestCard(request: pending[i], cellId: widget.cellId),
            ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  final CellJoinRequest request;
  final String cellId;

  const _RequestCard({required this.request, required this.cellId});

  @override
  Widget build(BuildContext context) {
    // Look up trust context.
    final contacts = ContactService.instance.contacts;
    final knownContact = contacts
        .where((c) => c.did == request.requesterDid)
        .firstOrNull;
    final trustContext = _buildTrustContext(knownContact?.trustLevel);

    // Look up cells the requester is member of (from discovered cells).
    final requesterCells = CellService.instance.allKnownCells
        .where((c) =>
            CellService.instance
                .membersOf(c.id)
                .any((m) => m.did == request.requesterDid))
        .toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.surfaceVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: AppColors.gold.withValues(alpha: 0.2),
                child: Text(
                  request.requesterPseudonym.isNotEmpty
                      ? request.requesterPseudonym[0].toUpperCase()
                      : '?',
                  style: const TextStyle(
                    color: AppColors.gold,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.requesterPseudonym,
                      style: const TextStyle(
                        color: AppColors.onDark,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      _formatDate(request.requestedAt),
                      style: TextStyle(
                        color: AppColors.onDark.withValues(alpha: 0.5),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // Message
          if (request.message != null && request.message!.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.deepBlue,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                request.message!,
                style: TextStyle(
                  color: AppColors.onDark.withValues(alpha: 0.85),
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
          ],

          // Trust context
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.shield_outlined, size: 14, color: Colors.blue),
              const SizedBox(width: 4),
              Text(
                trustContext,
                style: const TextStyle(color: Colors.blue, fontSize: 12),
              ),
            ],
          ),

          // Cell memberships
          if (requesterCells.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.group_work, size: 14, color: Colors.teal),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Mitglied in: ${requesterCells.map((c) => c.name).join(', ')}',
                    style: const TextStyle(
                      color: Colors.teal,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ] else ...[
            const SizedBox(height: 4),
            Text(
              'Noch in keiner Zelle',
              style: TextStyle(
                color: AppColors.onDark.withValues(alpha: 0.4),
                fontSize: 12,
              ),
            ),
          ],

          // Action buttons
          const SizedBox(height: 12),
          Row(
            children: [
              // Ablehnen
              Expanded(
                child: OutlinedButton(
                  onPressed: () =>
                      CellService.instance.rejectRequest(request),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text('Ablehnen'),
                ),
              ),
              const SizedBox(width: 8),
              // Nachfragen — opens a DM without requiring contact status
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _openInquiryChat(context),
                  icon: const Icon(Icons.chat_bubble_outline, size: 16),
                  label: const Text('Nachfragen'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.gold,
                    side: const BorderSide(color: AppColors.gold),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Bestätigen
              Expanded(
                child: ElevatedButton(
                  onPressed: () =>
                      CellService.instance.approveRequest(request),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text('Annehmen'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _openInquiryChat(BuildContext context) {
    // Register the requester's Nostr pubkey so DMs are routable even
    // without a contact relationship.
    final nostrPubkey = request.requesterNostrPubkey;
    if (nostrPubkey != null && nostrPubkey.isNotEmpty) {
      context.read<ChatProvider>().registerPeerNostrPubkey(
            request.requesterDid,
            nostrPubkey,
          );
    }
    print('[JOIN] Founder opening chat with applicant: ${request.requesterPseudonym} (no contact required)');

    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => ChangeNotifierProvider.value(
          value: context.read<ChatProvider>(),
          child: ConversationScreen(
            peerDid: request.requesterDid,
            peerPseudonym: request.requesterPseudonym,
            bypassContactGate: true,
          ),
        ),
      ),
    );
  }

  String _buildTrustContext(dynamic trustLevel) {
    if (trustLevel == null) {
      return 'Keinem Mitglied bekannt — bitte mit Vorsicht prüfen';
    }
    final idx = trustLevel.index as int? ?? 0;
    if (idx >= 3) return 'Bürge eines Mitglieds';
    if (idx >= 2) return 'Vertrauensperson eines Mitglieds';
    if (idx >= 1) return 'Kontakt eines Mitglieds';
    return 'Entdeckt durch ein Mitglied';
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return 'Heute';
    if (diff.inDays == 1) return 'Gestern';
    return 'Vor ${diff.inDays} Tagen';
  }
}
