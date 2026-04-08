import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/identity/identity_service.dart';
import '../../core/storage/pod_database.dart';
import '../../services/notification_service.dart';
import 'audit_log_entry.dart';
import 'cell_member.dart';
import 'cell_service.dart';
import 'decision_record.dart';
import 'proposal.dart';
import 'proposal_edit.dart';
import 'vote.dart';

/// Manages governance proposals and votes within cells.
///
/// G2 additions over G1:
/// - ProposalType (SACHFRAGE / VERFASSUNGSFRAGE)
/// - ProposalStatus VOTING_ENDED + WITHDRAWN
/// - Vote casting (Prompt 1B)
/// - Edit history (Prompt 1B)
/// - Audit log (Prompt 1B)
/// - Decision records with hash-chain (Prompt 1B)
/// - Nostr sync for votes + decisions (Prompt 1B)
class ProposalService {
  ProposalService._();
  static ProposalService? _instance;
  static ProposalService get instance => _instance ??= ProposalService._();

  // In-memory caches
  final Map<String, Proposal> _proposals = {};
  final Map<String, List<Vote>> _votes = {}; // keyed by proposal_id

  final _streamCtrl = StreamController<void>.broadcast();
  final _auditCtrl = StreamController<AuditLogEntry>.broadcast();

  Stream<void> get stream => _streamCtrl.stream;
  Stream<AuditLogEntry> get auditLogStream => _auditCtrl.stream;

  List<Proposal> get allProposals => List.unmodifiable(_proposals.values);

  // ── Init ───────────────────────────────────────────────────────────────────

  Future<void> load() async {
    debugPrint('[PROPOSAL] Service initializing');
    try {
      await _migrateLegacyProposals();
      await _loadFromDatabase();
      _advanceStatuses();
      debugPrint('[PROPOSAL] Loaded ${_proposals.length} proposals from DB');
      _notify();
    } catch (e) {
      debugPrint('[PROPOSAL] load error: $e');
    }
  }

  /// One-time migration: reads enc-blob rows from proposals_legacy and
  /// writes them to the new flat-column proposals table.
  Future<void> _migrateLegacyProposals() async {
    // Check if migration has already run.
    final db = PodDatabase.instance;
    final alreadyMigrated = await db.getIdentityValue('proposals_g2_migrated');
    if (alreadyMigrated != null) return;

    debugPrint('[PROPOSAL] Migrating legacy proposals…');
    int count = 0;
    try {
      final legacyRows = await db.listLegacyProposals();
      for (final json in legacyRows) {
        try {
          final proposal = Proposal.fromLegacyJson(json);
          await _saveProposalToDb(proposal);
          count++;
        } catch (e) {
          debugPrint('[PROPOSAL] Migration skip: $e');
        }
      }
    } catch (e) {
      debugPrint('[PROPOSAL] Legacy migration error: $e');
    }
    // Mark migration complete even if partial (avoids re-running on every start).
    await db.setIdentityValue('proposals_g2_migrated', {'done': true, 'count': count});
    debugPrint('[PROPOSAL] Migrated $count legacy proposals');
  }

  Future<void> _loadFromDatabase() async {
    _proposals.clear();
    _votes.clear();

    final rows = await PodDatabase.instance.listProposals();
    for (final row in rows) {
      try {
        final p = Proposal.fromMap(row);
        _proposals[p.id] = p;
      } catch (e) {
        debugPrint('[PROPOSAL] Parse error: $e');
      }
    }

    // Load votes for all cached proposals.
    for (final proposalId in _proposals.keys) {
      try {
        final voteRows = await PodDatabase.instance.listVotes(proposalId);
        _votes[proposalId] = voteRows.map(Vote.fromMap).toList();
      } catch (e) {
        debugPrint('[PROPOSAL] Vote load error for $proposalId: $e');
      }
    }
  }

  // ── CRUD ──────────────────────────────────────────────────────────────────

