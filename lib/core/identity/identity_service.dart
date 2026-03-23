import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as pkg_crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'identity.dart';
import 'did.dart';
import 'bip39.dart';
import 'pseudonym_generator.dart';

const _keySeedPhrase = 'nexus_seed_phrase';
const _keyPseudonym = 'nexus_pseudonym';
const _keyPublicKey = 'nexus_public_key';
const _keyDid = 'nexus_did';
const _keyEncKey = 'nexus_pod_enc_key';

/// Manages the user's NEXUS identity: key generation, storage, and retrieval.
class IdentityService {
  // Singleton
  static final IdentityService instance = IdentityService._internal();
  IdentityService._internal() : _storage = const FlutterSecureStorage();

  /// Convenience factory so callers can write `IdentityService()`.
  factory IdentityService() => instance;

  final FlutterSecureStorage _storage;

  NexusIdentity? _current;
  NexusIdentity? get currentIdentity => _current;
  bool get hasIdentity => _current != null;

  /// Loads the existing identity from secure storage. Call at app startup.
  Future<void> init() async {
    final pubKey = await _storage.read(key: _keyPublicKey);
    final pseudonym = await _storage.read(key: _keyPseudonym);
    if (pubKey != null && pseudonym != null) {
      // Load stored DID, or derive it on the fly for existing users (migration).
      String? did = await _storage.read(key: _keyDid);
      if (did == null) {
        did = DidKey.fromPublicKeyHex(pubKey);
        await _storage.write(key: _keyDid, value: did);
      }
      _current = NexusIdentity(publicKeyHex: pubKey, pseudonym: pseudonym, did: did);
    }
  }

  /// Generates a fresh 12-word mnemonic (does NOT persist yet).
  String generateMnemonic() => Bip39.generateMnemonic();

  /// Reads the stored seed phrase (for display during onboarding / backup).
  Future<String?> loadSeedPhrase() => _storage.read(key: _keySeedPhrase);

  /// Creates and persists a new identity from the given mnemonic + pseudonym.
  Future<NexusIdentity> createIdentity(
    String mnemonic,
    String pseudonym,
  ) async {
    final (pubKeyHex, did, podKeyHex) = await _deriveIdentityData(mnemonic);
    await _storage.write(key: _keySeedPhrase, value: mnemonic.trim());
    await _storage.write(key: _keyPublicKey, value: pubKeyHex);
    await _storage.write(key: _keyPseudonym, value: pseudonym);
    await _storage.write(key: _keyDid, value: did);
    await _storage.write(key: _keyEncKey, value: podKeyHex);
    _current = NexusIdentity(publicKeyHex: pubKeyHex, pseudonym: pseudonym, did: did);
    return _current!;
  }

  /// Restores an identity from an existing mnemonic.
  /// Throws [ArgumentError] if the mnemonic is invalid.
  Future<NexusIdentity> restoreFromMnemonic(
    String mnemonic, {
    String? pseudonym,
  }) async {
    if (!Bip39.validateMnemonic(mnemonic)) {
      throw ArgumentError('Ungültige Seed Phrase.');
    }
    final (pubKeyHex, did, podKeyHex) = await _deriveIdentityData(mnemonic);
    final resolvedPseudonym =
        pseudonym ?? PseudonymGenerator.fromBytes(_hexToBytes(pubKeyHex));
    await _storage.write(key: _keySeedPhrase, value: mnemonic.trim());
    await _storage.write(key: _keyPublicKey, value: pubKeyHex);
    await _storage.write(key: _keyPseudonym, value: resolvedPseudonym);
    await _storage.write(key: _keyDid, value: did);
    await _storage.write(key: _keyEncKey, value: podKeyHex);
    _current = NexusIdentity(
      publicKeyHex: pubKeyHex,
      pseudonym: resolvedPseudonym,
      did: did,
    );
    return _current!;
  }

  /// Reads the pod encryption key from secure storage.
  Future<Uint8List> getPodEncryptionKey() async {
    final hex = await _storage.read(key: _keyEncKey);
    if (hex == null) throw StateError('Pod encryption key not found.');
    return Uint8List.fromList(_hexToBytes(hex));
  }

  /// Derives identity data (pubKeyHex, DID, podEncKeyHex) from a BIP-39 mnemonic.
  Future<(String, String, String)> _deriveIdentityData(String mnemonic) async {
    final seed64 = Bip39.mnemonicToSeed(mnemonic);

    // SLIP-0010 Ed25519 master key derivation
    final slip10 =
        pkg_crypto.Hmac(pkg_crypto.sha512, utf8.encode('ed25519 seed'))
            .convert(seed64)
            .bytes;
    final privateKeyBytes = Uint8List.fromList(slip10.sublist(0, 32));
    final keyPair = await Ed25519().newKeyPairFromSeed(privateKeyBytes);
    final pubKey = await keyPair.extractPublicKey();
    final pubKeyHex =
        pubKey.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    // Derive DID from public key
    final did = DidKey.fromPublicKeyHex(pubKeyHex);

    // Derive pod encryption key: SHA-256(seed64 || "nexus-pod-v1")
    final podKeyBytes = pkg_crypto.sha256.convert([
      ...seed64,
      ...utf8.encode('nexus-pod-v1'),
    ]).bytes;
    final podKeyHex =
        podKeyBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    return (pubKeyHex, did, podKeyHex);
  }

  static List<int> _hexToBytes(String hex) {
    final result = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return result;
  }
}
