import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Handles picking, resizing (max 512 × 512 px), and saving profile images.
class ProfileImageService {
  static final ProfileImageService instance = ProfileImageService._();
  ProfileImageService._();

  final _picker = ImagePicker();

  Future<String?> pickFromCamera() => _pick(ImageSource.camera);
  Future<String?> pickFromGallery() => _pick(ImageSource.gallery);

  Future<String?> _pick(ImageSource source) async {
    final xFile = await _picker.pickImage(source: source);
    if (xFile == null) return null;
    final bytes = await xFile.readAsBytes();
    return processAndSave(bytes);
  }

  /// Decodes [bytes], scales down to max 512 × 512 (maintaining aspect ratio),
  /// encodes as JPEG at 85 % quality, and saves to the app documents directory.
  ///
  /// Returns the local file path, or null if decoding fails.
  Future<String?> processAndSave(Uint8List bytes) async {
    final image = img.decodeImage(bytes);
    if (image == null) return null;

    final resized = _resize(image, 512);
    final jpegBytes = Uint8List.fromList(img.encodeJpg(resized, quality: 85));

    final dir = await getApplicationDocumentsDirectory();
    final fileName = 'profile_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final file = File(p.join(dir.path, fileName));
    await file.writeAsBytes(jpegBytes);
    debugPrint('[ProfileImage] Saved profile image: ${file.path}');
    return file.path;
  }

  /// On Android the absolute app-documents path can differ across installs.
  /// This method reconstructs the path using the current documents dir so
  /// the file can always be found by its basename.
  ///
  /// Returns the resolved path if the file exists, null otherwise.
  Future<String?> resolveLocalPath(String? storedPath) async {
    if (storedPath == null) return null;

    // Try the stored path first.
    if (await File(storedPath).exists()) return storedPath;

    // Reconstruct using the current documents directory + just the filename.
    try {
      final dir = await getApplicationDocumentsDirectory();
      final fileName = p.basename(storedPath);
      final resolved = p.join(dir.path, fileName);
      if (await File(resolved).exists()) {
        debugPrint('[ProfileImage] Resolved stale path: $storedPath → $resolved');
        return resolved;
      }
    } catch (_) {}

    debugPrint('[ProfileImage] Image file not found: $storedPath');
    return null;
  }

  /// Reads a local profile image file, compresses it to max 200×200 px at
  /// 70 % JPEG quality, and returns a `data:image/jpeg;base64,...` string
  /// suitable for embedding in a Nostr Kind-0 `picture` field (~20–30 KB).
  ///
  /// Returns null if the file doesn't exist or decoding fails.
  Future<String?> toBase64DataUrl(String? localPath) async {
    debugPrint('[ProfileImage] toBase64DataUrl called: path=$localPath');
    final resolved = await resolveLocalPath(localPath);
    if (resolved == null) {
      debugPrint('[ProfileImage] toBase64DataUrl: file not found, returning null');
      return null;
    }
    try {
      final bytes = await File(resolved).readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) {
        debugPrint('[ProfileImage] toBase64DataUrl: decodeImage returned null');
        return null;
      }
      final resized = _resize(image, 200);
      final jpeg = Uint8List.fromList(img.encodeJpg(resized, quality: 70));
      final result = 'data:image/jpeg;base64,${base64Encode(jpeg)}';
      debugPrint('[ProfileImage] toBase64DataUrl: base64 length=${result.length}');
      return result;
    } catch (e) {
      debugPrint('[ProfileImage] toBase64DataUrl error: $e');
      return null;
    }
  }

  /// Decodes a base64 data URL or raw base64 string into bytes,
  /// resizes to max 200×200, saves to documents dir, returns local path.
  ///
  /// Returns null on any error.
  Future<String?> saveFromBase64(String base64Data) async {
    try {
      final raw = base64Data.startsWith('data:')
          ? base64Data.split(',').last
          : base64Data;
      final bytes = base64Decode(raw);
      final image = img.decodeImage(bytes);
      if (image == null) {
        debugPrint('[ProfileImage] saveFromBase64: decodeImage returned null');
        return null;
      }
      final resized = _resize(image, 200);
      final jpeg = Uint8List.fromList(img.encodeJpg(resized, quality: 85));
      final dir = await getApplicationDocumentsDirectory();
      final fileName = 'avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final file = File(p.join(dir.path, fileName));
      await file.writeAsBytes(jpeg);
      debugPrint('[ProfileImage] saveFromBase64: saved to ${file.path}');
      return file.path;
    } catch (e) {
      debugPrint('[ProfileImage] saveFromBase64 error: $e');
      return null;
    }
  }

  /// Deletes a previously saved profile image file.
  Future<void> deleteImage(String? path) async {
    if (path == null) return;
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  /// Resizes [image] so that neither dimension exceeds [maxSize],
  /// preserving aspect ratio.
  static img.Image _resize(img.Image image, int maxSize) {
    final w = image.width;
    final h = image.height;
    if (w <= maxSize && h <= maxSize) return image;

    if (w >= h) {
      return img.copyResize(image,
          width: maxSize,
          height: (h * maxSize / w).round(),
          interpolation: img.Interpolation.linear);
    } else {
      return img.copyResize(image,
          width: (w * maxSize / h).round(),
          height: maxSize,
          interpolation: img.Interpolation.linear);
    }
  }
}
