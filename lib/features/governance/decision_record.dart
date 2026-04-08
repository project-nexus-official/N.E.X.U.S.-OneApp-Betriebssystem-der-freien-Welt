import 'dart:convert';
import 'dart:math';

import 'vote.dart';

/// The immutable, tamper-evident record of a decided proposal.
///
/// Stored locally and published to Nostr as Kind-30001 (G2 Prompt 1B).
class DecisionRecord {
  final String recordId;
  final String proposalId;
  final String cellId;
  final String finalTitle;
  final String finalDescription;
  final String result;
  final int yesVotes;
  final int noVotes;
  final int abstainVotes;
  final double participation;
  final DateTime decidedAt;
  final List<Vote> allVotes;
  final String contentHash;
  final String? previousDecisionHash;
  final String nostrEventId;

  DecisionRecord({
    required this.recordId,
    required this.proposalId,
    required this.cellId,
    required this.finalTitle,
    required this.finalDescription,
    required this.result,
    required this.yesVotes,
    required this.noVotes,
    required this.abstainVotes,
    required this.participation,
    required this.decidedAt,
    required this.allVotes,
    required this.contentHash,
    this.previousDecisionHash,
    required this.nostrEventId,
  });

  static String generateId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rng = Random.secure();
    return List.generate(32, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  Map<String, dynamic> toMap() => {
        'record_id': recordId,
        'proposal_id': proposalId,
        'cell_id': cellId,
        'final_title': finalTitle,
        'final_description': finalDescription,
        'result': result,
        'yes_votes': yesVotes,
        'no_votes': noVotes,
        'abstain_votes': abstainVotes,
        'participation': participation,
        'decided_at': decidedAt.millisecondsSinceEpoch,
        'all_votes': jsonEncode(allVotes.map((v) => v.toMap()).toList()),
        'content_hash': contentHash,
        'previous_decision_hash': previousDecisionHash,
        'nostr_event_id': nostrEventId,
      };

  factory DecisionRecord.fromMap(Map<String, dynamic> map) {
    final votesJson =
        jsonDecode(map['all_votes'] as String) as List<dynamic>;
    return DecisionRecord(
      recordId: map['record_id'] as String,
      proposalId: map['proposal_id'] as String,
      cellId: map['cell_id'] as String,
      finalTitle: map['final_title'] as String,
      finalDescription: map['final_description'] as String,
      result: map['result'] as String,
      yesVotes: map['yes_votes'] as int,
      noVotes: map['no_votes'] as int,
      abstainVotes: map['abstain_votes'] as int,
      participation: (map['participation'] as num).toDouble(),
      decidedAt: DateTime.fromMillisecondsSinceEpoch(
          map['decided_at'] as int,
          isUtc: true),
      allVotes: votesJson
          .map((v) => Vote.fromMap(v as Map<String, dynamic>))
          .toList(),
      contentHash: map['content_hash'] as String,
      previousDecisionHash: map['previous_decision_hash'] as String?,
      nostrEventId: map['nostr_event_id'] as String,
    );
  }
}
