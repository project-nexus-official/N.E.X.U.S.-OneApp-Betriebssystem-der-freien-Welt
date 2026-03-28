import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/contacts/contact.dart';
import '../../core/contacts/contact_service.dart';
import '../../core/transport/message_transport.dart';
import '../../core/transport/nexus_peer.dart';
import '../../shared/theme/app_theme.dart';
import '../contacts/widgets/trust_badge.dart';
import 'chat_provider.dart';
import 'conversation_screen.dart';

/// Standalone peer-discovery screen opened from the conversations inbox FAB.
///
/// Shows the animated radar and a live peer list. Tapping a peer opens (or
/// creates) the corresponding direct conversation.
class RadarScreen extends StatefulWidget {
  const RadarScreen({super.key});

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatProvider>().initialize();
    });
  }

  void _showAddPeerDialog(BuildContext context, ChatProvider provider) {
    final ctrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Gerät per IP verbinden',
          style: TextStyle(color: AppColors.gold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Gib die IP-Adresse des anderen Geräts ein.\n'
              'Nutze dies wenn der Status-Punkt gelb bleibt '
              '(z. B. Windows-Firewall blockiert UDP-Broadcast).',
              style: TextStyle(
                  color: AppColors.onDark, fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: AppColors.onDark),
              decoration: InputDecoration(
                hintText: '192.168.1.42',
                hintStyle:
                    TextStyle(color: AppColors.onDark.withValues(alpha: 0.4)),
                filled: true,
                fillColor: AppColors.surfaceVariant,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child:
                const Text('Abbrechen', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.gold,
              foregroundColor: AppColors.deepBlue,
            ),
            onPressed: () {
              final ip = ctrl.text.trim();
              if (ip.isNotEmpty) {
                provider.addLanPeer(ip);
                Navigator.of(ctx).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Verbindungsversuch zu $ip gestartet…'),
                    duration: const Duration(seconds: 3),
                  ),
                );
              }
            },
            child: const Text('Verbinden'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Peers entdecken'),
        actions: [
          Consumer<ChatProvider>(
            builder: (context, provider, _) => IconButton(
              icon: const Icon(Icons.add_link, size: 22),
              tooltip: 'Gerät per IP verbinden',
              onPressed: () => _showAddPeerDialog(context, provider),
            ),
          ),
          Consumer<ChatProvider>(
            builder: (context, provider, _) => _MeshStatusDot(
              running: provider.running,
              hasPeers: provider.peers.isNotEmpty,
            ),
          ),
        ],
      ),
      body: Consumer<ChatProvider>(
        builder: (context, provider, _) {
          if (!provider.initialized) return const _LoadingBody();
          if (!provider.permissionsGranted) {
            return _PermissionDeniedBody(onRetry: provider.initialize);
          }
          if (provider.error != null && !provider.running) {
            return _ErrorBody(
              error: provider.error!,
              onRetry: provider.initialize,
            );
          }
          return _ChatBody(provider: provider);
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Legacy entry point kept for compatibility. Prefer [RadarScreen].
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatProvider>().initialize();
    });
  }

  void _showAddPeerDialog(BuildContext context, ChatProvider provider) {
    final ctrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Gerät per IP verbinden',
          style: TextStyle(color: AppColors.gold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Gib die IP-Adresse des anderen Geräts ein.\n'
              'Nutze dies wenn der Status-Punkt gelb bleibt '
              '(z. B. Windows-Firewall blockiert UDP-Broadcast).',
              style: TextStyle(color: AppColors.onDark, fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: AppColors.onDark),
              decoration: InputDecoration(
                hintText: '192.168.1.42',
                hintStyle: TextStyle(
                    color: AppColors.onDark.withValues(alpha: 0.4)),
                filled: true,
                fillColor: AppColors.surfaceVariant,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Abbrechen',
                style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.gold,
              foregroundColor: AppColors.deepBlue,
            ),
            onPressed: () {
              final ip = ctrl.text.trim();
              if (ip.isNotEmpty) {
                provider.addLanPeer(ip);
                Navigator.of(ctx).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                        'Verbindungsversuch zu $ip gestartet…'),
                    duration: const Duration(seconds: 3),
                  ),
                );
              }
            },
            child: const Text('Verbinden'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NEXUS Mesh'),
        actions: [
          Consumer<ChatProvider>(
            builder: (context, provider, _) => IconButton(
              icon: const Icon(Icons.add_link, size: 22),
              tooltip: 'Gerät per IP verbinden',
              onPressed: () => _showAddPeerDialog(context, provider),
            ),
          ),
          Consumer<ChatProvider>(
            builder: (context, provider, _) => _MeshStatusDot(
              running: provider.running,
              hasPeers: provider.peers.isNotEmpty,
            ),
          ),
        ],
      ),
      body: Consumer<ChatProvider>(
        builder: (context, provider, _) {
          if (!provider.initialized) {
            return const _LoadingBody();
          }
          if (!provider.permissionsGranted) {
            return _PermissionDeniedBody(onRetry: provider.initialize);
          }
          if (provider.error != null && !provider.running) {
            return _ErrorBody(
              error: provider.error!,
              onRetry: provider.initialize,
            );
          }
          return _ChatBody(provider: provider);
        },
      ),
    );
  }
}