  /// Creates a new proposal in DRAFT state.
  ///
  /// Throws if the caller is not a confirmed cell member or hasn't waited
  /// [Cell.proposalWaitDays] since joining.
  Future<Proposal> createProposal(Proposal proposal) async {
    final myDid = IdentityService.instance.currentIdentity!.did;
    _checkCanCreateProposal(proposal.cellId, myDid);

    await _saveProposalToDb(proposal);
    _proposals[proposal.id] = proposal;
    _notify();
    debugPrint('[PROPOSAL] Draft created: ${proposal.id}');
    return proposal;
  }

  /// Creates a draft using named parameters (convenience wrapper).
  Future<Proposal> createDraft({
    required String cellId,
    required String creatorDid,
    required String creatorPseudonym,
    required String title,
    required String description,
    String? category,
    ProposalType type = ProposalType.SACHFRAGE,
  }) async {
    debugPrint('[PROPOSAL] Creating draft: $title');
    final proposal = Proposal.create(
      cellId: cellId,
      creatorDid: creatorDid,
      creatorPseudonym: creatorPseudonym,
      title: title,
      description: description,
      category: category,
      proposalType: type,
    );
    return createProposal(proposal);
  }

  /// Updates a DRAFT proposal (title/description/category changes before publishing).
  Future<void> updateDraft(Proposal proposal) async {
    if (proposal.status != ProposalStatus.DRAFT) {
      throw StateError('Can only update DRAFT proposals');
    }
    await _saveProposalToDb(proposal);
    _proposals[proposal.id] = proposal;
    _notify();
    debugPrint('[PROPOSAL] Draft updated: ${proposal.id}');
  }

  /// Permanently deletes a DRAFT (only creator, only while DRAFT).
  Future<void> deleteDraft(String proposalId) async {
    final proposal = _proposals[proposalId];
    if (proposal == null || proposal.status != ProposalStatus.DRAFT) {
      throw StateError('Can only delete DRAFT proposals');
    }
    await _deleteProposalFromDb(proposalId);
    _proposals.remove(proposalId);
    _votes.remove(proposalId);
    _notify();
    debugPrint('[PROPOSAL] Draft deleted: $proposalId');
  }

  // ── Status transitions (stubs – implemented in Prompt 1B) ─────────────────

  /// Publishes a DRAFT → DISCUSSION (G1 compat + G2 entry point).
  Future<void> publishProposal(String proposalId) async {
    final p = _proposals[proposalId];
    if (p == null) return;
    if (p.status != ProposalStatus.DRAFT) return;

    p.status = ProposalStatus.DISCUSSION;
    p.discussionStartedAt = DateTime.now().toUtc();
    await _saveProposalToDb(p);
    _notify();

    await _notifyAllMembers(
      p.cellId,
      title: 'Neuer Antrag',
      body: p.title,
      payload: 'proposal:${p.id}',
    );
    debugPrint('[PROPOSAL] Published ${p.id} → DISCUSSION');
  }

  /// DISCUSSION → edit title/description (Prompt 1B).
  Future<void> editInDiscussion(String proposalId, String newTitle,
      String newDescription, String? reason) async {
    throw UnimplementedError('Implemented in Prompt 1B');
  }

  /// Withdraws a proposal (DRAFT or DISCUSSION only, by creator).
  Future<void> withdrawProposal(String proposalId) async {
    throw UnimplementedError('Implemented in Prompt 1B');
  }

  /// DISCUSSION → VOTING (Prompt 1B).
  Future<void> startVoting(String proposalId) async {
    throw UnimplementedError('Implemented in Prompt 1B');
  }

  /// VOTING → VOTING_ENDED (grace period start, Prompt 1B).
  Future<void> processGracePeriodStart(String proposalId) async {
    throw UnimplementedError('Implemented in Prompt 1B');
  }

  /// VOTING_ENDED → DECIDED (result calculation, Prompt 1B).
  Future<void> finalizeProposal(String proposalId) async {
    throw UnimplementedError('Implemented in Prompt 1B');
  }

  /// DECIDED → ARCHIVED (Prompt 1B).
  Future<void> archiveProposal(String proposalId) async {
    throw UnimplementedError('Implemented in Prompt 1B');
  }

