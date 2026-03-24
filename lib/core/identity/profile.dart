/// Visibility level for profile fields.
///
/// Implements the NEXUS "Selective Disclosure" principle:
/// data is withheld by default, not shared.
enum VisibilityLevel { public, contacts, trusted, private }

extension VisibilityLevelX on VisibilityLevel {
  String get label {
    switch (this) {
      case VisibilityLevel.public:
        return 'Alle';
      case VisibilityLevel.contacts:
        return 'Kontakte';
      case VisibilityLevel.trusted:
        return 'Vertrauenspersonen';
      case VisibilityLevel.private:
        return 'Privat';
    }
  }

  static VisibilityLevel fromString(String s) =>
      VisibilityLevel.values.firstWhere(
        (e) => e.name == s,
        orElse: () => VisibilityLevel.private,
      );
}

/// A typed profile field with its visibility level and last-updated timestamp.
class ProfileField<T> {
  T value;
  VisibilityLevel visibility;
  DateTime updatedAt;

  ProfileField({
    required this.value,
    required this.visibility,
    required this.updatedAt,
  });

  ProfileField<T> copyWith({T? value, VisibilityLevel? visibility}) =>
      ProfileField<T>(
        value: value ?? this.value,
        visibility: visibility ?? this.visibility,
        updatedAt: DateTime.now(),
      );

  Map<String, dynamic> toJson(dynamic Function(T) valueToJson) => {
        'value': valueToJson(value),
        'visibility': visibility.name,
        'updatedAt': updatedAt.toIso8601String(),
      };

  static ProfileField<T> fromJson<T>(
    Map<String, dynamic>? json,
    T Function(dynamic) valueFromJson,
    VisibilityLevel defaultVisibility,
    T defaultValue,
  ) {
    if (json == null || json.isEmpty) {
      return ProfileField<T>(
        value: defaultValue,
        visibility: defaultVisibility,
        updatedAt: DateTime.now(),
      );
    }
    try {
      return ProfileField<T>(
        value: json['value'] != null
            ? valueFromJson(json['value'])
            : defaultValue,
        visibility: json['visibility'] != null
            ? VisibilityLevelX.fromString(json['visibility'] as String)
            : defaultVisibility,
        updatedAt: json['updatedAt'] != null
            ? DateTime.parse(json['updatedAt'] as String)
            : DateTime.now(),
      );
    } catch (_) {
      return ProfileField<T>(
        value: defaultValue,
        visibility: defaultVisibility,
        updatedAt: DateTime.now(),
      );
    }
  }
}

/// The user's extended profile with selective disclosure support.
///
/// Fields are grouped by default visibility:
/// - [VisibilityLevel.public]   : pseudonym, profileImage, bio, languages
/// - [VisibilityLevel.contacts] : realName, location, skills
/// - [VisibilityLevel.private]  : birthDate (never transmitted or shared)
///
/// [age] and [isAdult] are computed from [birthDate] and are NEVER stored
/// or transmitted. They serve only for future Zero-Knowledge Proofs.
class UserProfile {
  // ── Public ────────────────────────────────────────────────────────────────
  ProfileField<String> pseudonym;
  ProfileField<String?> profileImage; // local file path
  ProfileField<String?> bio;
  ProfileField<List<String>> languages;

  // ── Contacts-only ─────────────────────────────────────────────────────────
  ProfileField<String?> realName;
  ProfileField<String?> location;
  ProfileField<List<String>> skills;

  // ── Private (never transmitted) ───────────────────────────────────────────
  ProfileField<DateTime?> birthDate;

  UserProfile({
    required this.pseudonym,
    required this.profileImage,
    required this.bio,
    required this.languages,
    required this.realName,
    required this.location,
    required this.skills,
    required this.birthDate,
  });

  /// Age in full years, computed from [birthDate]. Null if not set.
  /// NEVER transmitted outside the encrypted local POD.
  int? get age {
    final bd = birthDate.value;
    if (bd == null) return null;
    final now = DateTime.now();
    int a = now.year - bd.year;
    if (now.month < bd.month ||
        (now.month == bd.month && now.day < bd.day)) {
      a--;
    }
    return a;
  }

