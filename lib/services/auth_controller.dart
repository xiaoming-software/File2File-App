import 'package:file2file/l10n/app_l10n.dart';
import 'package:flutter/foundation.dart';

import '../models/account.dart';
import '../utils/user_facing_error.dart';
import 'app_debug_log.dart';
import 'auth_store.dart';
import 'chat_controller.dart';
import 'drive_controller.dart';
import 'portal_api.dart';
import 'webrpc_service.dart';

class AuthController extends ChangeNotifier {
  AuthController({
    required this._store,
    required this._webrpc,
    required this._chat,
    required this._drive,
    PortalApi? portal,
  }) : _portal = portal ?? PortalApi();

  final AuthStore _store;
  final WebrpcService _webrpc;
  final ChatController _chat;
  final DriveController _drive;
  final PortalApi _portal;

  bool bootstrapping = true;
  bool busy = false;
  /// True while silently recovering webrpc Login (keep HomeShell, no login page).
  bool webrpcRecovering = false;
  String? errorMessage;
  String? progressMessage;
  SavedAccount? account;
  List<SavedAccount> savedAccounts = const [];

  /// Bumped when login form fields must be cleared (退出并忘记 / 删本机账号 / 注销).
  int loginFormGeneration = 0;

  /// Single-flight for [ensureWebrpcAlive] so resume + screen heal don't stack Logins.
  Future<void>? _ensureAliveInFlight;
  bool _pendingForceRelogin = false;

  /// Has a signed-in account shell. Stays true during webrpc reconnect so the
  /// UI is not ripped to [LoginScreen] when Login briefly drops offline.
  bool get isLoggedIn => account != null;

  bool get isWebrpcOnline =>
      account != null && _webrpc.state == WebrpcLoginState.online;

  int get registerRemaining => _store.quickRegisterRemaining();

  void _bumpLoginFormClear() {
    loginFormGeneration++;
  }

  Future<void> bootstrap() async {
    bootstrapping = true;
    notifyListeners();
    try {
      // One-shot device test helper: flutter run --dart-define=RESET_QUICK_REGISTER=true
      if (const bool.fromEnvironment('RESET_QUICK_REGISTER')) {
        await _store.resetQuickRegisterCount();
        debugPrint('[auth] RESET_QUICK_REGISTER: quick register count cleared');
      }
      savedAccounts = await _store.loadAccounts();
      final last = await _store.lastAccount();
      if (last != null && last.passphrase.trim().isNotEmpty) {
        try {
          await _loginInternal(last, remember: true);
        } catch (e) {
          errorMessage = AppL10n.current.fill(r'自动登录失败: $e', {r'$e': '$e'});
          account = null;
        }
      }
    } finally {
      bootstrapping = false;
      notifyListeners();
    }
  }

  Future<void> loginWithToken({
    required String token,
    required String password,
    String passphrase = '',
    bool remember = true,
  }) async {
    final saved = SavedAccount(
      token: token.trim(),
      password: password.trim(),
      passphrase: passphrase.trim(),
    );
    await _runBusy(() => _loginInternal(saved, remember: remember));
  }

  Future<void> loginSaved(SavedAccount saved) async {
    await _runBusy(() => _loginInternal(saved, remember: true));
  }

  /// Portal 一键领 Token，不登录 webrpc；用户需再填认证口令后点登录。
  Future<SavedAccount?> oneClickRegister() async {
    if (_store.quickRegisterRemaining() <= 0) {
      errorMessage = '本机一键注册次数已用完，请改用已有 Token 登录'.tr;
      notifyListeners();
      throw PortalException(errorMessage!);
    }
    SavedAccount? created;
    await _runBusy(() async {
      progressMessage = '正在创建账户…'.tr;
      notifyListeners();
      final result = await _portal.autoRegister(
        onProgress: (step, message) {
          progressMessage = switch (step) {
            'register' => '正在创建账户…'.tr,
            'login' => '正在登录控制台…'.tr,
            'tokens' => '正在领取 Token…'.tr,
            _ => '完成'.tr,
          };
          notifyListeners();
        },
      );
      await _store.bumpQuickRegisterCount();
      created = SavedAccount(
        token: result.deviceToken,
        password: result.devicePassword,
        email: result.email,
        portalPassword: result.portalPassword,
        expireTimeMs: result.expireTimeMs,
        autoRegistered: true,
        passphrase: '',
      );
      // 仅预填账号信息，等用户设置认证口令后再登录。
      await _store.upsertAccount(created!);
      savedAccounts = await _store.loadAccounts();
      progressMessage = null;
    });
    return created;
  }

  Future<void> logout({bool clearSaved = false}) async {
    final leaving = account;
    await _drive.unbind();
    await _chat.unbind();
    await _webrpc.logout();
    if (clearSaved && leaving != null) {
      await _store.removeAccount(leaving.token);
      savedAccounts = await _store.loadAccounts();
      _bumpLoginFormClear();
    }
    account = null;
    errorMessage = null;
    progressMessage = null;
    notifyListeners();
  }

