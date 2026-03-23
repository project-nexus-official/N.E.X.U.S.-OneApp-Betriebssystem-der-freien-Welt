import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Message types in the NEXUS mesh protocol.
enum NexusMessageType { text, channel, system }

/// A NEXUS mesh protocol message.
///
/// Wire format pipeline:
///   1. Serialize to compact JSON
///   2. Compress with ZLib (TODO: migrate to LZ4 when a stable Dart package is available)
///   3. Fragment into ≤500-byte chunks via [BleMessageHandler]
///
/// Broadcast messages use [broadcastDid] as [toDid].
/// Direct messages carry the recipient's DID.
class NexusMessage {
  static const String broadcastDid = 'broadcast';
  static const int defaultTtlHours = 12;
  static const int maxHopCount = 7;

  final String id;
  final String fromDid;
  final String toDid;
  final NexusMessageType type;

  /// Optional channel name, e.g. "#mesh" or "#hilfe".
  final String? channel;

  final String body;
  final DateTime timestamp;

  /// Time-to-live in hours. Message is dropped after [timestamp] + [ttlHours].
  final int ttlHours;

  /// Incremented each time the message is forwarded by an intermediate node.
  final int hopCount;

  /// Base64-encoded Ed25519 signature over [toSignableBytes()].
  final String? signature;

  const NexusMessage({
    required this.id,
    required this.fromDid,
    required this.toDid,
    required this.type,
    this.channel,
    required this.body,
    required this.timestamp,
    this.ttlHours = defaultTtlHours,
    this.hopCount = 0,
    this.signature,
  });

  /// Creates a new outgoing message with a generated UUID.
  factory NexusMessage.create({
    required String fromDid,
    String toDid = broadcastDid,
    NexusMessageType type = NexusMessageType.text,
    String? channel,
    required String body,
    int ttlHours = defaultTtlHours,
  }) {
    return NexusMessage(
      id: _generateId(),
      fromDid: fromDid,
      toDid: toDid,
      type: type,
      channel: channel,
      body: body,
      timestamp: DateTime.now().toUtc(),
      ttlHours: ttlHours,
    );
  }

  bool get isBroadcast => toDid == broadcastDid;

  bool get isExpired {
    final expiresAt = timestamp.add(Duration(hours: ttlHours));
    return DateTime.now().toUtc().isAfter(expiresAt);
  }

  NexusMessage withSignature(String sig) => NexusMessage(
        id: id,
        fromDid: fromDid,
        toDid: toDid,
        type: type,
        channel: channel,
        body: body,
        timestamp: timestamp,
        ttlHours: ttlHours,
        hopCount: hopCount,
        signature: sig,
      );

  NexusMessage withIncrementedHopCount() => NexusMessage(
        id: id,
        fromDid: fromDid,
        toDid: toDid,
        type: type,
        channel: channel,
        body: body,
        timestamp: timestamp,
        ttlHours: ttlHours,
        hopCount: hopCount + 1,
        signature: signature,
      );

  // ── Serialization ──────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'id': id,
        'from': fromDid,
        'to': toDid,
        'type': type.name,
        'body': body,
        'ts': timestamp.millisecondsSinceEpoch,
        'ttl': ttlHours,
        'hop': hopCount,
        if (channel != null) 'ch': channel,
        if (signature != null) 'sig': signature,
      };

  factory NexusMessage.fromJson(Map<String, dynamic> json) {
    return NexusMessage(
      id: json['id'] as String,
      fromDid: json['from'] as String,
      toDid: json['to'] as String,
      type: NexusMessageType.values.firstWhere(
        (t) => t.name == (json['type'] as String),
        orElse: () => NexusMessageType.text,
      ),
      body: json['body'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        json['ts'] as int,
        isUtc: true,
      ),
      ttlHours: (json['ttl'] as int?) ?? defaultTtlHours,
      hopCount: (json['hop'] as int?) ?? 0,
      channel: json['ch'] as String?,
      signature: json['sig'] as String?,
    );
  }

  /// Encodes this message to ZLib-compressed bytes ready for BLE fragmentation.
  Uint8List toWireBytes() {
    final jsonStr = jsonEncode(toJson());
    final raw = utf8.encode(jsonStr);
    return Uint8List.fromList(zlib.encode(raw));
  }

  /// Decodes from ZLib-compressed wire bytes.
  static NexusMessage fromWireBytes(Uint8List bytes) {
    final decompressed = zlib.decode(bytes);
    final jsonStr = utf8.decode(decompressed);
    return NexusMessage.fromJson(
      jsonDecode(jsonStr) as Map<String, dynamic>,
    );
  }

  /// Returns the canonical bytes to sign: JSON serialized without the 'sig' field.
  Uint8List toSignableBytes() {
    final map = Map<String, dynamic>.from(toJson())..remove('sig');
    return Uint8List.fromList(utf8.encode(jsonEncode(map)));
  }

  // ── UUID v4 generation ─────────────────────────────────────────────────────

  static String _generateId() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 1
    final hex =
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  @override
  bool operator ==(Object other) => other is NexusMessage && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'NexusMessage(id: ${id.substring(0, 8)}, from: ${fromDid.substring(0, 12)}, '
      'body: "${body.length > 30 ? body.substring(0, 30) : body}")';
}
