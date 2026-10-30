import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLanguagePreference { system, zh, en }

class LocaleController extends ChangeNotifier {
  LocaleController._();
  static final LocaleController instance = LocaleController._();

  static const _prefsKey = 'app_language_pref_v1';

  AppLanguagePreference preference = AppLanguagePreference.system;
  Locale _resolved = const Locale('en');

  Locale get locale => _resolved;

  String get languageCode => _resolved.languageCode;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    preference = switch (raw) {
      'zh' => AppLanguagePreference.zh,
      'en' => AppLanguagePreference.en,
      _ => AppLanguagePreference.system,
    };
    _recompute();
  }

  Future<void> setPreference(AppLanguagePreference pref) async {
    if (preference == pref &&
        _resolved == resolveLocale(pref, WidgetsBinding.instance.platformDispatcher.locale)) {
      // Still notify so UI can refresh if AppL10n was stale.
      _recompute();
      notifyListeners();
      return;
    }
    preference = pref;
    _recompute();
    // Notify immediately so UI switches without waiting for disk I/O.
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      switch (pref) {
        AppLanguagePreference.system => 'system',
        AppLanguagePreference.zh => 'zh',
        AppLanguagePreference.en => 'en',
      },
    );
  }

  void _recompute() {
    _resolved = resolveLocale(
      preference,
      WidgetsBinding.instance.platformDispatcher.locale,
    );
  }

  /// Follow system when pref=system: zh* → Chinese, anything else → English.
  static Locale resolveLocale(AppLanguagePreference pref, Locale device) {
    switch (pref) {
      case AppLanguagePreference.zh:
        return const Locale('zh');
      case AppLanguagePreference.en:
        return const Locale('en');
      case AppLanguagePreference.system:
        if (device.languageCode.toLowerCase() == 'zh') {
          return const Locale('zh');
        }
        return const Locale('en');
    }
  }

  /// Cycle zh ↔ en for the login-page toggle (does not use system).
  Future<void> toggleZhEn() async {
    final next = languageCode == 'zh'
        ? AppLanguagePreference.en
        : AppLanguagePreference.zh;
    await setPreference(next);
  }
}
