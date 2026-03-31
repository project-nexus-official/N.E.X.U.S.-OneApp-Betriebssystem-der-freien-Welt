import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/core/contacts/contact.dart';
import 'package:nexus_oneapp/core/identity/profile.dart';

void main() {
  // ── UserProfile defaults ────────────────────────────────────────────────

  group('UserProfile.defaults', () {
    test('pseudonym field is public by default', () {
      final p = UserProfile.defaults('TestBiber42');
      expect(p.pseudonym.value, 'TestBiber42');
      expect(p.pseudonym.visibility, VisibilityLevel.public);
    });

    test('realName is contacts-visibility by default', () {
      final p = UserProfile.defaults('X');
      expect(p.realName.visibility, VisibilityLevel.contacts);
    });

    test('birthDate is private by default', () {
      final p = UserProfile.defaults('X');
      expect(p.birthDate.visibility, VisibilityLevel.private);
    });

    test('bio and languages start empty/null', () {
      final p = UserProfile.defaults('X');
      expect(p.bio.value, isNull);
      expect(p.languages.value, isEmpty);
    });
  });

  // ── Age & isAdult ───────────────────────────────────────────────────────

  group('age / isAdult calculation', () {
    test('returns null when birthDate not set', () {
      final p = UserProfile.defaults('X');
      expect(p.age, isNull);
      expect(p.isAdult, isNull);
    });

    test('correctly computes age', () {
      final p = UserProfile.defaults('X');
      final now = DateTime.now();
      // 30 years ago exactly
      p.birthDate = p.birthDate
          .copyWith(value: DateTime(now.year - 30, now.month, now.day));
      expect(p.age, 30);
    });

    test('birthday not yet reached this year subtracts one', () {
      final p = UserProfile.defaults('X');
      final now = DateTime.now();
      // Birthday tomorrow → not yet had birthday this year
      final tomorrow = now.add(const Duration(days: 1));
      p.birthDate = p.birthDate.copyWith(
          value: DateTime(now.year - 20, tomorrow.month, tomorrow.day));
      expect(p.age, 19);
    });

    test('isAdult is true at exactly 18', () {
      final p = UserProfile.defaults('X');
      final now = DateTime.now();
      p.birthDate = p.birthDate
          .copyWith(value: DateTime(now.year - 18, now.month, now.day));
      expect(p.isAdult, isTrue);
    });

    test('isAdult is false at 17', () {
      final p = UserProfile.defaults('X');
      final now = DateTime.now();
      p.birthDate = p.birthDate
          .copyWith(value: DateTime(now.year - 17, now.month, now.day));
      expect(p.isAdult, isFalse);
    });
  });

  // ── JSON round-trip ─────────────────────────────────────────────────────

  group('JSON serialization', () {
    test('round-trips all fields', () {
      final p = UserProfile.defaults('RunderBiber7');
      p.bio = p.bio.copyWith(value: 'Test Bio');
      p.realName = p.realName.copyWith(value: 'Max Muster');
      p.location = p.location.copyWith(value: 'Berlin');
      p.languages = p.languages.copyWith(value: ['Deutsch', 'Englisch']);
      p.skills = p.skills.copyWith(value: ['Programmieren']);
      p.birthDate = p.birthDate
          .copyWith(value: DateTime(1990, 6, 15));

      final json = p.toJson();
      final restored = UserProfile.fromJson(json);

      expect(restored.pseudonym.value, 'RunderBiber7');
      expect(restored.bio.value, 'Test Bio');
      expect(restored.realName.value, 'Max Muster');
      expect(restored.location.value, 'Berlin');
      expect(restored.languages.value, ['Deutsch', 'Englisch']);
      expect(restored.skills.value, ['Programmieren']);
      expect(restored.birthDate.value, DateTime(1990, 6, 15));
    });

    test('fromJson with empty map produces safe defaults', () {
      final p = UserProfile.fromJson({});
      expect(p.pseudonym.value, '');
      expect(p.birthDate.value, isNull);
      expect(p.languages.value, isEmpty);
    });
  });

  // ── Selective Disclosure / visibleTo ────────────────────────────────────

  group('visibleTo – selective disclosure', () {
    late UserProfile profile;

    setUp(() {
      profile = UserProfile.defaults('TestNutzer');
      profile.bio = profile.bio.copyWith(value: 'Hallo Welt');
      profile.realName = profile.realName.copyWith(value: 'Anna Beispiel');
      profile.location = profile.location.copyWith(value: 'München');
      profile.skills = profile.skills.copyWith(value: ['Kochen']);
      profile.birthDate =
          profile.birthDate.copyWith(value: DateTime(1985, 3, 10));
    });

    test('discovered → only public fields', () {
      final visible = profile.visibleTo(
          TrustLevel.discovered.allowedVisibility);
      expect(visible.containsKey('pseudonym'), isTrue);
      expect(visible.containsKey('bio'), isTrue);
      expect(visible.containsKey('realName'), isFalse);
      expect(visible.containsKey('location'), isFalse);
      expect(visible.containsKey('skills'), isFalse);
      expect(visible.containsKey('birthDate'), isFalse);
    });

    test('contact → public + contacts fields', () {
      final visible = profile.visibleTo(
          TrustLevel.contact.allowedVisibility);
      expect(visible.containsKey('pseudonym'), isTrue);
      expect(visible.containsKey('bio'), isTrue);
      expect(visible.containsKey('realName'), isTrue);
      expect(visible.containsKey('location'), isTrue);
      expect(visible.containsKey('skills'), isTrue);
      expect(visible.containsKey('birthDate'), isFalse);
    });

    test('trusted → public + contacts + trusted fields', () {
      final visible = profile.visibleTo(
          TrustLevel.trusted.allowedVisibility);
      expect(visible.containsKey('realName'), isTrue);
      expect(visible.containsKey('birthDate'), isFalse);
    });

    test('guardian sees trusted fields plus guardians-only fields', () {
      // Guardian is a superset of trusted: same fields + anything marked guardians.
      final trustedVisible =
          profile.visibleTo(TrustLevel.trusted.allowedVisibility);
      final guardianVisible =
          profile.visibleTo(TrustLevel.guardian.allowedVisibility);
      // Everything trusted can see, guardian can also see.
      for (final key in trustedVisible.keys) {
        expect(guardianVisible.containsKey(key), isTrue,
            reason: 'guardian must see "$key" that trusted can see');
      }
      // Guardian has at least as many visible fields as trusted.
      expect(guardianVisible.length,
          greaterThanOrEqualTo(trustedVisible.length));
    });

    test('birthDate is NEVER exposed regardless of trust level', () {
      for (final level in TrustLevel.values) {
        final visible = profile.visibleTo(level.allowedVisibility);
        expect(visible.containsKey('birthDate'), isFalse,
            reason: 'birthDate must not be visible at trust level $level');
      }
    });

    test('private field with custom visibility is hidden from contacts', () {
      // Mark skills as private
      profile.skills =
          profile.skills.copyWith(visibility: VisibilityLevel.private);
      final visible = profile.visibleTo(
          TrustLevel.contact.allowedVisibility);
      expect(visible.containsKey('skills'), isFalse);
    });
  });

  // ── ProfileField.copyWith ───────────────────────────────────────────────

  group('ProfileField.copyWith', () {
    test('updates value and bumps updatedAt', () {
      final before = DateTime.now().subtract(const Duration(seconds: 1));
      final field = ProfileField<String>(
        value: 'old',
        visibility: VisibilityLevel.public,
        updatedAt: before,
      );
      final updated = field.copyWith(value: 'new');
      expect(updated.value, 'new');
      expect(updated.visibility, VisibilityLevel.public);
      expect(updated.updatedAt.isAfter(before), isTrue);
    });

    test('updates visibility only', () {
      final field = ProfileField<String>(
        value: 'hello',
        visibility: VisibilityLevel.public,
        updatedAt: DateTime.now(),
      );
      final updated = field.copyWith(visibility: VisibilityLevel.private);
      expect(updated.value, 'hello');
      expect(updated.visibility, VisibilityLevel.private);
    });
  });
}
