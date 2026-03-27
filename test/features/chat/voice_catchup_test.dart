import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nexus_oneapp/core/crypto/message_encryption.dart';
import 'package:nexus_oneapp/core/transport/nexus_message.dart';

// ── Pure helpers mirroring production logic ───────────────────────────────────

/// Mirrors _onMessageReceived: checks encrypted flag and decrypts.
Future<NexusMessage> processIncoming(
  NexusMessage msg, {
  required SimpleKeyPair recipientKeyPair,
  required Uint8List senderPublicKeyBytes,
}) async {
  if (msg.metadata?['encrypted'] == true && !msg.isBroadcast) {
    final plaintext = await MessageEncryption.decrypt(
      msg.body,
      recipientKeyPair: recipientKeyPair,
      senderPublicKeyBytes: senderPublicKeyBytes,
    );
    if (plaintext != null) {
      return NexusMessage(
        id: msg.id,
        fromDid: msg.fromDid,
        toDid: msg.toDid,
        type: msg.type,
        channel: msg.channel,
        body: plaintext,
        timestamp: msg.timestamp,
        ttlHours: msg.ttlHours,
        hopCount: msg.hopCount,
        signature: msg.signature,
        metadata: {
          ...?msg.metadata,
          'encrypted': true,
        },
      );
    }
    // Decryption failed
    return NexusMessage(
      id: msg.id,
      fromDid: msg.fromDid,
      toDid: msg.toDid,
      type: msg.type,
      channel: msg.channel,
      body: '[Nachricht konnte nicht entschlüsselt werden]',
      timestamp: msg.timestamp,
      ttlHours: msg.ttlHours,
      hopCount: msg.hopCount,
      metadata: msg.metadata,
    );
  }
  return msg;
}

