import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// NIP-44 inspired E2E encryption using X25519 ECDH + AES-256-GCM + HKDF.
///
/// Wire format (base64 encoded):
///   nonce(12 bytes) || ciphertext || auth_tag(16 bytes)
///
/// Plaintext is padded to disguise message lengths:
///   padded_len = nextPadLength(plaintext.length)
///   [2 bytes big-endian plaintext length][plaintext][zero padding]
class MessageEncryption {
  static final _aesGcm = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final _x25519 = X25519();

  /// Encrypts [plaintext] for [recipientPublicKeyBytes] (32-byte X25519 pubkey).
  ///
  /// Returns base64-encoded payload: nonce(12) || ciphertext || tag(16).
  /// Returns null if [senderKeyPair] is null.
  static Future<String?> encrypt(
    String plaintext, {
    required SimpleKeyPair? senderKeyPair,
    required Uint8List? recipientPublicKeyBytes,
  }) async {
    if (senderKeyPair == null || recipientPublicKeyBytes == null) return null;

    try {
      final remotePublicKey =
          SimplePublicKey(recipientPublicKeyBytes, type: KeyPairType.x25519);
      final sharedSecretKey = await _x25519.sharedSecretKey(
        keyPair: senderKeyPair,
        remotePublicKey: remotePublicKey,
      );
      final sharedBytes = await sharedSecretKey.extractBytes();

      // Per-message AES key derived from shared secret
      final aesKey = await _hkdf.deriveKey(
        secretKey: SecretKey(sharedBytes),
        nonce: [],
        info: utf8.encode('nexus-msg-v1'),
      );

      // Pad plaintext to disguise length
      final paddedPlaintext = _pad(utf8.encode(plaintext));

      // 12-byte random nonce
      final nonce = _randomBytes(12);

      final secretBox = await _aesGcm.encrypt(
        paddedPlaintext,
        secretKey: aesKey,
        nonce: nonce,
      );

      // nonce(12) || ciphertext || tag(16)
      final payload = Uint8List(
          12 + secretBox.cipherText.length + secretBox.mac.bytes.length);
      payload.setRange(0, 12, nonce);
      payload.setRange(12, 12 + secretBox.cipherText.length, secretBox.cipherText);
      payload.setRange(12 + secretBox.cipherText.length, payload.length,
          secretBox.mac.bytes);

      return base64.encode(payload);
    } catch (e) {
      return null;
    }
  }

  /// Decrypts [encryptedBase64] from [senderPublicKeyBytes] (32-byte X25519 pubkey).
  ///
  /// Returns the plaintext string, or null if decryption fails.
  static Future<String?> decrypt(
    String encryptedBase64, {
    required SimpleKeyPair? recipientKeyPair,
    required Uint8List? senderPublicKeyBytes,
  }) async {
    if (recipientKeyPair == null || senderPublicKeyBytes == null) return null;

    try {
      final payload = base64.decode(encryptedBase64);
      if (payload.length < 12 + 16) return null; // too short

      final nonce = payload.sublist(0, 12);
      final cipherText = payload.sublist(12, payload.length - 16);
      final mac = payload.sublist(payload.length - 16);

      final remotePublicKey =
          SimplePublicKey(senderPublicKeyBytes, type: KeyPairType.x25519);
      final sharedSecretKey = await _x25519.sharedSecretKey(
        keyPair: recipientKeyPair,
        remotePublicKey: remotePublicKey,
      );
      final sharedBytes = await sharedSecretKey.extractBytes();

      final aesKey = await _hkdf.deriveKey(
        secretKey: SecretKey(sharedBytes),
        nonce: [],
        info: utf8.encode('nexus-msg-v1'),
      );

      final secretBox = SecretBox(
        cipherText,
        nonce: nonce,
        mac: Mac(mac),
      );

      final paddedPlaintext =
          await _aesGcm.decrypt(secretBox, secretKey: aesKey);
      return _unpad(paddedPlaintext);
    } catch (_) {
      return null; // wrong key or corrupted data
    }
  }

  // ── Padding ──────────────────────────────────────────────────────────────

  /// Pads [data] with a 2-byte length prefix and zero-padding to the next
  /// NIP-44 bucket length to hide message sizes.
  static List<int> _pad(List<int> data) {
    final len = data.length;
    final padLen = _nextPadLength(len);
    final result = List<int>.filled(2 + padLen, 0);
    result[0] = (len >> 8) & 0xFF;
    result[1] = len & 0xFF;
    result.setRange(2, 2 + len, data);
    return result;
  }

  /// Unpads data padded by [_pad].
  static String _unpad(List<int> data) {
    if (data.length < 2) throw FormatException('Padded data too short');
    final len = (data[0] << 8) | data[1];
    if (len > data.length - 2) throw FormatException('Invalid pad length');
    return utf8.decode(data.sublist(2, 2 + len));
  }

  /// Returns the next NIP-44 bucket size for [msgLen]:
  /// buckets: 32, 64, 96, … 256, 320, 384, … 512, 640, … in a stepped scheme.
  static int _nextPadLength(int msgLen) {
    if (msgLen <= 0) return 32;
    if (msgLen <= 32) return 32;
    // NIP-44 scheme: find next power of 2 after halving
    final step = pow(2, (log(msgLen - 1) / ln2).floor()) ~/ 8;
    final steppedLen =
        (((msgLen - 1) ~/ step) + 1) * step.clamp(32, 65536).toInt();
    return steppedLen.clamp(32, 65536);
  }

  static Uint8List _randomBytes(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rng.nextInt(256)));
  }
}
