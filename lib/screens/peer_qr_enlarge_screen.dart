import 'package:file2file/l10n/app_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../theme/app_theme.dart';
import '../utils/webrpc_qr.dart';

/// Full-screen peer QR (WeChat-style enlarge).
class PeerQrEnlargeScreen extends StatelessWidget {
  const PeerQrEnlargeScreen({
    super.key,
    required this.token,
    required this.permission,
  });

  final String token;
  final String permission;

  @override
  Widget build(BuildContext context) {
    final payload = encodePeerQr(token: token, permission: permission);
    final size = MediaQuery.sizeOf(context);
    final qrSize = (size.shortestSide * 0.62).clamp(200.0, 280.0);

    return Scaffold(
      backgroundColor: const Color(0xFF1A1F24),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text('我的二维码'.tr),
        actions: [
          IconButton(
            tooltip: '复制连接信息'.tr,
            onPressed: () async {
              final passLine = permission.isEmpty ? '（未设置）'.tr : permission;
              await Clipboard.setData(
                ClipboardData(text: AppL10n.current.fill(r'Token：$token\n认证口令：$passLine', {r'$token': token, r'$passLine': passLine})),
              );
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('已复制 Token 和口令'.tr)),
              );
            },
            icon: const Icon(Icons.copy_all_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.25),
                        blurRadius: 28,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      QrImageView(
                        data: payload,
                        version: QrVersions.auto,
                        size: qrSize,
                        backgroundColor: Colors.white,
                        eyeStyle: const QrEyeStyle(
                          eyeShape: QrEyeShape.square,
                          color: Color(0xFF0B6E4F),
                        ),
                        dataModuleStyle: const QrDataModuleStyle(
                          dataModuleShape: QrDataModuleShape.square,
                          color: Color(0xFF12241C),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '扫一扫，加我为会话'.tr,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.ink.withValues(alpha: 0.88),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '对方在「新建会话」中扫码即可填入 Token 与口令'.tr,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.35,
                          color: AppTheme.ink.withValues(alpha: 0.48),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
