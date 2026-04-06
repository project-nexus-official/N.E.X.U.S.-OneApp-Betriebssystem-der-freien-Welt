import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/contacts/contact_service.dart';
import '../../core/config/system_config.dart';
import '../../core/identity/identity_service.dart';
import '../../core/roles/permission_helper.dart';
import '../../core/utils/geohash.dart';
import '../../shared/theme/app_theme.dart';
import '../chat/conversation_screen.dart';
import 'cell.dart';
import 'cell_member.dart';
import 'cell_service.dart';
import 'create_cell_screen.dart';
import 'cell_screen.dart';

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
      MaterialPageRoute<void>(builder: (_) => CellScreen(cell: cell)),
    );
  }

  void _requestCellCreation(BuildContext context) {
    final superadminDid = SystemConfig.instance.superadminDid;
    if (superadminDid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Kontaktiere einen Admin über den Chat, um eine Zelle zu gründen.'),
          backgroundColor: Colors.blueGrey,
        ),
      );
      return;
    }
    final myPseudonym =
        IdentityService.instance.currentIdentity?.pseudonym ?? '';
    final adminName =
        ContactService.instance.getDisplayName(superadminDid);
    final prefill =
        'Hallo, ich möchte eine Zelle gründen. Kannst du mir dabei helfen? '
        '(Anfrage von $myPseudonym)';
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => ConversationScreen(
          peerDid: superadminDid,
          peerPseudonym: adminName,
          initialDraftText: prefill,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final myCells = CellService.instance.myCells;
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final canCreate = PermissionHelper.canCreateCell(myDid);

    // All known cells for discovery (joined + nostr-discovered), de-duplicated.
    final allKnown = CellService.instance.allKnownCells;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Meine Zellen'),
        backgroundColor: AppColors.deepBlue,
      ),
      backgroundColor: AppColors.deepBlue,
      floatingActionButton: canCreate
          ? FloatingActionButton.extended(
              onPressed: _openCreate,
              backgroundColor: AppColors.gold,
              foregroundColor: Colors.black,
              icon: const Icon(Icons.add),
              label: const Text('Zelle gründen'),
            )
          : FloatingActionButton.extended(
              onPressed: () => _requestCellCreation(context),
              backgroundColor: AppColors.surface,
              foregroundColor: AppColors.gold,
              icon: const Icon(Icons.mail_outline),
              label: const Text('Zellgründung anfragen'),
            ),
      body: myCells.isEmpty
          ? _EmptyState(
              onCreateTap: canCreate ? _openCreate : null,
              onRequestCreate: () => _requestCellCreation(context),
              canCreate: canCreate,
              myGeohash: _myGeohash,
              gpsUnavailable: _gpsUnavailable,
              allKnownCells: allKnown,
              selectedCategory: _selectedCategory,
              onCategoryChanged: (cat) =>
                  setState(() => _selectedCategory = cat),
            )
          : _FilledState(
              myCells: myCells,
              allKnownCells: allKnown,
              selectedCategory: _selectedCategory,
              onCategoryChanged: (cat) =>
                  setState(() => _selectedCategory = cat),
              onCellTap: _openCell,
              onCreateTap: canCreate ? _openCreate : null,
              onRequestCreate: () => _requestCellCreation(context),
              canCreate: canCreate,
              myGeohash: _myGeohash,
              gpsUnavailable: _gpsUnavailable,
            ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final VoidCallback? onCreateTap;
  final VoidCallback onRequestCreate;
  final bool canCreate;
  final String? myGeohash;
  final bool gpsUnavailable;
  final List<Cell> allKnownCells;
  final String selectedCategory;
  final ValueChanged<String> onCategoryChanged;

  const _EmptyState({
    required this.onCreateTap,
    required this.onRequestCreate,
    required this.canCreate,
    required this.myGeohash,
    required this.gpsUnavailable,
    required this.allKnownCells,
    required this.selectedCategory,
    required this.onCategoryChanged,
  });

  @override
  Widget build(BuildContext context) {
    final nearby = _nearbyCells(allKnownCells, myGeohash);
    final allCategories = ['Alle', 'Sonstiges', ...cellCategories.where((c) => c != 'Sonstiges')];
    final thematic = allKnownCells
        .where((c) => c.cellType == CellType.thematic)
        .toList();
    final filteredThematic = selectedCategory == 'Alle'
        ? thematic
        : thematic
            .where((c) => (c.category ?? 'Sonstiges') == selectedCategory)
            .toList();
    final recommended = _recommendedCells(allKnownCells);

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
                  'Du bist noch in keiner Zelle. Eine Zelle ist deine lokale '
                  'oder thematische Gemeinschaft — wie ein digitales Dorf. '
                  'Entdecke Zellen in deiner Nähe oder gründe eine eigene!',
                  style: TextStyle(
                    color: AppColors.onDark.withValues(alpha: 0.7),
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),

        // Nearby section (GPS-based)
        _NearbySection(
          nearbyCells: nearby,
          myGeohash: myGeohash,
          gpsUnavailable: gpsUnavailable,
        ),

        // Recommended: cells where contacts are members
        if (recommended.isNotEmpty) ...[
          _SectionHeader(title: 'Empfohlen für dich'),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => _DiscoveredCellTile(cell: recommended[i]),
              childCount: recommended.length,
            ),
          ),
        ],

        // Thematic cells with category chips + search
        _SectionHeader(title: 'Thematische Zellen'),
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
        if (filteredThematic.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                allKnownCells.isEmpty
                    ? 'Noch keine Zellen entdeckt. Sobald Zellen im NEXUS-Netzwerk '
                        'bekannt sind, erscheinen sie hier.'
                    : 'Keine thematischen Zellen in dieser Kategorie gefunden.',
                style: TextStyle(
                  color: AppColors.onDark.withValues(alpha: 0.5),
                  fontSize: 13,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          )
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => _DiscoveredCellTile(cell: filteredThematic[i]),
              childCount: filteredThematic.length,
            ),
          ),

        // Cell creation section
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Divider(color: AppColors.surfaceVariant),
                const SizedBox(height: 12),
                Text(
                  'Keine passende Zelle gefunden?',
                  style: TextStyle(
                    color: AppColors.onDark.withValues(alpha: 0.7),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 12),
                if (canCreate)
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
                  )
                else
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: onRequestCreate,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.gold,
                        side: BorderSide(color: AppColors.gold),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: const Icon(Icons.mail_outline),
                      label: const Text('Zellgründung anfragen',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ],
    );
  }
}

