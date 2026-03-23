import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/core/identity/did.dart';
import 'package:nexus_oneapp/core/identity/identity.dart';

void main() {
  group('DidKey', () {
    test('generates did:key prefix', () {
      final did = DidKey.fromPublicKeyBytes(List.filled(32, 0));
      expect(did.startsWith('did:key:z'), isTrue);
    });

    test('is deterministic for same key bytes', () {
      final bytes = List<int>.generate(32, (i) => i);
      expect(
        DidKey.fromPublicKeyBytes(bytes),
        DidKey.fromPublicKeyBytes(bytes),
      );
    });

    test('differs for different key bytes', () {
      final a = DidKey.fromPublicKeyBytes(List.filled(32, 0));
      final b = DidKey.fromPublicKeyBytes(List.filled(32, 1));
      expect(a, isNot(b));
    });

    test('fromPublicKeyHex matches fromPublicKeyBytes', () {
      final bytes = List<int>.generate(32, (i) => i * 7 % 256);
      final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(DidKey.fromPublicKeyHex(hex), DidKey.fromPublicKeyBytes(bytes));
    });

    test('shorten truncates long DID', () {
      final did = DidKey.fromPublicKeyBytes(List.filled(32, 42));
      final short = DidKey.shorten(did);
      expect(short.contains('…'), isTrue);
      expect(short.length, lessThan(did.length));
    });

    test('NexusIdentity auto-derives DID', () {
      final hex = List.filled(32, 5)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final identity = NexusIdentity(publicKeyHex: hex, pseudonym: 'Test');
      expect(identity.did.startsWith('did:key:z'), isTrue);
      expect(identity.shortDid.contains('…'), isTrue);
    });

    test('DID is ~56 characters for Ed25519 key', () {
      // did:key:z + base58(34 bytes) ≈ did:key:z + 46 chars ≈ 54-57 chars total
      final did = DidKey.fromPublicKeyBytes(List.filled(32, 0xAB));
      expect(did.length, greaterThanOrEqualTo(50));
      expect(did.length, lessThanOrEqualTo(65));
    });
  });
}
