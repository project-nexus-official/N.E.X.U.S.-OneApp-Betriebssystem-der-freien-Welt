import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../features/chat/chat_provider.dart';
import '../../services/contact_request_service.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/peer_avatar.dart';
import 'contact_request.dart';

/// Shows all contact requests that the user has sent, with their status.
///
/// Does NOT reveal whether a request was rejected or ignored – those are shown
/// only as "Ausstehend" to preserve the sender's dignity.
class SentRequestsScreen extends StatefulWidget {
  const SentRequestsScreen({super.key});

  @override
  State<SentRequestsScreen> createState() => _SentRequestsScreenState();
}

class _SentRequestsScreenState extends State<SentRequestsScreen> {
  List<ContactRequest> _sent = [];
  StreamSubscription<List<ContactRequest>>? _sub;

  @override
  void initState() {
    super.initState();
    _sent = ContactRequestService.instance.sentRequests;
    _sub = ContactRequestService.instance.stream.listen((_) {
      if (mounted) {
        setState(() {
          _sent = ContactRequestService.instance.sentRequests;
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _cancelRequest(ContactRequest req) async {
    final name = req.fromPseudonym.isNotEmpty ? req.fromPseudonym : req.fromDid;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Anfrage zurückziehen?',
          style: TextStyle(color: AppColors.onDark),
        ),
        content: Text(
          'Kontaktanfrage an $name zurückziehen?',
          style: const TextStyle(color: Colors.grey),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Abbrechen',
                style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Zurückziehen',
                style: TextStyle(color: AppColors.gold)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await context.read<ChatProvider>().cancelContactRequest(req.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Only show pending requests – accepted ones are now contacts.
    final displayed =
        _sent.where((r) => r.status == ContactRequestStatus.pending).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Gesendete Anfragen')),
      body: displayed.isEmpty
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.send_outlined, color: Colors.grey, size: 56),
                  SizedBox(height: 16),
                  Text(
                    'Keine ausstehenden Anfragen',
                    style: TextStyle(color: Colors.grey, fontSize: 16),
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: displayed.length,
              itemBuilder: (_, i) => _SentRequestTile(
                request: displayed[i],
                onCancel: () => _cancelRequest(displayed[i]),
              ),
            ),
    );
  }
}

class _SentRequestTile extends StatelessWidget {
  const _SentRequestTile({required this.request, required this.onCancel});

  final ContactRequest request;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final dateStr = _formatDate(request.receivedAt);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PeerAvatar(did: request.fromDid, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        request.fromPseudonym.isNotEmpty
                            ? request.fromPseudonym
                            : request.fromDid,
                        style: const TextStyle(
                          color: AppColors.onDark,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Chip(
                      label: const Text(
                        'Ausstehend',
                        style: TextStyle(fontSize: 11, color: Colors.white),
                      ),
                      backgroundColor: Colors.orange,
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: onCancel,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.red.shade400),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.close,
                                size: 12, color: Colors.red.shade400),
                            const SizedBox(width: 3),
                            Text(
                              'Abbrechen',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.red.shade400),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                if (request.message.isNotEmpty)
                  Text(
                    request.message,
                    style: const TextStyle(
                        color: Colors.grey,
                        fontSize: 12,
                        fontStyle: FontStyle.italic),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                const SizedBox(height: 4),
                Text(
                  'Gesendet $dateStr',
                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now();
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return 'heute ${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
    }
    return '${local.day.toString().padLeft(2, '0')}.'
        '${local.month.toString().padLeft(2, '0')}.'
        '${local.year}';
  }
}
