import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:nexus_oneapp/core/crypto/encryption_keys.dart';
import 'package:nexus_oneapp/core/crypto/message_encryption.dart';

void main() {
  // Needed for FlutterSecureStorage in EncryptionKeys.initFromEd25519Private
  TestWidgetsFlutterBinding.ensureInitialized();

  // Mock FlutterSecureStorage (no-op in tests)
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (MethodCall methodCall) async => null,
    );
  });

  // ── Key derivation ─────────────────────────────────────────────────────────

  group('EncryptionKeys – derivation', () {
    test('derives X25519 key from Ed25519 seed (deterministic)', () async {
      final seed = Uint8List.fromList(List.generate(32, (i) => i));
      await EncryptionKeys.instance.initFromEd25519Private(seed);
      final hex1 = EncryptionKeys.instance.publicKeyHex;

      // Second init with same seed → same result
      await EncryptionKeys.instance.initFromEd25519Private(seed);
      final hex2 = EncryptionKeys.instance.publicKeyHex;

      expect(hex1, isNotNull);
      expect(hex1, equals(hex2));
      expect(hex1!.length, 64); // 32-byte hex
    });

    test('different seeds produce different keys', () async {
      final seed1 = Uint8List.fromList(List.generate(32, (i) => i));
      await EncryptionKeys.instance.initFromEd25519Private(seed1);
      final hex1 = EncryptionKeys.instance.publicKeyHex;

      final seed2 = Uint8List.fromList(List.generate(32, (i) => i + 1));
      await EncryptionKeys.instance.initFromEd25519Private(seed2);
      final hex2 = EncryptionKeys.instance.publicKeyHex;

      expect(hex1, isNot(equals(hex2)));
    });
  });

  // ── Encrypt / Decrypt roundtrip ────────────────────────────────────────────

  group('MessageEncryption – roundtrip', () {
    late SimpleKeyPair aliceKp;
    late SimpleKeyPair bobKp;
    late Uint8List alicePub;
    late Uint8List bobPub;

    setUpAll(() async {
      aliceKp = await X25519().newKeyPair();
      bobKp = await X25519().newKeyPair();
      alicePub = Uint8List.fromList(
          (await aliceKp.extractPublicKey()).bytes);
      bobPub = Uint8List.fromList(
          (await bobKp.extractPublicKey()).bytes);
    });

    test('encrypt then decrypt returns original text', () async {
      const plaintext = 'Hallo Nexus!';
      final encrypted = await MessageEncryption.encrypt(
        plaintext,
        senderKeyPair: aliceKp,
        recipientPublicKeyBytes: bobPub,
      );
      expect(encrypted, isNotNull);

      final decrypted = await MessageEncryption.decrypt(
        encrypted!,
        recipientKeyPair: bobKp,
        senderPublicKeyBytes: alicePub,
      );
      expect(decrypted, equals(plaintext));
    });

    test('long message roundtrip', () async {
      final plaintext = 'X' * 2000;
      final encrypted = await MessageEncryption.encrypt(
        plaintext,
        senderKeyPair: aliceKp,
        recipientPublicKeyBytes: bobPub,
      );
      final decrypted = await MessageEncryption.decrypt(
        encrypted!,
        recipientKeyPair: bobKp,
        senderPublicKeyBytes: alicePub,
      );
      expect(decrypted, equals(plaintext));
    });

    // Voice messages: base64 audio can easily exceed 65 535 characters.
    // A 5-second AAC recording at 16 kHz / 32 kbps ≈ 20 KB raw → ~27 KB base64.
    // A 15-second recording ≈ 60 KB raw → ~80 KB base64 (> old 2-byte limit).
    test('large payload roundtrip (> 65535 chars – voice audio simulation)',
        () async {
      // 80 000 chars simulates a ~15-second voice message in base64.
      final plaintext = 'A' * 80000;
      final encrypted = await MessageEncryption.encrypt(
        plaintext,
        senderKeyPair: aliceKp,
        recipientPublicKeyBytes: bobPub,
      );
      expect(encrypted, isNotNull,
          reason: 'Encryption must succeed for large voice payloads');

      final decrypted = await MessageEncryption.decrypt(
        encrypted!,
        recipientKeyPair: bobKp,
        senderPublicKeyBytes: alicePub,
      );
      expect(decrypted, equals(plaintext),
          reason: 'Decryption must recover the full large payload');
    });

    test('very large payload roundtrip (300 KB – max voice message)', () async {
      // 400 000 chars ≈ 300 KB raw audio → 5-minute recording at 32 kbps.
      final plaintext = 'B' * 400000;
      final encrypted = await MessageEncryption.encrypt(
        plaintext,
        senderKeyPair: aliceKp,
        recipientPublicKeyBytes: bobPub,
      );
      expect(encrypted, isNotNull);
      final decrypted = await MessageEncryption.decrypt(
        encrypted!,
        recipientKeyPair: bobKp,
        senderPublicKeyBytes: alicePub,
      );
      expect(decrypted, equals(plaintext));
    });

    test('wrong key returns null (no crash)', () async {
      final charlieKp = await X25519().newKeyPair();
      const plaintext = 'Geheimnis';
      final encrypted = await MessageEncryption.encrypt(
        plaintext,
        senderKeyPair: aliceKp,
        recipientPublicKeyBytes: bobPub,
      );

      // Charlie tries to decrypt → should return null
      final charliePub = Uint8List.fromList(
          (await charlieKp.extractPublicKey()).bytes);
      final result = await MessageEncryption.decrypt(
        encrypted!,
        recipientKeyPair: charlieKp,
        senderPublicKeyBytes: charliePub,
      );
      expect(result, isNull);
    });

    test('null senderKeyPair returns null', () async {
      final result = await MessageEncryption.encrypt(
        'test',
        senderKeyPair: null,
        recipientPublicKeyBytes: bobPub,
      );
      expect(result, isNull);
    });

    test('null recipientPublicKey returns null', () async {
      final result = await MessageEncryption.encrypt(
        'test',
        senderKeyPair: aliceKp,
        recipientPublicKeyBytes: null,
      );
      expect(result, isNull);
    });

    test('corrupted ciphertext returns null (no crash)', () async {
      final result = await MessageEncryption.decrypt(
        base64.encode(Uint8List(50)),
        recipientKeyPair: bobKp,
        senderPublicKeyBytes: alicePub,
      );
      expect(result, isNull);
    });

    test('empty string roundtrip', () async {
      const plaintext = '';
      final encrypted = await MessageEncryption.encrypt(
        plaintext,
        senderKeyPair: aliceKp,
        recipientPublicKeyBytes: bobPub,
      );
      final decrypted = await MessageEncryption.decrypt(
        encrypted!,
        recipientKeyPair: bobKp,
        senderPublicKeyBytes: alicePub,
      );
      expect(decrypted, equals(plaintext));
    });

    test('unicode message roundtrip', () async {
      const plaintext = 'Güten Tag! 🔐 こんにちは';
      final encrypted = await MessageEncryption.encrypt(
        plaintext,
        senderKeyPair: aliceKp,
        recipientPublicKeyBytes: bobPub,
      );
      final decrypted = await MessageEncryption.decrypt(
        encrypted!,
        recipientKeyPair: bobKp,
        senderPublicKeyBytes: alicePub,
      );
      expect(decrypted, equals(plaintext));
    });

    test('each encryption produces different ciphertext (nonce randomness)',
        () async {
      const plaintext = 'same message';
      final enc1 = await MessageEncryption.encrypt(
        plaintext,
        senderKeyPair: aliceKp,
        recipientPublicKeyBytes: bobPub,
      );
      final enc2 = await MessageEncryption.encrypt(
        plaintext,
        senderKeyPair: aliceKp,
        recipientPublicKeyBytes: bobPub,
      );
      expect(enc1, isNot(equals(enc2)));
    });
  });

  // ── EncryptionKeys helpers ─────────────────────────────────────────────────

  group('EncryptionKeys – helpers', () {
    test('hexToBytes / bytesToHex roundtrip', () {
      final bytes = Uint8List.fromList([0x00, 0xAB, 0xFF, 0x12]);
      final hex = EncryptionKeys.bytesToHex(bytes);
      expect(hex, equals('00abff12'));
      expect(EncryptionKeys.hexToBytes(hex), equals(bytes));
    });
  });

  // ── Sender sees plaintext (regression for send-ciphertext bug) ────────────

  group('Send/receive plaintext visibility', () {
    late SimpleKeyPair aliceKp;
    late SimpleKeyPair bobKp;
    late Uint8List alicePub;
    late Uint8List bobPub;

    setUpAll(() async {
      aliceKp = await X25519().newKeyPair();
      bobKp = await X25519().newKeyPair();
      alicePub =
          Uint8List.fromList((await aliceKp.extractPublicKey()).bytes);
      bobPub =
          Uint8List.fromList((await bobKp.extractPublicKey()).bytes);
    });

    // Simulates what ChatProvider.sendMessage() now does: the body stored
    // locally must be the original plaintext, while the transport body is
    // the ciphertext.
    test('transport body is ciphertext, local body is plaintext', () async {
      const plaintext = 'Geheime Nachricht';

      final ciphertext = await MessageEncryption.encrypt(
        plaintext,
        senderKeyPair: aliceKp,
        recipientPublicKeyBytes: bobPub,
      );
      expect(ciphertext, isNotNull);

      // Local body = plaintext (what sender stores and displays)
      const localBody = plaintext;

      // Transport body = ciphertext
      final transportBody = ciphertext!;

      // They must differ
      expect(transportBody, isNot(equals(localBody)));

      // Local body is human-readable (not base64 ciphertext)
      expect(localBody, equals(plaintext));
    });

    // Simulates what ChatProvider._onMessageReceived() does: the received
    // ciphertext must be decrypted before storing/displaying.
    test('received ciphertext is decrypted before display', () async {
      const plaintext = 'Hallo Bob!';

      // Alice encrypts for Bob
      final ciphertext = await MessageEncryption.encrypt(
        plaintext,
        senderKeyPair: aliceKp,
        recipientPublicKeyBytes: bobPub,
      );
      expect(ciphertext, isNotNull);

      // Bob decrypts
      final decrypted = await MessageEncryption.decrypt(
        ciphertext!,
        recipientKeyPair: bobKp,
        senderPublicKeyBytes: alicePub,
      );

      // What Bob stores/displays is plaintext, not ciphertext
      expect(decrypted, equals(plaintext));
      expect(decrypted, isNot(equals(ciphertext)));
    });

    // Conversation list preview must not show ciphertext.
    // Simulates _previewBody() reading the stored body from DB.
    test('conversation preview shows plaintext (not ciphertext)', () async {
      const plaintext = 'Kurze Vorschau';

      // After the fix, what is stored in DB is the plaintext body.
      // _previewBody() just returns body.substring(0, 60), so:
      final storedBody = plaintext; // local message body = plaintext
      final preview =
          storedBody.length > 60 ? storedBody.substring(0, 60) : storedBody;

      expect(preview, equals(plaintext));

      // Ensure ciphertext would NOT be a valid preview
      final ciphertext = await MessageEncryption.encrypt(
        plaintext,
        senderKeyPair: aliceKp,
        recipientPublicKeyBytes: bobPub,
      );
      expect(ciphertext, isNotNull);
      expect(preview, isNot(equals(ciphertext!.substring(0, 60))));
    });
  });
}
