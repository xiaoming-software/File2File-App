import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../services/auth_controller.dart';
import '../services/chat_controller.dart';
import '../services/drive_controller.dart';
import '../services/webrpc_service.dart';

/// Keeps webrpc alive across app lifecycle (lock / background → foreground).
class WebrpcLifecycle extends StatefulWidget {
  const WebrpcLifecycle({super.key, required this.child});

  final Widget child;

  @override
  State<WebrpcLifecycle> createState() => _WebrpcLifecycleState();
}

class _WebrpcLifecycleState extends State<WebrpcLifecycle>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Only on resume. Forcing on `inactive` (Control Center, app switcher)
    // tears down a healthy callback and drops in-flight chat/NAS responses.
    final chat = context.read<ChatController>();
    final drive = context.read<DriveController>();
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      chat.setAppForeground(false);
      drive.setAppForeground(false);
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    chat.setAppForeground(true);
    drive.setAppForeground(true);
    final auth = context.read<AuthController>();
    if (!auth.isLoggedIn) {
      context.read<WebrpcService>().ensureCallbackAlive();
      return;
    }
    // Soft recover first; escalates to full Login when offline / callback dead.
    unawaited(() async {
      try {
        await auth.ensureWebrpcAlive(forceRelogin: false);
      } catch (_) {
        // Drive/chat screens still heal on their own; avoid crashing lifecycle.
      }
    }());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
