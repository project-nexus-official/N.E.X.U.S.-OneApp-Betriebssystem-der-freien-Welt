import 'dart:convert';
import 'dart:math';

/// Type of proposal within the Menschheitsfamilie governance system.
enum ProposalType {
  /// Standard factual question (Sachfrage).
  SACHFRAGE,

  /// Constitutional / foundational question (Verfassungsfrage).
  VERFASSUNGSFRAGE,
}

/// Lifecycle status of a proposal.
enum ProposalStatus {
  DRAFT,
  DISCUSSION,
  VOTING,

  /// Voting period ended; grace period for late votes running.
  VOTING_ENDED,

  DECIDED,
  ARCHIVED,
  WITHDRAWN,
}

/// Scope of a proposal (kept for UI compatibility from G1).
/// Only CELL-scope proposals are functional in G2.
enum ProposalScope {
  cell,
  federation,
  global,
}

/// Allowed topic domains for proposals.
const proposalDomains = [
  'Umwelt',
  'Infrastruktur',
  'Soziales',
  'Wirtschaft',
  'Governance',
  'Sonstiges',
];

String _generateProposalId() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final rng = Random.secure();
  return List.generate(32, (_) => chars[rng.nextInt(chars.length)]).join();
}

/// A governance proposal within a cell.
///
/// G2 model: direct-column persistence in the `proposals` table.
/// Legacy G1 data lives in `proposals_legacy` and is migrated on first load.
class Proposal {
  final String id;
  final String cellId;
  final String creatorDid;
  final String creatorPseudonym;
  String title;
  String description;
  ProposalType proposalType;
  String? category;
  ProposalStatus status;
  final DateTime createdAt;
  DateTime? discussionStartedAt;
  DateTime? votingStartedAt;
  DateTime? votingEndsAt;
  DateTime? decidedAt;
  DateTime? archivedAt;
  DateTime? withdrawnAt;
  double quorumRequired;
  int gracePeriodHours;
  int version;
  String? previousDecisionHash;
  List<String> impulseSupporters;
  String? resultSummary;
  int? resultYes;
  int? resultNo;
  int? resultAbstain;
  double? resultParticipation;

  // ── G1 compatibility fields (still used by GovernanceScreen / CreateProposalScreen) ──
  ProposalScope scope;
  String domain;

  Proposal({
    required this.id,
    required this.cellId,
    required this.creatorDid,
    required this.creatorPseudonym,
    required this.title,
    required this.description,
    this.proposalType = ProposalType.SACHFRAGE,
    this.category,
    this.status = ProposalStatus.DRAFT,
    required this.createdAt,
    this.discussionStartedAt,
    this.votingStartedAt,
    this.votingEndsAt,
    this.decidedAt,
    this.archivedAt,
    this.withdrawnAt,
    this.quorumRequired = 0.5,
    this.gracePeriodHours = 12,
    this.version = 1,
    this.previousDecisionHash,
    List<String>? impulseSupporters,
    this.resultSummary,
    this.resultYes,
    this.resultNo,
    this.resultAbstain,
    this.resultParticipation,
    this.scope = ProposalScope.cell,
    String? domain,
  })  : impulseSupporters = impulseSupporters ?? [],
        domain = domain ?? category ?? 'Sonstiges';

  // ── Factory helpers ────────────────────────────────────────────────────────

  /// Creates a new DRAFT proposal.
  factory Proposal.create({
    required String title,
    required String description,
    required String creatorDid,
    required String creatorPseudonym,
    required String cellId,
    ProposalType proposalType = ProposalType.SACHFRAGE,
    String? category,
    ProposalScope scope = ProposalScope.cell,
    String domain = 'Sonstiges',
    double quorumRequired = 0.5,
    int gracePeriodHours = 12,
  }) {
    final now = DateTime.now().toUtc();
    return Proposal(
      id: _generateProposalId(),
      cellId: cellId,
      creatorDid: creatorDid,
      creatorPseudonym: creatorPseudonym,
      title: title,
      description: description,
      proposalType: proposalType,
      category: category ?? domain,
      status: ProposalStatus.DRAFT,
      createdAt: now,
      quorumRequired: quorumRequired,
      gracePeriodHours: gracePeriodHours,
      impulseSupporters: [creatorDid],
      scope: scope,
      domain: domain,
    );
  }

  // ── Convenience getters ────────────────────────────────────────────────────

  bool get isActive =>
      status == ProposalStatus.DISCUSSION ||
      status == ProposalStatus.VOTING ||
      status == ProposalStatus.VOTING_ENDED;

  bool get isDraft => status == ProposalStatus.DRAFT;

  /// Alias kept for G1 callers (createProposal uses createdBy).
  String get createdBy => creatorDid;

  // ── Serialisation: new flat-column format ──────────────────────────────────

  Map<String, dynamic> toMap() => {
        'id': id,
        'cell_id': cellId,
        'creator_did': creatorDid,
        'creator_pseudonym': creatorPseudonym,
        'title': title,
        'description': description,
        'proposal_type': proposalType.name,
        'category': category,
        'status': status.name,
        'created_at': createdAt.millisecondsSinceEpoch,
        'discussion_started_at': discussionStartedAt?.millisecondsSinceEpoch,
        'voting_started_at': votingStartedAt?.millisecondsSinceEpoch,
        'voting_ends_at': votingEndsAt?.millisecondsSinceEpoch,
        'decided_at': decidedAt?.millisecondsSinceEpoch,
        'archived_at': archivedAt?.millisecondsSinceEpoch,
        'withdrawn_at': withdrawnAt?.millisecondsSinceEpoch,
        'quorum_required': quorumRequired,
        'grace_period_hours': gracePeriodHours,
        'version': version,
        'previous_decision_hash': previousDecisionHash,
        'impulse_supporters': jsonEncode(impulseSupporters),
        'result_summary': resultSummary,
        'result_yes': resultYes,
        'result_no': resultNo,
        'result_abstain': resultAbstain,
        'result_participation': resultParticipation,
        // G1 compat
        'scope': scope.name,
        'domain': domain,
      };