  /// 仅删除本机已保存的账号凭证（不调用 webrpc 作废）。
  Future<void> forgetSavedAccount(String token) async {
    final t = token.trim();
    if (t.isEmpty) return;
    await _store.removeAccount(t);
    savedAccounts = await _store.loadAccounts();
    if (account?.token.trim() == t) {
      account = null;
    }
    _bumpLoginFormClear();
    notifyListeners();
  }

  /// 作废当前 webrpc 设备 Token，并清除本机账号与缓存数据。
  Future<void> deleteAccountAndLocalData() async {
    final current = account;
    if (current == null) {
      throw PortalException('当前未登录'.tr);
    }
    await _runBusy(() async {
      progressMessage = '正在注销 Token…'.tr;
      notifyListeners();
      await _portal.revokeToken(
        token: current.token,
        password: current.password,
      );
      progressMessage = '正在清除本机数据…'.tr;
      notifyListeners();
      await _drive.wipeLocalData();
      await _chat.wipeLocalData();
      await _webrpc.logout();
      await _store.removeAccount(current.token);
      savedAccounts = await _store.loadAccounts();
      account = null;
      _bumpLoginFormClear();
      progressMessage = null;
    });
  }

  /// Resume / heal helper.
  ///
  /// Full Login when:
  /// - [forceRelogin] (caller saw OpenSession=0 / list timeout / zombie session), or
  /// - native LoginStatus==0, or
  /// - LoginStatus==1 but callback port is dead (Connection refused after suspend).
  /// Keeps the home shell ([isLoggedIn]); shows recovering banner (non-blocking).
  /// Concurrent callers share one in-flight recovery (single-flight).
  Future<void> ensureWebrpcAlive({bool forceRelogin = false}) async {
    if (forceRelogin) _pendingForceRelogin = true;
    // Coalesce concurrent callers onto one recovery; honor any force flag.
    while (true) {
      final existing = _ensureAliveInFlight;
      if (existing != null) {
        await existing;
        if (!_pendingForceRelogin) return;
      }
      final force = _pendingForceRelogin || forceRelogin;
      _pendingForceRelogin = false;
      final run = _ensureWebrpcAliveBody(forceRelogin: force);
      _ensureAliveInFlight = run;
      try {
        await run;
      } finally {
        if (identical(_ensureAliveInFlight, run)) {
          _ensureAliveInFlight = null;
        }
      }
      if (!_pendingForceRelogin) return;
    }
  }

  Future<void> _ensureWebrpcAliveBody({bool forceRelogin = false}) async {
    final saved = account;
    if (saved == null) {
      throw StateError('当前未登录'.tr);
    }

    var mustLogin = forceRelogin || !_webrpc.nativeLoginAlive;

    if (!mustLogin) {
      if (!_webrpc.isOnline) {
        _webrpc.resyncOnlineFromNative();
      }
      if (_webrpc.isOnline) {
        final callbackOk = await _webrpc.probeCallbackHealthy();
        if (callbackOk) return;
        AppDebugLog.log(
          'ensureWebrpcAlive: callback dead (status=${_webrpc.callbackStatus}) '
          '→ full Login despite LoginStatus=1',
        );
      } else {
        AppDebugLog.log(
          'ensureWebrpcAlive: dart offline after resync '
          '(nativeLogin=${_webrpc.nativeLoginAlive}) → full Login',
        );
      }
      mustLogin = true;
    }

    webrpcRecovering = true;
    progressMessage = '正在恢复连接…'.tr;
    notifyListeners();
    try {
      // Yield a frame so the banner paints before native Login work.
      await Future<void>.delayed(Duration.zero);
      await _loginInternal(saved, remember: true);
    } finally {
      webrpcRecovering = false;
      progressMessage = null;
      notifyListeners();
    }
  }

  Future<void> _loginInternal(SavedAccount saved, {required bool remember}) async {
    if (saved.token.trim().isEmpty) {
      throw StateError('请填写 Token'.tr);
    }
    if (saved.password.trim().isEmpty) {
      throw StateError('请填写 Token 密码'.tr);
    }
    if (saved.passphrase.trim().isEmpty) {
      throw StateError('请设置认证口令（不能为空）'.tr);
    }
    errorMessage = null;
    progressMessage ??= '正在连接 webrpc…'.tr;
    notifyListeners();
    await _webrpc.login(
      token: saved.token,
      password: saved.password,
      permission: saved.passphrase,
    );
    account = saved;
    if (remember) {
      await _store.upsertAccount(saved);
      savedAccounts = await _store.loadAccounts();
    }
    // Same-owner rebind is a no-op so recovery Login does not wipe sessions.
    await _chat.bindOwner(saved.token);
    await _drive.bindOwner(saved.token);
    progressMessage = null;
  }

  Future<void> _runBusy(Future<void> Function() action) async {
    if (busy) return;
    busy = true;
    errorMessage = null;
    notifyListeners();
    try {
      await action();
    } catch (e) {
      errorMessage =
          e is PortalException ? e.message : userFacingError(e);
      rethrow;
    } finally {
      busy = false;
      progressMessage = null;
      notifyListeners();
    }
  }
}
