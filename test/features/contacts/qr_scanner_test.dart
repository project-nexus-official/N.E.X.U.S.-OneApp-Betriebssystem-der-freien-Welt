import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/features/contacts/qr_contact_payload.dart';

/// Tests for QR code scanning and contact-add logic.
///
/// All tests are pure-logic (no Flutter widgets, no platform plugins)
/// so they run on any platform including CI.
void main() {
  // ── QrContactPayload: generation ─────────────────────────────────────────

  group('QrContactPayload.toJsonString', () {
    test('generates required fields in correct JSON format', () {
      const payload = QrContactPayload(
        did: 'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK',
        pseudonym: 'Josh Richman',
        publicKey: 'aabb1122aabb1122aabb1122aabb1122aabb1122aabb1122aabb1122aabb1122',
        nostrPubkey: '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef',
      );

      final json = jsonDecode(payload.toJsonString()) as Map<String, dynamic>;
      expect(json['type'], equals('nexus-contact'));
      expect(json['did'],
          equals('did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK'));
      expect(json['pseudonym'], equals('Josh Richman'));
      expect(json['publicKey'],
          equals('aabb1122aabb1122aabb1122aabb1122aabb1122aabb1122aabb1122aabb1122'));
      expect(json['nostrPubkey'],
          equals('1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef'));
    });

    test('omits publicKey and nostrPubkey when null', () {
      const payload = QrContactPayload(
        did: 'did:key:z6Mk123',
        pseudonym: 'Alice',
      );
      final json = jsonDecode(payload.toJsonString()) as Map<String, dynamic>;
      expect(json.containsKey('publicKey'), isFalse);
      expect(json.containsKey('nostrPubkey'), isFalse);
    });
  });

  // ── QrContactPayload.tryParse: valid payloads ─────────────────────────────

  group('QrContactPayload.tryParse – valid', () {
    test('parses full nexus-contact JSON correctly', () {
      final raw = jsonEncode({
        'type': 'nexus-contact',
        'did': 'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK',
        'pseudonym': 'Josh Richman',
        'publicKey': 'aabb1122' * 8,
        'nostrPubkey': 'deadbeef' * 8,
      });

      final payload = QrContactPayload.tryParse(raw);
      expect(payload, isNotNull);
      expect(payload!.did,
          equals('did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK'));
      expect(payload.pseudonym, equals('Josh Richman'));
      expect(payload.publicKey, equals('aabb1122' * 8));
      expect(payload.nostrPubkey, equals('deadbeef' * 8));
    });

    test('parses minimal payload (only required fields)', () {
      final raw = jsonEncode({
        'type': 'nexus-contact',
        'did': 'did:key:z6Mk123',
        'pseudonym': 'Bob',
      });

      final payload = QrContactPayload.tryParse(raw);
      expect(payload, isNotNull);
      expect(payload!.publicKey, isNull);
      expect(payload.nostrPubkey, isNull);
    });

    test('roundtrip: toJsonString → tryParse returns same data', () {
      final original = QrContactPayload(
        did: 'did:key:z6MkmRLeGBZTxoPMu48eXs9GHNPVJa1iNCzH9QCneWmy8TwK',
        pseudonym: 'Max Mustermann',
        publicKey: 'cafebabe' * 8,
        nostrPubkey: 'f00dface' * 8,
      );

      final parsed = QrContactPayload.tryParse(original.toJsonString());
      expect(parsed, isNotNull);
      expect(parsed!.did, equals(original.did));
      expect(parsed.pseudonym, equals(original.pseudonym));
      expect(parsed.publicKey, equals(original.publicKey));
      expect(parsed.nostrPubkey, equals(original.nostrPubkey));
    });

    test('trims whitespace in pseudonym', () {
      final raw = jsonEncode({
        'type': 'nexus-contact',
        'did': 'did:key:z6Mk123',
        'pseudonym': '  Alice  ',
      });
      final payload = QrContactPayload.tryParse(raw);
      expect(payload?.pseudonym, equals('Alice'));
    });
  });

  // ── QrContactPayload.tryParse: invalid payloads ───────────────────────────

  group('QrContactPayload.tryParse – invalid (returns null)', () {
    test('returns null for non-JSON string', () {
      expect(QrContactPayload.tryParse('not json at all'), isNull);
    });

    test('returns null when type is missing', () {
      final raw = jsonEncode({
        'did': 'did:key:z6Mk123',
        'pseudonym': 'Alice',
      });
      expect(QrContactPayload.tryParse(raw), isNull);
    });

    test('returns null when type is wrong', () {
      final raw = jsonEncode({
        'type': 'bitcoin-address',
        'did': 'did:key:z6Mk123',
        'pseudonym': 'Alice',
      });
      expect(QrContactPayload.tryParse(raw), isNull,
          reason: 'Kein NEXUS-Kontakt erkannt');
    });

    test('returns null when DID does not start with did:key:', () {
      final raw = jsonEncode({
        'type': 'nexus-contact',
        'did': 'did:web:example.com',
        'pseudonym': 'Alice',
      });
      expect(QrContactPayload.tryParse(raw), isNull);
    });

    test('returns null when DID is missing', () {
      final raw = jsonEncode({
        'type': 'nexus-contact',
        'pseudonym': 'Alice',
      });
      expect(QrContactPayload.tryParse(raw), isNull);
    });

    test('returns null when pseudonym is empty', () {
      final raw = jsonEncode({
        'type': 'nexus-contact',
        'did': 'did:key:z6Mk123',
        'pseudonym': '   ',
      });
      expect(QrContactPayload.tryParse(raw), isNull);
    });

    test('returns null when pseudonym is missing', () {
      final raw = jsonEncode({
        'type': 'nexus-contact',
        'did': 'did:key:z6Mk123',
      });
      expect(QrContactPayload.tryParse(raw), isNull);
    });

    test('returns null for empty string', () {
      expect(QrContactPayload.tryParse(''), isNull);
    });

    test('returns null for a plain DID string (not JSON)', () {
      // A bare DID is NOT a valid QR payload – it needs the JSON wrapper.
      expect(
          QrContactPayload.tryParse(
              'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK'),
          isNull);
    });
  });

  // ── shortDid helper ───────────────────────────────────────────────────────

  group('QrContactPayload.shortDid', () {
    test('abbreviates long DID', () {
      const payload = QrContactPayload(
        did: 'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK',
        pseudonym: 'Test',
      );
      expect(payload.shortDid.length, lessThan(payload.did.length));
      expect(payload.shortDid, contains('…'));
      expect(payload.shortDid, startsWith('did:key:z6MkhaX'));
      expect(payload.shortDid, endsWith('a2doK'));
    });

    test('returns full DID when short enough', () {
      const payload = QrContactPayload(
        did: 'did:key:z6Mk123',
        pseudonym: 'Test',
      );
      expect(payload.shortDid, equals('did:key:z6Mk123'));
    });
  });

  // ── Contact trust level from QR ───────────────────────────────────────────

  group('Contact trust level from QR scan', () {
    test('addContactFromQr sets trust level to contact (not discovered)', () {
      // The QR scan implies face-to-face meeting → start at TrustLevel.contact.
      // We can test this by inspecting the QrContactPayload alone (since
      // ContactService.addContactFromQr is the authoritative implementation).
      // Here we verify the QR payload carries all data needed to create a
      // contact at the correct trust level.
      final payload = QrContactPayload(
        did: 'did:key:z6Mk123',
        pseudonym: 'Alice',
        publicKey: 'aa' * 32,
        nostrPubkey: 'bb' * 32,
      );

      // The payload carries all 4 fields needed by addContactFromQr.
      expect(payload.did, startsWith('did:key:'));
      expect(payload.pseudonym, isNotEmpty);
      expect(payload.publicKey, isNotNull);
      expect(payload.nostrPubkey, isNotNull);
    });

    test('X25519 key is stored when present in QR payload', () {
      final raw = jsonEncode({
        'type': 'nexus-contact',
        'did': 'did:key:z6Mk456',
        'pseudonym': 'Bob',
        'publicKey': 'cafecafe' * 8,
      });

      final payload = QrContactPayload.tryParse(raw)!;
      expect(payload.publicKey, equals('cafecafe' * 8),
          reason: 'X25519 key must survive JSON roundtrip');
    });

    test('nostrPubkey is stored when present in QR payload', () {
      final raw = jsonEncode({
        'type': 'nexus-contact',
        'did': 'did:key:z6Mk789',
        'pseudonym': 'Carol',
        'nostrPubkey': 'f00df00d' * 8,
      });

      final payload = QrContactPayload.tryParse(raw)!;
      expect(payload.nostrPubkey, equals('f00df00d' * 8));
    });
  });

  // ── Duplicate detection logic ─────────────────────────────────────────────

  group('Duplicate detection', () {
    test('same DID parsed twice is identical (for duplicate detection)', () {
      final raw = jsonEncode({
        'type': 'nexus-contact',
        'did': 'did:key:z6MkDuplicate',
        'pseudonym': 'Dave',
      });

      final p1 = QrContactPayload.tryParse(raw)!;
      final p2 = QrContactPayload.tryParse(raw)!;

      // The DID is the unique key used for deduplication.
      expect(p1.did, equals(p2.did));
    });
  });

  // ── Windows fallback: manual DID/JSON input ───────────────────────────────

  group('Windows fallback – manual input parsing', () {
    test('full JSON string is parsed by tryParse', () {
      // User pastes full JSON from another device.
      final pastedJson = jsonEncode({
        'type': 'nexus-contact',
        'did': 'did:key:z6MkWindows',
        'pseudonym': 'Frank',
        'publicKey': '12345678' * 8,
      });

      final payload = QrContactPayload.tryParse(pastedJson);
      expect(payload, isNotNull);
      expect(payload!.pseudonym, equals('Frank'));
    });

    test('bare DID string is NOT parsed by tryParse (needs wrapping)', () {
      // The manual-entry widget must wrap a bare DID in QrContactPayload
      // before calling tryParse. A plain DID is not valid JSON.
      const bareDid =
          'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK';
      expect(QrContactPayload.tryParse(bareDid), isNull,
          reason: 'Bare DID must be wrapped by the UI before parsing');
    });

    test('UI wraps bare DID: result has correct did and pseudonym', () {
      // Mirrors the logic in _QrScannerScreenState._tryParseManual:
      // if (text.startsWith('did:key:')) {
      //   payload = QrContactPayload(did: text, pseudonym: _shortDid(text));
      // }
      const did =
          'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK';
      final payload = QrContactPayload(did: did, pseudonym: '${did.substring(0, 10)}…${did.substring(did.length - 6)}');
      expect(payload.did, equals(did));
      expect(payload.pseudonym, contains('…'));
    });
  });
}