  /// Whether the user is an adult (≥ 18). Null if birthDate not set.
  /// Intended for future Zero-Knowledge Proof: "über 18: JA/NEIN".
  bool? get isAdult {
    final a = age;
    return a == null ? null : a >= 18;
  }

  /// Creates a default profile for a newly created identity.
  factory UserProfile.defaults(String pseudonymValue) {
    final now = DateTime.now();
    return UserProfile(
      pseudonym: ProfileField(
          value: pseudonymValue,
          visibility: VisibilityLevel.public,
          updatedAt: now),
      profileImage: ProfileField(
          value: null,
          visibility: VisibilityLevel.public,
          updatedAt: now),
      bio: ProfileField(
          value: null,
          visibility: VisibilityLevel.public,
          updatedAt: now),
      languages: ProfileField(
          value: const [],
          visibility: VisibilityLevel.public,
          updatedAt: now),
      realName: ProfileField(
          value: null,
          visibility: VisibilityLevel.contacts,
          updatedAt: now),
      location: ProfileField(
          value: null,
          visibility: VisibilityLevel.contacts,
          updatedAt: now),
      skills: ProfileField(
          value: const [],
          visibility: VisibilityLevel.contacts,
          updatedAt: now),
      birthDate: ProfileField(
          value: null,
          visibility: VisibilityLevel.private,
          updatedAt: now),
    );
  }

  Map<String, dynamic> toJson() => {
        'pseudonym': pseudonym.toJson((v) => v),
        'profileImage': profileImage.toJson((v) => v),
        'bio': bio.toJson((v) => v),
        'languages': languages.toJson((v) => v),
        'realName': realName.toJson((v) => v),
        'location': location.toJson((v) => v),
        'skills': skills.toJson((v) => v),
        'birthDate': birthDate.toJson((v) => v?.toIso8601String()),
      };

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        pseudonym: ProfileField.fromJson<String>(
          json['pseudonym'] as Map<String, dynamic>?,
          (v) => v as String,
          VisibilityLevel.public,
          '',
        ),
        profileImage: ProfileField.fromJson<String?>(
          json['profileImage'] as Map<String, dynamic>?,
          (v) => v as String?,
          VisibilityLevel.public,
          null,
        ),
        bio: ProfileField.fromJson<String?>(
          json['bio'] as Map<String, dynamic>?,
          (v) => v as String?,
          VisibilityLevel.public,
          null,
        ),
        languages: ProfileField.fromJson<List<String>>(
          json['languages'] as Map<String, dynamic>?,
          (v) => List<String>.from(v as List),
          VisibilityLevel.public,
          const [],
        ),
        realName: ProfileField.fromJson<String?>(
          json['realName'] as Map<String, dynamic>?,
          (v) => v as String?,
          VisibilityLevel.contacts,
          null,
        ),
        location: ProfileField.fromJson<String?>(
          json['location'] as Map<String, dynamic>?,
          (v) => v as String?,
          VisibilityLevel.contacts,
          null,
        ),
        skills: ProfileField.fromJson<List<String>>(
          json['skills'] as Map<String, dynamic>?,
          (v) => List<String>.from(v as List),
          VisibilityLevel.contacts,
          const [],
        ),
        birthDate: ProfileField.fromJson<DateTime?>(
          json['birthDate'] as Map<String, dynamic>?,
          (v) => v != null ? DateTime.parse(v as String) : null,
          VisibilityLevel.private,
          null,
        ),
      );

  /// Returns the subset of profile data visible to a viewer with the given
  /// [allowedLevels] set (derived from the viewer's TrustLevel).
  ///
  /// [birthDate] is NEVER included, regardless of trust level.
  Map<String, dynamic> visibleTo(Set<VisibilityLevel> allowedLevels) {
    final result = <String, dynamic>{};

    void addIf<T>(String key, ProfileField<T> field, dynamic value) {
      if (allowedLevels.contains(field.visibility)) result[key] = value;
    }

    addIf('pseudonym', pseudonym, pseudonym.value);
    addIf('profileImage', profileImage, profileImage.value);
    addIf('bio', bio, bio.value);
    addIf('languages', languages, languages.value);
    addIf('realName', realName, realName.value);
    addIf('location', location, location.value);
    addIf('skills', skills, skills.value);
    // birthDate intentionally omitted

    return result;
  }
}
