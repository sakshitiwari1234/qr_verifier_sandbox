import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/qr_decoder_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Certificate Loader Test', () async {
    final certFile = File('assets/certs/root_authority.cer');
    expect(certFile.existsSync(), isTrue, reason: 'Root certificate not found');

    await QrDecoderService.initializeCertificate(certPath: certFile.path);
    print('\n SUCCESS: Root certificate parsed and RSA public key extracted cleanly!\n');
  });
}
