import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart' as pkg_crypto;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/identity/identity_service.dart';
import '../../core/storage/pod_database.dart';
import '../../core/transport/nostr/nostr_event.dart';
import '../../services/notification_service.dart';
import 'audit_log_entry.dart';
import 'cell_member.dart';
import 'cell_service.dart';
import 'decision_record.dart';
import 'proposal.dart';
import 'proposal_edit.dart';
import 'vote.dart';

/// A single discussion message attached to a proposal.
class ProposalDiscussionMessage {
  final String id;
  final String proposalId;
  final String authorDid;
  final String authorPseudonym;
  final String content;
  final DateTime createdAt;

  const ProposalDiscussionMessage({
    required this.id,
    required this.proposalId,
    required this.authorDid,
    required this.authorPseudonym,
    required this.content,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'proposal_id': proposalId,
        'author_did': authorDid,
        'author_pseudo': authorPseudonym,
        'content': content,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  static ProposalDiscussionMessage fromMap(Map<String, dynamic> m) =>
      ProposalDiscussionMessage(
        id: m['id'] as String,
        proposalId: m['proposal_id'] as String,
        authorDid: m['author_did'] as String,
        authorPseudonym: m['author_pseudo'] as String? ?? '',
        content: m['content'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            m['created_at'] as int,
            isUtc: true),
      );
}

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
  final Map<String, List<ProposalDiscussionMessage>> _discussions = {};

  /// Persistent tombstone list: proposal IDs that were deleted/withdrawn locally.
  /// Once tombstoned, a proposal can never be re-imported via Nostr replay.
  /// Tombstones are never cleared (except on full app data wipe).
  final Set<String> _proposalTombstones = {};

  static const _tombstonesKey = 'proposal_tombstones';

  final _streamCtrl = StreamController<void>.broadcast();
  final _auditCtrl = StreamController<AuditLogEntry>.broadcast();

  Stream<void> get stream => _streamCtrl.stream;
  Stream<AuditLogEntry> get auditLogStream => _auditCtrl.stream;

  List<Proposal> get allProposals => List.unmodifiable(_proposals.values);

  // ── Nostr publish callbacks (set by ChatProvider) ─────────────────────────

  /// Called to publish a Kind-31010 proposal event.
  /// Returns true on success, false on failure.
  Future<bool> Function(Map<String, dynamic>)? onPublishProposalToNostr;

  /// Called to publish a Kind-31011 vote event.
  /// Returns true on success, false on failure.
  Future<bool> Function(Map<String, dynamic>)? onPublishVoteToNostr;

  /// Called to publish a Kind-31013 decision record.
  /// Returns true on success, false on failure.
  Future<bool> Function(Map<String, dynamic>)? onPublishDecisionToNostr;

  /// Called to send a proposal discussion message via the transport layer.
  Future<void> Function(Map<String, dynamic>)? onSendDiscussionMessage;

  /// Returns the local user's Nostr public key hex (from NostrTransport).
  /// Set by ChatProvider after transport is initialised.
  String? Function()? getMyNostrPubkeyHex;

  // ── Retry queue for failed Nostr publishes ────────────────────────────────

  final List<Map<String, dynamic>> _retryQueue = [];
  Timer? _retryTimer;

  // ── Scheduler accessor ────────────────────────────────────────────────────

  /// Returns all proposals that need scheduler attention (active or recently
  /// decided). Used by [ProposalScheduler] to drive automatic status advances.
  List<Proposal> getAllProposalsForScheduler() {
    return _proposals.values.where((p) {
      switch (p.status) {
        case ProposalStatus.VOTING:
        case ProposalStatus.VOTING_ENDED:
          return true;
        case ProposalStatus.DECIDED:
          // Keep for 30-day auto-archive window.
          return p.decidedAt != null &&
              DateTime.now().toUtc().difference(p.decidedAt!).inDays < 31;
        default:
          return false;
      }
    }).toList();
  }

  // ── Init ───────────────────────────────────────────────────────────────────

  Future<void> load() async {
    debugPrint('[PROPOSAL] Service initializing');
    try {
      // Load tombstones FIRST so they are active before any DB or Nostr data arrives.
      await _loadTombstones();
      await _migrateLegacyProposals();
      await _loadFromDatabase();
      await _cleanupZombiesOnStart();
      _advanceStatuses();
      debugPrint('[PROPOSAL] Loaded ${_proposals.length} proposals from DB');
      _notify();
    } catch (e) {
      debugPrint('[PROPOSAL] load error: $e');
    }
  }

  /// Loads the persistent tombstone list from SharedPreferences.
  Future<void> _loadTombstones() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_tombstonesKey) ?? [];
    _proposalTombstones.addAll(list);
    print('[PROPOSAL] Loaded ${_proposalTombstones.length} tombstones');
  }

  /// Adds [proposalId] to the tombstone set and immediately persists it.
  ///
  /// The in-memory add is synchronous — callers can check [_proposalTombstones]
  /// right after this call without awaiting the SharedPreferences write.
  Future<void> _addTombstone(String proposalId) async {
    _proposalTombstones.add(proposalId); // synchronous, no await needed
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_tombstonesKey, _proposalTombstones.toList());
    print('[PROPOSAL] Tombstone added: $proposalId');
  }

  /// Removes any proposals from the DB/cache that are already tombstoned.
  ///
  /// Handles the race-window where a Nostr event landed between the last
  /// tombstone write and the current app start.
  Future<void> _cleanupZombiesOnStart() async {
    final zombies =
        _proposals.keys.where((id) => _proposalTombstones.contains(id)).toList();
    if (zombies.isEmpty) return;
    print('[PROPOSAL] Cleanup zombies on start: ${zombies.length} removed');
    for (final id in zombies) {
      _proposals.remove(id);
      _votes.remove(id);
      await _deleteProposalFromDb(id);
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

    // Load discussion messages for all cached proposals.
    for (final proposalId in _proposals.keys) {
      try {
        final rows =
            await PodDatabase.instance.listProposalDiscussions(proposalId);
        _discussions[proposalId] =
            rows.map(ProposalDiscussionMessage.fromMap).toList();
      } catch (e) {
        debugPrint('[PROPOSAL] Discussion load error for $proposalId: $e');
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
    // Tombstone synchronously BEFORE the async DB delete (race-condition guard).
    await _addTombstone(proposalId);
    _proposals.remove(proposalId);
    _votes.remove(proposalId);
    _notify(); // live UI update immediately
    await _deleteProposalFromDb(proposalId);
    debugPrint('[PROPOSAL] Draft deleted: $proposalId');
  }

  // ── Status transitions (stubs – implemented in Prompt 1B) ─────────────────

  /// Publishes a DRAFT → DISCUSSION.
  ///
  /// This is the canonical entry point for both G1 compat and G2.
  Future<void> publishProposal(String proposalId) async {
    await publishToDiscussion(proposalId);
  }

  /// DRAFT → DISCUSSION: publishes to Nostr, creates discussion thread,
  /// sends push notification to cell members.
  Future<void> publishToDiscussion(String proposalId) async {
    print('[PROPOSAL] publishToDiscussion: $proposalId');
    final p = _proposals[proposalId];
    if (p == null) throw StateError('Proposal not found: $proposalId');
    if (p.status != ProposalStatus.DRAFT) {
      throw StateError('Only DRAFT can be published (current: ${p.status})');
    }

    p.status = ProposalStatus.DISCUSSION;
    p.discussionStartedAt = DateTime.now().toUtc();
    await _saveProposalToDb(p);

    final published = await _publishProposalToNostr(p);
    if (!published) {
      print('[PROPOSAL] Publish failed, queuing retry');
      await _queueProposalRetry(p);
    }

    await addAuditEntry(AuditLogEntry(
      entryId: AuditLogEntry.generateId(),
      proposalId: p.id,
      cellId: p.cellId,
      eventType: AuditEventType.PROPOSAL_CREATED,
      actorDid: p.creatorDid,
      actorPseudonym: p.creatorPseudonym,
      timestamp: DateTime.now().toUtc(),
      payload: {'title': p.title, 'category': p.category},
    ));

    await _createDiscussionThread(p);

    await _notifyAllMembers(
      p.cellId,
      title: 'Neuer Antrag',
      body: '${p.creatorPseudonym}: ${p.title}',
      payload: 'proposal:${p.id}',
      excludeDid: p.creatorDid,
    );

    _notify();
    print('[PROPOSAL] Published ${p.id} → DISCUSSION');
  }

  /// DISCUSSION → edit title/description while in discussion phase.
  Future<void> editInDiscussion(String proposalId, String newTitle,
      String newDescription, String? reason) async {
    print('[PROPOSAL] editInDiscussion: $proposalId');
    final p = _proposals[proposalId];
    if (p == null) throw StateError('Proposal not found: $proposalId');
    if (p.status != ProposalStatus.DISCUSSION) {
      throw StateError('Only DISCUSSION proposals can be edited');
    }

    final edit = ProposalEdit(
      editId: ProposalEdit.generateId(),
      proposalId: p.id,
      editorDid: p.creatorDid,
      editorPseudonym: p.creatorPseudonym,
      oldTitle: p.title,
      newTitle: newTitle,
      oldDescription: p.description,
      newDescription: newDescription,
      editedAt: DateTime.now().toUtc(),
      editReason: reason,
      versionBefore: p.version,
      versionAfter: p.version + 1,
    );
    await _saveEditToDb(edit);

    print('[PROPOSAL] Edit detected: v${p.version} → v${p.version + 1}');
    p.title = newTitle;
    p.description = newDescription;
    p.version++;
    await _saveProposalToDb(p);

    final published = await _publishProposalToNostr(p, editReason: reason);
    if (!published) await _queueProposalRetry(p);

    await addAuditEntry(AuditLogEntry(
      entryId: AuditLogEntry.generateId(),
      proposalId: p.id,
      cellId: p.cellId,
      eventType: AuditEventType.PROPOSAL_EDITED,
      actorDid: p.creatorDid,
      actorPseudonym: p.creatorPseudonym,
      timestamp: DateTime.now().toUtc(),
      payload: {
        'oldTitle': edit.oldTitle,
        'newTitle': newTitle,
        'versionBefore': edit.versionBefore,
        'versionAfter': edit.versionAfter,
        'reason': reason,
      },
    ));

    await _notifyAllMembers(
      p.cellId,
      title: 'Antrag bearbeitet',
      body: '${p.creatorPseudonym} hat "${p.title}" bearbeitet',
      payload: 'proposal:${p.id}',
      excludeDid: p.creatorDid,
    );

    _notify();
  }

  /// Withdraws a proposal (DRAFT or DISCUSSION only, by creator).
  Future<void> withdrawProposal(String proposalId) async {
    print('[PROPOSAL] withdrawProposal: $proposalId');
    final p = _proposals[proposalId];
    if (p == null) throw StateError('Proposal not found: $proposalId');
    if (p.status != ProposalStatus.DRAFT &&
        p.status != ProposalStatus.DISCUSSION) {
      throw StateError(
          'Cannot withdraw at status ${p.status}');
    }

    final wasInDiscussion = p.discussionStartedAt != null;
    // Tombstone synchronously BEFORE DB write (race-condition guard).
    await _addTombstone(proposalId);
    p.status = ProposalStatus.WITHDRAWN;
    p.withdrawnAt = DateTime.now().toUtc();
    await _saveProposalToDb(p);

    if (wasInDiscussion) {
      // Inform other devices via Nostr.
      await _publishProposalToNostr(p);
    }

    await addAuditEntry(AuditLogEntry(
      entryId: AuditLogEntry.generateId(),
      proposalId: p.id,
      cellId: p.cellId,
      eventType: AuditEventType.PROPOSAL_WITHDRAWN,
      actorDid: p.creatorDid,
      actorPseudonym: p.creatorPseudonym,
      timestamp: DateTime.now().toUtc(),
      payload: {'reason': 'creator_withdrawal'},
    ));

    _notify();
  }

  /// Publishes a Kind-31010 withdrawal event for [proposalId] without any
  /// status-transition checks. Used by the debug cleanup button to notify
  /// peer devices regardless of the current proposal status.
  Future<void> publishProposalWithdrawal(String proposalId) async {
    final p = _proposals[proposalId];
    if (p == null) return;
    await _addTombstone(proposalId);
    await _publishProposalToNostr(p);
  }

  /// Tombstones [proposalId] and deletes all its local data.
  ///
  /// Used by the debug cleanup button so that tombstones are set before the
  /// DB delete, preventing Nostr relay replays from re-inserting the proposal.
  Future<void> tombstoneAndDelete(String proposalId) async {
    // Synchronous in-memory tombstone FIRST.
    await _addTombstone(proposalId);
    // Remove from cache immediately → live UI update.
    _proposals.remove(proposalId);
    _votes.remove(proposalId);
    _notify();
    // Async DB cleanup (safe even if already deleted).
    await _deleteProposalFromDb(proposalId);
    print('[PROPOSAL] tombstoneAndDelete: $proposalId');
  }

  /// DISCUSSION → VOTING. Checks proposalWaitDays constraint.
  Future<void> startVoting(String proposalId) async {
    print('[PROPOSAL] startVoting: $proposalId');
    final p = _proposals[proposalId];
    if (p == null) throw StateError('Proposal not found: $proposalId');
    if (p.status != ProposalStatus.DISCUSSION) {
      throw StateError('Only DISCUSSION can start voting');
    }

    // Check proposalWaitDays.
    final cell = CellService.instance.myCells
        .where((c) => c.id == p.cellId)
        .firstOrNull;
    if (cell != null && cell.proposalWaitDays > 0) {
      final discussionStart =
          p.discussionStartedAt ?? p.createdAt;
      final minStart =
          discussionStart.add(Duration(days: cell.proposalWaitDays));
      if (DateTime.now().toUtc().isBefore(minStart)) {
        throw StateError(
            'Discussion period not yet ended '
            '(${cell.proposalWaitDays} days required)');
      }
    }

    p.status = ProposalStatus.VOTING;
    p.votingStartedAt = DateTime.now().toUtc();
    p.votingEndsAt = DateTime.now().toUtc().add(const Duration(days: 7));
    await _saveProposalToDb(p);

    print('[PROPOSAL] startVoting: $proposalId, ends ${p.votingEndsAt}');

    final published = await _publishProposalToNostr(p);
    if (!published) await _queueProposalRetry(p);

    await addAuditEntry(AuditLogEntry(
      entryId: AuditLogEntry.generateId(),
      proposalId: p.id,
      cellId: p.cellId,
      eventType: AuditEventType.PROPOSAL_STATUS_CHANGED,
      actorDid: p.creatorDid,
      actorPseudonym: p.creatorPseudonym,
      timestamp: DateTime.now().toUtc(),
      payload: {
        'from': 'DISCUSSION',
        'to': 'VOTING',
        'votingEndsAt': p.votingEndsAt!.millisecondsSinceEpoch,
      },
    ));

    await _notifyAllMembers(
      p.cellId,
      title: '🗳️ Abstimmung gestartet',
      body: p.title,
      payload: 'proposal:${p.id}',
    );

    _notify();
  }

  /// VOTING → VOTING_ENDED (grace period start, called by scheduler).
  Future<void> processGracePeriodStart(String proposalId) async {
    print('[PROPOSAL] Grace period started: $proposalId');
    final p = _proposals[proposalId];
    if (p == null) return;
    if (p.status != ProposalStatus.VOTING) return;

    p.status = ProposalStatus.VOTING_ENDED;
    await _saveProposalToDb(p);

    print('[PROPOSAL] Status: VOTING → VOTING_ENDED for $proposalId');
    await _publishProposalToNostr(p);

    await addAuditEntry(AuditLogEntry(
      entryId: AuditLogEntry.generateId(),
      proposalId: p.id,
      cellId: p.cellId,
      eventType: AuditEventType.PROPOSAL_STATUS_CHANGED,
      actorDid: p.creatorDid,
      actorPseudonym: p.creatorPseudonym,
      timestamp: DateTime.now().toUtc(),
      payload: {'from': 'VOTING', 'to': 'VOTING_ENDED'},
    ));

    _notify();
  }

  /// VOTING_ENDED → DECIDED. Counts votes, checks quorum, creates DecisionRecord.
  Future<void> finalizeProposal(String proposalId) async {
    print('[PROPOSAL] Finalizing: $proposalId');
    final p = _proposals[proposalId];
    if (p == null) return;
    if (p.status != ProposalStatus.VOTING_ENDED) return;

    // Load votes directly from DB – the in-memory cache may be incomplete if
    // votes arrived on other devices while this device was offline.
    final voteRows = await PodDatabase.instance.listVotes(proposalId);
    final votes = voteRows.map(Vote.fromMap).toList();
    print('[PROPOSAL] finalizeProposal: ${votes.length} votes loaded from DB');
    // Sync the cache so UI reflects the same data.
    _votes[proposalId] = votes;

    final yes = votes.where((v) => v.choice == VoteChoice.YES).length;
    final no = votes.where((v) => v.choice == VoteChoice.NO).length;
    final abstain = votes.where((v) => v.choice == VoteChoice.ABSTAIN).length;
    print('[PROPOSAL] Counted: Y=$yes N=$no A=$abstain');

    // Load member count from DB – the in-memory membersOf() may be stale.
    final totalMembers = await CellService.instance.getMemberCount(p.cellId);
    final participation = totalMembers > 0
        ? (yes + no + abstain) / totalMembers
        : 0.0;
    print('[PROPOSAL] Participation: ${(participation * 100).toStringAsFixed(1)}% (${yes + no + abstain} of $totalMembers members)');

    String result;
    if (participation < p.quorumRequired) {
      result = 'invalid';
    } else if (yes > no) {
      result = 'approved';
    } else {
      result = 'rejected'; // Gleichstand → Status quo (Nein)
    }

    print('[PROPOSAL] Quorum: $yes+$no+$abstain/$totalMembers = '
        '${(participation * 100).toStringAsFixed(1)}%');
    print('[PROPOSAL] Result: $result (J:$yes N:$no E:$abstain)');

    p.status = ProposalStatus.DECIDED;
    p.decidedAt = DateTime.now().toUtc();
    p.resultSummary = result;
    p.resultYes = yes;
    p.resultNo = no;
    p.resultAbstain = abstain;
    p.resultParticipation = participation;
    await _saveProposalToDb(p);

    print('[PROPOSAL] Status: VOTING_ENDED → DECIDED for $proposalId');
    await _publishProposalToNostr(p);

    // Build DecisionRecord.
    final previousHash = await _getLastDecisionHashForCell(p.cellId);
    final recordContent = SplayTreeMap<String, dynamic>.from({
      'proposalId': p.id,
      'finalTitle': p.title,
      'finalDescription': p.description,
      'result': result,
      'yesVotes': yes,
      'noVotes': no,
      'abstainVotes': abstain,
      'participation': participation,
      'decidedAt': p.decidedAt!.millisecondsSinceEpoch,
      'allVotes': votes
          .map((v) => {
                'voterPseudonym': v.voterPseudonym,
                'choice': v.choice.name,
                'reasoning': v.reasoning,
                'createdAt': v.createdAt.millisecondsSinceEpoch,
              })
          .toList(),
    });
    final contentHash = _calculateContentHash(recordContent);

    print('[PROPOSAL] Content hash: $contentHash');
    print('[PROPOSAL] Previous hash: $previousHash');

    final record = DecisionRecord(
      recordId: DecisionRecord.generateId(),
      proposalId: p.id,
      cellId: p.cellId,
      finalTitle: p.title,
      finalDescription: p.description,
      result: result,
      yesVotes: yes,
      noVotes: no,
      abstainVotes: abstain,
      participation: participation,
      decidedAt: p.decidedAt!,
      allVotes: votes,
      contentHash: contentHash,
      previousDecisionHash: previousHash,
      nostrEventId: '',
    );
    await _saveDecisionRecordToDb(record);

    final recordMap = SplayTreeMap<String, dynamic>.from(recordContent);
    final published = await _publishDecisionRecord(
      proposalId: p.id,
      cellId: p.cellId,
      recordContent: Map<String, dynamic>.from(recordMap),
      result: result,
      contentHash: contentHash,
      previousDecisionHash: previousHash,
    );
    if (!published) {
      print('[PROPOSAL] Decision record publish failed, queuing retry');
      await _queueDecisionRetry(
        proposalId: p.id,
        cellId: p.cellId,
        recordContent: Map<String, dynamic>.from(recordMap),
        result: result,
        contentHash: contentHash,
        previousDecisionHash: previousHash,
      );
    } else {
      print('[PROPOSAL] Decision record published: ${record.recordId}');
    }

    await addAuditEntry(AuditLogEntry(
      entryId: AuditLogEntry.generateId(),
      proposalId: p.id,
      cellId: p.cellId,
      eventType: AuditEventType.RESULT_CALCULATED,
      actorDid: p.creatorDid,
      actorPseudonym: p.creatorPseudonym,
      timestamp: DateTime.now().toUtc(),
      payload: {
        'result': result,
        'yes': yes,
        'no': no,
        'abstain': abstain,
        'participation': participation,
        'totalMembers': totalMembers,
      },
    ));

    final resultLabel = result == 'approved'
        ? 'Angenommen'
        : result == 'rejected'
            ? 'Abgelehnt'
            : 'Ungültig (Quorum)';
    await _notifyAllMembers(
      p.cellId,
      title: 'Abstimmung beendet',
      body: '${p.title}: $resultLabel',
      payload: 'proposal:${p.id}',
    );

    _notify();
  }

  /// DECIDED → ARCHIVED (manual or auto after 30 days).
  Future<void> archiveProposal(String proposalId) async {
    final p = _proposals[proposalId];
    if (p == null) return;
    if (p.status != ProposalStatus.DECIDED) return;

    p.status = ProposalStatus.ARCHIVED;
    p.archivedAt = DateTime.now().toUtc();
    await _saveProposalToDb(p);

    await _publishProposalToNostr(p);

    await addAuditEntry(AuditLogEntry(
      entryId: AuditLogEntry.generateId(),
      proposalId: p.id,
      cellId: p.cellId,
      eventType: AuditEventType.PROPOSAL_ARCHIVED,
      actorDid: p.creatorDid,
      actorPseudonym: p.creatorPseudonym,
      timestamp: DateTime.now().toUtc(),
      payload: {},
    ));

    _notify();
  }

  // ── Voting ─────────────────────────────────────────────────────────────────

  /// Cast or change a vote on a VOTING proposal.
  ///
  /// If the caller already voted, the old vote is replaced.
  Future<void> castVote(String proposalId, VoteChoice choice,
      {String? reasoning}) async {
    print('[VOTE] castVote: $choice for $proposalId');
    final p = _proposals[proposalId];
    if (p == null) throw StateError('Proposal not found');
    if (p.status != ProposalStatus.VOTING) {
      throw StateError('Voting not active (status: ${p.status})');
    }

    final myDid = IdentityService.instance.currentIdentity?.did;
    if (myDid == null) throw StateError('No identity');

    final isMember = CellService.instance.isMember(p.cellId);
    if (!isMember) throw StateError('Not a member of this cell');

    final existingVotes = _votes[proposalId] ?? [];
    final myExisting = existingVotes
        .where((v) => v.voterDid == myDid)
        .firstOrNull;
    final isChange = myExisting != null;

    final myPubkey = getMyNostrPubkeyHex?.call() ?? '';
    final vote = Vote(
      voteId: Vote.generateId(),
      proposalId: proposalId,
      voterPubkey: myPubkey,
      voterDid: myDid,
      voterPseudonym: IdentityService.instance.currentIdentity!.pseudonym,
      choice: choice,
      reasoning: reasoning,
      createdAt: DateTime.now().toUtc(),
      nostrEventId: '',
    );

    // DB: upsert (UNIQUE(proposal_id, voter_pubkey) → REPLACE).
    await _saveVoteToDb(vote);

    // Memory: replace existing or add new.
    final updated = List<Vote>.from(existingVotes)
      ..removeWhere((v) => v.voterDid == myDid);
    updated.add(vote);
    _votes[proposalId] = updated;

    final published = await _publishVoteToNostr(
      proposalId: proposalId,
      cellId: p.cellId,
      vote: vote,
    );
    if (!published) await _queueVoteRetry(vote, p.cellId);

    await addAuditEntry(AuditLogEntry(
      entryId: AuditLogEntry.generateId(),
      proposalId: proposalId,
      cellId: p.cellId,
      eventType: isChange ? AuditEventType.VOTE_CHANGED : AuditEventType.VOTE_CAST,
      actorDid: myDid,
      actorPseudonym: vote.voterPseudonym,
      timestamp: DateTime.now().toUtc(),
      payload: {
        'choice': choice.name,
        if (reasoning != null) 'reasoning': reasoning,
        if (isChange) 'previousChoice': myExisting.choice.name,
      },
    ));

    _notify();
  }

  /// Alias – changeVote delegates to castVote (same semantics).
  Future<void> changeVote(String proposalId, VoteChoice newChoice,
      {String? newReasoning}) async {
    await castVote(proposalId, newChoice, reasoning: newReasoning);
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
    print('[G2-UI] My proposals filter: $myDid found ${_proposals.values.where((p) => p.creatorDid == myDid || (_votes[p.id]?.any((v) => v.voterDid == myDid) ?? false)).length}');
    return _proposals.values
        .where((p) =>
            p.creatorDid == myDid ||
            (_votes[p.id]?.any((v) => v.voterDid == myDid) ?? false))
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

  // ── Proposal discussions ──────────────────────────────────────────────────

  List<ProposalDiscussionMessage> getDiscussionMessages(String proposalId) {
    final msgs = _discussions[proposalId] ?? [];
    print('[G2-UI] Audit log filter for proposal $proposalId: ${msgs.length} entries');
    return List.unmodifiable(msgs);
  }

  Future<void> postDiscussionMessage(String proposalId, String content) async {
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final myPseudo = IdentityService.instance.currentIdentity?.pseudonym ?? '';
    final id = 'disc_${DateTime.now().millisecondsSinceEpoch}_${proposalId.substring(0, 8)}';

    final disc = ProposalDiscussionMessage(
      id: id,
      proposalId: proposalId,
      authorDid: myDid,
      authorPseudonym: myPseudo,
      content: content,
      createdAt: DateTime.now().toUtc(),
    );

    print('[G2-UI] Posting discussion message');
    await _saveDiscussion(disc);
    _notify();

    final fn = onSendDiscussionMessage;
    if (fn != null) {
      await fn({
        'id': id,
        'proposalId': proposalId,
        'content': content,
        'authorPseudonym': myPseudo,
      });
    }
  }

  Future<void> handleDiscussionMessage(Map<String, dynamic> params) async {
    final proposalId = params['proposalId'] as String? ?? '';
    if (proposalId.isEmpty) return;
    // Only store if we know this proposal
    if (!_proposals.containsKey(proposalId)) return;

    final disc = ProposalDiscussionMessage(
      id: params['id'] as String? ?? '',
      proposalId: proposalId,
      authorDid: params['authorDid'] as String? ?? '',
      authorPseudonym: params['authorPseudonym'] as String? ?? '',
      content: params['content'] as String? ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          params['createdAt'] as int? ?? 0,
          isUtc: true),
    );
    if (disc.id.isEmpty || disc.content.isEmpty) return;

    await _saveDiscussion(disc);
    _notify();
  }

  Future<void> _saveDiscussion(ProposalDiscussionMessage disc) async {
    _discussions.putIfAbsent(disc.proposalId, () => []);
    final list = _discussions[disc.proposalId]!;
    if (!list.any((d) => d.id == disc.id)) {
      list.add(disc);
      list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }
    try {
      await PodDatabase.instance.insertProposalDiscussion(disc.toMap());
    } catch (_) {}
  }

  // ── Incoming Nostr event handlers ─────────────────────────────────────────

  /// Processes a received Kind-31010 proposal event from Nostr.
  ///
  /// Creates or updates the local proposal. Edit and status-change audit
  /// entries are generated so both devices build an identical audit log.
  Future<void> handleIncomingProposal(NostrEvent event) async {
    print('[PROPOSAL] handleIncomingProposal: ${event.id}');
    try {
      final proposalId = event.tagValue('d');
      final cellId = event.tagValues('t')
          .where((v) => v.startsWith('nexus-cell-'))
          .map((v) => v.substring('nexus-cell-'.length))
          .firstOrNull;
      final type = event.tagValue('type');
      final statusStr = event.tagValue('status');
      final versionStr = event.tagValue('version');
      final category = event.tagValue('category');
      final votingEndsAtStr = event.tagValue('voting_ends_at');

      if (proposalId == null || cellId == null) {
        print('[PROPOSAL] handleIncomingProposal: missing d/nexus-cell tag, skipping');
        return;
      }

      // TOMBSTONE CHECK: never re-import a deleted/withdrawn proposal.
      if (_proposalTombstones.contains(proposalId)) {
        print('[PROPOSAL] Ignoring tombstoned proposal: $proposalId');
        return;
      }

      // Only process events for cells we are a member of.
      if (!CellService.instance.isMember(cellId)) {
        print('[PROPOSAL] Ignoring – not a member of cell $cellId');
        return;
      }

      final content = jsonDecode(event.content) as Map<String, dynamic>;
      final version = int.tryParse(versionStr ?? '1') ?? 1;
      final newStatus = ProposalStatus.values.firstWhere(
        (e) => e.name == (statusStr ?? 'DRAFT').toUpperCase(),
        orElse: () => ProposalStatus.DRAFT,
      );

      // WITHDRAWN from another device: tombstone + delete locally so it never
      // comes back via relay replay on this device either.
      if (newStatus == ProposalStatus.WITHDRAWN) {
        print('[PROPOSAL] Withdraw received, tombstoning: $proposalId');
        await _addTombstone(proposalId);
        _proposals.remove(proposalId);
        _votes.remove(proposalId);
        await _deleteProposalFromDb(proposalId);
        _notify();
        return;
      }

      final existing = _proposals[proposalId];

      if (existing != null) {
        final newTitle = content['title'] as String? ?? existing.title;
        final newDesc = content['description'] as String? ?? existing.description;

        // An edit requires both a content change AND a higher version number.
        final isContentEdit =
            (existing.title != newTitle || existing.description != newDesc) &&
                version > existing.version;
        final isStatusChange = existing.status != newStatus;

        // Nothing relevant changed – skip silently.
        if (!isContentEdit && !isStatusChange) {
          print(
              '[PROPOSAL] Ignoring – no content or status change (v$version, ${newStatus.name})');
          return;
        }

        if (isContentEdit) {
          print('[PROPOSAL] Edit detected: v${existing.version} → v$version');
          final edit = ProposalEdit(
            editId: ProposalEdit.generateId(),
            proposalId: proposalId,
            editorDid: existing.creatorDid,
            editorPseudonym: existing.creatorPseudonym,
            oldTitle: existing.title,
            newTitle: newTitle,
            oldDescription: existing.description,
            newDescription: newDesc,
            editedAt: DateTime.fromMillisecondsSinceEpoch(
                event.createdAt * 1000,
                isUtc: true),
            editReason: content['editReason'] as String?,
            versionBefore: existing.version,
            versionAfter: version,
          );
          await _saveEditToDb(edit);

          await addAuditEntry(AuditLogEntry(
            entryId: AuditLogEntry.generateId(),
            proposalId: proposalId,
            cellId: cellId,
            eventType: AuditEventType.PROPOSAL_EDITED,
            actorDid: existing.creatorDid,
            actorPseudonym: existing.creatorPseudonym,
            timestamp: edit.editedAt,
            payload: {
              'oldTitle': existing.title,
              'newTitle': newTitle,
              'versionBefore': existing.version,
              'versionAfter': version,
              'reason': content['editReason'],
            },
          ));
        }

        // Status change – always process regardless of version.
        if (isStatusChange) {
          print(
              '[PROPOSAL] Status: ${existing.status.name} → ${newStatus.name}');
          await addAuditEntry(AuditLogEntry(
            entryId: AuditLogEntry.generateId(),
            proposalId: proposalId,
            cellId: cellId,
            eventType: AuditEventType.PROPOSAL_STATUS_CHANGED,
            actorDid: existing.creatorDid,
            actorPseudonym: existing.creatorPseudonym,
            timestamp: DateTime.fromMillisecondsSinceEpoch(
                event.createdAt * 1000,
                isUtc: true),
            payload: {
              'from': existing.status.name,
              'to': newStatus.name,
            },
          ));
        }

        // Apply updates.
        if (isContentEdit) {
          existing.title = newTitle;
          existing.description = newDesc;
          existing.version = version;
        }
        existing.status = newStatus;
        if (category != null) existing.category = category;
        if (votingEndsAtStr != null) {
          final ts = int.tryParse(votingEndsAtStr);
          if (ts != null) {
            existing.votingEndsAt =
                DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true);
          }
        }
        await _saveProposalToDb(existing);
      } else {
        // New proposal – create from event.
        final createdAtTs = content['createdAt'] as int? ?? event.createdAt;
        final proposal = Proposal(
          id: proposalId,
          cellId: cellId,
          creatorDid: content['creatorDid'] as String? ?? '',
          creatorPseudonym: content['creatorPseudonym'] as String? ?? '',
          title: content['title'] as String? ?? '',
          description: content['description'] as String? ?? '',
          proposalType: ProposalType.values.firstWhere(
            (e) => e.name == (type ?? 'SACHFRAGE').toUpperCase(),
            orElse: () => ProposalType.SACHFRAGE,
          ),
          category: category,
          status: newStatus,
          createdAt: DateTime.fromMillisecondsSinceEpoch(
              createdAtTs * 1000,
              isUtc: true),
          version: version,
          votingEndsAt: votingEndsAtStr != null
              ? DateTime.fromMillisecondsSinceEpoch(
                  int.parse(votingEndsAtStr) * 1000,
                  isUtc: true)
              : null,
        );

        await _saveProposalToDb(proposal);
        _proposals[proposalId] = proposal;

        await addAuditEntry(AuditLogEntry(
          entryId: AuditLogEntry.generateId(),
          proposalId: proposalId,
          cellId: cellId,
          eventType: AuditEventType.PROPOSAL_CREATED,
          actorDid: proposal.creatorDid,
          actorPseudonym: proposal.creatorPseudonym,
          timestamp: proposal.createdAt,
          payload: {'title': proposal.title, 'category': proposal.category},
          nostrEventId: event.id,
        ));

        // Notify only if not own event.
        final myDid = IdentityService.instance.currentIdentity?.did;
        if (proposal.creatorDid != myDid &&
            newStatus == ProposalStatus.DISCUSSION) {
          await _notifyAllMembers(
            cellId,
            title: 'Neuer Antrag',
            body: '${proposal.creatorPseudonym}: ${proposal.title}',
            payload: 'proposal:$proposalId',
            excludeDid: proposal.creatorDid,
          );
        }
      }

      _notify();
    } catch (e) {
      print('[PROPOSAL] handleIncomingProposal error: $e');
    }
  }

  /// Processes a received Kind-31011 vote event from Nostr.
  Future<void> handleIncomingVote(NostrEvent event) async {
    print('[VOTE] handleIncomingVote: ${event.id}');
    try {
      // Skip echo of own votes – castVote() already wrote the audit entry locally.
      final myPubkey = getMyNostrPubkeyHex?.call();
      if (myPubkey != null && myPubkey.isNotEmpty && event.pubkey == myPubkey) {
        print('[VOTE] Echo of own vote ignored: ${event.id}');
        return;
      }

      // Dedup: the same event can arrive from multiple relays.
      if (await PodDatabase.instance.hasAuditEntryForNostrEvent(event.id)) {
        print('[VOTE] Already processed: ${event.id}');
        return;
      }

      final proposalId = event.tagValue('e');
      final cellId = event.tagValues('t')
          .where((v) => v.startsWith('nexus-cell-'))
          .map((v) => v.substring('nexus-cell-'.length))
          .firstOrNull;
      final choiceStr = event.tagValue('choice');

      if (proposalId == null || cellId == null || choiceStr == null) {
        print('[VOTE] handleIncomingVote: missing tags, skipping');
        return;
      }

      // TOMBSTONE CHECK: ignore votes for deleted proposals.
      if (_proposalTombstones.contains(proposalId)) {
        print('[VOTE] Ignoring vote for tombstoned proposal: $proposalId');
        return;
      }

      if (!CellService.instance.isMember(cellId)) return;

      final p = _proposals[proposalId];
      if (p == null) {
        print('[VOTE] handleIncomingVote: unknown proposal $proposalId, skipping');
        return;
      }

      // Grace period: accept votes created before the deadline, reject after.
      AuditEventType? lateType;
      if (p.status == ProposalStatus.VOTING_ENDED) {
        final voteCreatedAt = DateTime.fromMillisecondsSinceEpoch(
            event.createdAt * 1000,
            isUtc: true);
        if (p.votingEndsAt != null &&
            voteCreatedAt.isAfter(p.votingEndsAt!)) {
          print('[VOTE] Late REJECTED - created after deadline');
          await addAuditEntry(AuditLogEntry(
            entryId: AuditLogEntry.generateId(),
            proposalId: proposalId,
            cellId: cellId,
            eventType: AuditEventType.VOTE_LATE_REJECTED,
            actorDid: '',
            actorPseudonym: '',
            timestamp: voteCreatedAt,
            payload: {
              'voterPubkey': event.pubkey,
              'createdAt': voteCreatedAt.millisecondsSinceEpoch,
              'deadline': p.votingEndsAt!.millisecondsSinceEpoch,
            },
          ));
          return;
        }
        print('[VOTE] Late accepted (created before deadline)');
        lateType = AuditEventType.VOTE_LATE_ACCEPTED;
      } else if (p.status != ProposalStatus.VOTING) {
        return; // Voting not open
      }

      final content = jsonDecode(event.content) as Map<String, dynamic>;
      final choice = VoteChoice.values.firstWhere(
        (c) => c.name == choiceStr.toUpperCase(),
        orElse: () => VoteChoice.ABSTAIN,
      );

      final vote = Vote(
        voteId: content['voteId'] as String? ?? Vote.generateId(),
        proposalId: proposalId,
        voterPubkey: event.pubkey,
        voterDid: content['voterDid'] as String? ?? '',
        voterPseudonym: content['voterPseudonym'] as String? ?? '',
        choice: choice,
        reasoning: content['reasoning'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (content['createdAt'] as int? ?? event.createdAt) * 1000,
            isUtc: true),
        nostrEventId: event.id,
      );

      final existingVotes = _votes[proposalId] ?? [];
      final existing = existingVotes
          .where((v) => v.voterPubkey == event.pubkey)
          .firstOrNull;
      final isChange = existing != null;

      // DB: upsert handles UNIQUE(proposal_id, voter_pubkey) replacement.
      await _saveVoteToDb(vote);

      // Memory: replace.
      final updated = List<Vote>.from(existingVotes)
        ..removeWhere((v) => v.voterPubkey == event.pubkey);
      updated.add(vote);
      _votes[proposalId] = updated;

      if (isChange) {
        print('[VOTE] Updated (replaced existing)');
      }

      final eventType = lateType ??
          (isChange ? AuditEventType.VOTE_CHANGED : AuditEventType.VOTE_CAST);

      if (isChange) {
        print('[VOTE] Previous choice: ${existing?.choice.name}');
      }

      await addAuditEntry(AuditLogEntry(
        entryId: AuditLogEntry.generateId(),
        proposalId: proposalId,
        cellId: cellId,
        eventType: eventType,
        actorDid: vote.voterDid,
        actorPseudonym: vote.voterPseudonym,
        timestamp: vote.createdAt,
        payload: {
          'choice': vote.choice.name,
          if (vote.reasoning != null) 'reasoning': vote.reasoning,
          if (isChange && existing != null) 'previousChoice': existing.choice.name,
        },
        nostrEventId: event.id,
      ));

      _notify();
    } catch (e) {
      print('[VOTE] handleIncomingVote error: $e');
    }
  }

  /// Processes a received Kind-31013 decision record from Nostr.
  Future<void> handleIncomingDecisionRecord(NostrEvent event) async {
    print('[PROPOSAL] handleIncomingDecisionRecord: ${event.id}');
    try {
      final cellId = event.tagValues('t')
          .where((v) => v.startsWith('nexus-cell-'))
          .map((v) => v.substring('nexus-cell-'.length))
          .firstOrNull;
      if (cellId == null || !CellService.instance.isMember(cellId)) return;

      final content = jsonDecode(event.content) as Map<String, dynamic>;
      final proposalId = content['proposalId'] as String?;
      if (proposalId == null) return;

      // TOMBSTONE CHECK: ignore decision records for deleted proposals.
      if (_proposalTombstones.contains(proposalId)) {
        print('[PROPOSAL] Ignoring decision record for tombstoned proposal: $proposalId');
        return;
      }

      // Skip if we already have this record (e.g. we created it).
      final existing = await _getDecisionRecordByProposal(proposalId);
      if (existing != null) {
        print('[PROPOSAL] Decision record already exists for $proposalId, skipping');
        return;
      }

      final record = DecisionRecord(
        recordId: DecisionRecord.generateId(),
        proposalId: proposalId,
        cellId: cellId,
        finalTitle: content['finalTitle'] as String? ?? '',
        finalDescription: content['finalDescription'] as String? ?? '',
        result: content['result'] as String? ?? 'invalid',
        yesVotes: content['yesVotes'] as int? ?? 0,
        noVotes: content['noVotes'] as int? ?? 0,
        abstainVotes: content['abstainVotes'] as int? ?? 0,
        participation: (content['participation'] as num?)?.toDouble() ?? 0.0,
        decidedAt: DateTime.fromMillisecondsSinceEpoch(
            content['decidedAt'] as int? ?? 0,
            isUtc: true),
        allVotes: const [], // votes are tracked separately via Kind-31011
        contentHash: event.tagValue('content_hash') ?? '',
        previousDecisionHash: event.tagValue('prev_hash'),
        nostrEventId: event.id,
      );

      await _saveDecisionRecordToDb(record);
      print('[PROPOSAL] Decision record saved from Nostr for $proposalId');

      // Bug B fix: update the local proposal with the authoritative result
      // values from the received decision record so that all devices show the
      // same outcome regardless of which device ran finalizeProposal().
      final localProposal = _proposals[proposalId];
      if (localProposal != null) {
        print('[PROPOSAL] Updating local proposal with decision record values');
        print('[PROPOSAL]   Y=${record.yesVotes} N=${record.noVotes} '
            'A=${record.abstainVotes} Participation=${record.participation} '
            'Result=${record.result}');

        localProposal.status = ProposalStatus.DECIDED;
        localProposal.decidedAt = record.decidedAt;
        localProposal.resultSummary = record.result;
        localProposal.resultYes = record.yesVotes;
        localProposal.resultNo = record.noVotes;
        localProposal.resultAbstain = record.abstainVotes;
        localProposal.resultParticipation = record.participation;

        await _saveProposalToDb(localProposal);

        final myIdentity = IdentityService.instance.currentIdentity;
        await addAuditEntry(AuditLogEntry(
          entryId: AuditLogEntry.generateId(),
          proposalId: proposalId,
          cellId: record.cellId,
          eventType: AuditEventType.RESULT_CALCULATED,
          actorDid: myIdentity?.did ?? '',
          actorPseudonym: myIdentity?.pseudonym ?? '',
          timestamp: DateTime.now().toUtc(),
          payload: {
            'result': record.result,
            'yes': record.yesVotes,
            'no': record.noVotes,
            'abstain': record.abstainVotes,
            'participation': record.participation,
            'source': 'decision_record_received',
          },
          nostrEventId: event.id,
        ));

        _notify();
      }
    } catch (e) {
      print('[PROPOSAL] handleIncomingDecisionRecord error: $e');
    }
  }

  // ── Retry queue ────────────────────────────────────────────────────────────

  Future<void> _queueProposalRetry(Proposal p) async {
    print('[PROPOSAL] Queuing retry for ${p.id}');
    _retryQueue.add({'type': 'proposal', 'proposalId': p.id, 'attempts': 0});
    _startRetryTimer();
  }

  Future<void> _queueVoteRetry(Vote vote, String cellId) async {
    print('[VOTE] Queuing retry for ${vote.voteId}');
    _retryQueue.add({
      'type': 'vote',
      'voteId': vote.voteId,
      'proposalId': vote.proposalId,
      'cellId': cellId,
      'attempts': 0,
    });
    _startRetryTimer();
  }

  Future<void> _queueDecisionRetry({
    required String proposalId,
    required String cellId,
    required Map<String, dynamic> recordContent,
    required String result,
    required String contentHash,
    String? previousDecisionHash,
  }) async {
    print('[PROPOSAL] Queuing retry for decision record $proposalId');
    _retryQueue.add({
      'type': 'decision',
      'proposalId': proposalId,
      'cellId': cellId,
      'recordContent': recordContent,
      'result': result,
      'contentHash': contentHash,
      'previousDecisionHash': previousDecisionHash,
      'attempts': 0,
    });
    _startRetryTimer();
  }

  void _startRetryTimer() {
    if (_retryTimer != null && _retryTimer!.isActive) return;
    _retryTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      _processRetryQueue();
    });
  }

  Future<void> _processRetryQueue() async {
    if (_retryQueue.isEmpty) {
      _retryTimer?.cancel();
      _retryTimer = null;
      return;
    }

    print('[PROPOSAL] Processing retry queue: ${_retryQueue.length} items');

    final processed = <Map<String, dynamic>>[];
    for (final item in List.from(_retryQueue)) {
      item['attempts'] = (item['attempts'] as int) + 1;
      bool success = false;

      try {
        if (item['type'] == 'proposal') {
          final p = _proposals[item['proposalId'] as String];
          if (p != null) success = await _publishProposalToNostr(p);
        } else if (item['type'] == 'vote') {
          final proposalId = item['proposalId'] as String;
          final voteId = item['voteId'] as String;
          final cellId = item['cellId'] as String;
          final votes = _votes[proposalId] ?? [];
          final vote =
              votes.where((v) => v.voteId == voteId).firstOrNull;
          if (vote != null) {
            success = await _publishVoteToNostr(
                proposalId: proposalId, cellId: cellId, vote: vote);
          } else {
            success = true; // vote no longer relevant
          }
        } else if (item['type'] == 'decision') {
          success = await _publishDecisionRecord(
            proposalId: item['proposalId'] as String,
            cellId: item['cellId'] as String,
            recordContent:
                Map<String, dynamic>.from(item['recordContent'] as Map),
            result: item['result'] as String,
            contentHash: item['contentHash'] as String,
            previousDecisionHash: item['previousDecisionHash'] as String?,
          );
        }
      } catch (e) {
        print('[PROPOSAL] Retry error: $e');
      }

      if (success || (item['attempts'] as int) >= 10) {
        if ((item['attempts'] as int) >= 10 && !success) {
          print('[PROPOSAL] Retry abandoned after 10 attempts: ${item['type']}');
        }
        processed.add(item);
      }
    }

    for (final item in processed) {
      _retryQueue.remove(item);
    }
  }

  // ── Private Nostr publish wrappers ─────────────────────────────────────────

  Future<bool> _publishProposalToNostr(Proposal p,
      {String? editReason}) async {
    final fn = onPublishProposalToNostr;
    if (fn == null) return false;
    return fn({
      'proposalId': p.id,
      'cellId': p.cellId,
      'type': p.proposalType.name,
      'status': p.status.name,
      'title': p.title,
      'description': p.description,
      'creatorDid': p.creatorDid,
      'creatorPseudonym': p.creatorPseudonym,
      'createdAt': p.createdAt.millisecondsSinceEpoch ~/ 1000,
      'version': p.version,
      if (p.category != null) 'category': p.category,
      if (p.votingEndsAt != null)
        'votingEndsAt': p.votingEndsAt!.millisecondsSinceEpoch ~/ 1000,
      if (editReason != null) 'editReason': editReason,
    });
  }

  Future<bool> _publishVoteToNostr({
    required String proposalId,
    required String cellId,
    required Vote vote,
  }) async {
    final fn = onPublishVoteToNostr;
    if (fn == null) return false;
    return fn({
      'proposalId': proposalId,
      'cellId': cellId,
      'voteId': vote.voteId,
      'choiceName': vote.choice.name,
      'voterDid': vote.voterDid,
      'voterPseudonym': vote.voterPseudonym,
      'createdAt': vote.createdAt.millisecondsSinceEpoch ~/ 1000,
      if (vote.reasoning != null) 'reasoning': vote.reasoning,
    });
  }

  Future<bool> _publishDecisionRecord({
    required String proposalId,
    required String cellId,
    required Map<String, dynamic> recordContent,
    required String result,
    required String contentHash,
    String? previousDecisionHash,
  }) async {
    final fn = onPublishDecisionToNostr;
    if (fn == null) return false;
    return fn({
      'proposalId': proposalId,
      'cellId': cellId,
      'recordContent': recordContent,
      'result': result,
      'contentHash': contentHash,
      'previousDecisionHash': previousDecisionHash,
    });
  }

  // ── Hash calculation ────────────────────────────────────────────────────────

  /// Deterministic SHA-256 hash of the content map.
  ///
  /// Keys are sorted alphabetically (SplayTreeMap), serialised to canonical
  /// JSON (utf8), then SHA-256 hashed. This is stable across all devices.
  String _calculateContentHash(Map<String, dynamic> content) {
    final sorted = SplayTreeMap<String, dynamic>.from(content);
    final jsonStr = jsonEncode(sorted);
    final bytes = utf8.encode(jsonStr);
    final digest = pkg_crypto.sha256.convert(bytes);
    return digest.toString();
  }

  /// Returns the `content_hash` of the most recent DecisionRecord for a cell,
  /// or null if none exists yet. Used for the hash-chain in DecisionRecords.
  Future<String?> _getLastDecisionHashForCell(String cellId) async {
    final rows =
        await PodDatabase.instance.listDecisionRecords(cellId: cellId);
    if (rows.isEmpty) return null;
    // listDecisionRecords returns rows ordered DESC by decided_at.
    return rows.first['content_hash'] as String?;
  }

  Future<DecisionRecord?> _getDecisionRecordByProposal(
      String proposalId) async {
    final row = await PodDatabase.instance.getDecisionRecord(proposalId);
    if (row == null) return null;
    return DecisionRecord.fromMap(row);
  }

  // ── Discussion thread helper ───────────────────────────────────────────────

  Future<void> _createDiscussionThread(Proposal p) async {
    // Placeholder: in a future iteration this will post a message to the
    // cell's discussion Group Channel.
    print('[PROPOSAL] Discussion thread created in cell ${p.cellId}: "${p.title}"');
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
    // Tombstone all proposals for this cell BEFORE DB delete.
    final toTombstone =
        _proposals.values.where((p) => p.cellId == cellId).map((p) => p.id).toList();
    for (final id in toTombstone) {
      await _addTombstone(id);
    }
    debugPrint('[PROPOSAL] Tombstoned ${toTombstone.length} proposals for cell $cellId');
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

  Future<void> _saveEditToDb(ProposalEdit edit) async {
    await PodDatabase.instance.insertProposalEdit(edit.toMap());
  }

  Future<void> _saveVoteToDb(Vote vote) async {
    // upsertVote uses REPLACE conflict algorithm on UNIQUE(proposal_id,
    // voter_pubkey), so this handles both insert and change-vote.
    await PodDatabase.instance.upsertVote(vote.toMap());
  }

  Future<void> _saveDecisionRecordToDb(DecisionRecord record) async {
    await PodDatabase.instance.insertDecisionRecord(record.toMap());
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
    String? excludeDid,
  }) async {
    // excludeDid is reserved for future per-member push; currently we show one
    // local notification and skip it if the actor is the current user.
    final myDid = IdentityService.instance.currentIdentity?.did;
    if (excludeDid != null && excludeDid == myDid) return;
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
