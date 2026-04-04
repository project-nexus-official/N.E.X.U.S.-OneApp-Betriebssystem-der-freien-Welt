import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/identity/identity_service.dart';
import '../../core/utils/geohash.dart';
import '../../shared/theme/app_theme.dart';
import 'cell.dart';
import 'cell_member.dart';
import 'cell_service.dart';
import 'create_cell_screen.dart';
import 'cell_info_screen.dart';

/// The "Meine Zelle" hub – entry point to the cell system.
///
/// Shows the user's current cells and allows discovery / founding of new ones.
class CellHubScreen extends StatefulWidget {
  const CellHubScreen({super.key});

  @override
  State<CellHubScreen> createState() => _CellHubScreenState();
}

class _CellHubScreenState extends State<CellHubScreen> {
  StreamSubscription<void>? _sub;
  String _selectedCategory = 'Alle';

  String? _myGeohash;
  bool _gpsUnavailable = false;

  @override
  void initState() {
    super.initState();
    _sub = CellService.instance.stream.listen((_) {
      if (mounted) setState(() {});
    });
    _fetchMyGeohash();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _fetchMyGeohash() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) setState(() => _gpsUnavailable = true);
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) setState(() => _gpsUnavailable = true);
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 10),
      );
      if (mounted) {
        setState(() => _myGeohash = encodeGeohash(pos.latitude, pos.longitude));
      }
    } catch (_) {
      if (mounted) setState(() => _gpsUnavailable = true);
    }
  }

  void _openCreate() {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => const CreateCellScreen()),
    );
  }

  void _openCell(Cell cell) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => CellInfoScreen(cell: cell)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final myCells = CellService.instance.myCells;
    final discovered = CellService.instance.discoveredCells;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Meine Zelle'),
        backgroundColor: AppColors.deepBlue,
      ),
      backgroundColor: AppColors.deepBlue,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreate,
        backgroundColor: AppColors.gold,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add),
        label: const Text('Zelle gründen'),
      ),
      body: myCells.isEmpty
          ? _EmptyState(
              onCreateTap: _openCreate,
              myGeohash: _myGeohash,
              gpsUnavailable: _gpsUnavailable,
            )
          : _FilledState(
              myCells: myCells,
              discovered: discovered,
              selectedCategory: _selectedCategory,
              onCategoryChanged: (cat) =>
                  setState(() => _selectedCategory = cat),
              onCellTap: _openCell,
              onCreateTap: _openCreate,
              myGeohash: _myGeohash,
              gpsUnavailable: _gpsUnavailable,
            ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final VoidCallback onCreateTap;
  final String? myGeohash;
  final bool gpsUnavailable;
  const _EmptyState({
    required this.onCreateTap,
    required this.myGeohash,
    required this.gpsUnavailable,
  });

  @override
  Widget build(BuildContext context) {
    final discovered = CellService.instance.discoveredCells;
    final nearby = _nearbyCells(discovered, myGeohash);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Finde deine Gemeinschaft',
                  style: TextStyle(
                    color: AppColors.gold,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Eine Zelle ist eine Gemeinschaft von bis zu 150 Menschen. '
                  'Lokal in deiner Nachbarschaft oder thematisch mit '
                  'Gleichgesinnten weltweit.',
                  style: TextStyle(
                    color: AppColors.onDark.withValues(alpha: 0.7),
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),

        // Nearby section
        _NearbySection(
          nearbyCells: nearby,
          myGeohash: myGeohash,
          gpsUnavailable: gpsUnavailable,
        ),

        if (discovered.isNotEmpty) ...[
          _SectionHeader(title: 'Entdeckte Zellen'),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => _DiscoveredCellTile(cell: discovered[i]),
              childCount: discovered.length,
            ),
          ),
        ],
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: onCreateTap,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.gold,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.add),
                    label: const Text('Zelle gründen',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }
}

// ── Filled state (user is in at least one cell) ───────────────────────────────

class _FilledState extends StatelessWidget {
  final List<Cell> myCells;
  final List<Cell> discovered;
  final String selectedCategory;
  final ValueChanged<String> onCategoryChanged;
  final ValueChanged<Cell> onCellTap;
  final VoidCallback onCreateTap;
  final String? myGeohash;
  final bool gpsUnavailable;

