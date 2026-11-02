import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'image_qr_reader.dart';
import 'qr_decoder_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    home: QrVerificationScreen(),
    debugShowCheckedModeBanner: false,
  ));
}

class QrVerificationScreen extends StatefulWidget {
  const QrVerificationScreen({super.key});

  @override
  State<QrVerificationScreen> createState() => _QrVerificationScreenState();
}

class _QrVerificationScreenState extends State<QrVerificationScreen>
    with SingleTickerProviderStateMixin {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
  );

  bool _isProcessing = false;
  String _statusMessage = 'Align QR code inside the box';
  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    QrDecoderService.initializeCertificate();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _animController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _processPayload(Uint8List payloadBytes) async {
    if (_isProcessing) return;

    setState(() {
      _isProcessing = true;
      _statusMessage = 'Validating digital signature...';
    });

    // Provide immediate physical haptic feedback
    HapticFeedback.mediumImpact();
    await _controller.stop();

    final result = await QrDecoderService.decodeAndVerify(payloadBytes);
    if (!mounted) return;

    await _showResultModal(result);

    setState(() {
      _isProcessing = false;
      _statusMessage = 'Align QR code inside the box';
    });
    await _controller.start();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_isProcessing) return;
    final barcode = capture.barcodes.firstOrNull;
    if (barcode == null) return;

    Uint8List? payload = barcode.rawBytes;
    if (payload == null && barcode.rawValue != null) {
      payload = Uint8List.fromList(barcode.rawValue!.codeUnits);
    }

    if (payload != null && payload.isNotEmpty) {
      _processPayload(payload);
    }
  }

  Future<void> _pickImageFromGallery() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;

    setState(() {
      _isProcessing = true;
      _statusMessage = 'Extracting QR from image...';
    });

    try {
      final decodedBytes = await ImageQrReader.decodeQrFile(file.path);
      if (decodedBytes != null) {
        _processPayload(decodedBytes);
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not find a valid QR pattern in selected image.'),
            backgroundColor: Colors.redAccent,
          ),
        );
        setState(() {
          _isProcessing = false;
          _statusMessage = 'Align QR code inside the box';
        });
      }
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _statusMessage = 'Error reading file: $e';
      });
    }
  }

  Future<void> _showResultModal(VerifiedIdentity result) {
    return showModalBottomSheet(
      context: context,
      isDismissible: false,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _VerificationResultCard(result: result),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scanAreaSize = MediaQuery.of(context).size.width * 0.75;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text(
          'Offline Identity Verifier',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on, color: Colors.white),
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            icon: const Icon(Icons.photo_library_outlined, color: Colors.white),
            tooltip: 'Pick from Gallery',
            onPressed: _pickImageFromGallery,
          ),
        ],
        backgroundColor: Colors.black,
        elevation: 0,
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),

          // Darkened background overlay with transparent viewport
          ColorFiltered(
            colorFilter: ColorFilter.mode(
              Colors.black.withOpacity(0.65),
              BlendMode.srcOut,
            ),
            child: Stack(
              children: [
                Container(
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    backgroundBlendMode: BlendMode.dstOut,
                  ),
                ),
                Center(
                  child: Container(
                    width: scanAreaSize,
                    height: scanAreaSize,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Corner brackets around scanner box
          Center(
            child: Container(
              width: scanAreaSize,
              height: scanAreaSize,
              decoration: BoxDecoration(
                border: Border.all(
                  color: _isProcessing ? Colors.amberAccent : Colors.tealAccent,
                  width: 2.5,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: AnimatedBuilder(
                animation: _animController,
                builder: (context, child) {
                  return CustomPaint(
                    painter: _LaserPainter(
                      progress: _animController.value,
                      color: _isProcessing ? Colors.amberAccent : Colors.tealAccent,
                    ),
                  );
                },
              ),
            ),
          ),

          // Live scanning indicator pill
          Positioned(
            bottom: 40,
            left: 24,
            right: 24,
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1E).withOpacity(0.9),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_isProcessing)
                        const Padding(
                          padding: EdgeInsets.only(right: 10),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.amberAccent,
                            ),
                          ),
                        )
                      else
                        const Padding(
                          padding: EdgeInsets.only(right: 10),
                          child: Icon(Icons.qr_code_scanner, color: Colors.tealAccent, size: 18),
                        ),
                      Text(
                        _statusMessage,
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: _pickImageFromGallery,
                  icon: const Icon(Icons.image, color: Colors.white70, size: 16),
                  label: const Text('Pick QR from Gallery', style: TextStyle(color: Colors.white70, fontSize: 13)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LaserPainter extends CustomPainter {
  final double progress;
  final Color color;

  _LaserPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height * progress;
    final paint = Paint()
      ..color = color.withOpacity(0.8)
      ..strokeWidth = 2.0
      ..shader = LinearGradient(
        colors: [color.withOpacity(0.0), color, color.withOpacity(0.0)],
      ).createShader(Rect.fromLTWH(0, y, size.width, 2));

    canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
  }

  @override
  bool shouldRepaint(covariant _LaserPainter oldDelegate) => true;
}

class _VerificationResultCard extends StatelessWidget {
  final VerifiedIdentity result;

  const _VerificationResultCard({required this.result});

  @override
  Widget build(BuildContext context) {
    final isSuccess = result.isValid;

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      decoration: const BoxDecoration(
        color: Color(0xFF18181A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          Icon(
            isSuccess ? Icons.verified_rounded : Icons.cancel_rounded,
            color: isSuccess ? Colors.tealAccent : Colors.redAccent,
            size: 64,
          ),
          const SizedBox(height: 12),
          Text(
            isSuccess ? 'Cryptographically Verified' : 'Verification Rejected',
            style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            isSuccess
                ? 'RSA-256 Signature verified against authority root certificate.'
                : (result.failureReason ?? 'Digital signature validation failed.'),
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
          ),
          const SizedBox(height: 20),

          // Verification Details Badge
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isSuccess
                  ? Colors.tealAccent.withOpacity(0.08)
                  : Colors.redAccent.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSuccess
                    ? Colors.tealAccent.withOpacity(0.2)
                    : Colors.redAccent.withOpacity(0.2),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isSuccess ? Icons.lock_outline : Icons.lock_open,
                  color: isSuccess ? Colors.tealAccent : Colors.redAccent,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isSuccess ? 'Signature Matched' : 'Integrity Mismatch',
                        style: TextStyle(
                          color: isSuccess ? Colors.tealAccent : Colors.redAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        isSuccess
                            ? 'Root Certificate: assets/certs/root_authority.cer'
                            : 'Issuer signature does not match root public key',
                        style: TextStyle(color: Colors.grey.shade400, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          if (isSuccess) ...[
            const SizedBox(height: 20),
            if (result.photoBytes != null)
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.tealAccent, width: 2),
                ),
                child: ClipOval(
                  child: Image.memory(
                    result.photoBytes!,
                    width: 72,
                    height: 72,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            _infoRow('Reference ID', result.referenceId ?? 'CONFIRMED'),
            _infoRow('Name', result.name ?? 'Verified Subject'),
            if (result.dateOfBirth != null) _infoRow('DOB', result.dateOfBirth!),
            if (result.gender != null) _infoRow('Gender', result.gender!),
          ],

          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: isSuccess ? Colors.tealAccent.shade700 : Colors.white12,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Scan Another Code', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
