import 'dart:async';

import 'package:flutter/material.dart';

import '../../shared/theme/app_theme.dart';
import 'cell.dart';
import 'cell_service.dart';
import 'cell_hub_screen.dart';
import 'create_proposal_screen.dart';
import 'proposal.dart';
import 'proposal_detail_screen.dart';
import 'proposal_service.dart';

/// Agora – the political/governance sphere.
///
/// Only accessible once the user is a confirmed member of at least one cell.
/// Shows proposals for the selected cell with three tabs:
/// Aktiv · Abgeschlossen · Meine
class GovernanceScreen extends StatefulWidget {
  const GovernanceScreen({super.key});

  @override
  State<GovernanceScreen> createState() => _GovernanceScreenState();
}

class _GovernanceScreenState extends State<GovernanceScreen>
    with SingleTickerProviderStateMixin {
  TabController? _tabCtrl;
  StreamSubscription<void>? _cellSub;
  StreamSubscription<void>? _proposalSub;

  Cell? _selectedCell;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
    _cellSub = CellService.instance.stream.listen((_) {
      if (mounted) setState(() => _syncSelectedCell());
    });
    _proposalSub = ProposalService.instance.stream.listen((_) {
      if (mounted) setState(() {});
    });
    _syncSelectedCell();
  }

  void _syncSelectedCell() {
    final cells = CellService.instance.myCells
        .where((c) => CellService.instance.isMember(c.id))
        .toList();
    if (cells.isEmpty) {
      _selectedCell = null;
      return;
    }
    if (_selectedCell == null ||
        !cells.any((c) => c.id == _selectedCell!.id)) {
      _selectedCell = cells.first;
    }
  }

  @override
  void dispose() {
    _tabCtrl?.dispose();
    _cellSub?.cancel();
    _proposalSub?.cancel();
    super.dispose();
  }

  void _openCreate() {
    if (_selectedCell == null) return;
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => CreateProposalScreen(cell: _selectedCell!),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final myCells = CellService.instance.myCells
        .where((c) => CellService.instance.isMember(c.id))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Agora — Politik & Demokratie'),
        backgroundColor: AppColors.deepBlue,
        bottom: myCells.isNotEmpty
            ? TabBar(
                controller: _tabCtrl,
                indicatorColor: AppColors.gold,
                labelColor: AppColors.gold,
                unselectedLabelColor: AppColors.onDark,
                tabs: const [
                  Tab(text: 'Aktiv'),
                  Tab(text: 'Abgeschlossen'),
                  Tab(text: 'Meine'),
                ],
              )
            : null,
      ),
      backgroundColor: AppColors.deepBlue,
      floatingActionButton: _selectedCell != null
          ? FloatingActionButton.extended(
              onPressed: _openCreate,
              backgroundColor: AppColors.gold,
              foregroundColor: Colors.black,
              icon: const Icon(Icons.add),
              label: const Text('Neues Proposal'),
            )
          : null,
      body: myCells.isEmpty
          ? _NoCellState()
          : Column(
              children: [
                // Cell selector (only shown when in multiple cells)
                if (myCells.length > 1)
                  _CellSelector(
                    cells: myCells,
                    selected: _selectedCell,
                    onChanged: (cell) =>
                        setState(() => _selectedCell = cell),
                  ),
                Expanded(
                  child: TabBarView(
                    controller: _tabCtrl,
                    children: [
                      _ProposalList(
                        cellId: _selectedCell?.id ?? '',
                        filter: _activeFilter,
                      ),
                      _ProposalList(
                        cellId: _selectedCell?.id ?? '',
                        filter: _closedFilter,
                      ),
                      _MyProposalList(),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  bool _activeFilter(Proposal p) =>
      p.status == ProposalStatus.discussion ||
      p.status == ProposalStatus.voting;

  bool _closedFilter(Proposal p) =>
      p.status == ProposalStatus.decided ||
      p.status == ProposalStatus.archived;
}

// ── No-cell empty state ───────────────────────────────────────────────────────

class _NoCellState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.how_to_vote_outlined,
                size: 64, color: AppColors.onDark.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            const Text(
              'Um an Abstimmungen teilzunehmen,\ntritt zuerst einer Zelle bei.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.onDark,
                fontSize: 16,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.of(context, rootNavigator: true).pushReplacement(
                  MaterialPageRoute<void>(
                      builder: (_) => const CellHubScreen()),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.gold,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.group_work),
              label: const Text('Zelle finden'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Cell selector dropdown ────────────────────────────────────────────────────

class _CellSelector extends StatelessWidget {
  final List<Cell> cells;
  final Cell? selected;
  final ValueChanged<Cell> onChanged;

  const _CellSelector({
    required this.cells,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: DropdownButtonFormField<Cell>(
        value: selected,
        dropdownColor: AppColors.surface,
        style: const TextStyle(color: AppColors.onDark),
        decoration: InputDecoration(
          labelText: 'Zelle',
          labelStyle: TextStyle(color: AppColors.onDark.withValues(alpha: 0.6)),
          filled: true,
          fillColor: AppColors.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.surfaceVariant),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        items: cells
            .map((c) =>
                DropdownMenuItem<Cell>(value: c, child: Text(c.name)))
            .toList(),
        onChanged: (c) {
          if (c != null) onChanged(c);
        },
      ),
    );
  }
}

// ── Proposal list ─────────────────────────────────────────────────────────────

class _ProposalList extends StatelessWidget {
  final String cellId;
  final bool Function(Proposal) filter;

  const _ProposalList({required this.cellId, required this.filter});

  @override
  Widget build(BuildContext context) {
    if (cellId.isEmpty) {
      return const Center(
        child: Text('Keine Zelle ausgewählt.',
            style: TextStyle(color: AppColors.surfaceVariant)),
      );
    }
    final proposals = ProposalService.instance
        .proposalsForCell(cellId)
        .where(filter)
        .toList();

    if (proposals.isEmpty) {
      return const Center(
        child: Text('Keine Proposals.',
            style: TextStyle(color: AppColors.surfaceVariant)),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: proposals.length,
      itemBuilder: (context, i) => _ProposalTile(proposal: proposals[i]),
    );
  }
}

class _MyProposalList extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final proposals = ProposalService.instance.myProposals();

    if (proposals.isEmpty) {
      return const Center(
        child: Text('Du hast noch keine Proposals erstellt.',
            style: TextStyle(color: AppColors.surfaceVariant)),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: proposals.length,
      itemBuilder: (context, i) => _ProposalTile(proposal: proposals[i]),
    );
  }
}

// ── Proposal tile ─────────────────────────────────────────────────────────────

class _ProposalTile extends StatelessWidget {
  final Proposal proposal;
  const _ProposalTile({required this.proposal});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => ProposalDetailScreen(proposal: proposal),
        ),
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
                _StatusBadge(status: proposal.status),
                const SizedBox(width: 8),
                _ScopeBadge(scope: proposal.scope),
                const Spacer(),
                Text(
                  proposal.domain,
                  style: TextStyle(
                    color: AppColors.onDark.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              proposal.title,
              style: const TextStyle(
                color: AppColors.onDark,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
            if (proposal.description.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                proposal.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.onDark.withValues(alpha: 0.6),
                  fontSize: 13,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              _formatDeadline(proposal),
              style: TextStyle(
                color: AppColors.onDark.withValues(alpha: 0.4),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDeadline(Proposal p) {
    final now = DateTime.now().toUtc();
    switch (p.status) {
      case ProposalStatus.discussion:
        final diff = p.discussionDeadline.difference(now);
        if (diff.isNegative) return 'Diskussion abgelaufen';
        return 'Diskussion endet in ${diff.inDays}d ${diff.inHours % 24}h';
      case ProposalStatus.voting:
        final diff = p.votingDeadline.difference(now);
        if (diff.isNegative) return 'Abstimmung abgelaufen';
        return 'Abstimmung endet in ${diff.inDays}d ${diff.inHours % 24}h';
      case ProposalStatus.decided:
        return 'Entschieden';
      case ProposalStatus.archived:
        return 'Archiviert';
      case ProposalStatus.draft:
        return 'Entwurf';
    }
  }
}

// ── Status/Scope badges ───────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final ProposalStatus status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      ProposalStatus.draft => ('Entwurf', AppColors.onDark),
      ProposalStatus.discussion => ('Diskussion', Colors.blue),
      ProposalStatus.voting => ('Abstimmung', Colors.orange),
      ProposalStatus.decided => ('Entschieden', Colors.green),
      ProposalStatus.archived => ('Archiviert', AppColors.surfaceVariant),
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
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _ScopeBadge extends StatelessWidget {
  final ProposalScope scope;
  const _ScopeBadge({required this.scope});

  @override
  Widget build(BuildContext context) {
    if (scope == ProposalScope.cell) return const SizedBox.shrink();
    final label =
        scope == ProposalScope.federation ? 'Föderation' : 'Global';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.gold.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: AppColors.gold,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
