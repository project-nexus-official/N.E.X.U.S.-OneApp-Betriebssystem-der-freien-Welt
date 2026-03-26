import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _keyX25519Pub = 'nexus_x25519_public_key';

/// Manages the local X25519 keypair used for message encryption.
///
/// The private key is derived deterministically from the Ed25519 seed and
/// never stored – only the public key is cached in secure storage for speed.
class EncryptionKeys {
  static final instance = EncryptionKeys._();
  EncryptionKeys._();

  SimpleKeyPair? _keyPair;
  Uint8List? _publicKeyBytes;

  /// The X25519 keypair (available after [initFromEd25519Private]).
  SimpleKeyPair? get keyPair => _keyPair;

  /// Own X25519 public key (32 bytes). Null until initialized.
  Uint8List? get publicKeyBytes => _publicKeyBytes;

  /// Own X25519 public key as lowercase hex. Null until initialized.
  String? get publicKeyHex => _publicKeyBytes == null
      ? null
      : _publicKeyBytes!
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

  /// Whether the keys have been initialized.
  bool get isInitialized => _keyPair != null;

  /// Derives the X25519 keypair from [ed25519Private] (32-byte Ed25519 seed).
  ///
  /// Uses HKDF-SHA256:
  ///   IKM  = ed25519Private
  ///   salt = utf8("nexus-encryption-v1")
  ///   info = utf8("x25519-key-derivation")
  ///   L    = 32 bytes (X25519 seed)
  Future<void> initFromEd25519Private(Uint8List ed25519Private) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final seedKey = await hkdf.deriveKey(
      secretKey: SecretKey(ed25519Private),
      nonce: utf8.encode('nexus-encryption-v1'),
      info: utf8.encode('x25519-key-derivation'),
    );
    final seedBytes = await seedKey.extractBytes();
    _keyPair = await X25519().newKeyPairFromSeed(Uint8List.fromList(seedBytes));
    final pubKey = await _keyPair!.extractPublicKey();
    _publicKeyBytes = Uint8List.fromList(pubKey.bytes);

    // Cache public key for display / verification screens
    await const FlutterSecureStorage()
        .write(key: _keyX25519Pub, value: publicKeyHex);
  }

  /// Loads a cached X25519 public key from secure storage (display only).
  Future<String?> loadCachedPublicKeyHex() async {
    return const FlutterSecureStorage().read(key: _keyX25519Pub);
  }

  /// Converts a hex string to [Uint8List].
  static Uint8List hexToBytes(String hex) => Uint8List.fromList(
        List.generate(hex.length ~/ 2,
            (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16)),
      );

  /// Converts bytes to lowercase hex string.
  static String bytesToHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
