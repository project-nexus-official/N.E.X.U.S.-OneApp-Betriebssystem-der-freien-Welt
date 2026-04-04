/// Role of a member within a cell.
enum MemberRole { founder, moderator, member, pending }

/// Membership record linking a DID to a cell.
class CellMember {
  final String cellId;
  final String did;
  final DateTime joinedAt;
  final MemberRole role;
  final String? confirmedBy;

  const CellMember({
    required this.cellId,
    required this.did,
    required this.joinedAt,
    required this.role,
    this.confirmedBy,
  });

  bool get isConfirmed => role != MemberRole.pending;
  bool get canManageRequests =>
      role == MemberRole.founder || role == MemberRole.moderator;

  Map<String, dynamic> toJson() => {
        'cellId': cellId,
        'did': did,
        'joinedAt': joinedAt.millisecondsSinceEpoch,
        'role': role.name,
        if (confirmedBy != null) 'confirmedBy': confirmedBy,
      };

  factory CellMember.fromJson(Map<String, dynamic> json) => CellMember(
        cellId: json['cellId'] as String,
        did: json['did'] as String,
        joinedAt: DateTime.fromMillisecondsSinceEpoch(
            json['joinedAt'] as int,
            isUtc: true),
        role: MemberRole.values.firstWhere(
          (e) => e.name == (json['role'] as String? ?? 'member'),
          orElse: () => MemberRole.member,
        ),
        confirmedBy: json['confirmedBy'] as String?,
      );

  CellMember copyWith({MemberRole? role, String? confirmedBy}) => CellMember(
        cellId: cellId,
        did: did,
        joinedAt: joinedAt,
        role: role ?? this.role,
        confirmedBy: confirmedBy ?? this.confirmedBy,
      );
}
