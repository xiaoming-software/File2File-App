import 'package:flutter/widgets.dart';
import 'translations_en.dart';

class AppL10n {
  AppL10n(this.locale);
  final Locale locale;

  static AppL10n? _current;
  static AppL10n get current =>
      _current ?? AppL10n(const Locale('en'));
  static set current(AppL10n value) => _current = value;

  bool get isZh => locale.languageCode.toLowerCase() == 'zh';

  /// Translate a Chinese source / template string.
  String call(String source) {
    final translated = isZh ? source : (kEnTranslations[source] ?? source);
    // Templates keep Dart-style \n so they match translation keys.
    return translated.replaceAll(r'\n', '\n');
  }

  String t(String source) => call(source);

  /// Translate [template] then replace placeholders.
  ///
  /// [vars] keys should be the exact placeholder text as it appears in the
  /// Chinese template, e.g. `{r'$peerToken': peerToken}` or
  /// `{r'${uploads.length}': '${uploads.length}'}`.
  String fill(String template, Map<String, String> vars) {
    var s = t(template);
    final keys = vars.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final k in keys) {
      s = s.replaceAll(k, vars[k]!);
    }
    return s;
  }
}

extension AppL10nContext on BuildContext {
  AppL10n get l10n => AppL10n.current;
}

extension AppL10nString on String {
  String get tr => AppL10n.current.t(this);
}
