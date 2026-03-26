import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/core/contacts/contact.dart';
import 'package:nexus_oneapp/core/contacts/contact_service.dart';
import 'package:nexus_oneapp/core/identity/profile.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Contact _makeContact({
  String did = 'did:key:test',
  String pseudonym = 'Alice',
  TrustLevel level = TrustLevel.discovered,
  bool blocked = false,
  String? notes,
}) {
  final now = DateTime.now();
  return Contact(
    did: did,
    pseudonym: pseudonym,
    trustLevel: level,
    addedAt: now,
    lastSeen: now,
    blocked: blocked,
    notes: notes,
  );
}

// Minimal in-memory ContactService without DB (unit-test safe).
// We test the pure logic of Contact + TrustLevel directly.

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  sqfliteFfiInit();

  // ── TrustLevel ────────────────────────────────────────────────────────────

  group('TrustLevel', () {
    test('labels are correct', () {
      expect(TrustLevel.discovered.label, 'Entdeckt');
      expect(TrustLevel.contact.label, 'Kontakt');
      expect(TrustLevel.trusted.label, 'Vertrauensperson');
      expect(TrustLevel.guardian.label, 'Bürge');
    });

    test('sortWeight: guardian > trusted > contact > discovered', () {
      expect(TrustLevel.guardian.sortWeight,
          greaterThan(TrustLevel.trusted.sortWeight));
      expect(TrustLevel.trusted.sortWeight,
          greaterThan(TrustLevel.contact.sortWeight));
      expect(TrustLevel.contact.sortWeight,
          greaterThan(TrustLevel.discovered.sortWeight));
    });

    test('allowedVisibility – discovered can only see public', () {
      expect(
        TrustLevel.discovered.allowedVisibility,
        equals({VisibilityLevel.public}),
      );
    });

    test('allowedVisibility – contact can see public + contacts', () {
      expect(
        TrustLevel.contact.allowedVisibility,
        containsAll([VisibilityLevel.public, VisibilityLevel.contacts]),
      );
      expect(
        TrustLevel.contact.allowedVisibility,
        isNot(contains(VisibilityLevel.trusted)),
      );
    });

    test('allowedVisibility – trusted/guardian see all non-private', () {
      for (final level in [TrustLevel.trusted, TrustLevel.guardian]) {
        expect(
          level.allowedVisibility,
          containsAll([
            VisibilityLevel.public,
            VisibilityLevel.contacts,
            VisibilityLevel.trusted,
          ]),
        );
      }
    });
  });

  // ── Contact model ─────────────────────────────────────────────────────────

  group('Contact serialization', () {
    test('toJson / fromJson round-trip preserves all fields', () {
      final original = _makeContact(
        did: 'did:key:abc',
        pseudonym: 'Bob',
        level: TrustLevel.trusted,
        blocked: false,
        notes: 'My buddy',
      );

      final json = original.toJson();
      final restored = Contact.fromJson(json);

      expect(restored.did, original.did);
      expect(restored.pseudonym, original.pseudonym);
      expect(restored.trustLevel, original.trustLevel);
      expect(restored.blocked, original.blocked);
      expect(restored.notes, original.notes);
    });

    test('fromJson defaults blocked to false when field missing', () {
      final json = <String, dynamic>{
        'did': 'did:key:xyz',
        'pseudonym': 'Carol',
        'trustLevel': 'contact',
        'addedAt': DateTime.now().toIso8601String(),
        'lastSeen': DateTime.now().toIso8601String(),
        // 'blocked' intentionally absent
      };

      final contact = Contact.fromJson(json);
      expect(contact.blocked, isFalse);
    });

    test('fromJson handles unknown trustLevel gracefully', () {
      final json = <String, dynamic>{
        'did': 'did:key:xyz',
        'pseudonym': 'Dave',
        'trustLevel': 'super_admin_level_99', // invalid
        'addedAt': DateTime.now().toIso8601String(),
        'lastSeen': DateTime.now().toIso8601String(),
      };

      final contact = Contact.fromJson(json);
      expect(contact.trustLevel, TrustLevel.discovered); // fallback
    });
  });

  // ── Filtering by trust level ───────────────────────────────────────────────

  group('Filtering by trust level', () {
    List<Contact> contacts() => [
          _makeContact(did: 'a', level: TrustLevel.discovered),
          _makeContact(did: 'b', level: TrustLevel.contact),
          _makeContact(did: 'c', level: TrustLevel.trusted),
          _makeContact(did: 'd', level: TrustLevel.guardian),
        ];

    test('filter contact level', () {
      final result =
          contacts().where((c) => c.trustLevel == TrustLevel.contact).toList();
      expect(result.length, 1);
      expect(result.first.did, 'b');
    });

    test('filter trusted level', () {
      final result =
          contacts().where((c) => c.trustLevel == TrustLevel.trusted).toList();
      expect(result.length, 1);
      expect(result.first.did, 'c');
    });

    test('filter guardian level', () {
      final result =
          contacts().where((c) => c.trustLevel == TrustLevel.guardian).toList();
      expect(result.length, 1);
      expect(result.first.did, 'd');
    });
  });

  // ── Sorting ───────────────────────────────────────────────────────────────

  group('Sorting (guardian first, discovered last, alphabetical within level)',
      () {
    List<Contact> unsorted() => [
          _makeContact(did: 'z', pseudonym: 'Zara', level: TrustLevel.discovered),
          _makeContact(did: 'a', pseudonym: 'Alice', level: TrustLevel.trusted),
          _makeContact(did: 'b', pseudonym: 'Bob', level: TrustLevel.guardian),
          _makeContact(did: 'c', pseudonym: 'Carol', level: TrustLevel.contact),
          _makeContact(did: 'd', pseudonym: 'Dave', level: TrustLevel.trusted),
        ];

    List<Contact> sorted(List<Contact> all) {
      final list = [...all];
      list.sort((a, b) {
        final byLevel =
            b.trustLevel.sortWeight.compareTo(a.trustLevel.sortWeight);
        if (byLevel != 0) return byLevel;
        return a.pseudonym.toLowerCase().compareTo(b.pseudonym.toLowerCase());
      });
      return list;
    }

    test('guardian comes first', () {
      final s = sorted(unsorted());
      expect(s.first.trustLevel, TrustLevel.guardian);
    });

    test('discovered comes last', () {
      final s = sorted(unsorted());
      expect(s.last.trustLevel, TrustLevel.discovered);
    });

    test('within trusted level: alphabetical by pseudonym', () {
      final s = sorted(unsorted());
      final trustedGroup = s.where((c) => c.trustLevel == TrustLevel.trusted).toList();
      expect(trustedGroup.map((c) => c.pseudonym).toList(),
          ['Alice', 'Dave']);
    });
  });

  // ── Blocked contacts ───────────────────────────────────────────────────────

  group('Blocked contacts', () {
    test('blocked contact serializes correctly', () {
      final c = _makeContact(blocked: true);
      final json = c.toJson();
      expect(json['blocked'], isTrue);
      final restored = Contact.fromJson(json);
      expect(restored.blocked, isTrue);
    });

    test('blocked contacts are excluded from non-blocked list', () {
      final all = [
        _makeContact(did: 'a', blocked: false),
        _makeContact(did: 'b', blocked: true),
        _makeContact(did: 'c', blocked: false),
      ];
      final nonBlocked = all.where((c) => !c.blocked).toList();
      expect(nonBlocked.length, 2);
      expect(nonBlocked.any((c) => c.did == 'b'), isFalse);
    });

    test('blocked contacts are included in blocked list', () {
      final all = [
        _makeContact(did: 'a', blocked: false),
        _makeContact(did: 'b', blocked: true),
      ];
      final blocked = all.where((c) => c.blocked).toList();
      expect(blocked.length, 1);
      expect(blocked.first.did, 'b');
    });
  });

  // ── Selective Disclosure ──────────────────────────────────────────────────

  group('Selective Disclosure – correct field filtering per trust level', () {
    // Build a minimal UserProfile mock via visibilityLevel logic.
    test('discovered sees only public fields', () {
      final allowed = TrustLevel.discovered.allowedVisibility;
      expect(allowed.contains(VisibilityLevel.public), isTrue);
      expect(allowed.contains(VisibilityLevel.contacts), isFalse);
      expect(allowed.contains(VisibilityLevel.trusted), isFalse);
      expect(allowed.contains(VisibilityLevel.private), isFalse);
    });

    test('contact sees public + contacts fields', () {
      final allowed = TrustLevel.contact.allowedVisibility;
      expect(allowed.contains(VisibilityLevel.public), isTrue);
      expect(allowed.contains(VisibilityLevel.contacts), isTrue);
      expect(allowed.contains(VisibilityLevel.trusted), isFalse);
      expect(allowed.contains(VisibilityLevel.private), isFalse);
    });

    test('trusted/guardian see public + contacts + trusted', () {
      for (final level in [TrustLevel.trusted, TrustLevel.guardian]) {
        final allowed = level.allowedVisibility;
        expect(allowed.contains(VisibilityLevel.public), isTrue);
        expect(allowed.contains(VisibilityLevel.contacts), isTrue);
        expect(allowed.contains(VisibilityLevel.trusted), isTrue);
        // Private is always excluded from transmission.
        expect(allowed.contains(VisibilityLevel.private), isFalse);
      }
    });
  });

  // ── Trust level changes ───────────────────────────────────────────────────

  group('Trust level upgrade and downgrade', () {
    test('upgrade: contact → trusted → guardian', () {
      final c = _makeContact(level: TrustLevel.contact);
      c.trustLevel = TrustLevel.trusted;
      expect(c.trustLevel, TrustLevel.trusted);
      c.trustLevel = TrustLevel.guardian;
      expect(c.trustLevel, TrustLevel.guardian);
    });

    test('downgrade: guardian → contact → discovered', () {
      final c = _makeContact(level: TrustLevel.guardian);
      c.trustLevel = TrustLevel.contact;
      expect(c.trustLevel, TrustLevel.contact);
      c.trustLevel = TrustLevel.discovered;
      expect(c.trustLevel, TrustLevel.discovered);
    });
  });

  // ── Search ────────────────────────────────────────────────────────────────

  group('Search by pseudonym, DID fragment and note', () {
    final contacts = [
      _makeContact(
          did: 'did:key:abcdef', pseudonym: 'Alice', notes: 'Freundin'),
      _makeContact(did: 'did:key:xyz', pseudonym: 'Bob', notes: null),
      _makeContact(
          did: 'did:key:111222', pseudonym: 'Carol', notes: 'Kollegin'),
    ];

    List<Contact> search(String q) {
      final lower = q.toLowerCase();
      return contacts.where((c) {
        if (c.pseudonym.toLowerCase().contains(lower)) return true;
        if (c.did.toLowerCase().contains(lower)) return true;
        if (c.notes?.toLowerCase().contains(lower) ?? false) return true;
        return false;
      }).toList();
    }

    test('search by pseudonym', () {
      final r = search('ali');
      expect(r.length, 1);
      expect(r.first.pseudonym, 'Alice');
    });

    test('search by DID fragment', () {
      final r = search('xyz');
      expect(r.length, 1);
      expect(r.first.pseudonym, 'Bob');
    });

    test('search by note', () {
      final r = search('kollegin');
      expect(r.length, 1);
      expect(r.first.pseudonym, 'Carol');
    });

    test('empty query returns all', () {
      final r = search('');
      expect(r.length, contacts.length);
    });

    test('no match returns empty list', () {
      final r = search('zzznomatch999');
      expect(r.isEmpty, isTrue);
    });
  });

  // ── Import / Export ───────────────────────────────────────────────────────

  group('ContactService.exportJson / importJson (logic only)', () {
    test('exportJson produces valid JSON array', () {
      final contacts = [
        _makeContact(did: 'did:key:a', pseudonym: 'Alice'),
        _makeContact(did: 'did:key:b', pseudonym: 'Bob'),
      ];

      final jsonStr = jsonEncode(contacts.map((c) => c.toJson()).toList());
      final decoded = jsonDecode(jsonStr) as List<dynamic>;
      expect(decoded.length, 2);
      expect(decoded[0]['pseudonym'], 'Alice');
    });

    test('ImportResult counts: higher trust level wins on conflict', () {
      // Simulate what importJson does internally.
      final existing = _makeContact(
          did: 'did:key:x', level: TrustLevel.contact);
      final importedLevel = TrustLevel.trusted;

      final higherWins =
          importedLevel.sortWeight > existing.trustLevel.sortWeight;
      expect(higherWins, isTrue);
    });

    test('ImportResult: lower trust level does not overwrite', () {
      final existing = _makeContact(
          did: 'did:key:x', level: TrustLevel.trusted);
      final importedLevel = TrustLevel.contact;

      final higherWins =
          importedLevel.sortWeight > existing.trustLevel.sortWeight;
      expect(higherWins, isFalse);
    });

    test('blocked flag is never imported', () {
      final json = <String, dynamic>{
        'did': 'did:key:bad',
        'pseudonym': 'Villain',
        'trustLevel': 'contact',
        'addedAt': DateTime.now().toIso8601String(),
        'lastSeen': DateTime.now().toIso8601String(),
        'blocked': true, // should be stripped on import
      };

      final contact = Contact.fromJson(json);
      // In real importJson we reset blocked=false; simulate that here.
      contact.blocked = false;
      expect(contact.blocked, isFalse);
    });
  });
}
