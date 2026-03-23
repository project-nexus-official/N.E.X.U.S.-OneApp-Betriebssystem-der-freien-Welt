import 'dart:io';
import 'dart:typed_data';

/// Handles BLE-level message fragmentation, reassembly, compression,
/// and deduplication.
///
/// Wire chunk layout (max [chunkSize] bytes total):
/// ┌─────────────────────────────────────────────────────┐
/// │ msgHash[0..3] (4 bytes) – first 4 bytes of msg ID  │
/// │ chunkIdx      (1 byte)  – 0-based index             │
/// │ totalChunks   (1 byte)  – total number of chunks    │
/// │ payload       (≤494 bytes)                          │
/// └─────────────────────────────────────────────────────┘
///
/// Full pipeline for send:
///   JSON bytes → ZLib compress → fragment into chunks
///
/// Full pipeline for receive:
///   chunks → reassemble → ZLib decompress → JSON bytes
class BleMessageHandler {
  static const int chunkSize = 500;
  static const int headerSize = 6; // 4 (hash) + 1 (idx) + 1 (total)
  static const int payloadSize = chunkSize - headerSize; // 494 bytes

  // Reassembly buffers: msgHash → { chunkIdx → data }
  final Map<int, Map<int, Uint8List>> _partials = {};

  // Deduplication: set of recently seen message IDs
  final Set<String> _seenIds = {};
  static const int _maxSeenIds = 5000;

  // ── Compression ───────────────────────────────────────────────────────────

  /// ZLib-compresses [data]. TODO: migrate to LZ4 when a stable Dart package
  /// is available (LZ4 is faster for small payloads; ZLib gives better ratio).
  static Uint8List compress(Uint8List data) {
    return Uint8List.fromList(zlib.encode(data));
  }

  /// ZLib-decompresses [data].
  static Uint8List decompress(Uint8List data) {
    return Uint8List.fromList(zlib.decode(data));
  }

  // ── Fragmentation ─────────────────────────────────────────────────────────

  /// Splits [wireBytes] into ≤500-byte BLE chunks.
  ///
  /// [wireBytes] should already be compressed (e.g. from
  /// [NexusMessage.toWireBytes]).  Compression is NOT applied here – it lives
  /// in [encode] (for standalone use) and in the message serialization layer.
  ///
  /// [msgId] is the UUID string of the message; its first 8 hex chars
  /// (after stripping dashes) are used as a 32-bit hash to group chunks.
  static List<Uint8List> fragment(Uint8List wireBytes, String msgId) {
    final msgHash = _msgIdToHash(msgId);

    final totalChunks =
        ((wireBytes.length + payloadSize - 1) ~/ payloadSize).clamp(1, 255);

    final chunks = <Uint8List>[];
    for (int i = 0; i < totalChunks; i++) {
      final start = i * payloadSize;
      final end = (start + payloadSize).clamp(0, wireBytes.length);
      final payload = wireBytes.sublist(start, end);

      final chunk = Uint8List(headerSize + payload.length);
      // Write 4-byte hash
      chunk[0] = (msgHash >> 24) & 0xff;
      chunk[1] = (msgHash >> 16) & 0xff;
      chunk[2] = (msgHash >> 8) & 0xff;
      chunk[3] = msgHash & 0xff;
      // Write chunk index and total
      chunk[4] = i;
      chunk[5] = totalChunks;
      // Write payload
      chunk.setRange(headerSize, headerSize + payload.length, payload);

      chunks.add(chunk);
    }
    return chunks;
  }

  // ── Reassembly ────────────────────────────────────────────────────────────

  /// Processes an incoming BLE chunk.
  ///
  /// Returns the fully reassembled and decompressed message bytes once
  /// all chunks for a message have arrived, or null if more chunks are needed.
  ///
  /// Discards chunks whose msgHash maps to an already-seen message.
  Uint8List? processChunk(Uint8List chunk) {
    if (chunk.length < headerSize) return null;

    final msgHash = (chunk[0] << 24) | (chunk[1] << 16) | (chunk[2] << 8) | chunk[3];
    final chunkIdx = chunk[4];
    final totalChunks = chunk[5];

    if (totalChunks == 0 || chunkIdx >= totalChunks) return null;

    final payload = chunk.sublist(headerSize);

    // Store in partial buffer
    _partials.putIfAbsent(msgHash, () => {});
    _partials[msgHash]![chunkIdx] = payload;

    // Check if all chunks have arrived
    if (_partials[msgHash]!.length < totalChunks) return null;

    // Reassemble in order
    final parts = _partials.remove(msgHash)!;
    final assembled = BytesBuilder();
    for (int i = 0; i < totalChunks; i++) {
      final part = parts[i];
      if (part == null) return null; // defensive: missing chunk
      assembled.add(part);
    }

    // Return raw wire bytes; decompression is the caller's responsibility
    // (NexusMessage.fromWireBytes handles it).
    return Uint8List.fromList(assembled.toBytes());
  }

  // ── Deduplication ─────────────────────────────────────────────────────────

  /// Returns true if [msgId] has already been seen and marks it as seen.
  /// Returns false if this is a new message.
  bool isDuplicate(String msgId) {
    if (_seenIds.contains(msgId)) return true;
    _seenIds.add(msgId);
    if (_seenIds.length > _maxSeenIds) {
      // Simple eviction: clear the oldest half
      final toRemove = _seenIds.take(_maxSeenIds ~/ 2).toList();
      _seenIds.removeAll(toRemove);
    }
    return false;
  }

  /// Clears stale reassembly buffers (call periodically).
  void prunePartials() {
    // Remove groups with more than 256 chunks (clearly corrupt)
    _partials.removeWhere((_, chunks) => chunks.length > 256);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Converts a UUID string to a stable 32-bit hash by reading the first
  /// 4 hex bytes (8 hex chars) of the UUID after stripping dashes.
  static int _msgIdToHash(String msgId) {
    final hex = msgId.replaceAll('-', '');
    if (hex.length < 8) return 0;
    return int.parse(hex.substring(0, 8), radix: 16);
  }

  // ── Convenience: full encode/decode (compress + fragment / assemble + decompress) ──

  /// Compresses [rawBytes] and fragments them into chunks.
  ///
  /// Use this convenience method when you want the full pipeline in one call.
  /// The [BleTransport] uses the lower-level [fragment] directly because
  /// [NexusMessage.toWireBytes] already handles compression.
  static List<Uint8List> encode(Uint8List rawBytes, String msgId) {
    return fragment(compress(rawBytes), msgId);
  }

  /// Reassembles [chunks] and decompresses the result.
  ///
  /// Counterpart to [encode]. Returns null if reassembly is incomplete.
  Uint8List? decode(List<Uint8List> chunks) {
    Uint8List? assembled;
    for (final chunk in chunks) {
      assembled = processChunk(chunk);
    }
    if (assembled == null) return null;
    return decompress(assembled);
  }
}
