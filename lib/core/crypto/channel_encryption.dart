import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Symmetric AES-256-GCM encryption for private group channel messages.
///
/// All members of a private channel share the same [channelSecret] (a 64-char
/// hex string generated at channel creation). Each message uses a fresh 12-byte
/// random nonce. The AES key is derived from the secret and channelId via HKDF
/// so the key is unique per channel even if the same secret were ever reused.
///
/// Wire format (base64): nonce(12 bytes) || ciphertext || auth_tag(16 bytes)
class ChannelEncryption {
  static final _aesGcm = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  /// Encrypts [plaintext] with the channel's shared key.
  ///
  /// Returns null on error.
  static Future<String?> encrypt(
    String plaintext,
    String channelSecret,
    String channelId,
  ) async {
    try {
      final key = await _deriveKey(channelSecret, channelId);
      final nonce = _randomBytes(12);
      final secretBox = await _aesGcm.encrypt(
        utf8.encode(plaintext),
        secretKey: key,
        nonce: nonce,
      );
      final payload =
          Uint8List(12 + secretBox.cipherText.length + secretBox.mac.bytes.length);
      payload.setRange(0, 12, nonce);
      payload.setRange(12, 12 + secretBox.cipherText.length, secretBox.cipherText);
      payload.setRange(
          12 + secretBox.cipherText.length, payload.length, secretBox.mac.bytes);
      return base64.encode(payload);
    } catch (_) {
      return null;
    }
  }

  /// Decrypts [encryptedBase64] using the channel's shared key.
  ///
  /// Returns null if decryption fails (wrong key, tampered data, etc.).
  static Future<String?> decrypt(
    String encryptedBase64,
    String channelSecret,
    String channelId,
  ) async {
    try {
      final key = await _deriveKey(channelSecret, channelId);
      final payload = base64.decode(encryptedBase64);
      if (payload.length < 28) return null; // 12 nonce + 16 tag minimum
      final nonce = payload.sublist(0, 12);
      final cipherText = payload.sublist(12, payload.length - 16);
      final mac = payload.sublist(payload.length - 16);
      final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(mac));
      final plainBytes = await _aesGcm.decrypt(secretBox, secretKey: key);
      return utf8.decode(plainBytes);
    } catch (_) {
      return null;
    }
  }

  // ── Private ────────────────────────────────────────────────────────────────

  static Future<SecretKey> _deriveKey(
      String channelSecret, String channelId) async {
    return _hkdf.deriveKey(
      secretKey: SecretKey(utf8.encode(channelSecret)),
      nonce: [],
      info: utf8.encode('nexus-channel-v1:$channelId'),
    );
  }

  static Uint8List _randomBytes(int n) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));
  }
}
