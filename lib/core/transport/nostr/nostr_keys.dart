import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as pkg_crypto;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';

const _keyNostrPriv = 'nostr_private_key';
const _keyNostrPub = 'nostr_public_key';

final ECDomainParameters _secp256k1 = ECCurve_secp256k1();

// secp256k1 prime (hardcoded – well-known constant, avoids PointyCastle API)
final _secp256k1P = BigInt.parse(
  'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F',
  radix: 16,
);

/// Nostr keypair derived from the NEXUS seed phrase.
///
/// Uses BIP-32 / NIP-06 derivation path m/44'/1237'/0'/0/0.
/// The public key is in x-only BIP-340 format (32 bytes).
class NostrKeys {
  /// 32-byte secp256k1 private key.
  final Uint8List privateKey;

  /// 32-byte x-only public key (BIP-340 / Nostr format).
  final Uint8List publicKey;

  NostrKeys._(this.privateKey, this.publicKey);

  // ── Factory constructors ──────────────────────────────────────────────────

  /// Derives a Nostr keypair from a 64-byte BIP-39 seed.
  ///
  /// Follows NIP-06 derivation path m/44'/1237'/0'/0/0.
  static NostrKeys fromBip39Seed(Uint8List seed64) {
    final privKey = _bip32DeriveSecp256k1(seed64);
    final G = _secp256k1.G;
    final pub = (G * _bytesToBigInt(privKey))!;
    // x-only pubkey (32 bytes, big-endian)
    final xBytes = _bigIntToBytes32(pub.x!.toBigInteger()!);
    return NostrKeys._(privKey, xBytes);
  }

  /// Loads the cached Nostr keypair from secure storage, or derives and
  /// caches it from [seed64].
  static Future<NostrKeys> loadOrDerive(
    Uint8List seed64, {
    FlutterSecureStorage? storage,
  }) async {
    final store = storage ?? const FlutterSecureStorage();
    final privHex = await store.read(key: _keyNostrPriv);
    final pubHex = await store.read(key: _keyNostrPub);
    if (privHex != null && pubHex != null) {
      return NostrKeys._(
        Uint8List.fromList(_hexToBytes(privHex)),
        Uint8List.fromList(_hexToBytes(pubHex)),
      );
    }
    final keys = NostrKeys.fromBip39Seed(seed64);
    await store.write(key: _keyNostrPriv, value: _bytesToHex(keys.privateKey));
    await store.write(key: _keyNostrPub, value: _bytesToHex(keys.publicKey));
    return keys;
  }

  // ── Public API ────────────────────────────────────────────────────────────

  /// Public key encoded as npub bech32 string.
  String get npub => bech32Encode('npub', publicKey);

  /// Private key encoded as nsec bech32 string.
  String get nsec => bech32Encode('nsec', privateKey);

  /// Public key as lowercase hex (used in Nostr event JSON).
  String get publicKeyHex => _bytesToHex(publicKey);

  /// Signs [msgHash] (32 bytes) using BIP-340 Schnorr.  Returns 64 bytes.
  Uint8List schnorrSign(Uint8List msgHash) {
    assert(msgHash.length == 32, 'msgHash must be 32 bytes');
    final G = _secp256k1.G;
    final n = _secp256k1.n;

    final d0 = _bytesToBigInt(privateKey);
    final P = (G * d0)!;
    final px = _bigIntToBytes32(P.x!.toBigInteger()!);
    final py = P.y!.toBigInteger()!;

    // Negate d if P.y is odd
    final d = py.isOdd ? n - d0 : d0;

    // t = xor(bytes(d), tagHash("BIP0340/aux", zeroes))
    final aux = Uint8List(32);
    final hashAux = _taggedHash('BIP0340/aux', aux);
    final t = Uint8List(32);
    final dBytes = _bigIntToBytes32(d);
    for (var i = 0; i < 32; i++) {
      t[i] = dBytes[i] ^ hashAux[i];
    }

    // rand = tagHash("BIP0340/nonce", t || P.x || msg)
    final rand = _taggedHash(
      'BIP0340/nonce',
      Uint8List.fromList([...t, ...px, ...msgHash]),
    );

    final k0 = _bytesToBigInt(rand) % n;
    if (k0 == BigInt.zero) throw StateError('Schnorr: k0 is zero');

    final R = (G * k0)!;
    final rx = _bigIntToBytes32(R.x!.toBigInteger()!);
    final ry = R.y!.toBigInteger()!;

    // Negate k if R.y is odd
    final k = ry.isOdd ? n - k0 : k0;

    // e = tagHash("BIP0340/challenge", R.x || P.x || msg) mod n
    final e = _bytesToBigInt(_taggedHash(
          'BIP0340/challenge',
          Uint8List.fromList([...rx, ...px, ...msgHash]),
        )) %
        n;

    final s = (k + e * d) % n;
    return Uint8List.fromList([...rx, ..._bigIntToBytes32(s)]);
  }