  const _FilledState({
    required this.myCells,
    required this.discovered,
    required this.selectedCategory,
    required this.onCategoryChanged,
    required this.onCellTap,
    required this.onCreateTap,
    required this.myGeohash,
    required this.gpsUnavailable,
  });

  @override
  Widget build(BuildContext context) {
    final allCategories = ['Alle', ...cellCategories];
    final nearby = _nearbyCells(discovered, myGeohash);
    final filtered = selectedCategory == 'Alle'
        ? discovered
        : discovered.where((c) => c.category == selectedCategory).toList();

    return CustomScrollView(
      slivers: [
        // My cells section
        _SectionHeader(title: 'Meine Zellen'),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) => _MyCellTile(
              cell: myCells[i],
              onTap: () => onCellTap(myCells[i]),
            ),
            childCount: myCells.length,
          ),
        ),

        // Nearby section
        _NearbySection(
          nearbyCells: nearby,
          myGeohash: myGeohash,
          gpsUnavailable: gpsUnavailable,
        ),

        // Discovery section header
        _SectionHeader(title: 'Weitere Zellen entdecken'),

        // Category filter chips
        SliverToBoxAdapter(
          child: SizedBox(
            height: 44,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: allCategories.length,
              itemBuilder: (context, i) {
                final cat = allCategories[i];
                final selected = cat == selectedCategory;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(cat),
                    selected: selected,
                    onSelected: (_) => onCategoryChanged(cat),
                    selectedColor: AppColors.gold,
                    labelStyle: TextStyle(
                      color: selected ? Colors.black : AppColors.onDark,
                      fontWeight: FontWeight.w600,
                    ),
                    backgroundColor: AppColors.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: BorderSide(
                        color: selected
                            ? AppColors.gold
                            : AppColors.surfaceVariant,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 8)),

        // Discovered cells list
        if (filtered.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Keine Zellen in dieser Kategorie entdeckt.',
                style: TextStyle(
                  color: AppColors.onDark.withValues(alpha: 0.5),
                ),
                textAlign: TextAlign.center,
              ),
            ),
          )
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => _DiscoveredCellTile(cell: filtered[i]),
              childCount: filtered.length,
            ),
          ),

        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }
}

// ── Nearby helpers ────────────────────────────────────────────────────────────

/// Returns local cells sorted by geohash proximity.
/// A common prefix of ≥4 characters (≈40 km) is considered "nearby".
List<Cell> _nearbyCells(List<Cell> all, String? myGeohash) {
  if (myGeohash == null) return [];
  final local = all.where((c) =>
      c.cellType == CellType.local &&
      c.geohash != null &&
      geohashCommonPrefixLength(c.geohash!, myGeohash) >= 4);
  final sorted = local.toList()
    ..sort((a, b) {
      final pa = geohashCommonPrefixLength(a.geohash!, myGeohash);
      final pb = geohashCommonPrefixLength(b.geohash!, myGeohash);
      return pb.compareTo(pa); // longer prefix first = closer
    });
  return sorted;
}

class _NearbySection extends StatelessWidget {
  final List<Cell> nearbyCells;
  final String? myGeohash;
  final bool gpsUnavailable;

  const _NearbySection({
    required this.nearbyCells,
    required this.myGeohash,
    required this.gpsUnavailable,
  });

  @override
  Widget build(BuildContext context) {
    if (gpsUnavailable && myGeohash == null) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.location_off,
                  color: Colors.grey, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Aktiviere GPS um Zellen in deiner Nähe zu finden.',
                  style: TextStyle(
                    color: AppColors.onDark.withValues(alpha: 0.5),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (myGeohash == null) {
      // Still loading GPS
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    if (nearbyCells.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    return SliverMainAxisGroup(
      slivers: [
        _SectionHeader(title: 'Zellen in deiner Nähe'),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) => _DiscoveredCellTile(cell: nearbyCells[i]),
            childCount: nearbyCells.length,
          ),
        ),
      ],
    );
  }
}

