import 'did.dart';

/// Represents a NEXUS user identity (public info only – seed phrase lives in secure storage).
class NexusIdentity {
  final String publicKeyHex;
  final String pseudonym;
  final String did;

  NexusIdentity({
    required this.publicKeyHex,
    required this.pseudonym,
    String? did,
  }) : did = did ?? DidKey.fromPublicKeyHex(publicKeyHex);

  /// Shortened public key for display (first 8 + "…" + last 8 hex chars).
  String get shortPublicKey {
    if (publicKeyHex.length <= 16) return publicKeyHex;
    return '${publicKeyHex.substring(0, 8)}\u2026${publicKeyHex.substring(publicKeyHex.length - 8)}';
  }

  String get shortDid => DidKey.shorten(did);
}