// ── Sub-widgets ──────────────────────────────────────────────────────────────

class _LoadingBody extends StatelessWidget {
  const _LoadingBody();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Initialisiere Mesh…'),
        ],
      ),
    );
  }
}

class _PermissionDeniedBody extends StatelessWidget {
  const _PermissionDeniedBody({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bluetooth_disabled, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'Bluetooth-Berechtigung benötigt',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Android benötigt Standort-Berechtigung für BLE-Scanning. '
              'Deine Daten verlassen das Gerät niemals.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Erneut versuchen'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.redAccent),
            const SizedBox(height: 16),
            Text(error, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: onRetry, child: const Text('Nochmal')),
          ],
        ),
      ),
    );
  }
}

class _ChatBody extends StatelessWidget {
  const _ChatBody({required this.provider});
  final ChatProvider provider;

  @override
  Widget build(BuildContext context) {
    final peers = provider.peers;

    // Responsive: cap width on wide screens (desktop)
    return LayoutBuilder(
      builder: (context, constraints) {
        final inner = Column(
          children: [
            // Radar section
            SizedBox(
              height: 220,
              child: _RadarWidget(peerCount: peers.length),
            ),

            // Divider + heading
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.people, size: 16, color: AppColors.gold),
                  const SizedBox(width: 6),
                  Text(
                    peers.isEmpty
                        ? 'Suche nach Peers…'
                        : '${peers.length} Peer${peers.length == 1 ? '' : 's'} in Reichweite',
                    style: const TextStyle(
                      color: AppColors.gold,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),

            const Divider(height: 1, color: AppColors.surfaceVariant),

            // Peer list: local peers, then Nostr peers in a separate section
            Expanded(
              child: peers.isEmpty
                  ? const _EmptyPeerList()
                  : _PeerListWithNostr(peers: peers, provider: provider),
            ),
          ],
        );

        if (constraints.maxWidth > 640) {
          // Desktop: center and cap width
          return Center(
            child: SizedBox(width: 620, child: inner),
          );
        }
        return inner;
      },
    );
  }
}

/// Peer list split into local (BLE/LAN) and Nostr sections.
/// Blocked peers are filtered out automatically.
class _PeerListWithNostr extends StatelessWidget {
  const _PeerListWithNostr({required this.peers, required this.provider});
  final List<NexusPeer> peers;
  final ChatProvider provider;

  @override
  Widget build(BuildContext context) {
    final cs = ContactService.instance;
    final visible = peers.where((p) => !cs.isBlocked(p.did)).toList();

    final local = visible
        .where((p) =>
            p.transportType == TransportType.lan ||
            p.transportType == TransportType.ble)
        .toList();
    final nostrOnly = visible
        .where((p) =>
            p.transportType == TransportType.nostr &&
            !local.any((l) => l.did == p.did))
        .toList();

    return ListView(
      children: [
        if (local.isNotEmpty) ...[
          ...local.map((p) => _PeerTile(peer: p, provider: provider)),
        ],
        if (nostrOnly.isNotEmpty) ...[
          const _SectionDivider(label: 'Online im NEXUS-Netzwerk'),
          ...nostrOnly.map((p) => _PeerTile(peer: p, provider: provider)),
        ],
      ],
    );
  }
}

class _SectionDivider extends StatelessWidget {
  const _SectionDivider({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          const Icon(Icons.language, size: 14, color: Colors.blueAccent),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.blueAccent,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyPeerList extends StatelessWidget {
  const _EmptyPeerList();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'Keine NEXUS-Nodes im Netzwerk.\n'
          'Starte die App auf einem anderen Gerät im selben Netzwerk.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      ),
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer, required this.provider});
  final NexusPeer peer;
  final ChatProvider provider;

  @override
  Widget build(BuildContext context) {
    final contact = ContactService.instance.findByDid(peer.did);
    final displayName = contact?.pseudonym ?? peer.pseudonym;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: AppColors.surfaceVariant,
        child: Text(
          displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
          style: const TextStyle(color: AppColors.gold),
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              displayName,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (contact != null) ...[
            const SizedBox(width: 6),
            TrustBadge(level: contact.trustLevel, small: true),
          ],
        ],
      ),
      subtitle: _TransportBadges(transports: peer.availableTransports),
      trailing: _SignalIndicator(peer: peer),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChangeNotifierProvider.value(
            value: provider,
            child: ConversationScreen(
              peerDid: peer.did,
              peerPseudonym: displayName,
              peer: peer,
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows one icon per transport type the peer is reachable on.
class _TransportBadges extends StatelessWidget {
  const _TransportBadges({required this.transports});
  final Set<TransportType> transports;

  @override
  Widget build(BuildContext context) {
    final icons = transports.map(_iconFor).toList();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: icons
          .expand((icon) => [icon, const SizedBox(width: 4)])
          .toList()
        ..removeLast(),
    );
  }

  Widget _iconFor(TransportType t) {
    return switch (t) {
      TransportType.ble =>
        const Icon(Icons.bluetooth, size: 14, color: Colors.lightBlueAccent),
      TransportType.lan =>
        const Icon(Icons.wifi, size: 14, color: Colors.greenAccent),
      TransportType.nostr =>
        const Icon(Icons.language, size: 14, color: Colors.blueAccent),
      _ => const Icon(Icons.cloud_queue, size: 14, color: Colors.grey),
    };
  }
}

class _SignalIndicator extends StatelessWidget {
  const _SignalIndicator({required this.peer});
  final NexusPeer peer;

  @override
  Widget build(BuildContext context) {
    final color = _signalColor(peer.signalLevel);
    final icon = _signalIcon(peer.signalLevel, peer.transportType);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 4),
        Text(
          peer.signalLabel,
          style: TextStyle(color: color, fontSize: 12),
        ),
      ],
    );
  }

