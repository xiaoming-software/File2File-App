import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/account.dart';
import '../services/auth_controller.dart';
import '../theme/app_theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static final _webrpcUri = Uri.parse('https://www.webrpc.cn/');

  final _tokenCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _passphraseCtrl = TextEditingController();
  late final TapGestureRecognizer _webrpcTap;
  bool _obscurePassword = true;
  bool _remember = true;

  @override
  void initState() {
    super.initState();
    _webrpcTap = TapGestureRecognizer()..onTap = _openWebrpc;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthController>();
      final last = auth.savedAccounts.isEmpty ? null : auth.savedAccounts.first;
      if (last != null) {
        _tokenCtrl.text = last.token;
        _passwordCtrl.text = last.password;
        _passphraseCtrl.text = last.passphrase;
      }
    });
  }

  @override
  void dispose() {
    _webrpcTap.dispose();
    _tokenCtrl.dispose();
    _passwordCtrl.dispose();
    _passphraseCtrl.dispose();
    super.dispose();
  }

  Future<void> _openWebrpc() async {
    final ok = await launchUrl(_webrpcUri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开浏览器')),
      );
    }
  }

  Future<void> _submitLogin() async {
    final auth = context.read<AuthController>();
    if (_passphraseCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请设置认证口令（不能为空）')),
      );
      return;
    }
    try {
      await auth.loginWithToken(
        token: _tokenCtrl.text,
        password: _passwordCtrl.text,
        passphrase: _passphraseCtrl.text,
        remember: _remember,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(auth.errorMessage ?? '登录失败')),
      );
    }
  }

  Future<void> _oneClick() async {
    final auth = context.read<AuthController>();
    try {
      final created = await auth.oneClickRegister();
      if (!mounted) return;
      if (created != null) {
        _tokenCtrl.text = created.token;
        _passwordCtrl.text = created.password;
        _passphraseCtrl.clear();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Token 已领取，请设置认证口令后登录')),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(auth.errorMessage ?? '一键注册失败')),
      );
    }
  }

  Future<void> _loginSaved(SavedAccount a) async {
    final auth = context.read<AuthController>();
    _tokenCtrl.text = a.token;
    _passwordCtrl.text = a.password;
    _passphraseCtrl.text = a.passphrase;
    if (a.passphrase.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该账号未设置认证口令，请填写后再登录')),
      );
      return;
    }
    try {
      await auth.loginSaved(a);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(auth.errorMessage ?? '登录失败')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final showSaved = auth.savedAccounts.length > 1;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        body: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFFE8F2ED),
                Color(0xFFF5F7F9),
                Color(0xFFE6EEF3),
              ],
            ),
          ),
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: constraints.maxHeight - 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _BrandBlock(webrpcTap: _webrpcTap),
                        const SizedBox(height: 22),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 400),
                          child: _LoginCard(
                            tokenCtrl: _tokenCtrl,
                            passwordCtrl: _passwordCtrl,
                            passphraseCtrl: _passphraseCtrl,
                            obscurePassword: _obscurePassword,
                            remember: _remember,
                            busy: auth.busy,
                            registerRemaining: auth.registerRemaining,
                            errorMessage: auth.errorMessage,
                            progressMessage: auth.progressMessage,
                            onToggleObscure: () => setState(
                              () => _obscurePassword = !_obscurePassword,
                            ),
                            onRemember: (v) => setState(() => _remember = v),
                            onLogin: _submitLogin,
                            onOneClick: _oneClick,
                          ),
                        ),
                        if (showSaved) ...[
                          const SizedBox(height: 18),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 400),
                            child: _SavedAccounts(
                              accounts: auth.savedAccounts,
                              enabled: !auth.busy,
                              onTap: _loginSaved,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _BrandBlock extends StatelessWidget {
  const _BrandBlock({required this.webrpcTap});
  final TapGestureRecognizer webrpcTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: AppTheme.accent.withValues(alpha: 0.2),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Image.asset(
            'assets/icon/app_icon.png',
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const ColoredBox(
              color: AppTheme.accent,
              child: Center(
                child: Text(
                  'F2F',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'File2File',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.6,
            height: 1.1,
            color: AppTheme.ink,
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text.rich(
            TextSpan(
              style: TextStyle(
                fontSize: 13.5,
                height: 1.4,
                color: AppTheme.ink.withValues(alpha: 0.55),
              ),
              children: [
                const TextSpan(text: '基于'),
                TextSpan(
                  text: 'webrpc',
                  style: const TextStyle(
                    color: AppTheme.accent,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.underline,
                    decorationColor: AppTheme.accent,
                  ),
                  recognizer: webrpcTap,
                ),
                const TextSpan(text: ' p2p 的文件传输和网盘管理'),
              ],
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

class _LoginCard extends StatelessWidget {
  const _LoginCard({
    required this.tokenCtrl,
    required this.passwordCtrl,
    required this.passphraseCtrl,
    required this.obscurePassword,
    required this.remember,
    required this.busy,
    required this.registerRemaining,
    required this.errorMessage,
    required this.progressMessage,
    required this.onToggleObscure,
    required this.onRemember,
    required this.onLogin,
    required this.onOneClick,
  });

  final TextEditingController tokenCtrl;
  final TextEditingController passwordCtrl;
  final TextEditingController passphraseCtrl;
  final bool obscurePassword;
  final bool remember;
  final bool busy;
  final int registerRemaining;
  final String? errorMessage;
  final String? progressMessage;
  final VoidCallback onToggleObscure;
  final ValueChanged<bool> onRemember;
  final VoidCallback onLogin;
  final VoidCallback onOneClick;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 0,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.ink.withValues(alpha: 0.06)),
          boxShadow: [
            BoxShadow(
              color: AppTheme.ink.withValues(alpha: 0.05),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _LabeledField(
              label: 'Token',
              controller: tokenCtrl,
              hint: '粘贴设备 Token',
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            _LabeledField(
              label: 'Token 密码',
              controller: passwordCtrl,
              obscure: obscurePassword,
              textInputAction: TextInputAction.next,
              suffix: IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: onToggleObscure,
                icon: Icon(
                  obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 18,
                  color: AppTheme.ink.withValues(alpha: 0.4),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _LabeledField(
              label: '认证口令',
              controller: passphraseCtrl,
              hint: '对方连接你时需填写',
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => onLogin(),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(
                  height: 20,
                  width: 20,
                  child: Checkbox(
                    value: remember,
                    onChanged: busy ? null : (v) => onRemember(v ?? false),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    activeColor: AppTheme.accent,
                    side: BorderSide(
                      color: AppTheme.ink.withValues(alpha: 0.25),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    onTap: busy ? null : () => onRemember(!remember),
                    child: Text(
                      '记住账号，下次自动登录',
                      style: TextStyle(
                        fontSize: 13,
                        color: AppTheme.ink.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (errorMessage != null) ...[
              const SizedBox(height: 10),
              Text(
                errorMessage!,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFC62828),
                  height: 1.3,
                ),
              ),
            ],
            if (progressMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                progressMessage!,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.accent,
                  height: 1.3,
                ),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: busy ? null : onLogin,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      '登录',
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: busy || registerRemaining <= 0 ? null : onOneClick,
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.accent,
                minimumSize: const Size.fromHeight(40),
              ),
              child: Text(
                registerRemaining <= 0
                    ? '一键注册次数已用完'
                    : '没有 Token？一键注册（剩 $registerRemaining 次）',
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LabeledField extends StatelessWidget {
  const _LabeledField({
    required this.label,
    required this.controller,
    this.hint,
    this.obscure = false,
    this.suffix,
    this.textCapitalization = TextCapitalization.none,
    this.textInputAction,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool obscure;
  final Widget? suffix;
  final TextCapitalization textCapitalization;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: AppTheme.ink.withValues(alpha: 0.68),
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
          textCapitalization: textCapitalization,
          textInputAction: textInputAction,
          onSubmitted: onSubmitted,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: AppTheme.ink,
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              color: AppTheme.ink.withValues(alpha: 0.28),
              fontWeight: FontWeight.w400,
            ),
            suffixIcon: suffix,
            filled: true,
            fillColor: const Color(0xFFF7F9FA),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                color: AppTheme.ink.withValues(alpha: 0.06),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                color: AppTheme.accent.withValues(alpha: 0.55),
                width: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SavedAccounts extends StatelessWidget {
  const _SavedAccounts({
    required this.accounts,
    required this.enabled,
    required this.onTap,
  });

  final List<SavedAccount> accounts;
  final bool enabled;
  final ValueChanged<SavedAccount> onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '已保存账号',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: AppTheme.ink.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(height: 8),
        ...accounts.map((a) {
          final short = a.token.length <= 18
              ? a.token
              : '${a.token.substring(0, 8)}…${a.token.substring(a.token.length - 4)}';
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              color: Colors.white.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                onTap: enabled ? () => onTap(a) : null,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      Icon(
                        Icons.account_circle_outlined,
                        size: 22,
                        color: AppTheme.accent.withValues(alpha: 0.85),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              short,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.ink,
                              ),
                            ),
                            Text(
                              a.autoRegistered ? '一键注册账号' : '手动 Token',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: AppTheme.ink.withValues(alpha: 0.42),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: AppTheme.ink.withValues(alpha: 0.28),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }),
      ],
    );
  }
}
