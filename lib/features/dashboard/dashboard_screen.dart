import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/contacts/contact_service.dart';
import '../../core/identity/profile_service.dart';
import '../../services/contact_request_service.dart';
import '../contacts/contact_request.dart';
import '../../core/transport/message_transport.dart';
import '../../services/invite_service.dart';
import '../invite/invite_screen.dart';
import '../../services/principles_service.dart';
import '../../services/update_service.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/update_bottom_sheet.dart';
import '../chat/chat_provider.dart';
import '../chat/chat_screen.dart' show RadarScreen;
import '../chat/conversation.dart';
import '../chat/conversation_service.dart';
import '../chat/group_channel_service.dart';
import '../contacts/contacts_screen.dart';
import 'node_counter_service.dart';

// ── Top-level helpers (exported for testing) ─────────────────────────────────

/// Returns the correct German greeting for the given [hour] (0-23).
String dashboardGreeting(int hour) {
  if (hour < 12) return 'Guten Morgen';
  if (hour < 18) return 'Guten Tag';
  return 'Guten Abend';
}

/// Formats [date] as a German long date, e.g. "Samstag, 29. März 2026".
String dashboardFormattedDate(DateTime date) {
  const weekdays = [
    'Montag', 'Dienstag', 'Mittwoch', 'Donnerstag',
    'Freitag', 'Samstag', 'Sonntag',
  ];
  const months = [
    'Januar', 'Februar', 'März', 'April', 'Mai', 'Juni',
    'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember',
  ];
  return '${weekdays[date.weekday - 1]}, ${date.day}. '
      '${months[date.month - 1]} ${date.year}';
}

// ── DashboardScreen ───────────────────────────────────────────────────────────

