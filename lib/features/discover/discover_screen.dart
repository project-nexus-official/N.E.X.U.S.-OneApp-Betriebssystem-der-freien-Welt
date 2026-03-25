import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:nexus_oneapp/shared/theme/app_theme.dart';

/// A single entry in the Entdecken grid.
class _TileItem {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String? route; // null = coming soon
  final String? comingSoonPhase;

  const _TileItem({
    required this.icon,
    required this.iconColor,
    required this.label,
    this.route,
    this.comingSoonPhase,
  });

  bool get isActive => route != null;
}

const _mainTiles = <_TileItem>[
  _TileItem(
    icon: Icons.shopping_cart,
    iconColor: Color(0xFFFF9800),
    label: 'Marktplatz',
    comingSoonPhase: 'Phase 1c',
  ),
  _TileItem(
    icon: Icons.handshake,
    iconColor: Color(0xFF4CAF50),
    label: 'Care',
    comingSoonPhase: 'Phase 2',
  ),
  _TileItem(
    icon: Icons.how_to_vote,
    iconColor: AppColors.gold,
    label: 'Agora – Politik',
    route: '/governance',
  ),
  _TileItem(
    icon: Icons.campaign,
    iconColor: Color(0xFF9C27B0),
    label: 'Schwarzes Brett',
    comingSoonPhase: 'Phase 1a',
  ),
  _TileItem(
    icon: Icons.group_work,
    iconColor: Color(0xFF00BCD4),
    label: 'Meine Zelle',
    comingSoonPhase: 'Phase 2',
  ),
  _TileItem(
    icon: Icons.settings,
    iconColor: AppColors.onDark,
    label: 'Einstellungen',
    route: '/settings',
  ),
];

const _sphaereTiles = <_TileItem>[
  _TileItem(
    icon: Icons.medical_services,
    iconColor: Color(0xFFF44336),
    label: 'Asklepios\nGesundheit',
    comingSoonPhase: 'Phase 3',
  ),
  _TileItem(
    icon: Icons.school,
    iconColor: Color(0xFF2196F3),
    label: 'Paideia\nBildung',
    comingSoonPhase: 'Phase 3',
  ),
  _TileItem(
    icon: Icons.eco,
    iconColor: Color(0xFF8BC34A),
    label: 'Demeter\nErnährung',
    comingSoonPhase: 'Phase 3',
  ),
  _TileItem(
    icon: Icons.home,
    iconColor: Color(0xFFFF5722),
    label: 'Hestia\nWohnen',
    comingSoonPhase: 'Phase 3',
  ),
];

/// The Entdecken hub – a tile grid giving access to all app areas and sphären.
class DiscoverScreen extends StatelessWidget {
  const DiscoverScreen({super.key});

  void _onTileTap(BuildContext context, _TileItem tile) {
    if (!tile.isActive) return;
    if (tile.route == '/settings') {
      context.push('/settings');
      return;
    }
    context.go(tile.route!);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Entdecken')),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            sliver: SliverGrid(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _DiscoverTile(
                  tile: _mainTiles[index],
                  onTap: () => _onTileTap(context, _mainTiles[index]),
                ),
                childCount: _mainTiles.length,
              ),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 1.4,
              ),
            ),
          ),
          // "Sphären" section header
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Container(
                    width: 3,
                    height: 18,
                    decoration: BoxDecoration(
                      color: AppColors.gold,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Sphären',
                    style: TextStyle(
                      color: AppColors.gold,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: SliverGrid(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _DiscoverTile(
                  tile: _sphaereTiles[index],
                  onTap: () => _onTileTap(context, _sphaereTiles[index]),
                ),
                childCount: _sphaereTiles.length,
              ),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiscoverTile extends StatelessWidget {
  final _TileItem tile;
  final VoidCallback onTap;

  const _DiscoverTile({required this.tile, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isActive = tile.isActive;

    return Opacity(
      opacity: isActive ? 1.0 : 0.55,
      child: GestureDetector(
        onTap: isActive ? onTap : null,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isActive ? AppColors.gold : AppColors.surfaceVariant,
              width: isActive ? 1.5 : 1,
            ),
          ),
          padding: const EdgeInsets.all(12),
          child: Stack(
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(tile.icon, color: tile.iconColor, size: 32),
                  const SizedBox(height: 8),
                  Text(
                    tile.label,
                    style: const TextStyle(
                      color: AppColors.onDark,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
              if (!isActive && tile.comingSoonPhase != null)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceVariant,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      tile.comingSoonPhase!,
                      style: const TextStyle(
                        color: AppColors.onDark,
                        fontSize: 9,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
