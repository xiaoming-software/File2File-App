import 'package:file2file/l10n/app_l10n.dart';
import 'package:file2file/l10n/locale_controller.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_controller.dart';
import '../services/chat_controller.dart';
import '../services/drive_controller.dart';
import '../theme/app_theme.dart';
import 'drives_tab.dart';
import 'sessions_tab.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  Future<void> _logout() async {
    final clear = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('退出登录'.tr),
        content: Text('是否同时忘记本机保存的该账号？'.tr),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('仅退出'.tr),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('退出并忘记'.tr),
          ),
        ],
      ),
    );
    if (clear == null || !mounted) return;
    final auth = context.read<AuthController>();
    final chat = context.read<ChatController>();
    final drive = context.read<DriveController>();
    await drive.unbind();
    await chat.unbind();
    await auth.logout(clearSaved: clear);
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除账号与本机数据'.tr),
        content: Text(
          '将作废当前 webrpc 设备 Token（之后无法再用该 Token 登录），'.tr
          + r'并清除本机保存的账号、会话与网盘缓存。\n\n'.tr
          + '此操作不可撤销。webrpc 控制台邮箱账号不会一并删除；'.tr
          + '如需处理请前往 webrpc.cn。'.tr,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消'.tr),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC62828),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('确认删除'.tr),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final auth = context.read<AuthController>();
    try {
      await auth.deleteAccountAndLocalData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('账号已删除，本机数据已清除'.tr)),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(auth.errorMessage ?? '删除失败，请稍后重试'.tr)),
      );
    }
  }

  Future<void> _openAccountMenu() async {
    final auth = context.read<AuthController>();
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final localeCtrl = ctx.read<LocaleController>();
        return ListenableBuilder(
          listenable: localeCtrl,
          builder: (ctx, _) {
            final pref = localeCtrl.preference;
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                    child: Text(
                      '账号'.tr,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.ink,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                    child: Text(
                      '语言'.tr,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.ink.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                  ListTile(
                    dense: true,
                    title: Text('跟随系统'.tr),
                    trailing: pref == AppLanguagePreference.system
                        ? const Icon(Icons.check, color: AppTheme.accent)
                        : null,
                    onTap: () =>
                        localeCtrl.setPreference(AppLanguagePreference.system),
                  ),
                  ListTile(
                    dense: true,
                    title: const Text('中文'),
                    trailing: pref == AppLanguagePreference.zh
                        ? const Icon(Icons.check, color: AppTheme.accent)
                        : null,
                    onTap: () =>
                        localeCtrl.setPreference(AppLanguagePreference.zh),
                  ),
                  ListTile(
                    dense: true,
                    title: const Text('English'),
                    trailing: pref == AppLanguagePreference.en
                        ? const Icon(Icons.check, color: AppTheme.accent)
                        : null,
                    onTap: () =>
                        localeCtrl.setPreference(AppLanguagePreference.en),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.logout),
                    title: Text('退出登录'.tr),
                    subtitle: Text('断开连接，可选是否忘记本机账号'.tr),
                    enabled: !auth.busy,
                    onTap: () => Navigator.pop(ctx, 'logout'),
                  ),
                  ListTile(
                    leading: const Icon(
                      Icons.delete_forever_outlined,
                      color: Color(0xFFC62828),
                    ),
                    title: Text(
                      '删除账号与本机数据'.tr,
                      style: const TextStyle(
                        color: Color(0xFFC62828),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text('作废当前 Token，并清除本机会话与缓存'.tr),
                    enabled: !auth.busy,
                    onTap: () => Navigator.pop(ctx, 'delete'),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
    if (!mounted || action == null) return;
    if (action == 'logout') {
      await _logout();
    } else if (action == 'delete') {
      await _deleteAccount();
    }
  }

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
          title: Text(_index == 0 ? '会话'.tr : '网盘'.tr),
          actions: [
            TextButton(
              onPressed: auth.busy ? null : _openAccountMenu,
              child: Text('账号'.tr),
            ),
          ],
        ),
        body: Column(
          children: [
            if (auth.busy && auth.progressMessage != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    auth.progressMessage!,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.accent,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: IndexedStack(
                index: _index,
                children: const [
                  SessionsTab(),
                  DrivesTab(),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: [
            NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline),
              selectedIcon: Icon(Icons.chat_bubble),
              label: '会话'.tr,
            ),
            NavigationDestination(
              icon: Icon(Icons.cloud_outlined),
              selectedIcon: Icon(Icons.cloud),
              label: '网盘'.tr,
            ),
          ],
        ),
      ),
    );
  }
}
