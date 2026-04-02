import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';

import 'package:crypto/crypto.dart' as pkg_crypto;

import 'nostr_keys.dart';

/// Nostr event kinds used by NEXUS.
class NostrKind {
  /// NIP-01 kind 0 – user metadata (name, about, picture).
  static const int metadata = 0;

  /// NIP-01 text note (used for #mesh broadcasts).
  static const int textNote = 1;

  /// NIP-04 encrypted direct message.
  static const int encryptedDm = 4;

  /// NIP-09 deletion request (Kind 5).
  static const int deletion = 5;

  /// NIP-28 channel creation (Kind 40).
  static const int channelCreate = 40;

  /// NIP-28 channel message (Kind 42).
  static const int channelMessage = 42;

  /// NIP-78 parameterized replaceable event – NEXUS presence announcements.
  ///
  /// Each node publishes one of these every 30 s so peers can discover it.
  /// Relays keep only the latest event per pubkey+d-tag, which is efficient.
  static const int presence = 30078;

  /// NEXUS role assignment event (system-level: superadmin → system_admin).
  ///
  /// Parameterized replaceable (Kind 31000+), signed by the superadmin's key.
  /// d-tag: "nexus-role-{did}" — one event per assigned DID.
  /// Content: JSON { "role": "systemAdmin|user", "granted_by": "...", "granted_at": 1234567890 }
  static const int roleAssignment = 31001;

  /// NEXUS channel-role assignment event (channel-level: admin → moderator).
  ///
  /// d-tag: "nexus-channel-role-{channelId}-{did}"
  /// Content: JSON { "role": "channelModerator|channelMember", "channel_id": "...", "granted_by": "..." }
  static const int channelRoleAssignment = 31002;
}

/// A NIP-01 Nostr event.
///
/// Wire format:
/// ```json
/// {
///   "id":         "<sha256-hex>",
///   "pubkey":     "<32-byte-hex>",
///   "created_at": <unix-timestamp>,
///   "kind":       <integer>,
///   "tags":       [["p", "..."], ["t", "..."], ...],
///   "content":    "<string>",
///   "sig":        "<64-byte-hex>"
/// }
/// ```
class NostrEvent {
  final String id;
  final String pubkey;
  final int createdAt;
  final int kind;
  final List<List<String>> tags;
  final String content;
  final String sig;

  const NostrEvent({
    required this.id,
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    required this.sig,
  });

  // ── Factory ──────────────────────────────────────────────────────────────

  /// Creates and signs a new Nostr event.
  factory NostrEvent.create({
    required NostrKeys keys,
    required int kind,
    required String content,
    List<List<String>> tags = const [],
    DateTime? timestamp,
  }) {
    final ts =
        (timestamp ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
    final pubkeyHex = keys.publicKeyHex;

    final id = _computeId(
      pubkey: pubkeyHex,
      createdAt: ts,
      kind: kind,
      tags: tags,
      content: content,
    );

    final sig = _bytesToHex(keys.schnorrSign(Uint8List.fromList(_hexToBytes(id))));

    return NostrEvent(
      id: id,
      pubkey: pubkeyHex,
      createdAt: ts,
      kind: kind,
      tags: tags,
      content: content,
      sig: sig,
    );
  }

  // ── Verification ─────────────────────────────────────────────────────────

  /// Returns true if the event ID is correct and the signature is valid.
  bool verify() {
    // 1. Verify event ID
    final expectedId = _computeId(
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content,
    );
    if (expectedId != id) return false;

    // 2. Verify Schnorr signature
    try {
      final pubkeyBytes = Uint8List.fromList(_hexToBytes(pubkey));
      final sigBytes = Uint8List.fromList(_hexToBytes(sig));
      final idBytes = Uint8List.fromList(_hexToBytes(id));
      return NostrKeys.schnorrVerify(pubkeyBytes, sigBytes, idBytes);
    } catch (_) {
      return false;
    }
  }

  // ── Tag helpers ──────────────────────────────────────────────────────────

  /// Returns the first value for a given tag name (e.g. 'p', 't').
  String? tagValue(String name) {
    for (final tag in tags) {
      if (tag.isNotEmpty && tag[0] == name && tag.length > 1) return tag[1];
    }
    return null;
  }

  /// Returns all values for a given tag name.
  List<String> tagValues(String name) => tags
      .where((t) => t.isNotEmpty && t[0] == name && t.length > 1)
      .map((t) => t[1])
      .toList();

  // ── Serialization ────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'id': id,
        'pubkey': pubkey,
        'created_at': createdAt,
        'kind': kind,
        'tags': tags,
        'content': content,
        'sig': sig,
      };

  factory NostrEvent.fromJson(Map<String, dynamic> json) => NostrEvent(
        id: json['id'] as String,
        pubkey: json['pubkey'] as String,
        createdAt: json['created_at'] as int,
        kind: json['kind'] as int,
        tags: (json['tags'] as List<dynamic>)
            .map((t) => (t as List<dynamic>).map((e) => e as String).toList())
            .toList(),
        content: json['content'] as String,
        sig: json['sig'] as String,
      );

  @override
  String toString() =>
      'NostrEvent(id: ${id.substring(0, 8)}, kind: $kind, pubkey: ${pubkey.substring(0, 8)})';
}

// ── Event ID computation ──────────────────────────────────────────────────

String _computeId({
  required String pubkey,
  required int createdAt,
  required int kind,
  required List<List<String>> tags,
  required String content,
}) {
  final serialized = jsonEncode([
    0,
    pubkey,
    createdAt,
    kind,
    tags,
    content,
  ]);
  final bytes = pkg_crypto.sha256.convert(utf8.encode(serialized)).bytes;
  return _bytesToHex(Uint8List.fromList(bytes));
}

// ── Utilities ──────────────────────────────────────────────────────────────

String _bytesToHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

List<int> _hexToBytes(String hex) => List.generate(
      hex.length ~/ 2,
      (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
    );

/// Generates a random subscription ID (16 hex chars).
String generateSubId() {
  final rng = Random.secure();
  return List.generate(16, (_) => rng.nextInt(16).toRadixString(16)).join();
}