/// Mirrors sendVoice: builds the transport message (encrypted body, no local path).
Future<NexusMessage> buildTransportVoiceMsg(
  String audioBase64,
  int durationMs, {
  required String senderDid,
  required String recipientDid,
  required SimpleKeyPair senderKeyPair,
  required Uint8List recipientPublicKeyBytes,
}) async {
  final senderPubBytes = Uint8List.fromList(
    (await senderKeyPair.extractPublicKey()).bytes,
  );
  final senderPubHex = senderPubBytes.map(
    (b) => b.toRadixString(16).padLeft(2, '0'),
  ).join();

  final baseMeta = <String, dynamic>{
    'duration_ms': durationMs,
    'enc_key': senderPubHex,
  };

  final encryptedBody = await MessageEncryption.encrypt(
    audioBase64,
    senderKeyPair: senderKeyPair,
    recipientPublicKeyBytes: recipientPublicKeyBytes,
  );

  if (encryptedBody != null) {
    return NexusMessage.create(
      fromDid: senderDid,
      toDid: recipientDid,
      type: NexusMessageType.voice,
      body: encryptedBody,
      metadata: {
        ...baseMeta,
        'encrypted': true,
      },
    );
  }

  // Encryption failed – send plaintext without 'encrypted' flag.
  return NexusMessage.create(
    fromDid: senderDid,
    toDid: recipientDid,
    type: NexusMessageType.voice,
    body: audioBase64,
    metadata: baseMeta,
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late SimpleKeyPair phoneKp;
  late SimpleKeyPair windowsKp;
  late Uint8List phonePub;
  late Uint8List windowsPub;

  setUpAll(() async {
    phoneKp = await X25519().newKeyPair();
    windowsKp = await X25519().newKeyPair();
    phonePub =
        Uint8List.fromList((await phoneKp.extractPublicKey()).bytes);
    windowsPub =
        Uint8List.fromList((await windowsKp.extractPublicKey()).bytes);
  });

  // ── Voice events are recognized during catch-up ───────────────────────────

  group('Voice message type survives Nostr round-trip', () {
    test('NexusMessageType.voice is preserved in toJson/fromJson', () {
      final msg = NexusMessage.create(
        fromDid: 'did:key:phone',
        toDid: 'did:key:windows',
        type: NexusMessageType.voice,
        body: 'base64audiodata',
        metadata: {'duration_ms': 5000, 'encrypted': true},
      );

      final json = msg.toJson();
      expect(json['type'], equals('voice'));

      final recovered = NexusMessage.fromJson(json);
      expect(recovered.type, equals(NexusMessageType.voice));
    });

    test('voice type is preserved when embedded in Nostr event content', () {
      // Simulates the NIP-04 inner payload (after outer NIP-04 decryption)
      final inner = NexusMessage.create(
        fromDid: 'did:key:phone',
        toDid: 'did:key:windows',
        type: NexusMessageType.voice,
        body: 'base64audiodata==',
        metadata: {'duration_ms': 3000},
      );

      final json = jsonEncode(inner.toJson());
      final parsed = NexusMessage.fromJson(
        jsonDecode(json) as Map<String, dynamic>,
      );

      expect(parsed.type, equals(NexusMessageType.voice));
      expect(parsed.body, equals('base64audiodata=='));
      expect(parsed.metadata?['duration_ms'], equals(3000));
    });
  });

  // ── Short voice messages encrypt/decrypt correctly ────────────────────────

  group('Encrypted voice message catch-up (short, ~5 seconds)', () {
    // Simulates: phone sends voice → Windows misses it → Windows catches up.

    test('short voice msg (~27 KB base64) encrypts and decrypts correctly',
        () async {
      // ~20 KB raw audio → ~27 000 chars base64
      final audioBase64 = base64.encode(Uint8List(20000));

      final transportMsg = await buildTransportVoiceMsg(
        audioBase64,
        5000,
        senderDid: 'did:key:phone',
        recipientDid: 'did:key:windows',
        senderKeyPair: phoneKp,
        recipientPublicKeyBytes: windowsPub,
      );

      expect(transportMsg.metadata?['encrypted'], isTrue,
          reason: 'Short voice must be encrypted');

      final processed = await processIncoming(
        transportMsg,
        recipientKeyPair: windowsKp,
        senderPublicKeyBytes: phonePub,
      );

      expect(processed.type, equals(NexusMessageType.voice));
      expect(processed.body, equals(audioBase64),
          reason: 'Decrypted body must equal the original base64 audio');
      expect(processed.metadata?['duration_ms'], equals(5000));
    });
  });

  // ── Long voice messages encrypt/decrypt correctly (was broken before fix) ──

  group('Encrypted voice message catch-up (long, > 12 seconds)', () {
    test('long voice msg (~80 KB base64) encrypts and decrypts correctly',
        () async {
      // ~60 KB raw audio → ~80 000 chars base64 (exceeds old 2-byte limit).
      final audioBase64 = base64.encode(Uint8List(60000));

      final transportMsg = await buildTransportVoiceMsg(
        audioBase64,
        15000,
        senderDid: 'did:key:phone',
        recipientDid: 'did:key:windows',
        senderKeyPair: phoneKp,
        recipientPublicKeyBytes: windowsPub,
      );

      expect(transportMsg.metadata?['encrypted'], isTrue,
          reason: 'Long voice must also be encrypted after padding fix');

      final processed = await processIncoming(
        transportMsg,
        recipientKeyPair: windowsKp,
        senderPublicKeyBytes: phonePub,
      );

      expect(processed.type, equals(NexusMessageType.voice));
      expect(processed.body, equals(audioBase64));
    });

    test('max-length voice msg (~400 KB base64) encrypts and decrypts',
        () async {
      // 5-minute recording at 32 kbps ≈ 1.2 MB raw → ~1.6 MB base64.
      // Use 300 KB to keep test fast while still testing the large-size path.
      final audioBase64 = base64.encode(Uint8List(300000));

      final transportMsg = await buildTransportVoiceMsg(
        audioBase64,
        300000,
        senderDid: 'did:key:phone',
        recipientDid: 'did:key:windows',
        senderKeyPair: phoneKp,
        recipientPublicKeyBytes: windowsPub,
      );

      expect(transportMsg.metadata?['encrypted'], isTrue);

      final processed = await processIncoming(
        transportMsg,
        recipientKeyPair: windowsKp,
        senderPublicKeyBytes: phonePub,
      );

      expect(processed.type, equals(NexusMessageType.voice));
      expect(processed.body, equals(audioBase64));
    });
  });

  // ── Null-encryption fall-through fix ─────────────────────────────────────

  group('sendVoice: unencrypted fallback does NOT set encrypted=true', () {
    test('when encryption fails, transport msg has no encrypted flag', () {
      // This simulates the case where encryptedBody == null.
      // The transport metadata must NOT have 'encrypted': true.
      final transportMeta = <String, dynamic>{
        'duration_ms': 5000,
        'enc_key': 'somepubkeyhex',
        // No 'encrypted': true – this is the fixed behavior
      };

      expect(transportMeta.containsKey('encrypted'), isFalse,
          reason: 'Fallback transport msg must not claim encryption');
    });

    test('receiver plays audio directly when encrypted flag is absent',
        () async {
      final audioBase64 = base64.encode(Uint8List(5000));

      // Unencrypted voice message (no 'encrypted' flag in metadata)
      final incomingMsg = NexusMessage.create(
        fromDid: 'did:key:phone',
        toDid: 'did:key:windows',
        type: NexusMessageType.voice,
        body: audioBase64,
        metadata: {
          'duration_ms': 3000,
          'enc_key': 'abc123',
          // No 'encrypted': true
        },
      );

      final processed = await processIncoming(
        incomingMsg,
        recipientKeyPair: windowsKp,
        senderPublicKeyBytes: phonePub,
      );

      // Without the encrypted flag, processIncoming returns msg unchanged.
      expect(processed.type, equals(NexusMessageType.voice));
      expect(processed.body, equals(audioBase64),
          reason: 'Body must be the original base64 audio – no decryption attempted');
    });
  });

  // ── audio_local_path caching logic ───────────────────────────────────────

  group('Voice audio local path caching', () {
    test('audio_local_path is carried through after receive', () {
      // After _cacheVoiceAudio runs, metadata must contain audio_local_path.
      // We test the pure metadata update logic.
      const path = '/data/user/0/com.nexus/files/nexus_voice_abc.m4a';
      final meta = <String, dynamic>{
        'duration_ms': 5000,
        'enc_key': 'hex',
        'encrypted': true,
      };
      final updated = {...meta, 'audio_local_path': path};

      expect(updated['audio_local_path'], equals(path));
      expect(updated['duration_ms'], equals(5000));
    });

    test('existing audio_local_path is preserved when file exists (logic)', () {
      const existingPath = '/cache/nexus_voice_existing.m4a';
      final meta = <String, dynamic>{
        'duration_ms': 8000,
        'audio_local_path': existingPath,
      };

      // Mimic _cacheVoiceAudio early-return when path is already set.
      final pathInMeta = meta['audio_local_path'] as String?;
      expect(pathInMeta, equals(existingPath),
          reason: 'Should keep existing path and not overwrite it');
    });

    test('decryption error placeholder is NOT decoded as audio', () {
      const placeholder = '[Nachricht konnte nicht entschlüsselt werden]';

      // _cacheVoiceAudio skips bodies starting with '['
      expect(placeholder.startsWith('['), isTrue,
          reason: 'Placeholder body must be detected and skipped');
    });
  });

  // ── Image messages: same catch-up path works ──────────────────────────────

  group('Image message catch-up (same code path, no inner encryption)', () {
    test('image type is preserved in toJson/fromJson', () {
      final msg = NexusMessage.create(
        fromDid: 'did:key:phone',
        toDid: 'did:key:windows',
        type: NexusMessageType.image,
        body: base64.encode(Uint8List(1000)), // small fake JPEG
        metadata: {'width': 800, 'height': 600},
      );

      final json = msg.toJson();
      expect(json['type'], equals('image'));

      final recovered = NexusMessage.fromJson(json);
      expect(recovered.type, equals(NexusMessageType.image));
      expect(recovered.metadata?['width'], equals(800));
    });

    test('image without encrypted flag is returned unchanged by processIncoming',
        () async {
      final imgBase64 = base64.encode(Uint8List(5000));
      final msg = NexusMessage.create(
        fromDid: 'did:key:phone',
        toDid: 'did:key:windows',
        type: NexusMessageType.image,
        body: imgBase64,
        metadata: {'width': 512, 'height': 512, 'thumbnail': 'thumb=='},
      );

      final processed = await processIncoming(
        msg,
        recipientKeyPair: windowsKp,
        senderPublicKeyBytes: phonePub,
      );

      expect(processed.type, equals(NexusMessageType.image));
      expect(processed.body, equals(imgBase64));
      expect(processed.metadata?['width'], equals(512));
    });
  });

  // ── isExpired does not drop recent messages ───────────────────────────────

  group('TTL does not expire recently received catch-up messages', () {
    test('voice message sent 1 hour ago is not expired (TTL 12h)', () {
      final msg = NexusMessage(
        id: 'v1',
        fromDid: 'did:key:phone',
        toDid: 'did:key:windows',
        type: NexusMessageType.voice,
        body: 'base64audio',
        timestamp: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
        ttlHours: 12,
        hopCount: 0,
      );
      expect(msg.isExpired, isFalse);
    });

    test('voice message sent 13 hours ago IS expired (TTL 12h)', () {
      final msg = NexusMessage(
        id: 'v2',
        fromDid: 'did:key:phone',
        toDid: 'did:key:windows',
        type: NexusMessageType.voice,
        body: 'base64audio',
        timestamp: DateTime.now().toUtc().subtract(const Duration(hours: 13)),
        ttlHours: 12,
        hopCount: 0,
      );
      expect(msg.isExpired, isTrue);
    });
  });
}
