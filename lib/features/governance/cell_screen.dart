import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/identity/identity_service.dart';
import '../../core/transport/nexus_message.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/help_icon.dart';
import '../chat/chat_provider.dart';
import '../chat/group_channel.dart';
import '../chat/group_channel_service.dart';
import 'cell.dart';
import 'cell_info_screen.dart';
import 'cell_member.dart';
import 'cell_requests_screen.dart';
import 'cell_service.dart';
import 'create_proposal_screen.dart';
import 'proposal.dart';
import 'proposal_detail_screen.dart';
import 'proposal_service.dart';

/// Full tabbed cell screen: Pinnwand · Diskussion · Agora · Mitglieder.
///
/// Replaces the old [CellInfoScreen] as the main entry point for a cell.
class CellScreen extends StatefulWidget {
  final Cell cell;
  const CellScreen({super.key, required this.cell});

  @override
  State<CellScreen> createState() => _CellScreenState();
}

class _CellScreenState extends State<CellScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  StreamSubscription<void>? _cellSub;
  StreamSubscription<void>? _proposalSub;
  late Cell _cell;

  @override
  void initState() {
    super.initState();
    _cell = widget.cell;
    _tabCtrl = TabController(length: 4, vsync: this);
    _cellSub = CellService.instance.stream.listen((_) {
      if (mounted) {
        setState(() {
          _cell = CellService.instance.myCells
              .firstWhere((c) => c.id == _cell.id, orElse: () => _cell);
        });
      }
    });
    _proposalSub = ProposalService.instance.stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _cellSub?.cancel();
    _proposalSub?.cancel();
    super.dispose();
  }

  String get _myDid => IdentityService.instance.currentIdentity?.did ?? '';

  CellMember? get _myMembership =>
      CellService.instance.membersOf(_cell.id)
          .where((m) => m.did == _myDid)
          .firstOrNull;

  bool get _isFounder => _myMembership?.role == MemberRole.founder;
  bool get _isMod => _myMembership?.role == MemberRole.moderator;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.deepBlue,
      body: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) => [
          SliverAppBar(
            pinned: true,
            backgroundColor: AppColors.deepBlue,
            title: Text(_cell.name),
            actions: [
              if (_isFounder)
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: 'Zelle bearbeiten',
                  onPressed: () => _openSettings(context),
                ),
            ],
            bottom: TabBar(
              controller: _tabCtrl,
              indicatorColor: AppColors.gold,
              labelColor: AppColors.gold,
              unselectedLabelColor:
                  AppColors.onDark.withValues(alpha: 0.6),
              tabs: const [
                Tab(icon: Icon(Icons.push_pin_outlined), text: 'Pinnwand'),
                Tab(icon: Icon(Icons.forum_outlined), text: 'Diskussion'),
                Tab(icon: Icon(Icons.account_balance_outlined), text: 'Agora'),
                Tab(icon: Icon(Icons.people_outlined), text: 'Mitglieder'),
              ],
            ),
          ),
          // Cell header (type, description, member count) below AppBar.
          SliverToBoxAdapter(child: _CellHeader(cell: _cell)),
        ],
        body: TabBarView(
          controller: _tabCtrl,
          children: [
            _BulletinTab(cell: _cell, isFounder: _isFounder, isMod: _isMod),
            _DiscussionTab(cell: _cell),
            _AgoraTab(cell: _cell, isFounder: _isFounder, isMod: _isMod),
            _MitgliederTab(cell: _cell, myDid: _myDid),
          ],
        ),
      ),
    );
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => CellInfoScreen(cell: _cell),
      ),
    );
  }
}

// ── Cell header ───────────────────────────────────────────────────────────────

class _CellHeader extends StatelessWidget {
  final Cell cell;
  const _CellHeader({required this.cell});

