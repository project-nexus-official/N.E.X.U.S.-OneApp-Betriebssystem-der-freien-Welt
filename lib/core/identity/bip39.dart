import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'bip39_wordlist.dart';

/// BIP-39 mnemonic generation, validation, and seed derivation.
class Bip39 {
  Bip39._();

  /// Generates a 12-word BIP-39 mnemonic from secure random entropy.
  static String generateMnemonic() {
    final entropy = _secureRandomBytes(16); // 128 bits → 12 words
    return _entropyToMnemonic(entropy);
  }

  /// Validates a mnemonic: correct word count, all words in wordlist, valid checksum.
  static bool validateMnemonic(String mnemonic) {
    final words = mnemonic.trim().toLowerCase().split(RegExp(r'\s+'));
    if (![12, 15, 18, 21, 24].contains(words.length)) return false;
    for (final w in words) {
      if (!bip39Wordlist.contains(w)) return false;
    }
    // Verify checksum
    final bits = words.map((w) {
      final idx = bip39Wordlist.indexOf(w);
      return idx.toRadixString(2).padLeft(11, '0');
    }).join();
    final totalBits = bits.length; // e.g. 132 for 12 words
    final csLen = totalBits ~/ 33;
    final entBits = totalBits - csLen;
    final entropyBytes = Uint8List(entBits ~/ 8);
    for (int i = 0; i < entropyBytes.length; i++) {
      entropyBytes[i] = int.parse(bits.substring(i * 8, i * 8 + 8), radix: 2);
    }
    final hash = sha256.convert(entropyBytes);
    final hashBits =
        hash.bytes.map((b) => b.toRadixString(2).padLeft(8, '0')).join();
    return bits.substring(entBits) == hashBits.substring(0, csLen);
  }

  /// Derives a 64-byte seed from a mnemonic using PBKDF2-HMAC-SHA512.
  /// Uses passphrase "mnemonic" + optional user passphrase (BIP-39 standard).
  static Uint8List mnemonicToSeed(String mnemonic, {String passphrase = ''}) {
    final password =
        Uint8List.fromList(utf8.encode(mnemonic.trim().split(RegExp(r'\s+')).join(' ')));
    final salt = Uint8List.fromList(utf8.encode('mnemonic$passphrase'));
    return _pbkdf2HmacSha512(password, salt, 2048, 64);
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  static Uint8List _secureRandomBytes(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rng.nextInt(256)));
  }

  static String _entropyToMnemonic(Uint8List entropy) {
    final hash = sha256.convert(entropy);
    final csLen = entropy.length * 8 ~/ 32;
    final entBits =
        entropy.map((b) => b.toRadixString(2).padLeft(8, '0')).join();
    final csBits = hash.bytes
        .map((b) => b.toRadixString(2).padLeft(8, '0'))
        .join()
        .substring(0, csLen);
    final bits = entBits + csBits;
    final words = <String>[];
    for (int i = 0; i + 11 <= bits.length; i += 11) {
      words.add(
          bip39Wordlist[int.parse(bits.substring(i, i + 11), radix: 2)]);
    }
    return words.join(' ');
  }

  /// PBKDF2-HMAC-SHA512 implementation.
  static Uint8List _pbkdf2HmacSha512(
    Uint8List password,
    Uint8List salt,
    int iterations,
    int dkLen,
  ) {
    const hLen = 64; // SHA-512 output length in bytes
    final blocks = (dkLen / hLen).ceil();
    final result = <int>[];

    for (int i = 1; i <= blocks; i++) {
      // U1 = HMAC(password, salt || INT(i))
      final saltWithIndex = Uint8List(salt.length + 4);
      saltWithIndex.setAll(0, salt);
      saltWithIndex[salt.length] = (i >> 24) & 0xFF;
      saltWithIndex[salt.length + 1] = (i >> 16) & 0xFF;
      saltWithIndex[salt.length + 2] = (i >> 8) & 0xFF;
      saltWithIndex[salt.length + 3] = i & 0xFF;

      var u = Uint8List.fromList(
        Hmac(sha512, password).convert(saltWithIndex).bytes,
      );
      final t = Uint8List.fromList(u);

      for (int j = 1; j < iterations; j++) {
        u = Uint8List.fromList(Hmac(sha512, password).convert(u).bytes);
        for (int k = 0; k < hLen; k++) {
          t[k] ^= u[k];
        }
      }
      result.addAll(t);
    }

    return Uint8List.fromList(result.sublist(0, dkLen));
  }
}