  factory Proposal.fromMap(Map<String, dynamic> map) {
    final impulseSupportersRaw = map['impulse_supporters'];
    List<String> supporters = [];
    if (impulseSupportersRaw is String) {
      supporters = List<String>.from(jsonDecode(impulseSupportersRaw));
    } else if (impulseSupportersRaw is List) {
      supporters = List<String>.from(impulseSupportersRaw);
    }

    return Proposal(
      id: map['id'] as String,
      cellId: map['cell_id'] as String,
      creatorDid: map['creator_did'] as String,
      creatorPseudonym: map['creator_pseudonym'] as String? ?? '',
      title: map['title'] as String,
      description: map['description'] as String? ?? '',
      proposalType: _parseProposalType(map['proposal_type'] as String?),
      category: map['category'] as String?,
      status: _parseStatus(map['status'] as String?),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          map['created_at'] as int,
          isUtc: true),
      discussionStartedAt: map['discussion_started_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              map['discussion_started_at'] as int,
              isUtc: true)
          : null,
      votingStartedAt: map['voting_started_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              map['voting_started_at'] as int,
              isUtc: true)
          : null,
      votingEndsAt: map['voting_ends_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              map['voting_ends_at'] as int,
              isUtc: true)
          : null,
      decidedAt: map['decided_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              map['decided_at'] as int,
              isUtc: true)
          : null,
      archivedAt: map['archived_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              map['archived_at'] as int,
              isUtc: true)
          : null,
      withdrawnAt: map['withdrawn_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              map['withdrawn_at'] as int,
              isUtc: true)
          : null,
      quorumRequired: (map['quorum_required'] as num?)?.toDouble() ?? 0.5,
      gracePeriodHours: map['grace_period_hours'] as int? ?? 12,
      version: map['version'] as int? ?? 1,
      previousDecisionHash: map['previous_decision_hash'] as String?,
      impulseSupporters: supporters,
      resultSummary: map['result_summary'] as String?,
      resultYes: map['result_yes'] as int?,
      resultNo: map['result_no'] as int?,
      resultAbstain: map['result_abstain'] as int?,
      resultParticipation: (map['result_participation'] as num?)?.toDouble(),
      scope: ProposalScope.values.firstWhere(
        (e) => e.name == (map['scope'] as String? ?? 'cell'),
        orElse: () => ProposalScope.cell,
      ),
      domain: map['domain'] as String? ?? map['category'] as String? ?? 'Sonstiges',
    );
  }

  /// Reconstructs a Proposal from the G1 legacy enc-blob JSON format.
  ///
  /// Field mapping: createdBy→creatorDid, quorum→quorumRequired,
  /// votingDeadline→votingEndsAt, discussionDeadline→discussionStartedAt.
  factory Proposal.fromLegacyJson(Map<String, dynamic> json) {
    final statusStr = json['status'] as String? ?? 'draft';
    final legacyStatus = _parseLegacyStatus(statusStr);

    return Proposal(
      id: json['id'] as String,
      cellId: json['cellId'] as String,
      creatorDid: json['createdBy'] as String? ?? json['creator_did'] as String? ?? '',
      creatorPseudonym: json['creatorPseudonym'] as String? ?? '',
      title: json['title'] as String,
      description: json['description'] as String? ?? '',
      proposalType: ProposalType.SACHFRAGE,
      category: json['domain'] as String?,
      status: legacyStatus,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          json['createdAt'] as int,
          isUtc: true),
      votingEndsAt: json['votingDeadline'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              json['votingDeadline'] as int,
              isUtc: true)
          : null,
      quorumRequired: (json['quorum'] as num?)?.toDouble() ?? 0.5,
      gracePeriodHours: 12,
      impulseSupporters: [json['createdBy'] as String? ?? ''],
      scope: ProposalScope.values.firstWhere(
        (e) => e.name == (json['scope'] as String? ?? 'cell'),
        orElse: () => ProposalScope.cell,
      ),
      domain: json['domain'] as String? ?? 'Sonstiges',
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  static ProposalType _parseProposalType(String? s) {
    if (s == null) return ProposalType.SACHFRAGE;
    try {
      return ProposalType.values.byName(s);
    } catch (_) {
      return ProposalType.SACHFRAGE;
    }
  }

  static ProposalStatus _parseStatus(String? s) {
    if (s == null) return ProposalStatus.DRAFT;
    // Handle G1 lowercase status values
    final normalized = s.toUpperCase();
    try {
      return ProposalStatus.values.byName(normalized);
    } catch (_) {
      return ProposalStatus.DRAFT;
    }
  }

  static ProposalStatus _parseLegacyStatus(String s) {
    switch (s.toLowerCase()) {
      case 'draft':
        return ProposalStatus.DRAFT;
      case 'discussion':
        return ProposalStatus.DISCUSSION;
      case 'voting':
        return ProposalStatus.VOTING;
      case 'decided':
        return ProposalStatus.DECIDED;
      case 'archived':
        return ProposalStatus.ARCHIVED;
      default:
        return ProposalStatus.DRAFT;
    }
  }
}
