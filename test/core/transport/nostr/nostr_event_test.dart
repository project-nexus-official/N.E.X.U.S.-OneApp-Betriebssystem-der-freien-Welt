import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/core/identity/bip39.dart';
import 'package:nexus_oneapp/core/transport/nostr/nostr_event.dart';
import 'package:nexus_oneapp/core/transport/nostr/nostr_keys.dart';

void main() {
  const testMnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

  late NostrKeys keys;

  setUpAll(() {
    final seed64 = Uint8List.fromList(Bip39.mnemonicToSeed(testMnemonic));
    keys = NostrKeys.fromBip39Seed(seed64);
  });

  group('NostrEvent - creation', () {
    test('creates event with correct fields', () {
      final event = NostrEvent.create(
        keys: keys,
        kind: NostrKind.textNote,
        content: 'hello nexus',
        tags: [
          ['t', 'nexus-mesh']
        ],
      );

      expect(event.pubkey, equals(keys.publicKeyHex));
      expect(event.kind, equals(NostrKind.textNote));
      expect(event.content, equals('hello nexus'));
      expect(event.id.length, equals(64));
      expect(event.sig.length, equals(128));
      // Use tagValue helper – list equality needs special handling
      expect(event.tagValue('t'), equals('nexus-mesh'));
    });

    test('event ID is 64 hex chars (SHA256)', () {
      final event = NostrEvent.create(
        keys: keys,
        kind: NostrKind.encryptedDm,
        content: 'encrypted',
        tags: [
          ['p', 'deadbeef' * 8]
        ],
      );
      expect(event.id.length, equals(64));
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(event.id), isTrue);
    });

    test('created_at is within 5 seconds of now', () {
      final event = NostrEvent.create(
        keys: keys,
        kind: NostrKind.textNote,
        content: 'timing test',
      );
      final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      expect((event.createdAt - now).abs(), lessThan(5));
    });

    test('two events at same timestamp have different IDs', () {
      final ts = DateTime(2025, 1, 1, 12, 0, 0);
      final e1 = NostrEvent.create(
        keys: keys,
        kind: NostrKind.textNote,
        content: 'message 1',
        timestamp: ts,
      );
      final e2 = NostrEvent.create(
        keys: keys,
        kind: NostrKind.textNote,
        content: 'message 2',
        timestamp: ts,
      );
      expect(e1.id, isNot(equals(e2.id)));
    });
  });

  group('NostrEvent - verification', () {
    test('freshly created event verifies', () {
      final event = NostrEvent.create(
        keys: keys,
        kind: NostrKind.textNote,
        content: 'verify me',
      );
      expect(event.verify(), isTrue);
    });

    test('tampered content fails verification', () {
      final event = NostrEvent.create(
        keys: keys,
        kind: NostrKind.textNote,
        content: 'original',
      );
      final tampered = NostrEvent(
        id: event.id,
        pubkey: event.pubkey,
        createdAt: event.createdAt,
        kind: event.kind,
        tags: event.tags,
        content: 'tampered',
        sig: event.sig,
      );
      expect(tampered.verify(), isFalse);
    });

    test('tampered sig fails verification', () {
      final event = NostrEvent.create(
        keys: keys,
        kind: NostrKind.textNote,
        content: 'content',
      );
      final badSig = 'a' * 128;
      final tampered = NostrEvent(
        id: event.id,
        pubkey: event.pubkey,
        createdAt: event.createdAt,
        kind: event.kind,
        tags: event.tags,
        content: event.content,
        sig: badSig,
      );
      expect(tampered.verify(), isFalse);
    });
  });

  group('NostrEvent - tag helpers', () {
    test('tagValue returns first value for tag name', () {
      final event = NostrEvent.create(
        keys: keys,
        kind: NostrKind.textNote,
        content: '',
        tags: [
          ['t', 'nexus-mesh'],
          ['t', 'nexus-geo-u33d8'],
          ['p', 'abc123'],
        ],
      );
      expect(event.tagValue('t'), equals('nexus-mesh'));
      expect(event.tagValue('p'), equals('abc123'));
      expect(event.tagValue('e'), isNull);
    });

    test('tagValues returns all values for tag name', () {
      final event = NostrEvent.create(
        keys: keys,
        kind: NostrKind.textNote,
        content: '',
        tags: [
          ['t', 'nexus-mesh'],
          ['t', 'nexus-geo-u33d8'],
        ],
      );
      expect(event.tagValues('t'),
          containsAll(['nexus-mesh', 'nexus-geo-u33d8']));
      expect(event.tagValues('t').length, equals(2));
    });
  });

  group('NostrEvent - serialization', () {
    test('JSON round-trip preserves all fields', () {
      final event = NostrEvent.create(
        keys: keys,
        kind: NostrKind.encryptedDm,
        content: 'some encrypted content?iv=abc=',
        tags: [
          ['p', 'deadbeef' * 8]
        ],
      );

      final json = event.toJson();
      final restored = NostrEvent.fromJson(json);

      expect(restored.id, equals(event.id));
      expect(restored.pubkey, equals(event.pubkey));
      expect(restored.createdAt, equals(event.createdAt));
      expect(restored.kind, equals(event.kind));
      expect(restored.content, equals(event.content));
      expect(restored.sig, equals(event.sig));
      expect(restored.tags, equals(event.tags));
    });

    test('restored event also verifies', () {
      final event = NostrEvent.create(
        keys: keys,
        kind: NostrKind.textNote,
        content: 'roundtrip',
      );
      final restored = NostrEvent.fromJson(event.toJson());
      expect(restored.verify(), isTrue);
    });
  });

  group('generateSubId', () {
    test('generates 16-char hex string', () {
      final id = generateSubId();
      expect(id.length, equals(16));
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(id), isTrue);
    });

    test('each call returns a different ID', () {
      final ids = List.generate(20, (_) => generateSubId()).toSet();
      expect(ids.length, equals(20));
    });
  });
}