// ── Filled state (user is in at least one cell) ───────────────────────────────

class _FilledState extends StatelessWidget {
  final List<Cell> myCells;
  final List<Cell> allKnownCells;
  final String selectedCategory;
  final ValueChanged<String> onCategoryChanged;
  final ValueChanged<Cell> onCellTap;
  final VoidCallback? onCreateTap;
  final VoidCallback onRequestCreate;
  final bool canCreate;
  final String? myGeohash;
  final bool gpsUnavailable;

  const _FilledState({
    required this.myCells,
    required this.allKnownCells,
    required this.selectedCategory,
    required this.onCategoryChanged,
    required this.onCellTap,
    required this.onCreateTap,
    required this.onRequestCreate,
    required this.canCreate,
    required this.myGeohash,
    required this.gpsUnavailable,
  });

  @override
  Widget build(BuildContext context) {
    final allCategories = ['Alle', 'Sonstiges', ...cellCategories.where((c) => c != 'Sonstiges')];
    final nearby = _nearbyCells(allKnownCells, myGeohash);
    final recommended = _recommendedCells(allKnownCells);
    final thematic = allKnownCells
        .where((c) => c.cellType == CellType.thematic)
        .toList();
    final filtered = selectedCategory == 'Alle'
        ? thematic
        : thematic.where((c) => (c.category ?? 'Sonstiges') == selectedCategory).toList();

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

        // "Weitere Zellen entdecken" divider
        _SectionHeader(title: 'Weitere Zellen entdecken'),

        // Nearby section (GPS-based)
        _NearbySection(
          nearbyCells: nearby,
          myGeohash: myGeohash,
          gpsUnavailable: gpsUnavailable,
        ),

        // Recommended: cells where contacts are members
        if (recommended.isNotEmpty) ...[
          _SectionHeader(title: 'Empfohlen für dich'),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => _DiscoveredCellTile(cell: recommended[i]),
              childCount: recommended.length,
            ),
          ),
        ],

        // Thematic cells with category chips
        _SectionHeader(title: 'Thematische Zellen'),
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

        if (filtered.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Keine thematischen Zellen in dieser Kategorie entdeckt.',
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

        // Non-admin: "Zellgründung anfragen" button
        if (!canCreate)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: OutlinedButton.icon(
                onPressed: onRequestCreate,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.gold,
                  side: BorderSide(color: AppColors.gold),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.mail_outline),
                label: const Text('Neue Zelle gründen (anfragen)',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ),

        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ],
    );
  }
}

// ── Nearby helpers ────────────────────────────────────────────────────────────

