import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nexus_oneapp/core/transport/nexus_message.dart';

/// Creates a minimal in-memory JPEG image of [width] × [height].
Uint8List _createTestImage(int width, int height) {
  final image = img.Image(width: width, height: height);
  // Fill with a solid color so encoding is deterministic
  img.fill(image, color: img.ColorRgb8(100, 150, 200));
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}

/// Replicates the resize logic from chat_provider.dart (_processImage).
(String, String, int, int) processImage(Uint8List rawBytes) {
  final original = img.decodeImage(rawBytes)!;

  const maxSize = 1024;
  final img.Image resized;
  if (original.width >= original.height) {
    resized = original.width > maxSize
        ? img.copyResize(original, width: maxSize)
        : original;
  } else {
    resized = original.height > maxSize
        ? img.copyResize(original, height: maxSize)
        : original;
  }

  const thumbSize = 200;
  final img.Image thumb;
  if (resized.width >= resized.height) {
    thumb = resized.width > thumbSize
        ? img.copyResize(resized, width: thumbSize)
        : resized;
  } else {
    thumb = resized.height > thumbSize
        ? img.copyResize(resized, height: thumbSize)
        : resized;
  }

  final jpegFull = img.encodeJpg(resized, quality: 75);
  final jpegThumb = img.encodeJpg(thumb, quality: 75);

  return (
    base64Encode(jpegFull),
    base64Encode(jpegThumb),
    resized.width,
    resized.height,
  );
}

void main() {
  group('Image processing – resize and compression', () {
    test('landscape image wider than 1024px is resized to width=1024', () {
      final bytes = _createTestImage(2000, 800);
      final (_, __, width, height) = processImage(bytes);

      expect(width, 1024);
      expect(height, lessThan(800)); // proportionally scaled
    });

    test('portrait image taller than 1024px is resized to height=1024', () {
      final bytes = _createTestImage(800, 2000);
      final (_, __, width, height) = processImage(bytes);

      expect(height, 1024);
      expect(width, lessThan(800));
    });

    test('image smaller than 1024px is not upscaled', () {
      final bytes = _createTestImage(400, 300);
      final (_, __, width, height) = processImage(bytes);

      expect(width, 400);
      expect(height, 300);
    });

    test('thumbnail is at most 200px on longest side (landscape)', () {
      final bytes = _createTestImage(2000, 1000);
      final (_, thumbB64, _, __) = processImage(bytes);

      final thumbBytes = base64Decode(thumbB64);
      final thumb = img.decodeImage(thumbBytes)!;
      expect(thumb.width, lessThanOrEqualTo(200));
    });

    test('thumbnail is at most 200px on longest side (portrait)', () {
      final bytes = _createTestImage(600, 1200);
      final (_, thumbB64, _, __) = processImage(bytes);

      final thumbBytes = base64Decode(thumbB64);
      final thumb = img.decodeImage(thumbBytes)!;
      expect(thumb.height, lessThanOrEqualTo(200));
    });

    test('output is valid base64-encoded JPEG', () {
      final bytes = _createTestImage(800, 600);
      final (fullB64, thumbB64, _, __) = processImage(bytes);

      // Should not throw when decoding
      final fullBytes = base64Decode(fullB64);
      final thumbBytes = base64Decode(thumbB64);

      final fullDecoded = img.decodeImage(fullBytes);
      final thumbDecoded = img.decodeImage(thumbBytes);

      expect(fullDecoded, isNotNull);
      expect(thumbDecoded, isNotNull);
    });

    test('aspect ratio is preserved after resize', () {
      final bytes = _createTestImage(2400, 1600); // 3:2
      final (_, __, width, height) = processImage(bytes);

      // Width should be 1024, height ~682 (1024 * 1600/2400 ≈ 682.67)
      expect(width, 1024);
      // Allow ±1 px for rounding
      expect(height, closeTo(683, 2));
    });
  });

  group('NexusMessage – image type', () {
    test('image message serializes and deserializes correctly', () {
      final msg = NexusMessage.create(
        fromDid: 'did:key:sender',
        toDid: 'did:key:recipient',
        type: NexusMessageType.image,
        body: 'base64imagedata',
        metadata: {
          'width': 1024,
          'height': 768,
          'thumbnail': 'base64thumbdata',
        },
      );

      final json = msg.toJson();
      expect(json['type'], 'image');
      expect(json['meta'], isNotNull);
      expect(json['meta']['width'], 1024);

      final restored = NexusMessage.fromJson(json);
      expect(restored.type, NexusMessageType.image);
      expect(restored.metadata?['width'], 1024);
      expect(restored.metadata?['thumbnail'], 'base64thumbdata');
      expect(restored.body, 'base64imagedata');
    });

    test('image message round-trips through wire bytes', () {
      final msg = NexusMessage.create(
        fromDid: 'did:key:sender',
        toDid: 'did:key:recipient',
        type: NexusMessageType.image,
        body: base64Encode(Uint8List.fromList([1, 2, 3, 4, 5])),
        metadata: {'width': 100, 'height': 100, 'thumbnail': 'abc'},
      );

      final wire = msg.toWireBytes();
      final restored = NexusMessage.fromWireBytes(wire);

      expect(restored.id, msg.id);
      expect(restored.type, NexusMessageType.image);
      expect(restored.metadata?['width'], 100);
    });

    test('text message has null metadata', () {
      final msg = NexusMessage.create(
        fromDid: 'did:key:sender',
        toDid: 'did:key:recipient',
        body: 'Hello!',
      );

      expect(msg.metadata, isNull);
      final restored = NexusMessage.fromJson(msg.toJson());
      expect(restored.metadata, isNull);
    });

    test('withSignature preserves metadata', () {
      final msg = NexusMessage.create(
        fromDid: 'did:key:sender',
        toDid: 'did:key:recipient',
        type: NexusMessageType.image,
        body: 'imagedata',
        metadata: {'width': 512},
      );

      final signed = msg.withSignature('fakesig');
      expect(signed.metadata?['width'], 512);
      expect(signed.signature, 'fakesig');
    });

    test('withIncrementedHopCount preserves metadata', () {
      final msg = NexusMessage.create(
        fromDid: 'did:key:sender',
        toDid: 'did:key:recipient',
        type: NexusMessageType.image,
        body: 'imagedata',
        metadata: {'width': 512},
      );

      final hopped = msg.withIncrementedHopCount();
      expect(hopped.metadata?['width'], 512);
      expect(hopped.hopCount, 1);
    });
  });
}
