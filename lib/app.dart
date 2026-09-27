import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/auth_controller.dart';
import 'theme/app_theme.dart';
import 'widgets/voice_call_overlay.dart';

class File2FileApp extends StatelessWidget {
  const File2FileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'File2File',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      builder: (context, child) {
        return VoiceCallOverlay(child: child ?? const SizedBox.shrink());
      },
      home: Consumer<AuthController>(
        builder: (context, auth, _) {
          if (auth.bootstrapping) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (auth.isLoggedIn) {
            return const HomeScreen();
          }
          return const LoginScreen();
        },
      ),
    );
  }
}