/// The Home screen – the default start screen of the NEXUS OneApp.
///
/// Shows:
///  - A personalised greeting header.
///  - A mini radar card with live local and global node counts.
///  - Feature cards for Messages, Channels, Contacts, Governance.
///  - Coming-soon placeholder cards for Wallet and Marketplace.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _radarCtrl;

  List<Conversation> _conversations = [];
  StreamSubscription<List<Conversation>>? _convSub;

  int _nodeCount = 0;
  DateTime? _nodeCountUpdated;
  StreamSubscription<int>? _nodeCountSub;

  UpdateInfo? _updateInfo;
  StreamSubscription<UpdateInfo?>? _updateSub;

  StreamSubscription<List<ContactRequest>>? _requestSub;

  // Dismissed for this session only – reappears on next cold start.
  bool _principlesReminderDismissed = false;

  @override
  void initState() {
    super.initState();

    _radarCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    // Start peer discovery immediately so the radar shows live data from
    // the moment the app opens. ChatProvider.initialize() is idempotent —
    // calling it again from the Chat tab is a no-op.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<ChatProvider>().initialize();
    });

    _loadConversations();
    _convSub = ConversationService.instance.stream.listen((convs) {
      if (mounted) setState(() => _conversations = convs);
    });

    NodeCounterService.instance.init();
    _nodeCount = NodeCounterService.instance.count;
    _nodeCountUpdated = NodeCounterService.instance.lastUpdated;
    _nodeCountSub = NodeCounterService.instance.countStream.listen((count) {
      if (mounted) {
        setState(() {
          _nodeCount = count;
          _nodeCountUpdated = NodeCounterService.instance.lastUpdated;
        });
      }
    });

    // Show existing update info if already fetched in this session.
    _updateInfo = UpdateService.instance.current;
    _updateSub = UpdateService.instance.updateStream.listen((info) {
      if (mounted) setState(() => _updateInfo = info);
    });
    // Start background checks (respects 6-hour rate limit).
    UpdateService.instance.startPeriodicCheck();

    _requestSub = ContactRequestService.instance.stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadConversations() async {
    final convs = await ConversationService.instance.getConversations();
    if (mounted) setState(() => _conversations = convs);
  }

  @override
  void dispose() {
    _radarCtrl.dispose();
    _convSub?.cancel();
    _nodeCountSub?.cancel();
    _updateSub?.cancel();
    _requestSub?.cancel();
    super.dispose();
  }

  void _openRadar(BuildContext context) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => ChangeNotifierProvider.value(
          value: context.read<ChatProvider>(),
          child: const RadarScreen(),
        ),
      ),
    );
  }

  void _openContacts(BuildContext context) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => const ContactsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = ProfileService.instance.currentProfile;
    final pseudonym = profile?.pseudonym.value ?? 'Anonymus';
    final now = DateTime.now();
    final width = MediaQuery.sizeOf(context).width;
    final isDesktop = width >= 800;

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: _Header(
                greeting: dashboardGreeting(now.hour),
                pseudonym: pseudonym,
                date: dashboardFormattedDate(now),
              ),
            ),

            // Update banner – shown between header and radar when an update
            // is available. Disappears after "Later" or "Skip version".
            if (_updateInfo != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: _UpdateBanner(
                    info: _updateInfo!,
                    onTap: () => showUpdateBottomSheet(context, _updateInfo!),
                  ),
                ),
              ),

            // Principles reminder banner – shown when user skipped the flow.
            // Dismissed for the session via X, reappears on next cold start.
            if (!PrinciplesService.instance.isAccepted &&
                !_principlesReminderDismissed)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: _PrinciplesReminderBanner(
                    onReadNow: () => context.go('/principles/intro'),
                    onDismiss: () =>
                        setState(() => _principlesReminderDismissed = true),
                  ),
                ),
              ),

            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              sliver: SliverToBoxAdapter(
                child: Consumer<ChatProvider>(
                  builder: (context, chat, _) {
                    final localCount = chat.peers
                        .where((p) =>
                            p.transportType == TransportType.lan ||
                            p.transportType == TransportType.ble)
                        .length;
                    return _RadarCard(
                      radarCtrl: _radarCtrl,
                      localPeerCount: localCount,
                      totalPeerCount: chat.peers.length,
                      globalNodeCount: _nodeCount,
                      nodeCountUpdated: _nodeCountUpdated,
                      onTap: () => _openRadar(context),
                    );
                  },
                ),
              ),
            ),
            if (isDesktop)
              ..._buildDesktopSlivers(context)
            else
              ..._buildMobileSlivers(context),
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }

  // ── Layout helpers ─────────────────────────────────────────────────────────

  List<Widget> _buildMobileSlivers(BuildContext context) {
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        sliver: SliverList(
          delegate: SliverChildListDelegate([
            _buildMessagesCard(context),
            const SizedBox(height: 12),
            _buildChannelsCard(context),
            const SizedBox(height: 12),
            _buildContactsCard(context),
            const SizedBox(height: 12),
            _buildGovernanceCard(context),
            const SizedBox(height: 12),
            _buildInviteCard(context),
            const SizedBox(height: 16),
            _buildComingSoonRow(),
          ]),
        ),
      ),
    ];
  }

  List<Widget> _buildDesktopSlivers(BuildContext context) {
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 2.8,
          ),
          delegate: SliverChildListDelegate([
            _buildMessagesCard(context),
            _buildChannelsCard(context),
            _buildContactsCard(context),
            _buildGovernanceCard(context),
          ]),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        sliver: SliverToBoxAdapter(child: _buildComingSoonRow()),
      ),
    ];
  }

  // ── Feature cards ──────────────────────────────────────────────────────────

  Widget _buildMessagesCard(BuildContext context) {
    final dmConvs = _conversations.where((c) => !c.isGroup).toList();
    final unread = dmConvs.fold(0, (sum, c) => sum + c.unreadCount);
    final latest = dmConvs.isNotEmpty ? dmConvs.first : null;

    return _FeatureCard(
      key: const Key('messages_card'),
      icon: Icons.campaign,
      title: 'Nachrichten',
      subtitle: unread > 0 ? '$unread ungelesen' : 'Keine neuen Nachrichten',
      preview: latest != null
          ? '${latest.peerPseudonym}: ${latest.lastMessage}'
          : null,
      badgeCount: unread > 0 ? unread : null,
      onTap: () => context.go('/chat'),
    );
  }

  Widget _buildChannelsCard(BuildContext context) {
    final channelConvs = _conversations.where((c) => c.isGroup).toList();
    final unread = channelConvs.fold(0, (sum, c) => sum + c.unreadCount);
    final latest = channelConvs.isNotEmpty ? channelConvs.first : null;
    final privateCount = channelConvs.where((c) {
      return !(GroupChannelService.instance.findByName(c.id)?.isPublic ?? true);
    }).length;

    final subtitleParts = ['${channelConvs.length} aktive Kanäle'];
    if (privateCount > 0) subtitleParts.add('$privateCount privat');
    if (unread > 0) subtitleParts.add('$unread ungelesen');

    return _FeatureCard(
      key: const Key('channels_card'),
      icon: Icons.tag,
      title: 'Kanäle',
      subtitle: subtitleParts.join(', '),
      preview: latest != null
          ? '${latest.peerPseudonym}: ${latest.lastMessage}'
          : null,
      badgeCount: unread > 0 ? unread : null,
      onTap: () => context.go('/chat?tab=1'),
    );
  }

  Widget _buildContactsCard(BuildContext context) {
    final contacts = ContactService.instance.contacts;
    final requestCount = ContactRequestService.instance.pendingCount;
    return Consumer<ChatProvider>(
      builder: (context, chat, _) {
        final onlineCount = chat.peers
            .where((p) => contacts.any((c) => c.did == p.did))
            .length;
        final subtitleParts = ['${contacts.length} Kontakte'];
        if (onlineCount > 0) subtitleParts.add('$onlineCount online');
        if (requestCount > 0) {
          subtitleParts.add(
              '$requestCount Anfrage${requestCount == 1 ? '' : 'n'}');
        }
        return _FeatureCard(
          key: const Key('contacts_card'),
          icon: Icons.people_outline,
          title: 'Kontakte',
          subtitle: subtitleParts.join(', '),
          badgeCount: requestCount > 0 ? requestCount : null,
          onTap: () => _openContacts(context),
        );
      },
    );
  }

  Widget _buildGovernanceCard(BuildContext context) {
    return _FeatureCard(
      key: const Key('governance_card'),
      icon: Icons.how_to_vote_outlined,
      title: 'Governance',
      subtitle: 'Governance kommt bald',
      preview: 'Hier werdet ihr gemeinsam Entscheidungen treffen.',
      onTap: () => context.go('/governance'),
    );
  }

  Widget _buildInviteCard(BuildContext context) {
    final pendingCount = InviteService.instance.invites
        .where((r) => r.isPending)
        .length;
    return _FeatureCard(
      key: const Key('invite_card'),
      icon: Icons.person_add_outlined,
      title: 'Freunde einladen',
      subtitle: pendingCount > 0
          ? '$pendingCount Einladung${pendingCount == 1 ? '' : 'en'} ausstehend'
          : 'Lade Freunde zu N.E.X.U.S. ein',
      onTap: () => Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(builder: (_) => const _InviteScreenProxy()),
      ),
    );
  }

  Widget _buildComingSoonRow() {
    return Row(
      children: [
        Expanded(
          child: _ComingSoonCard(
            key: const Key('wallet_coming_soon'),
            icon: Icons.account_balance_wallet_outlined,
            label: 'Wallet',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _ComingSoonCard(
            key: const Key('marketplace_coming_soon'),
            icon: Icons.shopping_cart_outlined,
            label: 'Marktplatz',
          ),
        ),
      ],
    );
  }
}