  /// Verifies a BIP-340 Schnorr signature.
  ///
  /// [pubkeyX] is the 32-byte x-only signer pubkey.
  /// [sig] is the 64-byte signature.
  /// [msgHash] is the 32-byte message hash.
  static bool schnorrVerify(
    Uint8List pubkeyX,
    Uint8List sig,
    Uint8List msgHash,
  ) {
    if (sig.length != 64 || pubkeyX.length != 32 || msgHash.length != 32) {
      return false;
    }
    try {
      final G = _secp256k1.G;
      final n = _secp256k1.n;
      final p = _secp256k1P;

      final rx = _bytesToBigInt(sig.sublist(0, 32));
      final s = _bytesToBigInt(sig.sublist(32, 64));
      if (rx >= p || s >= n) return false;

      final px = _bytesToBigInt(pubkeyX);
      // Lift P: y = sqrt(x^3+7) mod p, choose even y
      final y2 = (px.modPow(BigInt.from(3), p) + BigInt.from(7)) % p;
      final y0 = y2.modPow((p + BigInt.one) >> 2, p);
      if (y0.modPow(BigInt.two, p) != y2) return false; // not on curve
      final py = y0.isEven ? y0 : p - y0;

      final curve = _secp256k1.curve;
      final P = curve.createPoint(px, py);

      // e = tagHash("BIP0340/challenge", R.x || P.x || msg) mod n
      final e = _bytesToBigInt(_taggedHash(
            'BIP0340/challenge',
            Uint8List.fromList([...sig.sublist(0, 32), ...pubkeyX, ...msgHash]),
          )) %
          n;

      // Verify: s*G - e*P == R where R.x == rx and R.y is even
      final rcheck = (G * s)! - (P * e)!;
      if (rcheck == null) return false;

      final rcx = rcheck.x!.toBigInteger()!;
      final rcy = rcheck.y!.toBigInteger()!;
      return rcx == rx && rcy.isEven;
    } catch (_) {
      return false;
    }
  }

  /// Computes the NIP-04 ECDH shared secret x-coordinate.
  ///
  /// [recipientPubKeyX] is the 32-byte x-only public key of the recipient.
  /// NIP-04 convention: lift to full point using even y (as if '02' prefix).
  Uint8List computeSharedSecret(Uint8List recipientPubKeyX) {
    final p = _secp256k1P;
    final rx = _bytesToBigInt(recipientPubKeyX);
    // y² = x³ + 7 mod p
    final y2 = (rx.modPow(BigInt.from(3), p) + BigInt.from(7)) % p;
    final y0 = y2.modPow((p + BigInt.one) >> 2, p);
    final y = y0.isEven ? y0 : p - y0;

    final curve = _secp256k1.curve;
    final recipientPoint = curve.createPoint(rx, y);
    final sharedPoint = (recipientPoint * _bytesToBigInt(privateKey))!;
    return _bigIntToBytes32(sharedPoint.x!.toBigInteger()!);
  }

  // ── Bech32 ─────────────────────────────────────────────────────────────────

  static const _bech32Charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

  /// Encodes [data] as a bech32 string with human-readable part [hrp].
  static String bech32Encode(String hrp, Uint8List data) {
    final converted = _convertBits(data.toList(), 8, 5, pad: true);
    final checksum = _bech32CreateChecksum(hrp, converted);
    final payload = [...converted, ...checksum];
    return '$hrp\x31${payload.map((v) => _bech32Charset[v]).join()}';
  }

  /// Decodes a bech32 string to raw bytes, verifying the [expectedHrp].
  static Uint8List bech32Decode(String expectedHrp, String encoded) {
    final lower = encoded.toLowerCase();
    final sep = lower.lastIndexOf('\x31');
    if (sep < 1) throw FormatException('Invalid bech32 string: $encoded');

    final hrp = lower.substring(0, sep);
    if (hrp != expectedHrp.toLowerCase()) {
      throw FormatException('Expected hrp $expectedHrp but got $hrp');
    }

    final dataStr = lower.substring(sep + 1, lower.length - 6);
    final fiveBit = dataStr.runes.map((r) {
      final idx = _bech32Charset.indexOf(String.fromCharCode(r));
      if (idx < 0) throw FormatException('Invalid bech32 character');
      return idx;
    }).toList();

    return Uint8List.fromList(_convertBits(fiveBit, 5, 8, pad: false));
  }

  static List<int> _convertBits(List<int> data, int from, int to,
      {required bool pad}) {
    var acc = 0, bits = 0;
    final result = <int>[];
    final maxv = (1 << to) - 1;
    for (final v in data) {
      acc = ((acc << from) | v) & 0x3FFFF;
      bits += from;
      while (bits >= to) {
        bits -= to;
        result.add((acc >> bits) & maxv);
      }
    }
    if (pad && bits > 0) result.add((acc << (to - bits)) & maxv);
    return result;
  }

