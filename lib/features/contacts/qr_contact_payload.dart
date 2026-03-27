import 'dart:convert';

/// Represents the data embedded in a NEXUS contact QR code.
///
/// Wire format (JSON encoded in the QR code):
/// ```json
/// {
///   "type": "nexus-contact",
///   "did": "did:key:z6Mk...",
///   "pseudonym": "Josh Richman",
///   "publicKey": "x25519-public-key-hex",
///   "nostrPubkey": "nostr-pubkey-hex"
/// }
/// ```
class QrContactPayload {
  final String did;
  final String pseudonym;

  /// X25519 public key as lowercase hex (64 chars = 32 bytes).
  final String? publicKey;

  /// Nostr public key as lowercase hex (64 chars = 32 bytes).
  final String? nostrPubkey;

  const QrContactPayload({
    required this.did,
    required this.pseudonym,
    this.publicKey,
    this.nostrPubkey,
  });

  /// Tries to parse a QR code [rawValue] into a [QrContactPayload].
  ///
  /// Returns null if [rawValue] is not a valid NEXUS contact QR code:
  /// - Must be valid JSON
  /// - Must have `"type": "nexus-contact"`
  /// - Must have a `did` starting with `"did:key:"`
  /// - Must have a non-empty `pseudonym`
  static QrContactPayload? tryParse(String rawValue) {
    try {
      final json = jsonDecode(rawValue) as Map<String, dynamic>;
      if (json['type'] != 'nexus-contact') return null;
      final did = json['did'] as String?;
      if (did == null || !did.startsWith('did:key:')) return null;
      final pseudonym = (json['pseudonym'] as String?)?.trim() ?? '';
      if (pseudonym.isEmpty) return null;
      return QrContactPayload(
        did: did,
        pseudonym: pseudonym,
        publicKey: json['publicKey'] as String?,
        nostrPubkey: json['nostrPubkey'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
        'type': 'nexus-contact',
        'did': did,
        'pseudonym': pseudonym,
        if (publicKey != null) 'publicKey': publicKey,
        if (nostrPubkey != null) 'nostrPubkey': nostrPubkey,
      };

  String toJsonString() => jsonEncode(toJson());

  /// Abbreviated DID for display (first 16 + "…" + last 8 chars).
  String get shortDid {
    if (did.length <= 24) return did;
    return '${did.substring(0, 16)}…${did.substring(did.length - 8)}';
  }
}
