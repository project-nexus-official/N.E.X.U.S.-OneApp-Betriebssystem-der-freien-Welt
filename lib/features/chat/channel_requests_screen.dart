import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/contacts/contact_service.dart';
import '../../shared/theme/app_theme.dart';
import 'channel_access_service.dart';
import 'chat_provider.dart';
import 'group_channel_service.dart';

/// Screen that lists:
///   Tab 0 – pending join requests the local user (as admin) needs to handle.
///   Tab 1 – pending channel invitations the local user received.
class ChannelRequestsScreen extends StatefulWidget {
  const ChannelRequestsScreen({super.key});

  @override
  State<ChannelRequestsScreen> createState() => _ChannelRequestsScreenState();
}

class _ChannelRequestsScreenState extends State<ChannelRequestsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _sub = ChannelAccessService.instance.onChanged
        .listen((_) => setState(() {}));
  }

  @override
  void dispose() {
    _tabs.dispose();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = ChannelAccessService.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kanal-Anfragen'),
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: AppColors.gold,
          labelColor: AppColors.gold,
          unselectedLabelColor: Colors.grey,
          tabs: [
            Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Beitrittsanfragen'),
                  if (service.pendingRequests.isNotEmpty)
                    _Badge(service.pendingRequests.length),
                ],
              ),
            ),
            Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Einladungen'),
                  if (service.pendingInvitations.isNotEmpty)
                    _Badge(service.pendingInvitations.length),
                ],
              ),
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _RequestsTab(requests: service.pendingRequests),
          _InvitationsTab(invitations: service.pendingInvitations),
        ],
      ),
    );
  }
}

// ── Beitrittsanfragen tab ─────────────────────────────────────────────────────

class _RequestsTab extends StatelessWidget {
  const _RequestsTab({required this.requests});
  final List<ChannelJoinRequest> requests;

  @override
  Widget build(BuildContext context) {
    if (requests.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.how_to_reg, size: 48, color: Colors.grey),
            SizedBox(height: 12),
            Text('Keine offenen Beitrittsanfragen.',
                style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: requests.length,
      separatorBuilder: (_, __) =>
          const Divider(height: 1, color: AppColors.surfaceVariant),
      itemBuilder: (ctx, i) => _RequestTile(request: requests[i]),
    );
  }
}

class _RequestTile extends StatefulWidget {
  const _RequestTile({required this.request});
  final ChannelJoinRequest request;

  @override
  State<_RequestTile> createState() => _RequestTileState();
}

class _RequestTileState extends State<_RequestTile> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final req = widget.request;
    final channel =
        GroupChannelService.instance.findByName(req.channelName);
    final senderName = req.requesterPseudonym.isNotEmpty
        ? req.requesterPseudonym
        : ContactService.instance.getDisplayName(req.requesterDid);

    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: const CircleAvatar(
        backgroundColor: AppColors.surfaceVariant,
        child: Icon(Icons.person, color: AppColors.gold),
      ),
      title: Text(
        senderName,
        style: const TextStyle(
            color: AppColors.onDark, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        'möchte ${req.channelName} beitreten'
        '${channel == null ? " (Kanal nicht gefunden)" : ""}',
        style: const TextStyle(color: Colors.grey, fontSize: 12),
      ),
      trailing: _busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2))
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: channel == null ? null : () => _reject(context),
                  child: const Text('Ablehnen',
                      style: TextStyle(color: Colors.redAccent)),
                ),
                const SizedBox(width: 4),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.gold,
                    foregroundColor: AppColors.deepBlue,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 6),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                  onPressed: channel == null ? null : () => _accept(context),
                  child: const Text('Annehmen'),
                ),
              ],
            ),
    );
  }

  Future<void> _accept(BuildContext context) async {
    setState(() => _busy = true);
    final provider = context.read<ChatProvider>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ChannelAccessService.instance
          .acceptRequest(widget.request, provider.sendSystemDm);
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('${widget.request.requesterPseudonym} '
                'wurde zu ${widget.request.channelName} hinzugefügt.'),
            backgroundColor: AppColors.gold,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject(BuildContext context) async {
    setState(() => _busy = true);
    try {
      final provider = context.read<ChatProvider>();
      await ChannelAccessService.instance
          .rejectRequest(widget.request, provider.sendSystemDm);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

// ── Einladungen tab ────────────────────────────────────────────────────────────

class _InvitationsTab extends StatelessWidget {
  const _InvitationsTab({required this.invitations});
  final List<ChannelInvitation> invitations;

  @override
  Widget build(BuildContext context) {
    if (invitations.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mail_outline, size: 48, color: Colors.grey),
            SizedBox(height: 12),
            Text('Keine ausstehenden Einladungen.',
                style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: invitations.length,
      separatorBuilder: (_, __) =>
          const Divider(height: 1, color: AppColors.surfaceVariant),
      itemBuilder: (ctx, i) => _InvitationTile(invite: invitations[i]),
    );
  }
}

class _InvitationTile extends StatefulWidget {
  const _InvitationTile({required this.invite});
  final ChannelInvitation invite;

  @override
  State<_InvitationTile> createState() => _InvitationTileState();
}

class _InvitationTileState extends State<_InvitationTile> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final inv = widget.invite;
    final adminName = inv.adminPseudonym.isNotEmpty
        ? inv.adminPseudonym
        : ContactService.instance.getDisplayName(inv.adminDid);

    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: const CircleAvatar(
        backgroundColor: AppColors.surfaceVariant,
        child: Icon(Icons.lock, color: AppColors.gold),
      ),
      title: Text(
        inv.channelName,
        style: const TextStyle(
            color: AppColors.gold, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        'Einladung von $adminName',
        style: const TextStyle(color: Colors.grey, fontSize: 12),
      ),
      trailing: _busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2))
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () => _decline(),
                  child: const Text('Ablehnen',
                      style: TextStyle(color: Colors.redAccent)),
                ),
                const SizedBox(width: 4),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.gold,
                    foregroundColor: AppColors.deepBlue,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 6),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                  onPressed: () => _accept(context),
                  child: const Text('Beitreten'),
                ),
              ],
            ),
    );
  }

  Future<void> _accept(BuildContext context) async {
    setState(() => _busy = true);
    final provider = context.read<ChatProvider>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ChannelAccessService.instance.acceptInvitation(
        widget.invite,
        (ch) => provider.joinChannelAndSubscribe(ch),
      );
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('${widget.invite.channelName} beigetreten!'),
            backgroundColor: AppColors.gold,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decline() async {
    setState(() => _busy = true);
    try {
      await ChannelAccessService.instance
          .declineInvitation(widget.invite);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

// ── Badge ──────────────────────────────────────────────────────────────────────

class _Badge extends StatelessWidget {
  const _Badge(this.count);
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: const BoxDecoration(
        color: AppColors.gold,
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      child: Text(
        '$count',
        style: const TextStyle(
          color: AppColors.deepBlue,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
