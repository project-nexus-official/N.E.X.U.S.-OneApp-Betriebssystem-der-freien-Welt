import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/core/identity/bip39.dart';
import 'package:nexus_oneapp/core/transport/nostr/nostr_keys.dart';

void main() {
  // Fixed test mnemonic (DO NOT use for real funds)
  const testMnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

  late Uint8List seed64;
  late NostrKeys keys;

  setUpAll(() {
    seed64 = Uint8List.fromList(Bip39.mnemonicToSeed(testMnemonic));
    keys = NostrKeys.fromBip39Seed(seed64);
  });

  group('NostrKeys - key derivation', () {
    test('produces 32-byte private and public key', () {
      expect(keys.privateKey.length, equals(32));
      expect(keys.publicKey.length, equals(32));
    });

    test('same seed always yields same keys (deterministic)', () {
      final keys2 = NostrKeys.fromBip39Seed(seed64);
      expect(keys.privateKey, equals(keys2.privateKey));
      expect(keys.publicKey, equals(keys2.publicKey));
    });

    test('different seeds yield different keys', () {
      const mnemonic2 =
          'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong';
      final seed2 = Uint8List.fromList(Bip39.mnemonicToSeed(mnemonic2));
      final keys2 = NostrKeys.fromBip39Seed(seed2);
      expect(keys.privateKey, isNot(equals(keys2.privateKey)));
      expect(keys.publicKey, isNot(equals(keys2.publicKey)));
    });

    test('publicKeyHex is 64 hex chars', () {
      expect(keys.publicKeyHex.length, equals(64));
      expect(
        RegExp(r'^[0-9a-f]+$').hasMatch(keys.publicKeyHex),
        isTrue,
      );
    });
  });

  group('Bech32 encoding', () {
    test('npub starts with "npub1"', () {
      expect(keys.npub, startsWith('npub1'));
    });

    test('nsec starts with "nsec1"', () {
      expect(keys.nsec, startsWith('nsec1'));
    });

    test('bech32 round-trip: encode then decode equals original', () {
      final encoded = NostrKeys.bech32Encode('npub', keys.publicKey);
      final decoded = NostrKeys.bech32Decode('npub', encoded);
      expect(decoded, equals(keys.publicKey));
    });

    test('decode with wrong hrp throws FormatException', () {
      final encoded = NostrKeys.bech32Encode('npub', keys.publicKey);
      expect(
        () => NostrKeys.bech32Decode('nsec', encoded),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Schnorr signing (BIP-340)', () {
    test('sign produces 64-byte signature', () {
      final msg = Uint8List(32); // all-zero 32-byte message
      final sig = keys.schnorrSign(msg);
      expect(sig.length, equals(64));
    });

    test('signature verifies with correct public key', () {
      final msg = Uint8List.fromList(List.generate(32, (i) => i));
      final sig = keys.schnorrSign(msg);
      final valid = NostrKeys.schnorrVerify(keys.publicKey, sig, msg);
      expect(valid, isTrue);
    });

    test('signature fails verification with wrong public key', () {
      const mnemonic2 =
          'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong';
      final seed2 = Uint8List.fromList(Bip39.mnemonicToSeed(mnemonic2));
      final keys2 = NostrKeys.fromBip39Seed(seed2);

      final msg = Uint8List.fromList(List.generate(32, (i) => i));
      final sig = keys.schnorrSign(msg);
      final valid = NostrKeys.schnorrVerify(keys2.publicKey, sig, msg);
      expect(valid, isFalse);
    });

    test('signature fails verification with tampered message', () {
      final msg = Uint8List.fromList(List.generate(32, (i) => i));
      final sig = keys.schnorrSign(msg);
      final tampered = Uint8List.fromList(msg)..last ^= 0xFF;
      final valid = NostrKeys.schnorrVerify(keys.publicKey, sig, tampered);
      expect(valid, isFalse);
    });

    test('signing is deterministic (same key+msg yields same sig)', () {
      final msg = Uint8List.fromList(List.generate(32, (i) => i * 3));
      final sig1 = keys.schnorrSign(msg);
      final sig2 = keys.schnorrSign(msg);
      expect(sig1, equals(sig2));
    });
  });

  group('ECDH shared secret (NIP-04)', () {
    test('shared secret is 32 bytes', () {
      const m2 = 'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong';
      final s2 = Uint8List.fromList(Bip39.mnemonicToSeed(m2));
      final keys2 = NostrKeys.fromBip39Seed(s2);

      final secret = keys.computeSharedSecret(keys2.publicKey);
      expect(secret.length, equals(32));
    });

    test('ECDH is commutative: A*B == B*A (same x-coord)', () {
      const m2 = 'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong';
      final s2 = Uint8List.fromList(Bip39.mnemonicToSeed(m2));
      final keys2 = NostrKeys.fromBip39Seed(s2);

      final shared1 = keys.computeSharedSecret(keys2.publicKey);
      final shared2 = keys2.computeSharedSecret(keys.publicKey);
      expect(shared1, equals(shared2));
    });

    test('different peers produce different shared secrets', () {
      const m2 = 'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong';
      const m3 = 'ability able about above absent absorb abstract absurd abuse access accident account';
      final s2 = Uint8List.fromList(Bip39.mnemonicToSeed(m2));
      final s3 = Uint8List.fromList(Bip39.mnemonicToSeed(m3));
      final keys2 = NostrKeys.fromBip39Seed(s2);
      final keys3 = NostrKeys.fromBip39Seed(s3);

      final secret12 = keys.computeSharedSecret(keys2.publicKey);
      final secret13 = keys.computeSharedSecret(keys3.publicKey);
      expect(secret12, isNot(equals(secret13)));
    });
  });

  group('Geohash', () {
    test('precision-5 geohash has 5 characters', () {
      final hash = geohashEncode(52.5200, 13.4050); // Berlin
      expect(hash.length, equals(5));
    });

    test('same coordinates produce same geohash', () {
      final h1 = geohashEncode(48.8566, 2.3522); // Paris
      final h2 = geohashEncode(48.8566, 2.3522);
      expect(h1, equals(h2));
    });

    test('nearby coordinates share geohash prefix', () {
      // Points within ~5 km should have the same 4-char prefix
      final h1 = geohashEncode(52.5200, 13.4050);
      final h2 = geohashEncode(52.5250, 13.4100); // ~700 m away
      expect(h1.substring(0, 4), equals(h2.substring(0, 4)));
    });

    test('far apart coordinates differ', () {
      final berlin = geohashEncode(52.5200, 13.4050);
      final sydney = geohashEncode(-33.8688, 151.2093);
      expect(berlin, isNot(equals(sydney)));
    });
  });
}