  @override
  Widget build(BuildContext context) {
    final memberCount = CellService.instance.membersOf(cell.id).length;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      color: AppColors.surface.withValues(alpha: 0.5),
      child: Row(
        children: [
          Icon(
            cell.cellType == CellType.local
                ? Icons.location_on
                : Icons.group_work,
            color: AppColors.gold,
            size: 16,
          ),
          const SizedBox(width: 6),
          Text(
            cell.cellType == CellType.local
                ? 'Lokale Gemeinschaft'
                : 'Thematische Gemeinschaft',
            style: const TextStyle(color: AppColors.gold, fontSize: 12),
          ),
          HelpIcon(
            contextId: cell.cellType == CellType.local
                ? 'cell_local'
                : 'cell_thematic',
            size: 15,
          ),
          const Spacer(),
          Icon(Icons.people, size: 14,
              color: AppColors.onDark.withValues(alpha: 0.5)),
          const SizedBox(width: 4),
          Text(
            '$memberCount/${cell.maxMembers}',
            style: TextStyle(
              color: AppColors.onDark.withValues(alpha: 0.5),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Shared channel chat view ───────────────────────────────────────────────────

/// Lightweight embedded chat view for cell-internal channels.
/// Does NOT have its own Scaffold — designed to live inside a [TabBarView].
class _CellChannelView extends StatefulWidget {
  final GroupChannel channel;
  final bool canPost;
  final String emptyMessage;
  final String? emptyHelpContextId;

  const _CellChannelView({
    required this.channel,
    required this.canPost,
    required this.emptyMessage,
    this.emptyHelpContextId,
  });

  @override
  State<_CellChannelView> createState() => _CellChannelViewState();
}

class _CellChannelViewState extends State<_CellChannelView> {
  final _scrollCtrl = ScrollController();
  final _textCtrl = TextEditingController();
  List<NexusMessage> _messages = [];
  bool _loading = true;
  ChatProvider? _chatProvider;

  @override
  void initState() {
    super.initState();
    _loadMessages();
    // Listen to ChatProvider for new messages.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _chatProvider = context.read<ChatProvider>();
        _chatProvider!.addListener(_onChatUpdate);
        _chatProvider!.setActiveConversation(widget.channel.conversationId);
      }
    });
  }

  @override
  void dispose() {
    _chatProvider?.removeListener(_onChatUpdate);
    _chatProvider?.setActiveConversation(null);
    _scrollCtrl.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  void _onChatUpdate() {
    _loadMessages();
  }

  Future<void> _loadMessages() async {
    if (!mounted) return;
    final provider = _chatProvider ?? context.read<ChatProvider>();
    final msgs = await provider.getMessages(widget.channel.conversationId);
    if (mounted) {
      setState(() {
        _messages = List.from(msgs);
        _loading = false;
      });
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  void _scrollToBottom() {
    if (_scrollCtrl.hasClients &&
        _scrollCtrl.position.maxScrollExtent > 0) {
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    _textCtrl.clear();
    await (_chatProvider ?? context.read<ChatProvider>())
        .sendToChannel(widget.channel.name, text);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: AppColors.gold))
              : _messages.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.emptyMessage,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.onDark.withValues(alpha: 0.4),
                              fontSize: 14,
                              height: 1.5,
                            ),
                          ),
                          if (widget.emptyHelpContextId != null) ...[
                            const SizedBox(height: 12),
                            HelpIcon(
                                contextId: widget.emptyHelpContextId!,
                                size: 20),
                          ],
                        ],
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      itemCount: _messages.length,
                      itemBuilder: (context, i) =>
                          _MessageBubble(msg: _messages[i]),
                    ),
        ),
        if (widget.canPost) _InputBar(ctrl: _textCtrl, onSend: _send),
        if (!widget.canPost)
          Container(
            padding: const EdgeInsets.all(12),
            color: AppColors.surface.withValues(alpha: 0.6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.lock_outline,
                    size: 14, color: AppColors.surfaceVariant),
                const SizedBox(width: 6),
                Text(
                  'Nur Gründer und Moderatoren können hier posten',
                  style: TextStyle(
                    color: AppColors.onDark.withValues(alpha: 0.4),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final NexusMessage msg;
  const _MessageBubble({required this.msg});

  @override
  Widget build(BuildContext context) {
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final isMe = msg.fromDid == myDid;
    final shortSender = isMe
        ? 'Du'
        : '…${msg.fromDid.length > 12 ? msg.fromDid.substring(msg.fromDid.length - 12) : msg.fromDid}';
    final time = _formatTime(msg.timestamp);

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.75,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isMe
              ? AppColors.gold.withValues(alpha: 0.2)
              : AppColors.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isMe ? 14 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 14),
          ),
        ),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!isMe)
              Text(
                shortSender,
                style: const TextStyle(
                  color: AppColors.gold,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            Text(
              msg.body,
              style: const TextStyle(color: AppColors.onDark, fontSize: 14),
            ),
            const SizedBox(height: 2),
            Text(
              time,
              style: TextStyle(
                color: AppColors.onDark.withValues(alpha: 0.4),
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime ts) {
    final h = ts.hour.toString().padLeft(2, '0');
    final m = ts.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController ctrl;
  final VoidCallback onSend;

  const _InputBar({required this.ctrl, required this.onSend});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      color: AppColors.surface,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: ctrl,
              style: const TextStyle(color: AppColors.onDark),
              maxLines: null,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: 'Nachricht…',
                hintStyle: TextStyle(
                    color: AppColors.onDark.withValues(alpha: 0.4)),
                filled: true,
                fillColor: AppColors.deepBlue,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            icon: const Icon(Icons.send_rounded, color: AppColors.gold),
            onPressed: onSend,
          ),
        ],
      ),
    );
  }
}

