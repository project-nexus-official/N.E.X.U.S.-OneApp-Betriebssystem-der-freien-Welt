import 'dart:math';

/// Records a single edit made to a proposal during DISCUSSION phase.
class ProposalEdit {
  final String editId;
  final String proposalId;
  final String editorDid;
  final String editorPseudonym;
  final String oldTitle;
  final String newTitle;
  final String oldDescription;
  final String newDescription;
  final DateTime editedAt;
  final String? editReason;
  final int versionBefore;
  final int versionAfter;

  ProposalEdit({
    required this.editId,
    required this.proposalId,
    required this.editorDid,
    required this.editorPseudonym,
    required this.oldTitle,
    required this.newTitle,
    required this.oldDescription,
    required this.newDescription,
    required this.editedAt,
    this.editReason,
    required this.versionBefore,
    required this.versionAfter,
  });

  static String generateId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rng = Random.secure();
    return List.generate(32, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  Map<String, dynamic> toMap() => {
        'edit_id': editId,
        'proposal_id': proposalId,
        'editor_did': editorDid,
        'editor_pseudonym': editorPseudonym,
        'old_title': oldTitle,
        'new_title': newTitle,
        'old_description': oldDescription,
        'new_description': newDescription,
        'edited_at': editedAt.millisecondsSinceEpoch,
        'edit_reason': editReason,
        'version_before': versionBefore,
        'version_after': versionAfter,
      };

  factory ProposalEdit.fromMap(Map<String, dynamic> map) => ProposalEdit(
        editId: map['edit_id'] as String,
        proposalId: map['proposal_id'] as String,
        editorDid: map['editor_did'] as String,
        editorPseudonym: map['editor_pseudonym'] as String,
        oldTitle: map['old_title'] as String,
        newTitle: map['new_title'] as String,
        oldDescription: map['old_description'] as String,
        newDescription: map['new_description'] as String,
        editedAt: DateTime.fromMillisecondsSinceEpoch(
            map['edited_at'] as int,
            isUtc: true),
        editReason: map['edit_reason'] as String?,
        versionBefore: map['version_before'] as int,
        versionAfter: map['version_after'] as int,
      );
}
