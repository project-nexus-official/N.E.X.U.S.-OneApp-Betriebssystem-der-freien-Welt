import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/core/contacts/contact.dart';
import 'package:nexus_oneapp/core/identity/profile.dart';

void main() {
  // ── TrustLevel.allowedVisibility ────────────────────────────────────────

  group('TrustLevel.allowedVisibility', () {
    test('discovered only allows public', () {
      expect(TrustLevel.discovered.allowedVisibility,
          {VisibilityLevel.public});
    });

    test('contact allows public + contacts', () {
      expect(TrustLevel.contact.allowedVisibility,
          {VisibilityLevel.public, VisibilityLevel.contacts});
    });

    test('trusted allows public + contacts + trusted', () {
      expect(TrustLevel.trusted.allowedVisibility, {
        VisibilityLevel.public,
        VisibilityLevel.contacts,
        VisibilityLevel.trusted,
      });
    });

    test('guardian has same visibility as trusted', () {
      expect(TrustLevel.guardian.allowedVisibility,
          TrustLevel.trusted.allowedVisibility);
    });
  });

  // ── Contact JSON round-trip ─────────────────────────────────────────────

  group('Contact serialization', () {
    test('round-trips all fields', () {
      final now = DateTime(2026, 1, 15, 10, 30);
      final c = Contact(
        did: 'did:key:z6MkTest',
        pseudonym: 'KlugeKatze99',
        profileImage: '/path/to/img.jpg',
        trustLevel: TrustLevel.trusted,
        addedAt: now,
        lastSeen: now,
        notes: 'Kenne ich vom Nachbarschaftstreff',
      );

      final json = c.toJson();
      final restored = Contact.fromJson(json);

      expect(restored.did, 'did:key:z6MkTest');
      expect(restored.pseudonym, 'KlugeKatze99');
      expect(restored.profileImage, '/path/to/img.jpg');
      expect(restored.trustLevel, TrustLevel.trusted);
      expect(restored.addedAt, now);
      expect(restored.notes, 'Kenne ich vom Nachbarschaftstreff');
    });

    test('unknown trustLevel falls back to discovered', () {
      final json = {
        'did': 'did:key:z6MkX',
        'pseudonym': 'X',
        'trustLevel': 'superAdmin', // unknown
        'addedAt': DateTime.now().toIso8601String(),
        'lastSeen': DateTime.now().toIso8601String(),
      };
      final c = Contact.fromJson(json);
      expect(c.trustLevel, TrustLevel.discovered);
    });

    test('missing dates fall back to now without throwing', () {
      final json = {
        'did': 'did:key:z6MkX',
        'pseudonym': 'X',
        'trustLevel': 'contact',
        'addedAt': null,
        'lastSeen': null,
      };
      expect(() => Contact.fromJson(json), returnsNormally);
    });
  });

  // ── TrustLevel labels ───────────────────────────────────────────────────

  group('TrustLevel.label', () {
    test('all trust levels have non-empty labels', () {
      for (final level in TrustLevel.values) {
        expect(level.label.isNotEmpty, isTrue);
      }
    });
  });
}