// ── Tab 1: Pinnwand ───────────────────────────────────────────────────────────

class _BulletinTab extends StatelessWidget {
  final Cell cell;
  final bool isFounder;
  final bool isMod;

  const _BulletinTab({
    required this.cell,
    required this.isFounder,
    required this.isMod,
  });

  @override
  Widget build(BuildContext context) {
    final channels =
        GroupChannelService.instance.cellChannelsFor(cell.id);
    final bulletin = channels
        .where((c) => c.name.endsWith('-bulletin'))
        .firstOrNull;

    if (bulletin == null) {
      return _NoChannelPlaceholder(
        icon: Icons.push_pin_outlined,
        message: 'Pinnwand wird eingerichtet…\nBitte kurz warten.',
      );
    }

    final canPost = isFounder || isMod;
    return _CellChannelView(
      channel: bulletin,
      canPost: canPost,
      emptyMessage: 'Noch keine Ankündigungen.\n'
          'Hier posten Gründer und Moderatoren wichtige Neuigkeiten für die Zelle.',
      emptyHelpContextId: 'cell_bulletin',
    );
  }
}

// ── Tab 2: Diskussion ─────────────────────────────────────────────────────────

class _DiscussionTab extends StatelessWidget {
  final Cell cell;

  const _DiscussionTab({required this.cell});

  @override
  Widget build(BuildContext context) {
    final channels =
        GroupChannelService.instance.cellChannelsFor(cell.id);
    final discussion = channels
        .where((c) => c.name.endsWith('-discussion'))
        .firstOrNull;

    if (discussion == null) {
      return _NoChannelPlaceholder(
        icon: Icons.forum_outlined,
        message: 'Diskussionskanal wird eingerichtet…\nBitte kurz warten.',
      );
    }

    return _CellChannelView(
      channel: discussion,
      canPost: true,
      emptyMessage: 'Noch keine Nachrichten.\nSchreib als Erste — sag der Zelle Hallo! 👋',
      emptyHelpContextId: 'cell_discussion',
    );
  }
}

// ── Tab 3: Agora ──────────────────────────────────────────────────────────────

class _AgoraTab extends StatelessWidget {
  final Cell cell;
  final bool isFounder;
  final bool isMod;

  const _AgoraTab({
    required this.cell,
    required this.isFounder,
    required this.isMod,
  });

  @override
  Widget build(BuildContext context) {
    final proposals = ProposalService.instance.proposalsForCell(cell.id);
    final canCreate = isFounder || isMod;

    return Scaffold(
      backgroundColor: AppColors.deepBlue,
      floatingActionButton: canCreate
          ? FloatingActionButton(
              mini: true,
              backgroundColor: AppColors.gold,
              foregroundColor: Colors.black,
              onPressed: () => Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute<void>(
                    builder: (_) => CreateProposalScreen(cell: cell)),
              ),
              child: const Icon(Icons.add),
            )
          : null,
      body: proposals.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.how_to_vote_outlined,
                      size: 48,
                      color: AppColors.onDark.withValues(alpha: 0.2)),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      'Noch keine Anträge. Anträge sind Vorschläge, '
                      'die du oder andere Mitglieder einbringen können. '
                      'Die Zelle stimmt dann gemeinsam darüber ab.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.onDark.withValues(alpha: 0.5),
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const HelpIcon(contextId: 'proposal_general', size: 20),
                  if (canCreate) ...[
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: () =>
                          Navigator.of(context, rootNavigator: true).push(
                        MaterialPageRoute<void>(
                            builder: (_) =>
                                CreateProposalScreen(cell: cell)),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.gold,
                        foregroundColor: Colors.black,
                      ),
                      icon: const Icon(Icons.add),
                      label: const Text('Ersten Antrag stellen'),
                    ),
                  ],
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: proposals.length,
              itemBuilder: (context, i) =>
                  _ProposalTile(proposal: proposals[i]),
            ),
    );
  }
}

