import 'dart:math';

/// Scope of a proposal.
enum ProposalScope {
  /// Only affects this cell (functional in G1).
  cell,

  /// Affects a federation of cells (UI prepared, logic in G3).
  federation,

  /// Constitutional / global (UI prepared, logic in G4).
  global,
}

/// Lifecycle status of a proposal.
enum ProposalStatus {
  draft,
  discussion,
  voting,
  decided,
  archived,
}

/// Domain / topic area of a proposal.
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
class Proposal {
  final String id;
  final String title;
  final String description;
  final String createdBy;
  final DateTime createdAt;
  final String cellId;
  final ProposalScope scope;
  final String domain;
  ProposalStatus status;
  final DateTime discussionDeadline;
  final DateTime votingDeadline;
  final String? discussionChannelId;
  final double quorum;
  final Map<String, dynamic>? result;

  Proposal({
    required this.id,
    required this.title,
    required this.description,
    required this.createdBy,
    required this.createdAt,
    required this.cellId,
    required this.scope,
    required this.domain,
    this.status = ProposalStatus.draft,
    required this.discussionDeadline,
    required this.votingDeadline,
    this.discussionChannelId,
    this.quorum = 0.5,
    this.result,
  });

  factory Proposal.create({
    required String title,
    required String description,
    required String createdBy,
    required String cellId,
    ProposalScope scope = ProposalScope.cell,
    String domain = 'Sonstiges',
    int discussionDays = 7,
    int votingDays = 3,
    double quorum = 0.5,
  }) {
    final now = DateTime.now().toUtc();
    return Proposal(
      id: _generateProposalId(),
      title: title,
      description: description,
      createdBy: createdBy,
      createdAt: now,
      cellId: cellId,
      scope: scope,
      domain: domain,
      discussionDeadline: now.add(Duration(days: discussionDays)),
      votingDeadline: now
          .add(Duration(days: discussionDays))
          .add(Duration(days: votingDays)),
      quorum: quorum,
    );
  }

  bool get isActive =>
      status == ProposalStatus.discussion || status == ProposalStatus.voting;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'createdBy': createdBy,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'cellId': cellId,
        'scope': scope.name,
        'domain': domain,
        'status': status.name,
        'discussionDeadline': discussionDeadline.millisecondsSinceEpoch,
        'votingDeadline': votingDeadline.millisecondsSinceEpoch,
        if (discussionChannelId != null)
          'discussionChannelId': discussionChannelId,
        'quorum': quorum,
        if (result != null) 'result': result,
      };

  factory Proposal.fromJson(Map<String, dynamic> json) => Proposal(
        id: json['id'] as String,
        title: json['title'] as String,
        description: json['description'] as String? ?? '',
        createdBy: json['createdBy'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            json['createdAt'] as int,
            isUtc: true),
        cellId: json['cellId'] as String,
        scope: ProposalScope.values.firstWhere(
          (e) => e.name == (json['scope'] as String? ?? 'cell'),
          orElse: () => ProposalScope.cell,
        ),
        domain: json['domain'] as String? ?? 'Sonstiges',
        status: ProposalStatus.values.firstWhere(
          (e) => e.name == (json['status'] as String? ?? 'draft'),
          orElse: () => ProposalStatus.draft,
        ),
        discussionDeadline: DateTime.fromMillisecondsSinceEpoch(
            json['discussionDeadline'] as int,
            isUtc: true),
        votingDeadline: DateTime.fromMillisecondsSinceEpoch(
            json['votingDeadline'] as int,
            isUtc: true),
        discussionChannelId: json['discussionChannelId'] as String?,
        quorum: (json['quorum'] as num?)?.toDouble() ?? 0.5,
        result: json['result'] as Map<String, dynamic>?,
      );
}
