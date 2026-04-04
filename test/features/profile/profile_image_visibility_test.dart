import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/core/contacts/contact.dart';
import 'package:nexus_oneapp/core/identity/profile.dart';

void main() {
  // ── UserProfile defaults ────────────────────────────────────────────────────

  group('UserProfile – profileImage default visibility', () {
    test('new profile has profileImage visibility = contacts', () {
      final p = UserProfile.defaults('Testuser');
      expect(p.profileImage.visibility, VisibilityLevel.contacts);
    });

    test('fromJson uses contacts as default when visibility key is missing', () {
      final json = <String, dynamic>{
        'pseudonym': {'value': 'Tester', 'visibility': 'public', 'updatedAt': DateTime.now().toIso8601String()},
      };
      final p = UserProfile.fromJson(json);
      expect(p.profileImage.visibility, VisibilityLevel.contacts);
    });

    test('fromJson preserves stored visibility', () {
      final json = <String, dynamic>{
        'pseudonym': {'value': 'Tester', 'visibility': 'public', 'updatedAt': DateTime.now().toIso8601String()},
        'profileImage': {
          'value': '/some/path.jpg',
          'visibility': 'trusted',
          'updatedAt': DateTime.now().toIso8601String()
        },
      };
      final p = UserProfile.fromJson(json);
      expect(p.profileImage.visibility, VisibilityLevel.trusted);
    });
  });

  // ── toNexusKind0 ────────────────────────────────────────────────────────────

  group('UserProfile.toNexusKind0 – profileImageVisibility', () {
    test('includes profileImageVisibility key', () {
      final p = UserProfile.defaults('Tester');
      final map = p.toNexusKind0();
      expect(map.containsKey('profileImageVisibility'), isTrue);
    });

    test('profileImageVisibility matches current visibility', () {
      final p = UserProfile.defaults('Tester');
      p.profileImage = p.profileImage.copyWith(visibility: VisibilityLevel.contacts);
      expect(p.toNexusKind0()['profileImageVisibility'], 'contacts');
    });

    test('profileImageVisibility = public when set to public', () {
      final p = UserProfile.defaults('Tester');
      p.profileImage = p.profileImage.copyWith(visibility: VisibilityLevel.public);
      expect(p.toNexusKind0()['profileImageVisibility'], 'public');
    });

    test('profileImageVisibility = private when set to private', () {
      final p = UserProfile.defaults('Tester');
      p.profileImage = p.profileImage.copyWith(visibility: VisibilityLevel.private);
      expect(p.toNexusKind0()['profileImageVisibility'], 'private');
    });
  });

  // ── Contact.profileImageVisibility ─────────────────────────────────────────

  group('Contact.profileImageVisibility', () {
    Contact _makeContact({
      TrustLevel trust = TrustLevel.contact,
      String? image,
      Map<String, dynamic>? nexus,
    }) {
      return Contact(
        did: 'did:key:z6Mk' + 'a' * 44,
        pseudonym: 'Alice',
        profileImage: image,
        trustLevel: trust,
        addedAt: DateTime.now(),
        lastSeen: DateTime.now(),
        nexusProfile: nexus,
      );
    }

    test('defaults to public when nexusProfile has no key', () {
      final c = _makeContact();
      expect(c.profileImageVisibility, VisibilityLevel.public);
    });

    test('reads visibility from nexusProfile', () {
      final c = _makeContact(nexus: {'profileImageVisibility': 'contacts'});
      expect(c.profileImageVisibility, VisibilityLevel.contacts);
    });

    test('unknown value in nexusProfile defaults to public', () {
      final c = _makeContact(nexus: {'profileImageVisibility': 'unknown_future_level'});
      expect(c.profileImageVisibility, VisibilityLevel.public);
    });
  });

  // ── Contact.visibleProfileImage ─────────────────────────────────────────────

  group('Contact.visibleProfileImage', () {
    Contact _makeContact({
      required TrustLevel trust,
      String? image,
      Map<String, dynamic>? nexus,
    }) {
      return Contact(
        did: 'did:key:z6Mk' + 'a' * 44,
        pseudonym: 'Bob',
        profileImage: image,
        trustLevel: trust,
        addedAt: DateTime.now(),
        lastSeen: DateTime.now(),
        nexusProfile: nexus,
      );
    }

    test('returns null when no image is set', () {
      final c = _makeContact(trust: TrustLevel.contact, image: null);
      expect(c.visibleProfileImage, isNull);
    });

    test('returns image when visibility=public and trust=discovered', () {
      final c = _makeContact(
        trust: TrustLevel.discovered,
        image: '/img.jpg',
        nexus: {'profileImageVisibility': 'public'},
      );
      expect(c.visibleProfileImage, '/img.jpg');
    });

    test('returns image when visibility=contacts and trust=contact', () {
      final c = _makeContact(
        trust: TrustLevel.contact,
        image: '/img.jpg',
        nexus: {'profileImageVisibility': 'contacts'},
      );
      expect(c.visibleProfileImage, '/img.jpg');
    });

    test('returns image when visibility=contacts and trust=trusted', () {
      final c = _makeContact(
        trust: TrustLevel.trusted,
        image: '/img.jpg',
        nexus: {'profileImageVisibility': 'contacts'},
      );
      expect(c.visibleProfileImage, '/img.jpg');
    });

    test('returns image when visibility=contacts and trust=guardian', () {
      final c = _makeContact(
        trust: TrustLevel.guardian,
        image: '/img.jpg',
        nexus: {'profileImageVisibility': 'contacts'},
      );
      expect(c.visibleProfileImage, '/img.jpg');
    });

    test('returns null when visibility=contacts and trust=discovered', () {
      final c = _makeContact(
        trust: TrustLevel.discovered,
        image: '/img.jpg',
        nexus: {'profileImageVisibility': 'contacts'},
      );
      expect(c.visibleProfileImage, isNull);
    });

    test('returns null when visibility=trusted and trust=contact', () {
      final c = _makeContact(
        trust: TrustLevel.contact,
        image: '/img.jpg',
        nexus: {'profileImageVisibility': 'trusted'},
      );
      expect(c.visibleProfileImage, isNull);
    });

    test('returns image when visibility=trusted and trust=trusted', () {
      final c = _makeContact(
        trust: TrustLevel.trusted,
        image: '/img.jpg',
        nexus: {'profileImageVisibility': 'trusted'},
      );
      expect(c.visibleProfileImage, '/img.jpg');
    });

    test('returns null when visibility=private regardless of trust', () {
      for (final trust in TrustLevel.values) {
        final c = _makeContact(
          trust: trust,
          image: '/img.jpg',
          nexus: {'profileImageVisibility': 'private'},
        );
        expect(c.visibleProfileImage, isNull,
            reason: 'trust=$trust should not see private image');
      }
    });

    test('returns image when no visibility key (defaults public)', () {
      final c = _makeContact(trust: TrustLevel.discovered, image: '/img.jpg');
      expect(c.visibleProfileImage, '/img.jpg');
    });
  });

  // ── Kind-0 does not include picture for non-public ──────────────────────────

  group('Kind-0 picture field control', () {
    test('toNexusKind0 does not include profileImage value – picture is top-level', () {
      // The profile image path/data is handled at the transport layer (Kind-0
      // "picture" top-level field), not via nexus_profile. This test verifies
      // toNexusKind0() never leaks the raw file path.
      final p = UserProfile.defaults('Tester');
      p.profileImage = p.profileImage.copyWith(value: '/secret/path.jpg');
      final map = p.toNexusKind0();
      expect(map.containsKey('profileImage'), isFalse);
      // Only the visibility setting is included, not the path.
      expect(map.containsKey('profileImageVisibility'), isTrue);
      expect(map.containsValue('/secret/path.jpg'), isFalse);
    });
  });
}