class _ProposalTile extends StatelessWidget {
  final Proposal proposal;
  const _ProposalTile({required this.proposal});

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (proposal.status) {
      ProposalStatus.draft => AppColors.onDark,
      ProposalStatus.discussion => Colors.blue,
      ProposalStatus.voting => Colors.orange,
      ProposalStatus.decided => Colors.green,
      ProposalStatus.archived => AppColors.surfaceVariant,
    };
    final statusLabel = switch (proposal.status) {
      ProposalStatus.draft => 'Entwurf',
      ProposalStatus.discussion => 'Diskussion',
      ProposalStatus.voting => 'Abstimmung',
      ProposalStatus.decided => 'Entschieden',
      ProposalStatus.archived => 'Archiviert',
    };

    return InkWell(
      onTap: () => Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
            builder: (_) => ProposalDetailScreen(proposal: proposal)),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.surfaceVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(statusLabel,
                      style: TextStyle(
                          color: statusColor,
                          fontSize: 10,
                          fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              proposal.title,
              style: const TextStyle(
                  color: AppColors.onDark,
                  fontWeight: FontWeight.w600,
                  fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Tab 4: Mitglieder ─────────────────────────────────────────────────────────

class _MitgliederTab extends StatelessWidget {
  final Cell cell;
  final String myDid;

  const _MitgliederTab({required this.cell, required this.myDid});

  @override
  Widget build(BuildContext context) {
    final members = CellService.instance.membersOf(cell.id);
    final pendingRequests = CellService.instance
        .requestsFor(cell.id)
        .where((r) => r.isPending)
        .length;
    final myMembership =
        members.where((m) => m.did == myDid).firstOrNull;
    final isFounder = myMembership?.role == MemberRole.founder;
    final isMod = myMembership?.role == MemberRole.moderator;
    final canManage = isFounder || isMod;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (canManage && pendingRequests > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              leading: const Icon(Icons.person_add, color: Colors.orange),
              title: Text(
                'Offene Anfragen ($pendingRequests)',
                style: const TextStyle(color: AppColors.onDark),
              ),
              trailing: const Icon(Icons.chevron_right,
                  color: AppColors.surfaceVariant),
              tileColor: AppColors.surface,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              onTap: () =>
                  Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute<void>(
                  builder: (_) => CellRequestsScreen(
                      cellId: cell.id, cellName: cell.name),
                ),
              ),
            ),
          ),
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            'Mitglieder',
            style: TextStyle(
              color: AppColors.gold,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
        ),
        ...members.map((m) {
          return _SimpleMemberTile(
            member: m,
            isMe: m.did == myDid,
            canPromote: isFounder && m.role == MemberRole.member,
            onPromote: isFounder
                ? () async {
                    await CellService.instance
                        .promoteModerator(cell.id, m.did);
                  }
                : null,
          );
        }),
      ],
    );
  }
}

// ── Simple member tile ────────────────────────────────────────────────────────

class _SimpleMemberTile extends StatelessWidget {
  final CellMember member;
  final bool isMe;
  final bool canPromote;
  final VoidCallback? onPromote;

  const _SimpleMemberTile({
    required this.member,
    required this.isMe,
    required this.canPromote,
    this.onPromote,
  });

  @override
  Widget build(BuildContext context) {
    final roleLabel = switch (member.role) {
      MemberRole.founder => 'Gründer',
      MemberRole.moderator => 'Moderator',
      MemberRole.member => 'Mitglied',
      MemberRole.pending => 'Ausstehend',
    };
    final shortDid = isMe
        ? 'Du'
        : '…${member.did.substring(member.did.length > 12 ? member.did.length - 12 : 0)}';

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: AppColors.gold.withValues(alpha: 0.2),
            child: Text(
              member.did.substring(member.did.length - 2),
              style: const TextStyle(
                  color: AppColors.gold,
                  fontSize: 11,
                  fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  shortDid,
                  style: TextStyle(
                    color: isMe ? AppColors.gold : AppColors.onDark,
                    fontWeight: isMe ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                Text(
                  roleLabel,
                  style: TextStyle(
                    color: AppColors.onDark.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          if (canPromote)
            TextButton(
              onPressed: onPromote,
              child: const Text('Zum Moderator',
                  style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

// ── Placeholder when channels not yet loaded ──────────────────────────────────

class _NoChannelPlaceholder extends StatelessWidget {
  final IconData icon;
  final String message;

  const _NoChannelPlaceholder(
      {required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: AppColors.onDark.withValues(alpha: 0.2)),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.onDark.withValues(alpha: 0.4),
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