/// Returns discovered cells where at least one of the user's contacts is a
/// member. Excludes cells the user is already in.
List<Cell> _recommendedCells(List<Cell> discovered) {
  final contactDids =
      ContactService.instance.contacts.map((c) => c.did).toSet();
  if (contactDids.isEmpty) return [];
  final myDid = IdentityService.instance.currentIdentity?.did ?? '';
  return discovered.where((cell) {
    if (CellService.instance.isMember(cell.id)) return false;
    final members = CellService.instance.membersOf(cell.id);
    return members.any(
        (m) => m.did != myDid && contactDids.contains(m.did));
  }).toList();
}

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
                  if (cell.description.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      cell.description,
                      style: TextStyle(
                        color: AppColors.onDark.withValues(alpha: 0.55),
                        fontSize: 12,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
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
        crossAxisAlignment: CrossAxisAlignment.start,
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
                if (cell.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    cell.description,
                    style: TextStyle(
                      color: AppColors.onDark.withValues(alpha: 0.55),
                      fontSize: 12,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  '${cell.memberCount}/${cell.maxMembers} Mitglieder',
                  style: TextStyle(
                    color: AppColors.onDark.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (alreadyMember)
            const Icon(Icons.check_circle, color: Colors.green, size: 20)
          else
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor:
                    applied ? AppColors.onDark.withValues(alpha: 0.4) : AppColors.gold,
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => _showCellInfoSheet(context),
              child: Text(
                applied ? 'Ausstehend' : 'Anfragen / Info',
                style: const TextStyle(fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  void _showCellInfoSheet(BuildContext pageContext) {
    final alreadyMember = CellService.instance.isMember(cell.id);
    final applied = CellService.instance.hasAppliedTo(cell.id);

    // Contacts who are cell members
    final contactDids =
        ContactService.instance.contacts.map((c) => c.did).toSet();
    final members = CellService.instance.membersOf(cell.id);
    final commonCount =
        members.where((m) => contactDids.contains(m.did)).length;

    // Founder display name
    final founderName =
        ContactService.instance.getDisplayName(cell.createdBy);

    final msgCtrl = TextEditingController();

    // Helper: type label
    final typeLabel =
        cell.cellType == CellType.local ? 'Lokal' : 'Thematisch';

    // Helper: subtitle in header  (Typ · Kategorie/Standort)
    final headerSub = () {
      final parts = <String>[typeLabel];
      if (cell.cellType == CellType.local && cell.locationName != null) {
        parts.add(cell.locationName!);
      } else if (cell.cellType == CellType.thematic &&
          cell.category != null) {
        parts.add(cell.category!);
      }
      return parts.join(' · ');
    }();

    // Helper: join policy label
    final joinLabel = switch (cell.joinPolicy) {
      JoinPolicy.approvalRequired => 'Genehmigung erforderlich',
      JoinPolicy.inviteOnly => 'Nur Einladung',
    };

    // Helper: proposal wait label
    final waitLabel = switch (cell.proposalWaitDays) {
      0 => 'Sofort',
      _ => '${cell.proposalWaitDays} Tage nach Beitritt',
    };

    // Helper: formatted date
    final dt = cell.createdAt.toLocal();
    final dateLabel =
        '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';

    showModalBottomSheet<void>(
      context: pageContext,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.65,
        maxChildSize: 0.92,
        minChildSize: 0.4,
        builder: (_, scrollCtrl) => StatefulBuilder(
          builder: (ctx, setSheetState) => ListView(
            controller: scrollCtrl,
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 12,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
            ),
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // ── Header ────────────────────────────────────────────────────
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
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
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          headerSub,
                          style: TextStyle(
                            color: AppColors.onDark.withValues(alpha: 0.6),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              // ── Description ───────────────────────────────────────────────
              if (cell.description.isNotEmpty) ...[
                const SizedBox(height: 20),
                _SheetLabel('BESCHREIBUNG'),
                const SizedBox(height: 6),
                Text(
                  cell.description,
                  style: TextStyle(
                    color: AppColors.onDark.withValues(alpha: 0.85),
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
              ],

              // ── Details ───────────────────────────────────────────────────
              const SizedBox(height: 20),
              _SheetLabel('DETAILS'),
              const SizedBox(height: 10),
              _InfoRow(label: 'Typ', value: typeLabel),
              if (cell.cellType == CellType.local &&
                  cell.locationName != null)
                _InfoRow(label: 'Standort', value: cell.locationName!),
              if (cell.cellType == CellType.thematic &&
                  cell.category != null)
                _InfoRow(label: 'Kategorie', value: cell.category!),
              _InfoRow(label: 'Beitritt', value: joinLabel),
              _InfoRow(
                label: 'Mitglieder',
                value: '${cell.memberCount} / ${cell.maxMembers}',
              ),
              _InfoRow(label: 'Gegründet', value: dateLabel),

              // ── Governance ────────────────────────────────────────────────
              const SizedBox(height: 16),
              Divider(color: AppColors.surfaceVariant.withValues(alpha: 0.5)),
              const SizedBox(height: 16),
              _SheetLabel('GOVERNANCE'),
              const SizedBox(height: 10),
              _InfoRow(label: 'Wartezeit für Anträge', value: waitLabel),

              // ── Founder ───────────────────────────────────────────────────
              const SizedBox(height: 16),
              Divider(color: AppColors.surfaceVariant.withValues(alpha: 0.5)),
              const SizedBox(height: 16),
              _SheetLabel('GRÜNDER'),
              const SizedBox(height: 10),
              Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: AppColors.gold.withValues(alpha: 0.2),
                    child: Text(
                      founderName.isNotEmpty
                          ? founderName[0].toUpperCase()
                          : '?',
                      style: const TextStyle(
                        color: AppColors.gold,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    founderName,
                    style: const TextStyle(
                        color: AppColors.onDark, fontSize: 14),
                  ),
                ],
              ),

              // ── Common contacts ───────────────────────────────────────────
              if (commonCount > 0) ...[
                const SizedBox(height: 16),
                Divider(
                    color: AppColors.surfaceVariant.withValues(alpha: 0.5)),
                const SizedBox(height: 16),
                _SheetLabel('GEMEINSAME KONTAKTE'),
                const SizedBox(height: 8),
                Text(
                  commonCount == 1
                      ? '1 deiner Kontakte ist Mitglied'
                      : '$commonCount deiner Kontakte sind Mitglied',
                  style: const TextStyle(color: AppColors.gold, fontSize: 14),
                ),
              ],

              const SizedBox(height: 24),

              // ── Join message field (only when user can request) ───────────
              if (!alreadyMember &&
                  !applied &&
                  cell.joinPolicy == JoinPolicy.approvalRequired &&
                  !cell.isFull) ...[
                TextField(
                  controller: msgCtrl,
                  decoration: InputDecoration(
                    hintText: 'Warum möchtest du beitreten? (empfohlen)',
                    hintStyle: TextStyle(
                        color: AppColors.onDark.withValues(alpha: 0.5)),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide:
                          const BorderSide(color: AppColors.surfaceVariant),
                    ),
                    filled: true,
                    fillColor: AppColors.deepBlue,
                  ),
                  style: const TextStyle(color: AppColors.onDark),
                  maxLines: 3,
                  maxLength: 500,
                ),
                const SizedBox(height: 12),
              ],

              // ── Action button ─────────────────────────────────────────────
              SizedBox(
                width: double.infinity,
                child: _buildJoinButton(
                  sheetCtx,
                  pageContext,
                  alreadyMember,
                  applied,
                  msgCtrl,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildJoinButton(
    BuildContext sheetCtx,
    BuildContext pageCtx,
    bool alreadyMember,
    bool applied,
    TextEditingController msgCtrl,
  ) {
    final disabledStyle = ElevatedButton.styleFrom(
      disabledForegroundColor: Colors.grey.shade400,
      disabledBackgroundColor: Colors.grey.shade800,
      padding: const EdgeInsets.symmetric(vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );

    if (alreadyMember) {
      return ElevatedButton(
        onPressed: null,
        style: disabledStyle,
        child: const Text('Bereits Mitglied'),
      );
    }
    if (applied) {
      return ElevatedButton(
        onPressed: null,
        style: disabledStyle,
        child: const Text('Anfrage ausstehend'),
      );
    }
    if (cell.isFull) {
      return ElevatedButton(
        onPressed: null,
        style: disabledStyle,
        child: const Text('Zelle ist voll'),
      );
    }
    if (cell.joinPolicy == JoinPolicy.inviteOnly) {
      return ElevatedButton(
        onPressed: null,
        style: disabledStyle,
        child: const Text('Nur auf Einladung'),
      );
    }
    // Can request join
    return ElevatedButton(
      onPressed: () async {
        Navigator.of(sheetCtx).pop();
        await CellService.instance.sendJoinRequest(
          cell,
          message:
              msgCtrl.text.trim().isEmpty ? null : msgCtrl.text.trim(),
        );
        if (pageCtx.mounted) {
          ScaffoldMessenger.of(pageCtx).showSnackBar(
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
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: const Text(
        'Beitritt anfragen',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
    );
  }
}

/// Small gold section label used inside the cell info bottom sheet.
class _SheetLabel extends StatelessWidget {
  final String text;
  const _SheetLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: AppColors.gold.withValues(alpha: 0.8),
        fontSize: 10,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
      ),
    );
  }
}

/// A detail row inside the cell info sheet: gold label above, value below.
class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: TextStyle(
                color: AppColors.onDark.withValues(alpha: 0.5),
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: AppColors.onDark,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
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
