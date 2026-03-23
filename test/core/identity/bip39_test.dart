import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/core/identity/bip39.dart';
import 'package:nexus_oneapp/core/identity/bip39_wordlist.dart';

void main() {
  group('Bip39', () {
    test('wordlist has exactly 2048 entries', () {
      expect(bip39Wordlist.length, 2048);
    });

    test('wordlist entries are unique', () {
      expect(bip39Wordlist.toSet().length, 2048);
    });

    test('generateMnemonic returns 12 words', () {
      final mnemonic = Bip39.generateMnemonic();
      final words = mnemonic.split(' ');
      expect(words.length, 12);
    });

    test('all generated words are in the wordlist', () {
      final mnemonic = Bip39.generateMnemonic();
      for (final word in mnemonic.split(' ')) {
        expect(bip39Wordlist.contains(word), isTrue,
            reason: 'Word "$word" not in BIP-39 wordlist');
      }
    });

    test('validateMnemonic accepts valid mnemonic', () {
      final mnemonic = Bip39.generateMnemonic();
      expect(Bip39.validateMnemonic(mnemonic), isTrue);
    });

    test('validateMnemonic rejects wrong word count', () {
      expect(Bip39.validateMnemonic('abandon abandon abandon'), isFalse);
    });

    test('validateMnemonic rejects unknown words', () {
      final mnemonic = Bip39.generateMnemonic();
      final words = mnemonic.split(' ').toList();
      words[0] = 'xxxxxx';
      expect(Bip39.validateMnemonic(words.join(' ')), isFalse);
    });

    test('mnemonicToSeed is deterministic', () {
      const mnemonic =
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final seed1 = Bip39.mnemonicToSeed(mnemonic);
      final seed2 = Bip39.mnemonicToSeed(mnemonic);
      expect(seed1, equals(seed2));
    });

    test('mnemonicToSeed returns 64 bytes', () {
      const mnemonic =
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final seed = Bip39.mnemonicToSeed(mnemonic);
      expect(seed.length, 64);
    });

    test('known test vector: abandon x11 + about', () {
      // BIP-39 test vector with empty passphrase
      // mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
      // seed (hex): 5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4
      const mnemonic =
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final seed = Bip39.mnemonicToSeed(mnemonic);
      expect(seed.length, 64);
      // Check first 3 bytes of known vector
      expect(seed[0], 0x5e);
      expect(seed[1], 0xb0);
      expect(seed[2], 0x0b);
    });

    test('two different mnemonics produce different seeds', () {
      final m1 = Bip39.generateMnemonic();
      final m2 = Bip39.generateMnemonic();
      if (m1 == m2) return; // astronomically unlikely
      expect(
          Bip39.mnemonicToSeed(m1), isNot(equals(Bip39.mnemonicToSeed(m2))));
    });
  });
}
