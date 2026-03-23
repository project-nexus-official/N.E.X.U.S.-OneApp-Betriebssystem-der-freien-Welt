import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/core/transport/ble/ble_message_handler.dart';

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Creates [size] bytes of pseudo-random data that ZLib cannot compress well.
///
/// Uses a quadratic congruential generator to avoid obvious patterns.
Uint8List _pseudoRandom(int size) {
  return Uint8List.fromList(
    List.generate(size, (i) => (i * 167 + i * i * 11 + 37) % 256),
  );
}

/// Valid UUIDs (all hex chars after stripping dashes).
const _uuid1 = 'aabbccdd-0011-4000-8000-000000000001';
const _uuid2 = 'deadbeef-cafe-4001-8000-000000000002';
const _uuid3 = '11223344-5566-4000-8000-000000000003';

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  group('BleMessageHandler – compression', () {
    test('compress/decompress round-trip', () {
      final original = Uint8List.fromList(utf8.encode('Hello, NEXUS Mesh! 🌍'));
      final compressed = BleMessageHandler.compress(original);
      final decompressed = BleMessageHandler.decompress(compressed);
      expect(decompressed, equals(original));
    });

    test('compressed bytes differ from input', () {
      final data = Uint8List.fromList(utf8.encode('A' * 100));
      final compressed = BleMessageHandler.compress(data);
      expect(compressed, isNot(equals(data)));
    });

    test('compression reduces size for repetitive data', () {
      final repetitive = Uint8List.fromList(utf8.encode('NEXUS' * 100));
      final compressed = BleMessageHandler.compress(repetitive);
      expect(compressed.length, lessThan(repetitive.length));
    });

    test('single byte round-trip', () {
      final data = Uint8List.fromList([0x42]);
      final rt = BleMessageHandler.decompress(BleMessageHandler.compress(data));
      expect(rt, equals(data));
    });

    test('empty bytes round-trip', () {
      final data = Uint8List(0);
      final rt = BleMessageHandler.decompress(BleMessageHandler.compress(data));
      expect(rt, equals(data));
    });
  });

  group('BleMessageHandler – fragmentation (fragment() receives pre-compressed data)', () {
    test('small payload produces exactly one chunk', () {
      // 100 bytes → 1 chunk (well under 494-byte payload limit)
      final data = Uint8List(100)..fillRange(0, 100, 0x42);
      final chunks = BleMessageHandler.fragment(data, _uuid1);
      expect(chunks.length, 1);
    });

    test('chunk has correct header layout', () {
      final data = Uint8List(100)..fillRange(0, 100, 0x01);
      final chunks = BleMessageHandler.fragment(data, _uuid1);
      final chunk = chunks.first;

      // byte 4: chunk index (0), byte 5: total chunks (1)
      expect(chunk[4], 0);
      expect(chunk[5], 1);
      // total length ≤ 500
      expect(chunk.length, lessThanOrEqualTo(BleMessageHandler.chunkSize));
    });

    test('chunk size never exceeds 500 bytes', () {
      // 5 × payloadSize = 5 × 494 = 2470 bytes → 5 chunks
      final data = Uint8List(BleMessageHandler.payloadSize * 5);
      final chunks = BleMessageHandler.fragment(data, _uuid1);
      for (final chunk in chunks) {
        expect(chunk.length, lessThanOrEqualTo(BleMessageHandler.chunkSize));
      }
    });

    test('multiple chunks: indices are 0-based and total is correct', () {
      // 3 × payloadSize bytes → exactly 3 chunks
      final data = Uint8List(BleMessageHandler.payloadSize * 3);
      final chunks = BleMessageHandler.fragment(data, _uuid1);
      expect(chunks.length, 3);

      for (int i = 0; i < chunks.length; i++) {
        expect(chunks[i][4], i);         // chunkIdx
        expect(chunks[i][5], 3);          // totalChunks
      }
    });

    test('exact payload boundary: payloadSize bytes → 1 chunk', () {
      final data = Uint8List(BleMessageHandler.payloadSize);
      final chunks = BleMessageHandler.fragment(data, _uuid1);
      expect(chunks.length, 1);
    });

    test('payloadSize + 1 bytes → 2 chunks', () {
      final data = Uint8List(BleMessageHandler.payloadSize + 1);
      final chunks = BleMessageHandler.fragment(data, _uuid1);
      expect(chunks.length, 2);
    });
  });

  group('BleMessageHandler – reassembly (processChunk returns raw wire bytes)', () {
    test('single-chunk message reassembles correctly', () {
      final handler = BleMessageHandler();
      // Compress first (as NexusMessage.toWireBytes would do)
      final wireBytes =
          BleMessageHandler.compress(Uint8List.fromList(utf8.encode('Hallo!')));
      final chunks = BleMessageHandler.fragment(wireBytes, _uuid2);

      final assembled = handler.processChunk(chunks.first);
      expect(assembled, isNotNull);

      // assembled == wireBytes → still compressed; decompress to get original
      final decompressed = BleMessageHandler.decompress(assembled!);
      expect(utf8.decode(decompressed), 'Hallo!');
    });

    test('multi-chunk message reassembles in order', () {
      final handler = BleMessageHandler();
      // Use pseudo-random data that won't compress to < payloadSize
      final raw = _pseudoRandom(BleMessageHandler.payloadSize * 3);
      // fragment() expects pre-compressed; pass raw directly (no compression)
      // so we control the size exactly
      final chunks = BleMessageHandler.fragment(raw, _uuid2);

      expect(chunks.length, greaterThan(1));

      Uint8List? result;
      for (final chunk in chunks) {
        result = handler.processChunk(chunk);
      }

      expect(result, isNotNull);
      expect(result, equals(raw));
    });

    test('multi-chunk message reassembles out of order', () {
      final handler = BleMessageHandler();
      final raw = _pseudoRandom(BleMessageHandler.payloadSize * 3);
      final chunks = BleMessageHandler.fragment(raw, _uuid3);

      expect(chunks.length, greaterThan(1));

      // Reverse the chunk order
      Uint8List? result;
      for (final chunk in chunks.reversed) {
        result = handler.processChunk(chunk);
      }

      expect(result, isNotNull);
      expect(result, equals(raw));
    });

    test('returns null while chunks are still missing', () {
      final handler = BleMessageHandler();
      final raw = Uint8List(BleMessageHandler.payloadSize * 3);
      final chunks = BleMessageHandler.fragment(raw, _uuid1);

      expect(chunks.length, 3);

      // Process only the first two chunks
      expect(handler.processChunk(chunks[0]), isNull);
      expect(handler.processChunk(chunks[1]), isNull);
    });

    test('ignores chunks shorter than header', () {
      final handler = BleMessageHandler();
      final result = handler.processChunk(Uint8List.fromList([0, 1, 2]));
      expect(result, isNull);
    });
  });

  group('BleMessageHandler – encode/decode convenience (compress + fragment / assemble + decompress)', () {
    test('encode + decode round-trip for small data', () {
      final handler = BleMessageHandler();
      final text = 'NEXUS Mesh Chat – Hallo Welt! 🌍';
      final raw = Uint8List.fromList(utf8.encode(text));

      final chunks = BleMessageHandler.encode(raw, _uuid1);
      final recovered = handler.decode(chunks);

      expect(recovered, isNotNull);
      expect(utf8.decode(recovered!), text);
    });

    test('encode + decode round-trip for arbitrary data', () {
      final handler = BleMessageHandler();
      final raw = Uint8List.fromList(utf8.encode('Hallo NEXUS Mesh! ' * 20));

      final chunks = BleMessageHandler.encode(raw, _uuid2);
      expect(chunks, isNotEmpty);

      final recovered = handler.decode(chunks);
      expect(recovered, isNotNull);
      expect(recovered, equals(raw));
    });

    test('decode returns null if chunks are incomplete (uses fragment() for guaranteed multi-chunk)', () {
      final handler = BleMessageHandler();
      // Pass raw (uncompressed) bytes > payloadSize so fragment() splits them
      final raw = Uint8List(BleMessageHandler.payloadSize * 3);
      final chunks = BleMessageHandler.fragment(raw, _uuid3);

      expect(chunks.length, greaterThan(1));

      // Provide all but the last chunk; decode assembles without decompressing
      // so pass remaining chunks through processChunk directly
      for (int i = 0; i < chunks.length - 1; i++) {
        expect(handler.processChunk(chunks[i]), isNull);
      }
    });
  });

  group('BleMessageHandler – deduplication', () {
    test('first occurrence returns false (not a duplicate)', () {
      final handler = BleMessageHandler();
      expect(handler.isDuplicate('msg-001'), isFalse);
    });

    test('second occurrence returns true (duplicate)', () {
      final handler = BleMessageHandler();
      handler.isDuplicate('msg-001');
      expect(handler.isDuplicate('msg-001'), isTrue);
    });

    test('different IDs are not duplicates of each other', () {
      final handler = BleMessageHandler();
      handler.isDuplicate('msg-001');
      expect(handler.isDuplicate('msg-002'), isFalse);
    });

    test('marks and recalls many IDs correctly', () {
      final handler = BleMessageHandler();
      final ids = List.generate(100, (i) => 'msg-${i.toString().padLeft(4, '0')}');

      // Mark all as seen
      for (final id in ids) {
        expect(handler.isDuplicate(id), isFalse);
      }
      // All should now be duplicates
      for (final id in ids) {
        expect(handler.isDuplicate(id), isTrue);
      }
    });
  });
}