// ── Shared widgets ────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 16,
              decoration: BoxDecoration(
                color: AppColors.gold,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(
                color: AppColors.gold,
                fontWeight: FontWeight.bold,
                fontSize: 13,
                letterSpacing: 1.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MyCellTile extends StatelessWidget {
  final Cell cell;
  final VoidCallback onTap;

  const _MyCellTile({required this.cell, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final myDid = IdentityService.instance.currentIdentity?.did;
    final members = CellService.instance.membersOf(cell.id);
    final myMembership =
        members.where((m) => m.did == myDid).firstOrNull;
    final role = myMembership?.role ?? MemberRole.member;
    final pendingCount = CellService.instance
        .requestsFor(cell.id)
        .where((r) => r.isPending)
        .length;

    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.gold.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            _CellTypeIcon(type: cell.cellType),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          cell.name,
                          style: const TextStyle(
                            color: AppColors.onDark,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (cell.isNew)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.gold.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'Neu',
                            style: TextStyle(
                              color: AppColors.gold,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _RoleBadge(role: role),
                      const SizedBox(width: 8),
                      Text(
                        '${cell.memberCount}/${cell.maxMembers} Mitglieder',
                        style: TextStyle(
                          color: AppColors.onDark.withValues(alpha: 0.6),
                          fontSize: 12,
                        ),
                      ),
                      if (pendingCount > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '$pendingCount Anfrage${pendingCount == 1 ? '' : 'n'}',
                            style: const TextStyle(
                              color: Colors.orange,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.surfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _DiscoveredCellTile extends StatelessWidget {
  final Cell cell;
  const _DiscoveredCellTile({required this.cell});

  @override
  Widget build(BuildContext context) {
    final alreadyMember = CellService.instance.isMember(cell.id);
    final applied = CellService.instance.hasAppliedTo(cell.id);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surfaceVariant),
      ),
      child: Row(
        children: [
          _CellTypeIcon(type: cell.cellType),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cell.name,
                  style: const TextStyle(
                    color: AppColors.onDark,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  cell.cellType == CellType.local
                      ? (cell.locationName ?? 'Lokale Gemeinschaft')
                      : (cell.category ?? 'Thematische Gemeinschaft'),
                  style: TextStyle(
                    color: AppColors.onDark.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${cell.memberCount}/${cell.maxMembers} Mitglieder · '
                  '${cell.joinPolicy == JoinPolicy.approvalRequired ? 'Beitritt anfragen' : 'Nur auf Einladung'}',
                  style: TextStyle(
                    color: AppColors.onDark.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          if (alreadyMember)
            const Icon(Icons.check_circle, color: Colors.green, size: 20)
          else if (applied)
            Text(
              'Angefragt ⏳',
              style: TextStyle(color: AppColors.gold, fontSize: 12),
            )
          else if (cell.joinPolicy == JoinPolicy.approvalRequired &&
              !cell.isFull)
            TextButton(
              onPressed: () => _showJoinSheet(context, cell),
              child: const Text('Anfragen'),
            ),
        ],
      ),
    );
  }

  void _showJoinSheet(BuildContext context, Cell cell) {
    final msgCtrl = TextEditingController();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Beitritt anfragen: ${cell.name}',
              style: const TextStyle(
                color: AppColors.onDark,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: msgCtrl,
              decoration: InputDecoration(
                hintText: 'Warum möchtest du beitreten? (empfohlen)',
                hintStyle:
                    TextStyle(color: AppColors.onDark.withValues(alpha: 0.5)),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.surfaceVariant),
                ),
                filled: true,
                fillColor: AppColors.deepBlue,
              ),
              style: const TextStyle(color: AppColors.onDark),
              maxLines: 3,
              maxLength: 500,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  await CellService.instance.sendJoinRequest(
                    cell,
                    message: msgCtrl.text.trim().isEmpty
                        ? null
                        : msgCtrl.text.trim(),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Anfrage an ${cell.name} gesendet.'),
                        backgroundColor: AppColors.gold,
                      ),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.gold,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text('Anfrage senden'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Small reusable widgets ────────────────────────────────────────────────────

class _CellTypeIcon extends StatelessWidget {
  final CellType type;
  const _CellTypeIcon({required this.type});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: AppColors.gold.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(
        type == CellType.local ? Icons.location_on : Icons.group_work,
        color: AppColors.gold,
        size: 22,
      ),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  final MemberRole role;
  const _RoleBadge({required this.role});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (role) {
      MemberRole.founder => ('Gründer', AppColors.gold),
      MemberRole.moderator => ('Moderator', Colors.blue),
      MemberRole.member => ('Mitglied', Colors.green),
      MemberRole.pending => ('Ausstehend', Colors.orange),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
