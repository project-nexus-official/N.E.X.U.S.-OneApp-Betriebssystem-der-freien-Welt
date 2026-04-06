import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/contact_request_service.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/help_icon.dart';
import '../../shared/widgets/peer_avatar.dart';
import '../chat/chat_provider.dart';
import 'contact_request.dart';

/// Shows all incoming pending contact requests.
///
/// The user can:
///   - Accept (green button) – adds the sender as a contact and sends a DM.
///   - Reject (red button) – silently rejects.
///   - Swipe to dismiss – marks as ignored.
class ContactRequestsScreen extends StatefulWidget {
  const ContactRequestsScreen({super.key});

  @override
  State<ContactRequestsScreen> createState() => _ContactRequestsScreenState();
}

class _ContactRequestsScreenState extends State<ContactRequestsScreen> {
  late List<ContactRequest> _pending;
  StreamSubscription<List<ContactRequest>>? _sub;

  @override
  void initState() {
    super.initState();
    _pending = ContactRequestService.instance.pendingRequests;
    _sub = ContactRequestService.instance.stream.listen((all) {
      if (mounted) {
        setState(() {
          _pending = ContactRequestService.instance.pendingRequests;
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _accept(ContactRequest req) async {
    final provider = context.read<ChatProvider>();
    await provider.acceptContactRequest(req.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${req.fromPseudonym} als Kontakt hinzugefügt'),
        backgroundColor: Colors.green,
      ),
    );
  }

  Future<void> _reject(ContactRequest req) async {
    await ContactRequestService.instance.rejectRequest(req.id);
  }

  Future<void> _ignore(ContactRequest req) async {
    await ContactRequestService.instance.ignoreRequest(req.id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kontaktanfragen'),
        actions: const [
          HelpIcon(contextId: 'contact_request'),
          SizedBox(width: 8),
        ],
      ),
      body: _pending.isEmpty
          ? _EmptyState()
          : ListView.builder(
              itemCount: _pending.length,
              itemBuilder: (_, i) {
                final req = _pending[i];
                return _RequestTile(
                  request: req,
                  onAccept: () => _accept(req),
                  onReject: () => _reject(req),
                  onDismiss: () => _ignore(req),
                );
              },
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.person_add_alt_1, color: Colors.grey, size: 56),
            SizedBox(height: 16),
            Text(
              'Keine offenen Anfragen',
              style: TextStyle(color: Colors.grey, fontSize: 16),
            ),
            SizedBox(height: 8),
            Text(
              'Wenn dir jemand eine Kontaktanfrage schickt, erscheint sie hier.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 13, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _RequestTile extends StatelessWidget {
  const _RequestTile({
    required this.request,
    required this.onAccept,
    required this.onReject,
    required this.onDismiss,
  });

  final ContactRequest request;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final dateStr = _formatDate(request.receivedAt);
    return Dismissible(
      key: ValueKey(request.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.grey.shade800,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.visibility_off, color: Colors.white),
            SizedBox(height: 4),
            Text('Ignorieren',
                style: TextStyle(color: Colors.white, fontSize: 11)),
          ],
        ),
      ),
      onDismissed: (_) => onDismiss(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PeerAvatar(did: request.fromDid, size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    request.fromPseudonym.isNotEmpty
                        ? request.fromPseudonym
                        : request.fromDid,
                    style: const TextStyle(
                      color: AppColors.onDark,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (request.message.isNotEmpty)
                    Text(
                      request.message,
                      style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 13,
                          fontStyle: FontStyle.italic),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  const SizedBox(height: 6),
                  Text(
                    'Empfangen $dateStr',
                    style: const TextStyle(
                        color: Colors.grey, fontSize: 11),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: onReject,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.redAccent,
                            side: const BorderSide(
                                color: Colors.redAccent),
                            padding: const EdgeInsets.symmetric(
                                vertical: 8),
                          ),
                          child: const Text('Ablehnen'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: onAccept,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                                vertical: 8),
                          ),
                          child: const Text('Annehmen'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
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
