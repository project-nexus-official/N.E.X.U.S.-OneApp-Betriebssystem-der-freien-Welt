import 'dart:math';

/// Status of a join request.
enum JoinRequestStatus { pending, approved, rejected }

String _generateRequestId() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final rng = Random.secure();
  return List.generate(32, (_) => chars[rng.nextInt(chars.length)]).join();
}

/// A request by a peer to join a cell.
class CellJoinRequest {
  final String id;
  final String cellId;
  final String requesterDid;
  final String requesterPseudonym;

  /// The requester's Nostr public key (hex). Included so the founder can
  /// send the Kind-31004 membership-confirmation event back without needing
  /// a contact relationship.
  final String? requesterNostrPubkey;

  final String? message;
  final DateTime requestedAt;
  final JoinRequestStatus status;
  final String? decidedBy;
  final DateTime? decidedAt;

  const CellJoinRequest({
    required this.id,
    required this.cellId,
    required this.requesterDid,
    required this.requesterPseudonym,
    this.requesterNostrPubkey,
    this.message,
    required this.requestedAt,
    this.status = JoinRequestStatus.pending,
    this.decidedBy,
    this.decidedAt,
  });

  factory CellJoinRequest.create({
    required String cellId,
    required String requesterDid,
    required String requesterPseudonym,
    String? requesterNostrPubkey,
    String? message,
  }) =>
      CellJoinRequest(
        id: _generateRequestId(),
        cellId: cellId,
        requesterDid: requesterDid,
        requesterPseudonym: requesterPseudonym,
        requesterNostrPubkey: requesterNostrPubkey,
        message: message,
        requestedAt: DateTime.now().toUtc(),
      );

  bool get isPending => status == JoinRequestStatus.pending;

  Map<String, dynamic> toJson() => {
        'id': id,
        'cellId': cellId,
        'requesterDid': requesterDid,
        'requesterPseudonym': requesterPseudonym,
        if (requesterNostrPubkey != null) 'requesterNostrPubkey': requesterNostrPubkey,
        if (message != null) 'message': message,
        'requestedAt': requestedAt.millisecondsSinceEpoch,
        'status': status.name,
        if (decidedBy != null) 'decidedBy': decidedBy,
        if (decidedAt != null) 'decidedAt': decidedAt!.millisecondsSinceEpoch,
      };

  factory CellJoinRequest.fromJson(Map<String, dynamic> json) =>
      CellJoinRequest(
        id: json['id'] as String,
        cellId: json['cellId'] as String,
        requesterDid: json['requesterDid'] as String,
        requesterPseudonym: json['requesterPseudonym'] as String? ?? '',
        requesterNostrPubkey: json['requesterNostrPubkey'] as String?,
        message: json['message'] as String?,
        requestedAt: DateTime.fromMillisecondsSinceEpoch(
            json['requestedAt'] as int,
            isUtc: true),
        status: JoinRequestStatus.values.firstWhere(
          (e) => e.name == (json['status'] as String? ?? 'pending'),
          orElse: () => JoinRequestStatus.pending,
        ),
        decidedBy: json['decidedBy'] as String?,
        decidedAt: json['decidedAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['decidedAt'] as int,
                isUtc: true)
            : null,
      );

  CellJoinRequest copyWith({
    JoinRequestStatus? status,
    String? decidedBy,
    DateTime? decidedAt,
  }) =>
      CellJoinRequest(
        id: id,
        cellId: cellId,
        requesterDid: requesterDid,
        requesterPseudonym: requesterPseudonym,
        requesterNostrPubkey: requesterNostrPubkey,
        message: message,
        requestedAt: requestedAt,
        status: status ?? this.status,
        decidedBy: decidedBy ?? this.decidedBy,
        decidedAt: decidedAt ?? this.decidedAt,
      );
}
