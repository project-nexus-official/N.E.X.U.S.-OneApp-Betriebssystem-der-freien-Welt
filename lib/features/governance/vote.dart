import 'dart:math';

/// The voter's choice on a proposal.
enum VoteChoice { YES, NO, ABSTAIN }

/// A single vote cast by a cell member on a proposal.
class Vote {
  final String voteId;
  final String proposalId;
  final String voterPubkey;
  final String voterDid;
  final String voterPseudonym;
  final VoteChoice choice;
  final int weight;
  final int voiceCredits;
  final String? reasoning;
  final DateTime createdAt;
  final bool isDelegated;
  final String? delegatedFrom;
  final String nostrEventId;

  Vote({
    required this.voteId,
    required this.proposalId,
    required this.voterPubkey,
    required this.voterDid,
    required this.voterPseudonym,
    required this.choice,
    this.weight = 1,
    this.voiceCredits = 1,
    this.reasoning,
    required this.createdAt,
    this.isDelegated = false,
    this.delegatedFrom,
    required this.nostrEventId,
  });

  static String generateId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rng = Random.secure();
    return List.generate(32, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  Map<String, dynamic> toMap() => {
        'vote_id': voteId,
        'proposal_id': proposalId,
        'voter_pubkey': voterPubkey,
        'voter_did': voterDid,
        'voter_pseudonym': voterPseudonym,
        'choice': choice.name,
        'weight': weight,
        'voice_credits': voiceCredits,
        'reasoning': reasoning,
        'created_at': createdAt.millisecondsSinceEpoch,
        'is_delegated': isDelegated ? 1 : 0,
        'delegated_from': delegatedFrom,
        'nostr_event_id': nostrEventId,
      };

  factory Vote.fromMap(Map<String, dynamic> map) => Vote(
        voteId: map['vote_id'] as String,
        proposalId: map['proposal_id'] as String,
        voterPubkey: map['voter_pubkey'] as String,
        voterDid: map['voter_did'] as String,
        voterPseudonym: map['voter_pseudonym'] as String,
        choice: VoteChoice.values.byName(map['choice'] as String),
        weight: map['weight'] as int? ?? 1,
        voiceCredits: map['voice_credits'] as int? ?? 1,
        reasoning: map['reasoning'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            map['created_at'] as int,
            isUtc: true),
        isDelegated: (map['is_delegated'] as int? ?? 0) == 1,
        delegatedFrom: map['delegated_from'] as String?,
        nostrEventId: map['nostr_event_id'] as String,
      );
}
