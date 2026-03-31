import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/core/contacts/contact.dart';

void main() {
  group('Contact – mutedUntil model', () {
    test('defaults to not muted', () {
      final c = Contact(
        did: 'did:key:test',
        pseudonym: 'Alice',
        trustLevel: TrustLevel.contact,
        addedAt: DateTime.now(),
        lastSeen: DateTime.now(),
      );
      expect(c.mutedUntil, isNull);
    });

    test('toJson serialises mutedUntil as ISO string', () {
      final until = DateTime(2030, 6, 15, 12, 0, 0);
      final c = Contact(
        did: 'did:key:test',
        pseudonym: 'Alice',
        trustLevel: TrustLevel.contact,
        addedAt: DateTime.now(),
        lastSeen: DateTime.now(),
        mutedUntil: until,
      );
      final json = c.toJson();
      expect(json['mutedUntil'], until.toIso8601String());
      expect(json.containsKey('muted'), isFalse);
    });

    test('toJson serialises null mutedUntil', () {
      final c = Contact(
        did: 'did:key:test',
        pseudonym: 'Alice',
        trustLevel: TrustLevel.contact,
        addedAt: DateTime.now(),
        lastSeen: DateTime.now(),
      );
      final json = c.toJson();
      expect(json['mutedUntil'], isNull);
    });

    test('fromJson round-trips mutedUntil', () {
      final until = DateTime(2035, 1, 1);
      final c = Contact(
        did: 'did:key:test',
        pseudonym: 'Bob',
        trustLevel: TrustLevel.discovered,
        addedAt: DateTime(2024),
        lastSeen: DateTime(2024),
        mutedUntil: until,
      );
      final c2 = Contact.fromJson(c.toJson());
      expect(c2.mutedUntil, until);
    });

    test('fromJson with null mutedUntil', () {
      final c = Contact(
        did: 'did:key:test',
        pseudonym: 'Bob',
        trustLevel: TrustLevel.discovered,
        addedAt: DateTime(2024),
        lastSeen: DateTime(2024),
      );
      final c2 = Contact.fromJson(c.toJson());
      expect(c2.mutedUntil, isNull);
    });

    test('fromJson migrates legacy muted:true to permanent mute', () {
      final json = {
        'did': 'did:key:legacy',
        'pseudonym': 'Legacy',
        'trustLevel': 'contact',
        'addedAt': DateTime(2024).toIso8601String(),
        'lastSeen': DateTime(2024).toIso8601String(),
        'muted': true,
      };
      final c = Contact.fromJson(json);
      // mutedUntil must be far in the future (year 9999 = permanent)
      expect(c.mutedUntil, isNotNull);
      expect(c.mutedUntil!.isAfter(DateTime.now()), isTrue);
      expect(c.mutedUntil!.year, 9999);
    });

    test('fromJson with muted:false leaves mutedUntil null', () {
      final json = {
        'did': 'did:key:legacy',
        'pseudonym': 'Legacy',
        'trustLevel': 'contact',
        'addedAt': DateTime(2024).toIso8601String(),
        'lastSeen': DateTime(2024).toIso8601String(),
        'muted': false,
      };
      final c = Contact.fromJson(json);
      expect(c.mutedUntil, isNull);
    });
  });

  group('isMuted logic', () {
    Contact _make({DateTime? mutedUntil}) => Contact(
          did: 'did:key:test',
          pseudonym: 'Test',
          trustLevel: TrustLevel.contact,
          addedAt: DateTime.now(),
          lastSeen: DateTime.now(),
          mutedUntil: mutedUntil,
        );

    bool _isMuted(Contact c) {
      return c.mutedUntil != null &&
          c.mutedUntil!.isAfter(DateTime.now());
    }

    test('returns false when mutedUntil is null', () {
      expect(_isMuted(_make()), isFalse);
    });

    test('returns true when mutedUntil is in the future (timed)', () {
      final c = _make(mutedUntil: DateTime.now().add(const Duration(hours: 1)));
      expect(_isMuted(c), isTrue);
    });

    test('returns true when mutedUntil is year 9999 (permanent)', () {
      final c = _make(mutedUntil: DateTime(9999));
      expect(_isMuted(c), isTrue);
    });

    test('returns false when mutedUntil is in the past (expired)', () {
      final c =
          _make(mutedUntil: DateTime.now().subtract(const Duration(seconds: 1)));
      expect(_isMuted(c), isFalse);
    });

    test('1 hour mute expires after duration', () {
      final start = DateTime.now();
      final c = _make(mutedUntil: start.add(const Duration(hours: 1)));
      // Simulate time passing past the mute end
      final afterExpiry = start.add(const Duration(hours: 1, seconds: 1));
      final stillMuted = c.mutedUntil!.isAfter(afterExpiry);
      expect(stillMuted, isFalse);
    });

    test('permanent mute (year 9999) does not expire within normal time', () {
      final c = _make(mutedUntil: DateTime(9999));
      final farFuture = DateTime.now().add(const Duration(days: 365 * 10));
      expect(c.mutedUntil!.isAfter(farFuture), isTrue);
    });
  });

  group('MuteDuration options', () {
    // Replicate the option list from conversation_screen to test values
    final options = [
      ('1 Stunde', const Duration(hours: 1)),
      ('8 Stunden', const Duration(hours: 8)),
      ('24 Stunden', const Duration(hours: 24)),
      ('7 Tage', const Duration(days: 7)),
      ('Dauerhaft', null),
    ];

    test('all duration labels are unique', () {
      final labels = options.map((o) => o.$1).toList();
      expect(labels.toSet().length, labels.length);
    });

    test('timed durations are strictly increasing', () {
      final durations = options
          .where((o) => o.$2 != null)
          .map((o) => o.$2!.inSeconds)
          .toList();
      for (int i = 1; i < durations.length; i++) {
        expect(durations[i], greaterThan(durations[i - 1]));
      }
    });

    test('permanent option has null duration', () {
      final permanent = options.firstWhere((o) => o.$1 == 'Dauerhaft');
      expect(permanent.$2, isNull);
    });

    test('timed mute calculates correct mutedUntil', () {
      final now = DateTime(2026, 1, 1, 12, 0, 0);
      final duration = const Duration(hours: 8);
      final expected = now.add(duration);
      expect(expected, DateTime(2026, 1, 1, 20, 0, 0));
    });
  });
}
