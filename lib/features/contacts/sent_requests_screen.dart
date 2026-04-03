import 'dart:async';

import 'package:flutter/material.dart';

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gesendete Anfragen')),
      body: _sent.isEmpty
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.send_outlined, color: Colors.grey, size: 56),
                  SizedBox(height: 16),
                  Text(
                    'Keine gesendeten Anfragen',
                    style: TextStyle(color: Colors.grey, fontSize: 16),
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: _sent.length,
              itemBuilder: (_, i) => _SentRequestTile(request: _sent[i]),
            ),
    );
  }
}

class _SentRequestTile extends StatelessWidget {
  const _SentRequestTile({required this.request});

  final ContactRequest request;

  @override
  Widget build(BuildContext context) {
    // Never reveal rejected/ignored status to the sender.
    final isAccepted =
        request.status == ContactRequestStatus.accepted;
    final chipLabel = isAccepted ? 'Angenommen' : 'Ausstehend';
    final chipColor = isAccepted ? Colors.green : Colors.orange;

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
                      label: Text(
                        chipLabel,
                        style:
                            const TextStyle(fontSize: 11, color: Colors.white),
                      ),
                      backgroundColor: chipColor,
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
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
                  style:
                      const TextStyle(color: Colors.grey, fontSize: 11),
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
