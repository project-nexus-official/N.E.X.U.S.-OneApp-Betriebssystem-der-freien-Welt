import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/core/transport/nexus_message.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  // ── Reply metadata construction ────────────────────────────────────────────

  group('Reply metadata', () {
    test('reply_to fields are set from replyTo message', () {
      const plaintext = 'Original message text';
      final originalMsg = NexusMessage.create(
        fromDid: 'did:nexus:alice',
        toDid: 'did:nexus:bob',
        body: plaintext,
      );

      // Simulate what ChatProvider builds for reply metadata
      final replyMeta = {
        'reply_to_id': originalMsg.id,
        'reply_to_sender': 'Alice',
        'reply_to_preview':
            plaintext.substring(0, plaintext.length.clamp(0, 100)),
      };

      expect(replyMeta['reply_to_id'], equals(originalMsg.id));
      expect(replyMeta['reply_to_sender'], equals('Alice'));
      expect(replyMeta['reply_to_preview'], equals(plaintext));
    });

    test('image reply sets reply_to_image=true and preview=Foto', () {
      final imageMsg = NexusMessage.create(
        fromDid: 'did:nexus:alice',
        toDid: 'did:nexus:bob',
        body: 'base64imagedata',
        type: NexusMessageType.image,
      );

      final isImg = imageMsg.type == NexusMessageType.image;
      final replyMeta = {
        'reply_to_id': imageMsg.id,
        'reply_to_sender': 'Alice',
        'reply_to_preview': isImg ? 'Foto' : imageMsg.body,
        if (isImg) 'reply_to_image': true,
      };

      expect(replyMeta['reply_to_image'], isTrue);
      expect(replyMeta['reply_to_preview'], equals('Foto'));
    });

    test('preview is truncated to 100 chars', () {
      final longText = 'A' * 200;
      final preview = longText.substring(0, longText.length.clamp(0, 100));
      expect(preview.length, equals(100));
    });

    test('reply metadata survives NexusMessage serialization roundtrip', () {
      final msg = NexusMessage.create(
        fromDid: 'did:nexus:alice',
        toDid: 'did:nexus:bob',
        body: 'Reply text',
        metadata: {
          'reply_to_id': 'original-id-123',
          'reply_to_sender': 'Alice',
          'reply_to_preview': 'Original preview',
        },
      );

      final json = msg.toJson();
      final restored = NexusMessage.fromJson(json);

      expect(restored.metadata?['reply_to_id'], equals('original-id-123'));
      expect(restored.metadata?['reply_to_sender'], equals('Alice'));
      expect(restored.metadata?['reply_to_preview'], equals('Original preview'));
    });

    test('broadcast message can carry reply metadata', () {
      final broadcastReply = NexusMessage.create(
        fromDid: 'did:nexus:alice',
        toDid: NexusMessage.broadcastDid,
        body: 'Reply to broadcast',
        channel: '#mesh',
        metadata: {
          'reply_to_id': 'broadcast-msg-id',
          'reply_to_sender': 'Bob',
          'reply_to_preview': 'Original broadcast',
        },
      );

      expect(broadcastReply.isBroadcast, isTrue);
      expect(broadcastReply.metadata?['reply_to_id'], isNotNull);
    });

    test('message without reply has no reply_to_id', () {
      final plainMsg = NexusMessage.create(
        fromDid: 'did:nexus:alice',
        toDid: 'did:nexus:bob',
        body: 'No reply',
      );

      expect(plainMsg.metadata?['reply_to_id'], isNull);
    });

    test('hasReply check works via metadata', () {
      final withReply = NexusMessage.create(
        fromDid: 'did:nexus:alice',
        toDid: 'did:nexus:bob',
        body: 'Answer',
        metadata: {'reply_to_id': 'some-id'},
      );
      final withoutReply = NexusMessage.create(
        fromDid: 'did:nexus:alice',
        toDid: 'did:nexus:bob',
        body: 'Standalone',
      );

      expect(withReply.metadata?['reply_to_id'] != null, isTrue);
      expect(withoutReply.metadata?['reply_to_id'] != null, isFalse);
    });

    test('reply metadata is preserved alongside encryption metadata', () {
      final msg = NexusMessage.create(
        fromDid: 'did:nexus:alice',
        toDid: 'did:nexus:bob',
        body: 'Encrypted reply',
        metadata: {
          'encrypted': true,
          'enc_key': 'abcd1234',
          'reply_to_id': 'orig-id',
          'reply_to_sender': 'Bob',
          'reply_to_preview': 'Original',
        },
      );

      final restored = NexusMessage.fromJson(msg.toJson());
      expect(restored.metadata?['encrypted'], isTrue);
      expect(restored.metadata?['reply_to_id'], equals('orig-id'));
    });
  });
}
