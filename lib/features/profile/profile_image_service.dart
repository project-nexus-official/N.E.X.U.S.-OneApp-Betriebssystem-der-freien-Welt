import 'dart:io';
import 'dart:typed_data';

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
    return file.path;
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
