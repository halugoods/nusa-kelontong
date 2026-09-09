import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Kompresi gambar sebelum upload — resize ke max width 800px + JPEG quality 80.
/// Dipakai untuk mengurangi ukuran payload upload produk/karyawan ke cloud.
class ImageCompressService {
  static const int maxWidth = 800;
  static const int quality = 80;

  /// Kompres file gambar dari path. Return bytes asli jika decode gagal.
  static Future<Uint8List> compress(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      return compressBytes(bytes);
    } catch (e) {
      debugPrint('[ImageCompress] compress error: $e');
      return File(path).readAsBytes();
    }
  }

  /// Kompres dari bytes. Return bytes asli jika decode gagal.
  static Future<Uint8List> compressBytes(Uint8List bytes) async {
    try {
      final image = img.decodeImage(bytes);
      if (image == null) return bytes;

      // Resize jika terlalu lebar
      final resized = image.width > maxWidth
          ? img.copyResize(image, width: maxWidth)
          : image;

      // Encode sebagai JPEG dengan quality yang ditentukan
      return Uint8List.fromList(img.encodeJpg(resized, quality: quality));
    } catch (e) {
      debugPrint('[ImageCompress] compressBytes error: $e');
      return bytes;
    }
  }
}
