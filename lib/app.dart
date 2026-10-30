import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'l10n/app_l10n.dart';
import 'l10n/locale_controller.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/auth_controller.dart';
import 'theme/app_theme.dart';
import 'widgets/voice_call_overlay.dart';
import 'widgets/webrpc_lifecycle.dart';

class File2FileApp extends StatelessWidget {
  const File2FileApp({super.key});

  @override
  Widget build(BuildContext context) {
    final localeController = context.watch<LocaleController>();
    final locale = localeController.locale;
    AppL10n.current = AppL10n(locale);

    return MaterialApp(
      title: 'File2File',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      locale: locale,
      supportedLocales: const [
        Locale('zh'),
        Locale('en'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        AppL10n.current = AppL10n(locale);
        final body = WebrpcLifecycle(
          child: VoiceCallOverlay(child: child ?? const SizedBox.shrink()),
        );
        return Consumer<AuthController>(
          builder: (context, auth, _) {
            if (!auth.webrpcRecovering) return body;
            return Stack(
              fit: StackFit.expand,
              children: [
                body,
                const Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: _WebrpcRecoveringBanner(),
                ),
              ],
            );
          },
        );
      },
      // Force remount of home subtree when language changes so every `.tr` refreshes.
      home: KeyedSubtree(
        key: ValueKey<String>('lang-${locale.languageCode}'),
        child: Consumer<AuthController>(
          builder: (context, auth, _) {
            if (auth.bootstrapping) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            if (auth.isLoggedIn) {
              return const HomeScreen();
            }
            return LoginScreen(
              key: ValueKey<int>(auth.loginFormGeneration),
              formGeneration: auth.loginFormGeneration,
            );
          },
        ),
      ),
    );
  }
}

class _WebrpcRecoveringBanner extends StatelessWidget {
  const _WebrpcRecoveringBanner();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1565C0),
      elevation: 2,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '正在恢复连接…'.tr,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
