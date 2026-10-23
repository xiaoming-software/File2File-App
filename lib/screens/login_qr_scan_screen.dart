import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../utils/webrpc_qr.dart';

export '../utils/webrpc_qr.dart' show LoginQrCredentials;

/// Full-screen QR scanner for official portal login QR.
class LoginQrScanScreen extends StatefulWidget {
  const LoginQrScanScreen({super.key});

  @override
  State<LoginQrScanScreen> createState() => _LoginQrScanScreenState();
}

class _LoginQrScanScreenState extends State<LoginQrScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
    formats: const [BarcodeFormat.qrCode],
  );

  bool _handled = false;
  bool _torchOn = false;
  DateTime? _lastTipAt;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _tip(String message) {
    final now = DateTime.now();
    final cool =
        _lastTipAt == null ||
        now.difference(_lastTipAt!) > const Duration(seconds: 2);
    if (!cool || !mounted) return;
    _lastTipAt = now;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled || !mounted) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      final parsed = parseWebrpcQr(raw);
      if (parsed.kind == WebrpcQrKind.peer) {
        _tip('这是连接码，请在新建会话/网盘时扫');
        return;
      }
      if (parsed.kind != WebrpcQrKind.login || parsed.login == null) {
        _tip('无效的登录二维码');
        return;
      }
      _handled = true;
      HapticFeedback.mediumImpact();
      await _controller.stop();
      if (!mounted) return;
      Navigator.of(context).pop(parsed.login);
      return;
    }
  }

  Future<void> _toggleTorch() async {
    await _controller.toggleTorch();
    if (!mounted) return;
    setState(() => _torchOn = !_torchOn);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final cut = (size.shortestSide * 0.68).clamp(220.0, 280.0);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),
          CustomPaint(
            painter: _ScanOverlayPainter(cutOutSize: cut),
            child: const SizedBox.expand(),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close, color: Colors.white, size: 26),
                    tooltip: '关闭',
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: _toggleTorch,
                    icon: Icon(
                      _torchOn ? Icons.flash_on : Icons.flash_off,
                      color: Colors.white,
                      size: 24,
                    ),
                    tooltip: '手电筒',
                  ),
                ],
              ),
            ),
          ),
          Align(
            alignment: const Alignment(0, 0.42),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                '将官网登录二维码放入框内\n即可自动扫描',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.88),
                  fontSize: 14.5,
                  height: 1.45,
                  fontWeight: FontWeight.w500,
                  shadows: const [
                    Shadow(blurRadius: 8, color: Colors.black54),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanOverlayPainter extends CustomPainter {
  _ScanOverlayPainter({required this.cutOutSize});

  final double cutOutSize;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.42);
    final rect = Rect.fromCenter(
      center: center,
      width: cutOutSize,
      height: cutOutSize,
    );

    final overlay = Path()..addRect(Offset.zero & size);
    final hole = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(12)));
    final mask = Path.combine(PathOperation.difference, overlay, hole);
    canvas.drawPath(
      mask,
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );

    const corner = 22.0;
    const stroke = 3.5;
    final paint = Paint()
      ..color = const Color(0xFF00C853)
      ..strokeWidth = stroke
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(corner, 0), paint);
    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(0, corner), paint);
    canvas.drawLine(rect.topRight, rect.topRight + const Offset(-corner, 0), paint);
    canvas.drawLine(rect.topRight, rect.topRight + const Offset(0, corner), paint);
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft + const Offset(corner, 0), paint);
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft + const Offset(0, -corner), paint);
    canvas.drawLine(rect.bottomRight, rect.bottomRight + const Offset(-corner, 0), paint);
    canvas.drawLine(rect.bottomRight, rect.bottomRight + const Offset(0, -corner), paint);
  }

  @override
  bool shouldRepaint(covariant _ScanOverlayPainter oldDelegate) =>
      oldDelegate.cutOutSize != cutOutSize;
}
