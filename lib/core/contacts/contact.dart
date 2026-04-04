import 'package:nexus_oneapp/core/identity/profile.dart';

/// Trust level for a contact in the NEXUS web of trust.
///
/// Determines which profile fields of your contact you can see,
/// and which of your own fields they can see.
enum TrustLevel { discovered, contact, trusted, guardian }

extension TrustLevelX on TrustLevel {
  String get label {
    switch (this) {
      case TrustLevel.discovered:
        return 'Entdeckt';
      case TrustLevel.contact:
        return 'Kontakt';
      case TrustLevel.trusted:
        return 'Vertrauensperson';
      case TrustLevel.guardian:
        return 'Bürge';
    }
  }

  String get description {
    switch (this) {
      case TrustLevel.discovered:
        return 'Neu entdeckter Peer – nur öffentliche Infos sichtbar.';
      case TrustLevel.contact:
        return 'Du kennst diese Person – Kontakt-Felder freigegeben.';
      case TrustLevel.trusted:
        return 'Du vertraust dieser Person – erweiterte Felder sichtbar.';
      case TrustLevel.guardian:
        return 'Du bürgst für diese Person – Treuhänder im Notfall.';
    }
  }

  /// Returns the set of [VisibilityLevel]s this trust level grants access to.
  Set<VisibilityLevel> get allowedVisibility {
    switch (this) {
      case TrustLevel.discovered:
        return {VisibilityLevel.public};
      case TrustLevel.contact:
        return {VisibilityLevel.public, VisibilityLevel.contacts};
      case TrustLevel.trusted:
        return {
          VisibilityLevel.public,
          VisibilityLevel.contacts,
          VisibilityLevel.trusted,
        };
      case TrustLevel.guardian:
        return {
          VisibilityLevel.public,
          VisibilityLevel.contacts,
          VisibilityLevel.trusted,
          VisibilityLevel.guardians,
        };
    }
  }

  /// Sort weight for contact list ordering (higher = listed first).
  int get sortWeight {
    switch (this) {
      case TrustLevel.guardian:
        return 3;
      case TrustLevel.trusted:
        return 2;
      case TrustLevel.contact:
        return 1;
      case TrustLevel.discovered:
        return 0;
    }
  }
}

/// A known peer in the NEXUS network.
class Contact {
  final String did;
  String pseudonym;
  String? profileImage; // locally cached path
  TrustLevel trustLevel;
  final DateTime addedAt;
  DateTime lastSeen;
  String? notes; // private local note, never transmitted
  bool blocked;          // local-only, never transmitted
  DateTime? mutedUntil; // null = not muted; DateTime(9999) = permanent
  String? encryptionPublicKey; // X25519 pubkey hex (32 bytes = 64 hex chars)
  String? previousEncryptionPublicKey; // for key-change warning
  String? nostrPubkey; // Nostr public key hex (32 bytes = 64 hex chars)

  // ── Nostr Kind-0 metadata fields (received via relay) ─────────────────────
  String? about;   // bio / description from Kind-0 "about"
  String? website; // website URL from Kind-0 "website"
  String? nip05;   // verified Nostr address from Kind-0 "nip05"

  /// Generic NEXUS profile fields received via Kind-0 `nexus_profile` block.
  /// Keys match [UserProfile] field names (e.g. "realName", "location",
  /// "languages", "skills").  New fields added to [UserProfile] are stored
  /// here automatically without any schema change.
  Map<String, dynamic> nexusProfile;

  /// The visibility level declared by this contact for their profile picture.
  /// Read from [nexusProfile]['profileImageVisibility'], defaulting to
  /// [VisibilityLevel.public] for backwards compatibility with contacts that
  /// have not yet republished a Kind-0 with the new field.
  VisibilityLevel get profileImageVisibility {
    final v = nexusProfile['profileImageVisibility'] as String?;
    if (v == null) return VisibilityLevel.public;
    return VisibilityLevel.values.firstWhere(
      (e) => e.name == v,
      orElse: () => VisibilityLevel.public,
    );
  }

  /// Returns the locally cached profile image path only when our trust level
  /// with this contact meets their declared [profileImageVisibility].
  /// Returns null otherwise, which causes widgets to show an Identicon.
  String? get visibleProfileImage {
    if (profileImage == null) return null;
    if (trustLevel.allowedVisibility.contains(profileImageVisibility)) {
      return profileImage;
    }
    return null;
  }

  Contact({
    required this.did,
    required this.pseudonym,
    this.profileImage,
    required this.trustLevel,
    required this.addedAt,
    required this.lastSeen,
    this.notes,
    this.blocked = false,
    this.mutedUntil,
    this.encryptionPublicKey,
    this.previousEncryptionPublicKey,
    this.nostrPubkey,
    this.about,
    this.website,
    this.nip05,
    Map<String, dynamic>? nexusProfile,
  }) : nexusProfile = nexusProfile ?? {};

  Map<String, dynamic> toJson() => {
        'did': did,
        'pseudonym': pseudonym,
        'profileImage': profileImage,
        'trustLevel': trustLevel.name,
        'addedAt': addedAt.toIso8601String(),
        'lastSeen': lastSeen.toIso8601String(),
        'notes': notes,
        'blocked': blocked,
        'mutedUntil': mutedUntil?.toIso8601String(),
        'encryptionPublicKey': encryptionPublicKey,
        'previousEncryptionPublicKey': previousEncryptionPublicKey,
        'nostrPubkey': nostrPubkey,
        'about': about,
        'website': website,
        'nip05': nip05,
        'nexusProfile': nexusProfile.isEmpty ? null : nexusProfile,
      };

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
        did: json['did'] as String? ?? '',
        pseudonym: json['pseudonym'] as String? ?? '',
        profileImage: json['profileImage'] as String?,
        trustLevel: TrustLevel.values.firstWhere(
          (e) => e.name == json['trustLevel'],
          orElse: () => TrustLevel.discovered,
        ),
        addedAt: _parseDate(json['addedAt']),
        lastSeen: _parseDate(json['lastSeen']),
        notes: json['notes'] as String?,
        blocked: json['blocked'] as bool? ?? false,
        mutedUntil: _parseMutedUntil(json),
        encryptionPublicKey: json['encryptionPublicKey'] as String?,
        previousEncryptionPublicKey: json['previousEncryptionPublicKey'] as String?,
        nostrPubkey: json['nostrPubkey'] as String?,
        about: json['about'] as String?,
        website: json['website'] as String?,
        nip05: json['nip05'] as String?,
        nexusProfile: (json['nexusProfile'] as Map<String, dynamic>?) ?? {},
      );

  static DateTime _parseDate(dynamic v) {
    if (v == null) return DateTime.now();
    try {
      return DateTime.parse(v as String);
    } catch (_) {
      return DateTime.now();
    }
  }

  /// Reads mutedUntil from JSON. Handles both the new ISO string field and
  /// the legacy boolean `muted: true` (migrates to permanent mute).
  static DateTime? _parseMutedUntil(Map<String, dynamic> json) {
    final raw = json['mutedUntil'];
    if (raw is String) {
      try {
        return DateTime.parse(raw);
      } catch (_) {}
    }
    // Legacy migration: old `muted: true` → permanent mute
    if (json['muted'] == true) return DateTime(9999);
    return null;
  }
}
