import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nexus_oneapp/services/invite_service.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    InviteService.instance.resetForTest();
  });

  // ── InvitePayload ────────────────────────────────────────────────────────────

  group('InvitePayload.displayCode', () {
    test('formats 8-char code as NEXUS-XXXX-XXXX', () {
      final payload = InvitePayload(
        code: 'A7K3M9PX',
        did: 'did:key:z123',
        pseudonym: 'Alice',
        xpub: 'aabb',
        npub: 'ccdd',
        expires: DateTime.now().add(const Duration(days: 30)),
      );
      expect(payload.displayCode, 'NEXUS-A7K3-M9PX');
    });
  });

  group('InvitePayload.isExpired', () {
    test('returns false when expires is in the future', () {
      final payload = InvitePayload(
        code: 'AAAAAAAA',
        did: 'did:key:z1',
        pseudonym: 'A',
        xpub: 'x',
        npub: 'n',
        expires: DateTime.now().add(const Duration(days: 1)),
      );
      expect(payload.isExpired, isFalse);
    });

    test('returns true when expires is in the past', () {
      final payload = InvitePayload(
        code: 'AAAAAAAA',
        did: 'did:key:z1',
        pseudonym: 'A',
        xpub: 'x',
        npub: 'n',
        expires: DateTime.now().subtract(const Duration(seconds: 1)),
      );
      expect(payload.isExpired, isTrue);
    });
  });

  group('InvitePayload encode/decode roundtrip', () {
    test('tryDecode reverses encoded output', () {
      final original = InvitePayload(
        code: 'B3PX7QMN',
        did: 'did:key:zAbcDef',
        pseudonym: 'TestUser',
        xpub: 'deadbeef',
        npub: 'cafebabe',
        expires: DateTime.fromMillisecondsSinceEpoch(1900000000000),
      );
      final decoded = InvitePayload.tryDecode(original.encoded);
      expect(decoded, isNotNull);
      expect(decoded!.code, original.code);
      expect(decoded.did, original.did);
      expect(decoded.pseudonym, original.pseudonym);
      expect(decoded.xpub, original.xpub);
      expect(decoded.npub, original.npub);
      expect(decoded.expires.millisecondsSinceEpoch,
          original.expires.millisecondsSinceEpoch);
    });

    test('tryDecode returns null for garbage input', () {
      expect(InvitePayload.tryDecode('not-valid-base64!!!'), isNull);
    });

    test('tryDecode handles missing padding gracefully', () {
      final payload = InvitePayload(
        code: 'ZZZZAAAA',
        did: 'did:key:z2',
        pseudonym: 'Bob',
        xpub: 'x2',
        npub: 'n2',
        expires: DateTime.fromMillisecondsSinceEpoch(2000000000000),
      );
      // Remove trailing '=' chars that base64url may add
      final noPad = payload.encoded.replaceAll('=', '');
      final decoded = InvitePayload.tryDecode(noPad);
      expect(decoded, isNotNull);
      expect(decoded!.pseudonym, 'Bob');
    });
  });

  group('InvitePayload.normaliseCode', () {
    test('strips separators and uppercases', () {
      expect(InvitePayload.normaliseCode('NEXUS-A7K3-M9PX'), 'NEXUSA7K3M9PX');
      expect(InvitePayload.normaliseCode('nexus-a7k3-m9px'), 'NEXUSA7K3M9PX');
      expect(InvitePayload.normaliseCode('A7K3M9PX'), 'A7K3M9PX');
    });
  });

  group('InvitePayload.isValidCode', () {
    test('accepts 8 uppercase alphanumeric chars', () {
      expect(InvitePayload.isValidCode('A7K3M9PX'), isTrue);
      expect(InvitePayload.isValidCode('ZZZZZZZZ'), isTrue);
    });

    test('rejects wrong length', () {
      expect(InvitePayload.isValidCode('SHORT'), isFalse);
      expect(InvitePayload.isValidCode('TOOLONGGG'), isFalse);
    });

    test('rejects lowercase', () {
      expect(InvitePayload.isValidCode('a7k3m9px'), isFalse);
    });
  });

  // ── InviteRecord ─────────────────────────────────────────────────────────────

  group('InviteRecord', () {
    test('displayCode formats correctly', () {
      final r = InviteRecord(
        code: 'M9PXAAAA',
        encoded: '',
        createdAt: DateTime(2026),
      );
      expect(r.displayCode, 'NEXUS-M9PX-AAAA');
    });

    test('isPending is true when redeemedByPseudonym is null', () {
      final r = InviteRecord(
        code: 'AAAAAAAA',
        encoded: '',
        createdAt: DateTime(2026),
      );
      expect(r.isPending, isTrue);
    });

    test('isPending is false when redeemed', () {
      final r = InviteRecord(
        code: 'AAAAAAAA',
        encoded: '',
        createdAt: DateTime(2026),
        redeemedByPseudonym: 'Alice',
      );
      expect(r.isPending, isFalse);
    });

    test('toJson / fromJson roundtrip', () {
      final r = InviteRecord(
        code: 'BBBBBBBB',
        encoded: 'some_encoded',
        createdAt: DateTime(2026, 3, 15),
        redeemedByPseudonym: 'Carol',
      );
      final r2 = InviteRecord.fromJson(r.toJson());
      expect(r2.code, r.code);
      expect(r2.encoded, r.encoded);
      expect(r2.createdAt, r.createdAt);
      expect(r2.redeemedByPseudonym, r.redeemedByPseudonym);
    });
  });

  // ── InviteService ─────────────────────────────────────────────────────────────

  group('InviteService.generateInviteCode', () {
    test('adds a record to invites list', () async {
      expect(InviteService.instance.invites, isEmpty);
      await InviteService.instance.generateInviteCode(
        did: 'did:key:z1',
        pseudonym: 'Alice',
        xpub: 'aa',
        npub: 'bb',
      );
      expect(InviteService.instance.invites, hasLength(1));
    });

    test('record is pending after generation', () async {
      await InviteService.instance.generateInviteCode(
        did: 'did:key:z2',
        pseudonym: 'Bob',
        xpub: 'xx',
        npub: 'yy',
      );
      expect(InviteService.instance.invites.first.isPending, isTrue);
    });

    test('generates unique codes for multiple calls', () async {
      await InviteService.instance.generateInviteCode(
          did: 'd1', pseudonym: 'A', xpub: 'x', npub: 'n');
      await InviteService.instance.generateInviteCode(
          did: 'd2', pseudonym: 'B', xpub: 'x', npub: 'n');
      final codes = InviteService.instance.invites.map((r) => r.code).toList();
      expect(codes.toSet().length, codes.length); // all unique
    });

    test('newest invite is first in list', () async {
      await InviteService.instance.generateInviteCode(
          did: 'd1', pseudonym: 'First', xpub: 'x', npub: 'n');
      await InviteService.instance.generateInviteCode(
          did: 'd2', pseudonym: 'Second', xpub: 'x', npub: 'n');
      final payload0 =
          InvitePayload.tryDecode(InviteService.instance.invites[0].encoded)!;
      final payload1 =
          InvitePayload.tryDecode(InviteService.instance.invites[1].encoded)!;
      expect(payload0.pseudonym, 'Second');
      expect(payload1.pseudonym, 'First');
    });
  });

  group('InviteService.markRedeemed', () {
    test('sets redeemedByPseudonym on the matching record', () async {
      final record = await InviteService.instance.generateInviteCode(
        did: 'did:key:z3',
        pseudonym: 'Carol',
        xpub: 'xx',
        npub: 'yy',
      );
      await InviteService.instance.markRedeemed(record.code, 'Dave');
      expect(record.redeemedByPseudonym, 'Dave');
      expect(record.isPending, isFalse);
    });

    test('does nothing for unknown code', () async {
      await InviteService.instance.generateInviteCode(
          did: 'd', pseudonym: 'E', xpub: 'x', npub: 'n');
      // Should not throw.
      await InviteService.instance.markRedeemed('UNKNOWN1', 'Eve');
      expect(InviteService.instance.invites.first.isPending, isTrue);
    });
  });

  group('InviteService.buildDeepLink', () {
    test('builds a nexus://invite deep-link', () async {
      final record = await InviteService.instance.generateInviteCode(
        did: 'did:key:zX',
        pseudonym: 'Frank',
        xpub: 'xx',
        npub: 'nn',
      );
      final link = InviteService.instance.buildDeepLink(record);
      expect(link, startsWith('nexus://invite'));
      expect(link, contains('d=${record.encoded}'));
    });
  });

  group('InviteService.redeemEncoded', () {
    test('fails on garbage input', () async {
      final result = await InviteService.instance.redeemEncoded(
        encoded: 'not-a-real-code',
        myPseudonym: 'Me',
      );
      expect(result.success, isFalse);
    });

    test('fails on expired payload', () async {
      final expired = InvitePayload(
        code: 'EXPIREDA',
        did: 'did:key:zOld',
        pseudonym: 'Old',
        xpub: 'x',
        npub: 'n',
        expires: DateTime.now().subtract(const Duration(days: 1)),
      );
      final result = await InviteService.instance.redeemEncoded(
        encoded: expired.encoded,
        myPseudonym: 'Me',
      );
      expect(result.success, isFalse);
      expect(result.error, contains('abgelaufen'));
    });
  });

  group('InviteService.buildShareText', () {
    test('includes display code and NEXUS branding', () async {
      final record = await InviteService.instance.generateInviteCode(
        did: 'did:key:zShare',
        pseudonym: 'Grace',
        xpub: 'x',
        npub: 'n',
      );
      final text = InviteService.instance.buildShareText(record);
      expect(text, contains(record.displayCode));
      expect(text, contains('N.E.X.U.S.'));
    });
  });

  group('InviteService.load / persistence', () {
    test('roundtrips invites via SharedPreferences', () async {
      await InviteService.instance.generateInviteCode(
          did: 'd', pseudonym: 'Persist', xpub: 'x', npub: 'n');
      final code = InviteService.instance.invites.first.code;

      // Simulate a fresh service instance by resetting and reloading.
      InviteService.instance.resetForTest();
      expect(InviteService.instance.invites, isEmpty);

      await InviteService.instance.load();
      expect(InviteService.instance.invites, hasLength(1));
      expect(InviteService.instance.invites.first.code, code);
    });
  });
}