  Color _signalColor(SignalLevel level) {
    return switch (level) {
      SignalLevel.excellent => Colors.greenAccent,
      SignalLevel.good => Colors.lightGreen,
      SignalLevel.fair => Colors.amber,
      SignalLevel.poor => Colors.redAccent,
      SignalLevel.unknown => Colors.grey,
    };
  }

  IconData _signalIcon(SignalLevel level, TransportType primary) {
    if (primary == TransportType.lan) return Icons.wifi;
    if (primary == TransportType.nostr) return Icons.language;
    return switch (level) {
      SignalLevel.excellent || SignalLevel.good => Icons.bluetooth_connected,
      SignalLevel.fair => Icons.bluetooth_searching,
      SignalLevel.poor => Icons.bluetooth_disabled,
      SignalLevel.unknown => Icons.cloud_queue,
    };
  }
}

// ── Radar animation ──────────────────────────────────────────────────────────

class _RadarWidget extends StatefulWidget {
  const _RadarWidget({required this.peerCount});
  final int peerCount;

  @override
  State<_RadarWidget> createState() => _RadarWidgetState();
}

class _RadarWidgetState extends State<_RadarWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, child) {
          return CustomPaint(
            size: const Size(180, 180),
            painter: _RadarPainter(
              progress: _ctrl.value,
              peerCount: widget.peerCount,
            ),
          );
        },
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({required this.progress, required this.peerCount});
  final double progress;
  final int peerCount;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    // Draw 3 concentric circles
    for (int i = 1; i <= 3; i++) {
      final r = maxRadius * i / 3;
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..color = AppColors.gold.withValues(alpha: 0.15)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }

    // Draw rotating sweep arc
    final sweepRect = Rect.fromCircle(center: center, radius: maxRadius);
    const sweepAngle = 0.4; // radians

    canvas.drawArc(
      sweepRect,
      progress * 2 * 3.14159,
      sweepAngle,
      true,
      Paint()
        ..shader = RadialGradient(
          colors: [
            AppColors.gold.withValues(alpha: 0.35),
            AppColors.gold.withValues(alpha: 0.0),
          ],
        ).createShader(sweepRect),
    );

    // Draw center dot
    canvas.drawCircle(center, 5, Paint()..color = AppColors.gold);

    // Draw peer blips (if any)
    if (peerCount > 0) {
      final rng = peerCount.hashCode;
      for (int i = 0; i < peerCount.clamp(0, 6); i++) {
        final angle = (rng + i * 43758) % 628 / 100.0;
        final dist = maxRadius * (0.35 + (i * 0.13) % 0.5);
        final blipPos = Offset(
          center.dx + dist * (angle.remainder(6.28)).sin(),
          center.dy + dist * (angle.remainder(6.28)).cos(),
        );
        canvas.drawCircle(
          blipPos,
          4,
          Paint()..color = Colors.greenAccent.withValues(alpha: 0.9),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_RadarPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.peerCount != peerCount;
}

// Extension for angle trig without import
extension on double {
  double sin() => _sin(this);
  double cos() => _cos(this);

  static double _sin(double x) {
    double result = 0;
    double term = x;
    for (int i = 1; i <= 10; i++) {
      result += term;
      term *= -x * x / ((2 * i) * (2 * i + 1));
    }
    return result;
  }

  static double _cos(double x) {
    double result = 1;
    double term = 1;
    for (int i = 1; i <= 10; i++) {
      term *= -x * x / ((2 * i - 1) * (2 * i));
      result += term;
    }
    return result;
  }
}

// ── Mesh status dot (AppBar) ──────────────────────────────────────────────────

/// Three-state connection indicator:
///   green  = running AND at least one peer found
///   yellow = running but no peers yet
///   red    = no transport active
class _MeshStatusDot extends StatelessWidget {
  const _MeshStatusDot({required this.running, required this.hasPeers});
  final bool running;
  final bool hasPeers;

  @override
  Widget build(BuildContext context) {
    final color = !running
        ? Colors.redAccent
        : hasPeers
            ? Colors.greenAccent
            : Colors.amber;

    return Padding(
      padding: const EdgeInsets.only(right: 14),
      child: Center(
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
