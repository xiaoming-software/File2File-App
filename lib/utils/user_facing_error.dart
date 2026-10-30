import 'package:file2file/l10n/app_l10n.dart';

/// Strip Dart exception wrappers and map technical webrpc text to short UX copy.
String userFacingError(
  Object? error, {
  String? fallback,
}) {
  final fb = fallback ?? '操作失败，请重试'.tr;
  if (error == null) return fb;

  var s = error is String ? error : error.toString();
  s = s.replaceFirst(
    RegExp(
      r'^(Bad state|Exception|StateError|ArgumentError|Error|TimeoutException):\s*',
      caseSensitive: false,
    ),
    '',
  );
  s = s.replaceFirst(RegExp(r'^Instance of \w+:\s*'), '');
  // Nested "Exception: Bad state: …"
  s = s.replaceFirst(
    RegExp(
      r'^(Bad state|Exception|StateError|Error):\s*',
      caseSensitive: false,
    ),
    '',
  );
  s = s.trim();
  if (s.isEmpty) return fb;

  final lower = s.toLowerCase();

  if (lower.contains('opensession=0') ||
      s.contains('连接失败（OpenSession=0）')) {
    return '无法连接对端，请确认对方在线、Token 与口令正确后重试'.tr;
  }
  if (s.contains('握手失败')) {
    return '握手失败，请稍后重试'.tr;
  }
  if (s.contains('请先登录') || s.contains('当前未登录') || s.contains('webrpc 未登录')) {
    return '账号未就绪，请稍候或重新登录'.tr;
  }
  if (s.contains('自己连自己')) {
    return '不能连接自己的 Token'.tr;
  }
  if (s.contains('登录超时') || lower.contains('timeout')) {
    return '网络超时，请检查网络后重试'.tr;
  }
  if (s.contains('连接已断开') || s.contains('连接已重置')) {
    return '连接已断开，请重新连接'.tr;
  }
  if (s.contains('网盘未连接') || s.contains('未连接')) {
    return '尚未连接，请先连接后再试'.tr;
  }
  if (s.contains('回调') && (s.contains('无效') || s.contains('未建立'))) {
    return '连接通道异常，正在恢复，请稍后重试'.tr;
  }
  if (lower.contains('connection refused') ||
      lower.contains('socket') ||
      s.contains('Connection refused')) {
    return '网络异常，请稍后重试'.tr;
  }

  // Keep short; drop long stack-looking tails.
  final nl = s.indexOf('\n');
  if (nl > 0) s = s.substring(0, nl).trim();
  if (s.length > 120) {
    s = '${s.substring(0, 117)}…';
  }
  return s;
}
