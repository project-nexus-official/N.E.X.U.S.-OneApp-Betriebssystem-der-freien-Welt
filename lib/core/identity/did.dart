import 'dart:typed_data';

/// Generates W3C did:key identifiers from Ed25519 public keys.
///
/// Format: did:key:z + base58btc(0xED 0x01 || pubKeyBytes)
///
/// - 0xED 0x01 = varint-encoded multicodec prefix for Ed25519 public key (0xED = 237)
/// - 'z' = multibase prefix for base58btc
class DidKey {
  DidKey._();

  static const _base58Alphabet =
      '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

  /// Derives a did:key string from a 32-byte Ed25519 public key.
  static String fromPublicKeyBytes(List<int> pubKeyBytes) {
    assert(pubKeyBytes.length == 32, 'Ed25519 public key must be 32 bytes');
    // Prepend multicodec varint prefix [0xED, 0x01]
    final prefixed = Uint8List(34)
      ..[0] = 0xED
      ..[1] = 0x01;
    prefixed.setRange(2, 34, pubKeyBytes);
    return 'did:key:z${_base58Encode(prefixed)}';
  }

  /// Derives a did:key string from a hex-encoded public key string.
  static String fromPublicKeyHex(String hex) {
    final bytes = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return fromPublicKeyBytes(bytes);
  }

  /// Shortens a DID for display: first 14 chars + "…" + last 6 chars.
  static String shorten(String did) {
    if (did.length <= 20) return did;
    return '${did.substring(0, 14)}…${did.substring(did.length - 6)}';
  }

  // ── Base58btc encoding ───────────────────────────────────────────────────

  static String _base58Encode(Uint8List bytes) {
    // Count leading zero bytes
    int leadingZeros = 0;
    for (final b in bytes) {
      if (b == 0) {
        leadingZeros++;
      } else {
        break;
      }
    }

    // Convert bytes to big integer (as a list of digits in base 256)
    final digits = <int>[0];
    for (final byte in bytes) {
      int carry = byte;
      for (int i = 0; i < digits.length; i++) {
        carry += digits[i] << 8;
        digits[i] = carry % 58;
        carry ~/= 58;
      }
      while (carry > 0) {
        digits.add(carry % 58);
        carry ~/= 58;
      }
    }

    final result = StringBuffer();
    for (int i = 0; i < leadingZeros; i++) {
      result.write(_base58Alphabet[0]);
    }
    for (int i = digits.length - 1; i >= 0; i--) {
      result.write(_base58Alphabet[digits[i]]);
    }
    return result.toString();
  }
}
