import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// AES-256-GCM encryption helper for the local POD database.
///
/// Encrypted format: base64url( nonce(12) || ciphertext || mac(16) )
class PodEncryption {
  PodEncryption._();

  static final _aesGcm = AesGcm.with256bits();

  /// Encrypts [plaintext] with the 32-byte [keyBytes].
  /// Returns a base64url-encoded blob: nonce || ciphertext || mac.
  static Future<String> encrypt(String plaintext, Uint8List keyBytes) async {
    final sk = SecretKey(keyBytes);
    final nonce = _aesGcm.newNonce();
    final box = await _aesGcm.encrypt(
      utf8.encode(plaintext),
      secretKey: sk,
      nonce: nonce,
    );
    final blob = Uint8List(nonce.length + box.cipherText.length + box.mac.bytes.length)
      ..setAll(0, nonce)
      ..setAll(nonce.length, box.cipherText)
      ..setAll(nonce.length + box.cipherText.length, box.mac.bytes);
    return base64Url.encode(blob);
  }

  /// Decrypts a blob produced by [encrypt].
  static Future<String> decrypt(String blob, Uint8List keyBytes) async {
    final bytes = base64Url.decode(blob);
    const nonceLen = 12;
    const macLen = 16;
    final nonce = bytes.sublist(0, nonceLen);
    final mac = Mac(bytes.sublist(bytes.length - macLen));
    final cipherText = bytes.sublist(nonceLen, bytes.length - macLen);
    final sk = SecretKey(keyBytes);
    final plain = await _aesGcm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: sk,
    );
    return utf8.decode(plain);
  }
}
