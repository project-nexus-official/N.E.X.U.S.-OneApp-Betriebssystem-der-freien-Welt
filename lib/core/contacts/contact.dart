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
      case TrustLevel.guardian:
        return {
          VisibilityLevel.public,
          VisibilityLevel.contacts,
          VisibilityLevel.trusted,
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
  bool blocked;  // local-only, never transmitted
  bool muted;    // local-only, silences notifications without blocking

  Contact({
    required this.did,
    required this.pseudonym,
    this.profileImage,
    required this.trustLevel,
    required this.addedAt,
    required this.lastSeen,
    this.notes,
    this.blocked = false,
    this.muted = false,
  });

  Map<String, dynamic> toJson() => {
        'did': did,
        'pseudonym': pseudonym,
        'profileImage': profileImage,
        'trustLevel': trustLevel.name,
        'addedAt': addedAt.toIso8601String(),
        'lastSeen': lastSeen.toIso8601String(),
        'notes': notes,
        'blocked': blocked,
        'muted': muted,
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
        muted: json['muted'] as bool? ?? false,
      );

  static DateTime _parseDate(dynamic v) {
    if (v == null) return DateTime.now();
    try {
      return DateTime.parse(v as String);
    } catch (_) {
      return DateTime.now();
    }
  }
}
