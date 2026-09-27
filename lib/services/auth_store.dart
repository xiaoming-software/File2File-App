import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/account.dart';

class AuthStore {
  AuthStore._(this._prefs, this._secure);

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  static const _accountsKey = 'saved_accounts_v1';
  static const _lastTokenKey = 'last_token_v1';
  static const _quickRegisterCountKey = 'quick_register_count_v1';
  static const quickRegisterLimit = 2;

  static Future<AuthStore> open() async {
    final prefs = await SharedPreferences.getInstance();
    const secure = FlutterSecureStorage(
      aOptions: AndroidOptions(),
    );
    return AuthStore._(prefs, secure);
  }

  Future<List<SavedAccount>> loadAccounts() async {
    final raw = await _secure.read(key: _accountsKey);
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map>()
          .map((e) => SavedAccount.fromJson(Map<String, dynamic>.from(e)))
          .where((a) => a.token.isNotEmpty && a.password.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> upsertAccount(SavedAccount account) async {
    final accounts = await loadAccounts();
    accounts.removeWhere((a) => a.token == account.token);
    accounts.insert(0, account);
    await _secure.write(
      key: _accountsKey,
      value: jsonEncode(accounts.map((a) => a.toJson()).toList()),
    );
    await _prefs.setString(_lastTokenKey, account.token);
  }

  Future<void> removeAccount(String token) async {
    final accounts = await loadAccounts();
    accounts.removeWhere((a) => a.token == token);
    await _secure.write(
      key: _accountsKey,
      value: jsonEncode(accounts.map((a) => a.toJson()).toList()),
    );
    if (_prefs.getString(_lastTokenKey) == token) {
      await _prefs.remove(_lastTokenKey);
    }
  }

  String? lastToken() => _prefs.getString(_lastTokenKey);

  Future<SavedAccount?> lastAccount() async {
    final token = lastToken();
    if (token == null) return null;
    final accounts = await loadAccounts();
    for (final a in accounts) {
      if (a.token == token) return a;
    }
    return accounts.isEmpty ? null : accounts.first;
  }

  int quickRegisterCount() => _prefs.getInt(_quickRegisterCountKey) ?? 0;

  int quickRegisterRemaining() =>
      max(0, quickRegisterLimit - quickRegisterCount());

  Future<void> bumpQuickRegisterCount() async {
    await _prefs.setInt(_quickRegisterCountKey, quickRegisterCount() + 1);
  }
}
