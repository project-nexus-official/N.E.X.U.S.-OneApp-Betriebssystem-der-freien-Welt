import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/identity/identity_service.dart';
import '../../core/storage/pod_database.dart';
import '../../services/notification_service.dart';
import 'cell_member.dart';
import 'cell_service.dart';
import 'proposal.dart';

/// Manages proposals within cells.
///
/// Only CELL-scope proposals are functional in G1.
/// FEDERATION and GLOBAL scope are UI-only placeholders.
class ProposalService {
  ProposalService._();
  static ProposalService? _instance;
  static ProposalService get instance => _instance ??= ProposalService._();

  // All proposals keyed by id.
  final Map<String, Proposal> _proposals = {};

  final _streamCtrl = StreamController<void>.broadcast();
  Stream<void> get stream => _streamCtrl.stream;

  List<Proposal> get allProposals => List.unmodifiable(_proposals.values);

  // ── Init ───────────────────────────────────────────────────────────────────

  Future<void> load() async {
    try {
      final rows = await PodDatabase.instance.listProposals();
      _proposals.clear();
      for (final row in rows) {
        final p = Proposal.fromJson(row);
        _proposals[p.id] = p;
      }
      _advanceStatuses();
      debugPrint('[PROPOSALS] Loaded ${_proposals.length} proposals');
      _notify();
    } catch (e) {
      debugPrint('[PROPOSALS] load error: $e');
    }
  }

  // ── Queries ────────────────────────────────────────────────────────────────

  List<Proposal> proposalsForCell(
    String cellId, {
    ProposalStatus? status,
  }) {
    var list = _proposals.values.where((p) => p.cellId == cellId).toList();
    if (status != null) list = list.where((p) => p.status == status).toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  List<Proposal> activeProposalsForCell(String cellId) => proposalsForCell(
        cellId,
      ).where((p) => p.isActive).toList();

  List<Proposal> myProposals() {
    final myDid = IdentityService.instance.currentIdentity?.did;
    if (myDid == null) return [];
    return _proposals.values
        .where((p) => p.createdBy == myDid)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  // ── Create ─────────────────────────────────────────────────────────────────

  /// Creates a new proposal in DRAFT state.
  ///
  /// Throws if the caller is not a confirmed member or hasn't waited
  /// [Cell.proposalWaitDays] since joining.
  Future<Proposal> createProposal(Proposal proposal) async {
    final myDid = IdentityService.instance.currentIdentity!.did;
    _checkCanCreateProposal(proposal.cellId, myDid);

    await PodDatabase.instance.upsertProposal(
        proposal.id, proposal.cellId, proposal.toJson());
    _proposals[proposal.id] = proposal;
    _notify();
    debugPrint('[PROPOSALS] Created draft ${proposal.id}');
    return proposal;
  }

  /// Publishes a DRAFT proposal → DISCUSSION status.
  Future<void> publishProposal(String proposalId) async {
    final p = _proposals[proposalId];
    if (p == null) return;
    if (p.status != ProposalStatus.draft) return;

    p.status = ProposalStatus.discussion;
    await PodDatabase.instance.upsertProposal(p.id, p.cellId, p.toJson());
    _notify();

    // Notify all cell members.
    await _notifyAllMembers(
      p.cellId,
      title: 'Neuer Antrag',
      body: p.title,
      payload: 'proposal:${p.id}',
    );
    debugPrint('[PROPOSALS] Published ${p.id} → discussion');
  }

  /// Archives a decided proposal after 30 days (called by _advanceStatuses).
  Future<void> _archiveProposal(Proposal p) async {
    p.status = ProposalStatus.archived;
    await PodDatabase.instance.upsertProposal(p.id, p.cellId, p.toJson());
  }

  // ── Status advancement ─────────────────────────────────────────────────────

  /// Advances proposal statuses based on deadlines.
  void _advanceStatuses() {
    final now = DateTime.now().toUtc();
    for (final p in _proposals.values) {
      switch (p.status) {
        case ProposalStatus.discussion:
          if (now.isAfter(p.discussionDeadline)) {
            p.status = ProposalStatus.voting;
            PodDatabase.instance.upsertProposal(p.id, p.cellId, p.toJson());
            _notifyAllMembers(
              p.cellId,
              title: 'Abstimmung gestartet',
              body: p.title,
              payload: 'proposal:${p.id}',
            );
          }
        case ProposalStatus.voting:
          if (now.isAfter(p.votingDeadline)) {
            p.status = ProposalStatus.decided;
            PodDatabase.instance.upsertProposal(p.id, p.cellId, p.toJson());
            _notifyAllMembers(
              p.cellId,
              title: 'Ergebnis: ${p.title}',
              body: 'Abstimmung abgeschlossen.',
              payload: 'proposal:${p.id}',
            );
          }
        case ProposalStatus.decided:
          if (now.difference(p.votingDeadline).inDays >= 30) {
            _archiveProposal(p);
          }
        default:
          break;
      }
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  void _checkCanCreateProposal(String cellId, String myDid) {
    final membership = CellService.instance.myMembershipIn(cellId);
    if (membership == null || !membership.isConfirmed) {
      throw StateError(
          'Must be a confirmed cell member to create proposals.');
    }
    if (membership.role == MemberRole.pending) {
      throw StateError('Pending members cannot create proposals.');
    }

    final cell = CellService.instance.myCells
        .where((c) => c.id == cellId)
        .firstOrNull;
    if (cell == null) return;

    if (cell.proposalWaitDays > 0) {
      final waitedDays =
          DateTime.now().toUtc().difference(membership.joinedAt).inDays;
      if (waitedDays < cell.proposalWaitDays) {
        throw StateError(
            'Must wait ${cell.proposalWaitDays - waitedDays} more day(s) before creating proposals.');
      }
    }
  }

  Future<void> _notifyAllMembers(
    String cellId, {
    required String title,
    required String body,
    String? payload,
  }) async {
    try {
      await NotificationService.instance.showGenericNotification(
        title: title,
        body: body,
        payload: payload,
      );
    } catch (_) {}
  }

  void _notify() => _streamCtrl.add(null);
}
