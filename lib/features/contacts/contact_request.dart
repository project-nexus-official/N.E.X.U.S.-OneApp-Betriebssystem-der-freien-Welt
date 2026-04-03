import 'dart:math';

/// Status of a contact request.
enum ContactRequestStatus { pending, accepted, rejected, ignored }

/// A contact request – either received (isSent=false) or sent (isSent=true).
class ContactRequest {
  final String id;

  /// DID of the requester.  For *sent* requests this is our own DID.
  final String fromDid;
  final String fromPseudonym;

  /// X25519 public key (hex) of the requester.
  final String fromPublicKey;

  /// Nostr public key (hex) of the requester.
  final String fromNostrPubkey;

  /// Short introduction text (max 500 chars).
  final String message;

  final DateTime receivedAt;
  final ContactRequestStatus status;
  final DateTime? decidedAt;

  /// true = we sent this request; false = we received it.
  final bool isSent;

  const ContactRequest({
    required this.id,
    required this.fromDid,
    required this.fromPseudonym,
    required this.fromPublicKey,
    required this.fromNostrPubkey,
    required this.message,
    required this.receivedAt,
    required this.status,
    this.decidedAt,
    required this.isSent,
  });

  ContactRequest copyWith({
    ContactRequestStatus? status,
    DateTime? decidedAt,
  }) {
    return ContactRequest(
      id: id,
      fromDid: fromDid,
      fromPseudonym: fromPseudonym,
      fromPublicKey: fromPublicKey,
      fromNostrPubkey: fromNostrPubkey,
      message: message,
      receivedAt: receivedAt,
      status: status ?? this.status,
      decidedAt: decidedAt ?? this.decidedAt,
      isSent: isSent,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'fromDid': fromDid,
        'fromPseudonym': fromPseudonym,
        'fromPublicKey': fromPublicKey,
        'fromNostrPubkey': fromNostrPubkey,
        'message': message,
        'receivedAt': receivedAt.millisecondsSinceEpoch,
        'status': status.name,
        if (decidedAt != null) 'decidedAt': decidedAt!.millisecondsSinceEpoch,
        'isSent': isSent,
      };

  factory ContactRequest.fromJson(Map<String, dynamic> json) {
    return ContactRequest(
      id: json['id'] as String,
      fromDid: json['fromDid'] as String,
      fromPseudonym: json['fromPseudonym'] as String? ?? '',
      fromPublicKey: json['fromPublicKey'] as String? ?? '',
      fromNostrPubkey: json['fromNostrPubkey'] as String? ?? '',
      message: json['message'] as String? ?? '',
      receivedAt: DateTime.fromMillisecondsSinceEpoch(
        json['receivedAt'] as int,
      ),
      status: ContactRequestStatus.values.firstWhere(
        (s) => s.name == (json['status'] as String? ?? 'pending'),
        orElse: () => ContactRequestStatus.pending,
      ),
      decidedAt: json['decidedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['decidedAt'] as int)
          : null,
      isSent: json['isSent'] as bool? ?? false,
    );
  }

  /// Generates a UUID v4 string.
  static String generateId() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    // Version 4
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    // Variant bits
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex =
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}
