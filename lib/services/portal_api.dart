import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../models/account.dart';

class PortalApi {
  PortalApi({http.Client? client}) : _client = client ?? http.Client();

  static const apiBase = 'https://api.webrpc.cn/webrpc';
  static const registerTimeout = Duration(seconds: 30);

  final http.Client _client;
  final _rng = Random.secure();

  Future<AutoRegisterResult> autoRegister({
    void Function(String step, String message)? onProgress,
  }) async {
    final deadline = DateTime.now().add(registerTimeout);
    final email = _genEmail();
    final portalPassword = _genPassword();

    onProgress?.call('register', 'creating-account');
    await _register(email, portalPassword);

    onProgress?.call('login', 'signing-in');
    final session = await _login(email, portalPassword);

    onProgress?.call('tokens', 'claiming-tokens');
    final rows = await _waitForTokens(session, deadline);
    final first = rows.first;

    onProgress?.call('done', 'complete');
    return AutoRegisterResult(
      email: email,
      portalPassword: portalPassword,
      deviceToken: first.token,
      devicePassword: first.password,
      expireTimeMs: first.expireTimeMs,
    );
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
    final token = json['data']?['token'] as String?;
    if (token == null || token.isEmpty) {
      throw PortalException('login-token-missing');
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
    final list = (json['data']?['list'] as List?) ?? const [];
    final rows = <_DeviceTokenRow>[];
    for (final item in list) {
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
        throw PortalException('tokens-not-ready');
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
    };
    if (sessionToken != null) {
      headers['token'] = sessionToken;
    }
    final resp = await _client
        .post(url, headers: headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 15));
    Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw PortalException('parse-error');
    }
    if (resp.statusCode >= 400 || json['status'] != 200) {
      throw PortalException(_apiError(json));
    }
    return json;
  }

  String _apiError(Map<String, dynamic> json) {
    return (json['errorMsg'] ?? json['error_msg'] ?? 'request-failed').toString();
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
