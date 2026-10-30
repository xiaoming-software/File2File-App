import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file2file/l10n/app_l10n.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/account.dart';

class PortalApi {
  PortalApi({http.Client? client}) : _client = client ?? http.Client();

  static const apiBase = 'https://api.webrpc.cn/webrpc';
  static const registerTimeout = Duration(seconds: 45);

  final http.Client _client;
  final _rng = Random.secure();

  Future<AutoRegisterResult> autoRegister({
    void Function(String step, String message)? onProgress,
  }) async {
    final deadline = DateTime.now().add(registerTimeout);
    final email = _genEmail();
    final portalPassword = _genPassword();
    debugPrint('[portal] autoRegister start email=$email');

    try {
      onProgress?.call('register', 'creating-account');
      await _register(email, portalPassword);

      onProgress?.call('login', 'signing-in');
      final session = await _login(email, portalPassword);

      onProgress?.call('tokens', 'claiming-tokens');
      final rows = await _waitForTokens(session, deadline);
      final first = rows.first;

      onProgress?.call('done', 'complete');
      debugPrint('[portal] autoRegister ok token=${first.token}');
      return AutoRegisterResult(
        email: email,
        portalPassword: portalPassword,
        deviceToken: first.token,
        devicePassword: first.password,
        expireTimeMs: first.expireTimeMs,
      );
    } catch (e, st) {
      debugPrint('[portal] autoRegister failed: $e');
      debugPrint('[portal] $st');
      rethrow;
    }
  }

  /// 作废设备 Token（需 token + 密码双因子），对应后台 {@code /revokeToken}。
  Future<void> revokeToken({
    required String token,
    required String password,
  }) async {
    final t = token.trim();
    final p = password.trim();
    if (t.isEmpty || p.isEmpty) {
      throw PortalException('token 和密码不能为空'.tr);
    }
    debugPrint('[portal] revokeToken token=$t');
    await _postJson(
      Uri.parse('$apiBase/revokeToken'),
      {'token': t, 'password': p},
    );
    debugPrint('[portal] revokeToken ok');
  }

  Future<void> _register(String email, String password) async {
    await _postJson(
      Uri.parse('$apiBase/register'),
      {'email': email, 'password': password},
    );
  }

  Future<String> _login(String email, String password) async {
    final json = await _postJson(
      Uri.parse('$apiBase/login'),
      {'email': email, 'password': password},
    );
    final data = json['data'];
    final token = data is Map ? ('${data['token'] ?? ''}').trim() : '';
    if (token.isEmpty) {
      throw PortalException('登录成功但未返回会话，请重试'.tr);
    }
    return token;
  }

  Future<List<_DeviceTokenRow>> _fetchTokens(String sessionToken) async {
    final json = await _postJson(
      Uri.parse('$apiBase/myTokens'),
      {
        'page': 1,
        'pageSize': 20,
        'keyword': '',
        'searchMode': 'orderNo',
      },
      sessionToken: sessionToken,
    );
    final data = json['data'];
    final list = data is Map ? (data['list'] as List?) : null;
    final rows = <_DeviceTokenRow>[];
    for (final item in list ?? const []) {
      if (item is! Map) continue;
      final token = ('${item['token'] ?? ''}').trim();
      final password = ('${item['password'] ?? ''}').trim();
      final expire = (item['expireTime'] as num?)?.toInt() ?? 0;
      if (token.isNotEmpty && password.isNotEmpty) {
        rows.add(_DeviceTokenRow(token, password, expire));
      }
    }
    return rows;
  }

  Future<List<_DeviceTokenRow>> _waitForTokens(
    String sessionToken,
    DateTime deadline,
  ) async {
    while (true) {
      final rows = await _fetchTokens(sessionToken);
      if (rows.isNotEmpty) return rows;
      if (DateTime.now().isAfter(deadline)) {
        throw PortalException('Token 尚未就绪，请稍后在控制台查看或重试'.tr);
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  Future<Map<String, dynamic>> _postJson(
    Uri url,
    Map<String, dynamic> body, {
    String? sessionToken,
  }) async {
    final headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      'Accept': 'application/json',
    };
    if (sessionToken != null) {
      headers['token'] = sessionToken;
    }
    late http.Response resp;
    try {
      resp = await _client
          .post(url, headers: headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw PortalException('连接 webrpc 超时，请检查网络后重试'.tr);
    } on SocketException catch (e) {
      throw PortalException(AppL10n.current.fill(r'网络不可用：${e.message}', {r'${e.message}': e.message}));
    } on HandshakeException catch (e) {
      throw PortalException(AppL10n.current.fill(r'安全连接失败：${e.message}', {r'${e.message}': e.message}));
    } on http.ClientException catch (e) {
      throw PortalException(AppL10n.current.fill(r'网络请求失败：${e.message}', {r'${e.message}': e.message}));
    }
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is! Map) {
        throw const FormatException('not-a-map');
      }
      json = Map<String, dynamic>.from(decoded);
    } catch (_) {
      throw PortalException(
        AppL10n.current.fill(r'服务器返回异常（HTTP ${resp.statusCode}）', {r'${resp.statusCode}': '${resp.statusCode}'}),
      );
    }
    final status = json['status'];
    final okStatus = status == 200 || status == '200';
    if (resp.statusCode >= 400 || !okStatus) {
      throw PortalException(_apiError(json));
    }
    return json;
  }

  String _apiError(Map<String, dynamic> json) {
    final msg =
        (json['errorMsg'] ?? json['error_msg'] ?? json['message'] ?? '')
            .toString()
            .trim();
    return msg.isEmpty ? '请求失败，请稍后重试'.tr : msg;
  }

  String _genEmail() => 'f2f${_randChars(12, _alnumLower)}@auto.webrpc';

  String _genPassword() => _randChars(16, _alnum);

  String _randChars(int len, String alphabet) {
    final buf = StringBuffer();
    for (var i = 0; i < len; i++) {
      buf.write(alphabet[_rng.nextInt(alphabet.length)]);
    }
    return buf.toString();
  }

  static const _alnumLower = 'abcdefghijklmnopqrstuvwxyz0123456789';
  static const _alnum =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
}

class _DeviceTokenRow {
  const _DeviceTokenRow(this.token, this.password, this.expireTimeMs);
  final String token;
  final String password;
  final int expireTimeMs;
}

class PortalException implements Exception {
  PortalException(this.message);
  final String message;
  @override
  String toString() => message;
}