  // ── Voting (stubs – implemented in Prompt 1B) ──────────────────────────────

  Future<void> castVote(String proposalId, VoteChoice choice,
      {String? reasoning}) async {
    throw UnimplementedError('Implemented in Prompt 1B');
  }

  Future<void> changeVote(String proposalId, VoteChoice newChoice,
      {String? newReasoning}) async {
    throw UnimplementedError('Implemented in Prompt 1B');
  }

  // ── Queries ────────────────────────────────────────────────────────────────

  List<Proposal> proposalsForCell(String cellId, {ProposalStatus? status}) {
    var list = _proposals.values.where((p) => p.cellId == cellId).toList();
    if (status != null) list = list.where((p) => p.status == status).toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  List<Proposal> activeProposalsForCell(String cellId) =>
      proposalsForCell(cellId).where((p) => p.isActive).toList();

  List<Proposal> getActiveProposals(String cellId) => activeProposalsForCell(cellId);

  List<Proposal> myProposals() {
    final myDid = IdentityService.instance.currentIdentity?.did;
    if (myDid == null) return [];
    return _proposals.values
        .where((p) => p.creatorDid == myDid)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  List<Proposal> getMyProposals(String cellId, String myDid) {
    return _proposals.values
        .where((p) =>
            p.cellId == cellId &&
            (p.creatorDid == myDid ||
                (_votes[p.id]?.any((v) => v.voterDid == myDid) ?? false)))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  List<Proposal> getCompletedProposals(String cellId) => proposalsForCell(
        cellId,
        status: ProposalStatus.DECIDED,
      );

  List<Proposal> getArchivedProposals(
    String cellId, {
    String? searchQuery,
    String? category,
    DateTimeRange? range,
    String? resultFilter,
  }) {
    var list = _proposals.values.where((p) =>
        p.cellId == cellId &&
        (p.status == ProposalStatus.ARCHIVED ||
            p.status == ProposalStatus.WITHDRAWN));

    if (searchQuery != null && searchQuery.isNotEmpty) {
      final q = searchQuery.toLowerCase();
      list = list.where((p) =>
          p.title.toLowerCase().contains(q) ||
          p.description.toLowerCase().contains(q));
    }
    if (category != null) {
      list = list.where((p) => p.category == category);
    }
    if (range != null) {
      list = list.where((p) =>
          p.createdAt.isAfter(range.start) && p.createdAt.isBefore(range.end));
    }
    if (resultFilter != null) {
      list = list.where((p) => p.resultSummary == resultFilter);
    }
    return list.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Proposal? getProposal(String proposalId) => _proposals[proposalId];

  List<Vote> getVotes(String proposalId) => _votes[proposalId] ?? [];

  Future<List<ProposalEdit>> getEditHistory(String proposalId) async {
    final rows = await PodDatabase.instance.listProposalEdits(proposalId);
    return rows.map(ProposalEdit.fromMap).toList();
  }

  Future<List<AuditLogEntry>> getAuditLog(String proposalId) async {
    final rows = await PodDatabase.instance.listAuditLog(proposalId);
    return rows.map(AuditLogEntry.fromMap).toList();
  }

  Future<DecisionRecord?> getDecisionRecord(String proposalId) async {
    final row = await PodDatabase.instance.getDecisionRecord(proposalId);
    if (row == null) return null;
    return DecisionRecord.fromMap(row);
  }

  // ── Permissions ────────────────────────────────────────────────────────────

  bool canVote(String proposalId, String userDid) {
    final proposal = _proposals[proposalId];
    if (proposal == null) return false;
    if (proposal.status != ProposalStatus.VOTING) return false;
    // TODO (Prompt 1B): verify userDid is a confirmed member of proposal.cellId
    return true;
  }

  bool canEdit(String proposalId, String userDid) {
    final proposal = _proposals[proposalId];
    if (proposal == null) return false;
    if (proposal.creatorDid != userDid) return false;
    return proposal.status == ProposalStatus.DRAFT ||
        proposal.status == ProposalStatus.DISCUSSION;
  }

  bool canStartVoting(String proposalId, String userDid) {
    final proposal = _proposals[proposalId];
    if (proposal == null) return false;
    if (proposal.status != ProposalStatus.DISCUSSION) return false;
    // TODO (Prompt 1B): check proposalWaitDays + role (creator or mod/founder)
    return true;
  }

  bool canArchive(String proposalId, String userDid) {
    final proposal = _proposals[proposalId];
    if (proposal == null) return false;
    if (proposal.status != ProposalStatus.DECIDED) return false;
    // TODO (Prompt 1B): check userDid is mod/founder
    return true;
  }

  bool canWithdraw(String proposalId, String userDid) {
    final proposal = _proposals[proposalId];
    if (proposal == null) return false;
    if (proposal.creatorDid != userDid) return false;
    return proposal.status == ProposalStatus.DRAFT ||
        proposal.status == ProposalStatus.DISCUSSION;
  }

  // ── Audit log ──────────────────────────────────────────────────────────────

  Future<void> addAuditEntry(AuditLogEntry entry) async {
    await _saveAuditEntryToDb(entry);
    _auditCtrl.add(entry);
    debugPrint('[AUDIT] Saving entry: ${entry.eventType}');
  }

  // ── Cleanup ────────────────────────────────────────────────────────────────

  Future<void> deleteAllProposalsForCell(String cellId) async {
    debugPrint('[PROPOSAL] Deleting all data for cell: $cellId');
    await PodDatabase.instance.deleteAllProposalDataForCell(cellId);
    _proposals.removeWhere((_, p) => p.cellId == cellId);
    _votes.removeWhere((id, _) => !_proposals.containsKey(id));
    _notify();
  }

  // ── Status advancement (G1 compat, replaces _advanceStatuses) ─────────────

  void _advanceStatuses() {
    final now = DateTime.now().toUtc();
    for (final p in _proposals.values) {
      switch (p.status) {
        case ProposalStatus.DISCUSSION:
          // Auto-advance if votingEndsAt was set via legacy discussionDeadline.
          // G2 advancement is driven by explicit startVoting() calls (Prompt 1B).
          break;
        case ProposalStatus.VOTING:
          if (p.votingEndsAt != null && now.isAfter(p.votingEndsAt!)) {
            p.status = ProposalStatus.VOTING_ENDED;
            _saveProposalToDb(p);
            _notifyAllMembers(
              p.cellId,
              title: 'Abstimmung beendet',
              body: p.title,
              payload: 'proposal:${p.id}',
            );
          }
        case ProposalStatus.DECIDED:
          if (p.decidedAt != null &&
              now.difference(p.decidedAt!).inDays >= 30) {
            p.status = ProposalStatus.ARCHIVED;
            p.archivedAt = now;
            _saveProposalToDb(p);
          }
        default:
          break;
      }
    }
  }

  // ── DB helpers ─────────────────────────────────────────────────────────────

  Future<void> _saveProposalToDb(Proposal proposal) async {
    debugPrint('[PROPOSAL] Saving to DB: ${proposal.id}');
    await PodDatabase.instance.upsertProposal(
      proposal.id,
      proposal.cellId,
      proposal.toMap(),
    );
  }

  Future<void> _deleteProposalFromDb(String proposalId) async {
    debugPrint('[PROPOSAL] Deleting from DB: $proposalId');
    await PodDatabase.instance.deleteProposal(proposalId);
    await PodDatabase.instance.deleteVotesForProposal(proposalId);
    await PodDatabase.instance.deleteEditsForProposal(proposalId);
    await PodDatabase.instance.deleteAuditLogForProposal(proposalId);
    await PodDatabase.instance.deleteDecisionRecord(proposalId);
  }

  Future<void> _saveAuditEntryToDb(AuditLogEntry entry) async {
    await PodDatabase.instance.insertAuditEntry(entry.toMap());
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

/// DateTimeRange helper (used in getArchivedProposals filter).
/// Avoids a Flutter material dependency here — UI code passes this in.
class DateTimeRange {
  final DateTime start;
  final DateTime end;
  const DateTimeRange({required this.start, required this.end});
}