  static List<int> _bech32CreateChecksum(String hrp, List<int> data) {
    final values = [..._bech32HrpExpand(hrp), ...data, 0, 0, 0, 0, 0, 0];
    final polymod = _bech32Polymod(values) ^ 1;
    return List.generate(6, (i) => (polymod >> (5 * (5 - i))) & 31);
  }

  static List<int> _bech32HrpExpand(String hrp) => [
        ...hrp.codeUnits.map((c) => c >> 5),
        0,
        ...hrp.codeUnits.map((c) => c & 31),
      ];

  static int _bech32Polymod(List<int> values) {
    const gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
    var chk = 1;
    for (final v in values) {
      final top = chk >> 25;
      chk = ((chk & 0x1ffffff) << 5) ^ v;
      for (var i = 0; i < 5; i++) {
        if ((top >> i) & 1 != 0) chk ^= gen[i];
      }
    }
    return chk;
  }
}

// ── BIP-32 secp256k1 derivation ────────────────────────────────────────────

/// Derives a secp256k1 private key from a 64-byte BIP-39 seed.
/// Path: m/44'/1237'/0'/0/0  (NIP-06)
Uint8List _bip32DeriveSecp256k1(Uint8List seed64) {
  // Master key from seed
  final master = _hmacSha512(utf8.encode('Bitcoin seed'), seed64);
  var key = Uint8List.fromList(master.sublist(0, 32));
  var chainCode = Uint8List.fromList(master.sublist(32));

  // NIP-06 path indices
  const indices = [
    0x8000002C, // 44'
    0x800004D5, // 1237'
    0x80000000, // 0'
    0x00000000, // 0
    0x00000000, // 0
  ];

  final G = _secp256k1.G;
  final n = _secp256k1.n;

  for (final idx in indices) {
    final data = Uint8List(37);
    if (idx >= 0x80000000) {
      // Hardened: 0x00 || private_key || index
      data[0] = 0x00;
      data.setRange(1, 33, key);
    } else {
      // Normal: compressed public key || index
      final pubPoint = (G * _bytesToBigInt(key))!;
      final ybig = pubPoint.y!.toBigInteger()!;
      data[0] = ybig.isOdd ? 0x03 : 0x02;
      data.setRange(1, 33, _bigIntToBytes32(pubPoint.x!.toBigInteger()!));
    }
    data[33] = (idx >> 24) & 0xFF;
    data[34] = (idx >> 16) & 0xFF;
    data[35] = (idx >> 8) & 0xFF;
    data[36] = idx & 0xFF;

    final child = _hmacSha512(chainCode, data);
    final childScalar = _bytesToBigInt(Uint8List.fromList(child.sublist(0, 32)));
    final parentScalar = _bytesToBigInt(key);
    final newKey = (childScalar + parentScalar) % n;

    key = _bigIntToBytes32(newKey);
    chainCode = Uint8List.fromList(child.sublist(32));
  }

  return key;
}

List<int> _hmacSha512(List<int> key, List<int> data) =>
    pkg_crypto.Hmac(pkg_crypto.sha512, key).convert(data).bytes;

// ── BIP-340 tagged hash ────────────────────────────────────────────────────

Uint8List _taggedHash(String tag, Uint8List data) {
  final tagHash = pkg_crypto.sha256.convert(utf8.encode(tag)).bytes;
  return Uint8List.fromList(
    pkg_crypto.sha256
        .convert([...tagHash, ...tagHash, ...data])
        .bytes,
  );
}

// ── Utilities ────────────────────────────────────────────────────────────────

BigInt _bytesToBigInt(Uint8List bytes) =>
    BigInt.parse(_bytesToHex(bytes), radix: 16);

Uint8List _bigIntToBytes32(BigInt value) {
  final hex = value.toRadixString(16).padLeft(64, '0');
  return Uint8List.fromList(
    List.generate(32, (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16)),
  );
}

String _bytesToHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

List<int> _hexToBytes(String hex) => List.generate(
      hex.length ~/ 2,
      (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
    );

/// Computes a 5-character geohash for [lat]/[lon] (≈ 5 km radius).
String geohashEncode(double lat, double lon, {int precision = 5}) {
  const base32 = '0123456789bcdefghjkmnpqrstuvwxyz';
  double minLat = -90, maxLat = 90;
  double minLon = -180, maxLon = 180;
  int bit = 4, ch = 0;
  var isEven = true;
  final buf = StringBuffer();

  while (buf.length < precision) {
    final double mid;
    if (isEven) {
      mid = (minLon + maxLon) / 2;
      if (lon >= mid) {
        ch |= 1 << bit;
        minLon = mid;
      } else {
        maxLon = mid;
      }
    } else {
      mid = (minLat + maxLat) / 2;
      if (lat >= mid) {
        ch |= 1 << bit;
        minLat = mid;
      } else {
        maxLat = mid;
      }
    }
    isEven = !isEven;
    if (bit > 0) {
      bit--;
    } else {
      buf.write(base32[ch]);
      ch = 0;
      bit = 4;
    }
  }
  return buf.toString();
}
