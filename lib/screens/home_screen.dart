import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_controller.dart';
import '../services/chat_controller.dart';
import '../services/drive_controller.dart';
import 'drives_tab.dart';
import 'sessions_tab.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFE8F1F5), Color(0xFFF7F3EB)],
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(_index == 0 ? '会话' : '网盘'),
          actions: [
            IconButton(
              tooltip: '退出登录',
              onPressed: () async {
                final clear = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('退出登录'),
                    content: const Text('是否同时忘记本机保存的该账号？'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('仅退出'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('退出并忘记'),
                      ),
                    ],
                  ),
                );
                if (clear == null || !context.mounted) return;
                final chat = context.read<ChatController>();
                final drive = context.read<DriveController>();
                await drive.unbind();
                await chat.unbind();
                await auth.logout(clearSaved: clear);
              },
              icon: const Icon(Icons.logout),
            ),
          ],
        ),
        body: IndexedStack(
          index: _index,
          children: const [
            SessionsTab(),
            DrivesTab(),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline),
              selectedIcon: Icon(Icons.chat_bubble),
              label: '会话',
            ),
            NavigationDestination(
              icon: Icon(Icons.cloud_outlined),
              selectedIcon: Icon(Icons.cloud),
              label: '网盘',
            ),
          ],
        ),
      ),
    );
  }
}
