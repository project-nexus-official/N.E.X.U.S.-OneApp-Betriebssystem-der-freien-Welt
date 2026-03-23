import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/core/transport/nexus_message.dart';

void main() {
  group('NexusMessage', () {
    test('create() generates a unique UUID each time', () {
      final a = NexusMessage.create(fromDid: 'did:key:zA', body: 'hello');
      final b = NexusMessage.create(fromDid: 'did:key:zB', body: 'hello');
      expect(a.id, isNot(equals(b.id)));
      // UUID v4 format
      expect(
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
            .hasMatch(a.id),
        isTrue,
      );
    });

    test('defaults: toDid=broadcast, ttl=12h, hopCount=0', () {
      final msg = NexusMessage.create(fromDid: 'did:key:zA', body: 'hi');
      expect(msg.toDid, NexusMessage.broadcastDid);
      expect(msg.isBroadcast, isTrue);
      expect(msg.ttlHours, 12);
      expect(msg.hopCount, 0);
      expect(msg.signature, isNull);
    });

    test('isExpired returns false for fresh message', () {
      final msg = NexusMessage.create(fromDid: 'did:key:zA', body: 'fresh');
      expect(msg.isExpired, isFalse);
    });

    test('isExpired returns true for old message', () {
      final old = NexusMessage(
        id: 'test-id',
        fromDid: 'did:key:zA',
        toDid: NexusMessage.broadcastDid,
        type: NexusMessageType.text,
        body: 'old',
        timestamp: DateTime.now().toUtc().subtract(const Duration(hours: 13)),
        ttlHours: 12,
      );
      expect(old.isExpired, isTrue);
    });

    test('JSON round-trip preserves all fields', () {
      final msg = NexusMessage(
        id: 'aabb-ccdd-eeff-0011-22334455',
        fromDid: 'did:key:zAlice',
        toDid: 'did:key:zBob',
        type: NexusMessageType.text,
        channel: '#nexus',
        body: 'Hallo Welt',
        timestamp: DateTime.utc(2026, 3, 23, 12, 0, 0),
        ttlHours: 6,
        hopCount: 2,
        signature: 'sigABC',
      );

      final json = msg.toJson();
      final restored = NexusMessage.fromJson(json);

      expect(restored.id, msg.id);
      expect(restored.fromDid, msg.fromDid);
      expect(restored.toDid, msg.toDid);
      expect(restored.type, msg.type);
      expect(restored.channel, msg.channel);
      expect(restored.body, msg.body);
      expect(restored.timestamp, msg.timestamp);
      expect(restored.ttlHours, msg.ttlHours);
      expect(restored.hopCount, msg.hopCount);
      expect(restored.signature, msg.signature);
    });

    test('wire bytes round-trip (ZLib compress/decompress)', () {
      final msg = NexusMessage.create(
        fromDid: 'did:key:zAlice',
        body: 'Test-Nachricht 🌍',
      );

      final wire = msg.toWireBytes();
      expect(wire, isA<Uint8List>());

      final restored = NexusMessage.fromWireBytes(wire);
      expect(restored.id, msg.id);
      expect(restored.body, msg.body);
      expect(restored.fromDid, msg.fromDid);
    });

    test('wire bytes are smaller than raw JSON for repeated content', () {
      final longBody = 'A' * 500;
      final msg = NexusMessage.create(fromDid: 'did:key:zA', body: longBody);

      final wire = msg.toWireBytes();
      final rawJson = msg.toJson().toString().length;

      // ZLib should compress repetitive content significantly
      expect(wire.length, lessThan(rawJson));
    });

    test('withSignature() creates new instance with signature set', () {
      final msg = NexusMessage.create(fromDid: 'did:key:zA', body: 'hi');
      final signed = msg.withSignature('base64sigXYZ');

      expect(signed.id, msg.id);
      expect(signed.signature, 'base64sigXYZ');
      // Original must be unchanged
      expect(msg.signature, isNull);
    });

    test('withIncrementedHopCount() increments by 1', () {
      final msg = NexusMessage.create(fromDid: 'did:key:zA', body: 'hi');
      expect(msg.hopCount, 0);
      final forwarded = msg.withIncrementedHopCount();
      expect(forwarded.hopCount, 1);
      final forwarded2 = forwarded.withIncrementedHopCount();
      expect(forwarded2.hopCount, 2);
    });

    test('toSignableBytes() excludes sig field', () {
      final msg = NexusMessage.create(fromDid: 'did:key:zA', body: 'sign me');
      final signed = msg.withSignature('mysig');

      final signable = signed.toSignableBytes();
      final str = String.fromCharCodes(signable);

      expect(str.contains('mysig'), isFalse);
      expect(str.contains(msg.id), isTrue);
    });

    test('equality is based on id only', () {
      final msg = NexusMessage.create(fromDid: 'did:key:zA', body: 'hi');
      final copy = msg.withSignature('whatever');
      expect(msg, equals(copy)); // same id
    });

    test('channel message type survives round-trip', () {
      final msg = NexusMessage.create(
        fromDid: 'did:key:zA',
        type: NexusMessageType.channel,
        channel: '#mesh',
        body: 'hello #mesh',
      );
      final restored = NexusMessage.fromJson(msg.toJson());
      expect(restored.type, NexusMessageType.channel);
      expect(restored.channel, '#mesh');
    });
  });
}