// ── Widgets ───────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final String greeting;
  final String pseudonym;
  final String date;

  const _Header({
    required this.greeting,
    required this.pseudonym,
    required this.date,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$greeting, $pseudonym',
            style: const TextStyle(
              color: AppColors.gold,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            date,
            style: TextStyle(
              color: AppColors.onDark.withValues(alpha: 0.6),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Radar card ────────────────────────────────────────────────────────────────

class _RadarCard extends StatelessWidget {
  final AnimationController radarCtrl;
  final int localPeerCount;
  final int totalPeerCount;
  final int globalNodeCount;
  final DateTime? nodeCountUpdated;
  final VoidCallback onTap;

  const _RadarCard({
    required this.radarCtrl,
    required this.localPeerCount,
    required this.totalPeerCount,
    required this.globalNodeCount,
    required this.nodeCountUpdated,
    required this.onTap,
  });

  String _nodeCountLabel() {
    if (globalNodeCount == 0) return 'NEXUS-Netzwerk: –';
    if (nodeCountUpdated == null) return 'NEXUS-Netzwerk: $globalNodeCount Nodes';
    final ageMinutes =
        DateTime.now().difference(nodeCountUpdated!).inMinutes;
    if (ageMinutes > 60) {
      final hours = ageMinutes ~/ 60;
      return 'NEXUS-Netzwerk: $globalNodeCount Nodes (vor ${hours}h)';
    }
    return 'NEXUS-Netzwerk: $globalNodeCount Nodes';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 200,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.gold.withValues(alpha: 0.6), width: 1.5),
        ),
        child: Stack(
          children: [
            // Mini radar animation centred
            Center(
              child: AnimatedBuilder(
                animation: radarCtrl,
                builder: (_, __) => CustomPaint(
                  size: const Size(150, 150),
                  painter: _MiniRadarPainter(
                    progress: radarCtrl.value,
                    peerCount: totalPeerCount,
                  ),
                ),
              ),
            ),

            // Bottom row: local | global
            Positioned(
              left: 14,
              right: 14,
              bottom: 12,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _CountLabel(
                    icon: Icons.bluetooth,
                    label: 'Lokal: $localPeerCount Peers',
                  ),
                  _CountLabel(
                    icon: Icons.language,
                    label: _nodeCountLabel(),
                    alignRight: true,
                  ),
                ],
              ),
            ),

            // Tap hint in top-right corner
            Positioned(
              top: 10,
              right: 12,
              child: Icon(
                Icons.open_in_full,
                size: 16,
                color: AppColors.gold.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CountLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool alignRight;

  const _CountLabel({
    required this.icon,
    required this.label,
    this.alignRight = false,
  });

  @override
  Widget build(BuildContext context) {
    final children = [
      Icon(icon, size: 12, color: AppColors.gold.withValues(alpha: 0.8)),
      const SizedBox(width: 4),
      Text(
        label,
        style: TextStyle(
          color: AppColors.onDark.withValues(alpha: 0.8),
          fontSize: 11,
        ),
      ),
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: alignRight ? children.reversed.toList() : children,
    );
  }
}

// ── Mini radar painter ────────────────────────────────────────────────────────

class _MiniRadarPainter extends CustomPainter {
  final double progress;
  final int peerCount;

  const _MiniRadarPainter({required this.progress, required this.peerCount});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    // Concentric rings
    for (int i = 1; i <= 3; i++) {
      canvas.drawCircle(
        center,
        maxRadius * i / 3,
        Paint()
          ..color = AppColors.gold.withValues(alpha: 0.15)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }

    // Rotating sweep arc
    final sweepRect = Rect.fromCircle(center: center, radius: maxRadius);
    canvas.drawArc(
      sweepRect,
      progress * 2 * math.pi,
      0.4,
      true,
      Paint()
        ..shader = RadialGradient(
          colors: [
            AppColors.gold.withValues(alpha: 0.35),
            AppColors.gold.withValues(alpha: 0.0),
          ],
        ).createShader(sweepRect),
    );

    // Centre dot
    canvas.drawCircle(center, 4, Paint()..color = AppColors.gold);

    // Peer blips
    if (peerCount > 0) {
      final seed = peerCount.hashCode;
      final count = peerCount.clamp(0, 6);
      for (int i = 0; i < count; i++) {
        final angle = ((seed + i * 43758) % 628) / 100.0;
        final dist = maxRadius * (0.35 + (i * 0.13) % 0.5);
        final blipPos = Offset(
          center.dx + dist * math.sin(angle),
          center.dy + dist * math.cos(angle),
        );
        canvas.drawCircle(
          blipPos,
          3,
          Paint()..color = Colors.greenAccent.withValues(alpha: 0.9),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_MiniRadarPainter old) =>
      old.progress != progress || old.peerCount != peerCount;
}

// ── Update banner ─────────────────────────────────────────────────────────────

class _UpdateBanner extends StatelessWidget {
  final UpdateInfo info;
  final VoidCallback onTap;

  const _UpdateBanner({required this.info, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.gold.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: AppColors.gold.withValues(alpha: 0.5), width: 1.2),
        ),
        child: Row(
          children: [
            const Icon(Icons.system_update_outlined,
                color: AppColors.gold, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Update verfügbar: ${info.version}',
                style: const TextStyle(
                  color: AppColors.gold,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
            const Icon(Icons.chevron_right,
                color: AppColors.gold, size: 18),
          ],
        ),
      ),
    );
  }
}

// ── Principles reminder banner ────────────────────────────────────────────────

class _PrinciplesReminderBanner extends StatelessWidget {
  final VoidCallback onReadNow;
  final VoidCallback onDismiss;

  const _PrinciplesReminderBanner({
    required this.onReadNow,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: AppColors.gold.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.gold.withValues(alpha: 0.5),
          width: 1.2,
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.menu_book_outlined,
              color: AppColors.gold, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Du hast die Grundsätze noch nicht bestätigt',
                  style: TextStyle(
                    color: AppColors.gold,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                GestureDetector(
                  onTap: onReadNow,
                  child: const Text(
                    'Jetzt lesen',
                    style: TextStyle(
                      color: AppColors.goldLight,
                      fontSize: 12,
                      decoration: TextDecoration.underline,
                      decorationColor: AppColors.goldLight,
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('principles_banner_dismiss'),
            onPressed: onDismiss,
            icon: Icon(
              Icons.close,
              color: AppColors.gold.withValues(alpha: 0.6),
              size: 18,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}

// ── Feature card ──────────────────────────────────────────────────────────────

class _FeatureCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? preview;
  final int? badgeCount;
  final VoidCallback onTap;

  const _FeatureCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.preview,
    this.badgeCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              // Icon
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.gold.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: AppColors.gold, size: 22),
              ),
              const SizedBox(width: 14),

              // Text
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: AppColors.onDark,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: AppColors.onDark.withValues(alpha: 0.65),
                        fontSize: 12,
                      ),
                    ),
                    if (preview != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        preview!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.onDark.withValues(alpha: 0.45),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // Badge
              if (badgeCount != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.gold,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$badgeCount',
                    style: const TextStyle(
                      color: AppColors.deepBlue,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                )
              else
                const Icon(
                  Icons.chevron_right,
                  color: AppColors.gold,
                  size: 20,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Invite screen proxy ───────────────────────────────────────────────────────

/// Passes the current [ChatProvider] to [InviteScreen] when opened via
/// rootNavigator (which exits the widget tree above the Provider).
class _InviteScreenProxy extends StatelessWidget {
  const _InviteScreenProxy();

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: context.read<ChatProvider>(),
      child: const InviteScreen(),
    );
  }
}

// ── Coming-soon card ──────────────────────────────────────────────────────────

class _ComingSoonCard extends StatelessWidget {
  final IconData icon;
  final String label;

  const _ComingSoonCard({super.key, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.45,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: AppColors.onDark, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: AppColors.onDark,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Bald verfügbar',
                      style: TextStyle(
                        color: AppColors.onDark.withValues(alpha: 0.6),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'Bald',
                  style: TextStyle(color: AppColors.onDark, fontSize: 9),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
