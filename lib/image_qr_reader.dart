import 'dart:typed_data';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';

class ImageQrReader {
  static final BarcodeScanner _scanner = BarcodeScanner(
    formats: [BarcodeFormat.qrCode],
  );

  static Future<Uint8List?> decodeQrFile(String filePath) async {
    try {
      final inputImage = InputImage.fromFilePath(filePath);
      final barcodes = await _scanner.processImage(inputImage);

      for (final barcode in barcodes) {
        if (barcode.rawBytes != null && barcode.rawBytes!.isNotEmpty) {
          return barcode.rawBytes;
        }
        if (barcode.rawValue != null) {
          return Uint8List.fromList(barcode.rawValue!.codeUnits);
        }
      }
      return null;
    } catch (e) {
      return null;
    }
  }
}