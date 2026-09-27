import 'package:flutter/foundation.dart';

import '../models/account.dart';
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
  String? errorMessage;
  String? progressMessage;
  SavedAccount? account;
  List<SavedAccount> savedAccounts = const [];

  bool get isLoggedIn =>
      account != null && _webrpc.state == WebrpcLoginState.online;

  int get registerRemaining => _store.quickRegisterRemaining();

  Future<void> bootstrap() async {
    bootstrapping = true;
    notifyListeners();
    try {
      savedAccounts = await _store.loadAccounts();
      final last = await _store.lastAccount();
      if (last != null && last.passphrase.trim().isNotEmpty) {
        try {
          await _loginInternal(last, remember: true);
        } catch (e) {
          errorMessage = '自动登录失败: $e';
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
      errorMessage = '本机一键注册次数已用完，请改用已有 Token 登录';
      notifyListeners();
      return null;
    }
    SavedAccount? created;
    await _runBusy(() async {
      progressMessage = '正在创建账户…';
      notifyListeners();
      final result = await _portal.autoRegister(
        onProgress: (step, message) {
          progressMessage = switch (step) {
            'register' => '正在创建账户…',
            'login' => '正在登录控制台…',
            'tokens' => '正在领取 Token…',
            _ => '完成',
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
    await _drive.unbind();
    await _chat.unbind();
    await _webrpc.logout();
    if (clearSaved && account != null) {
      await _store.removeAccount(account!.token);
      savedAccounts = await _store.loadAccounts();
    }
    account = null;
    errorMessage = null;
    progressMessage = null;
    notifyListeners();
  }

  Future<void> _loginInternal(SavedAccount saved, {required bool remember}) async {
    if (saved.token.trim().isEmpty) {
      throw StateError('请填写 Token');
    }
    if (saved.password.trim().isEmpty) {
      throw StateError('请填写 Token 密码');
    }
    if (saved.passphrase.trim().isEmpty) {
      throw StateError('请设置认证口令（不能为空）');
    }
    errorMessage = null;
    progressMessage = '正在连接 webrpc…';
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
      errorMessage = e.toString();
      rethrow;
    } finally {
      busy = false;
      progressMessage = null;
      notifyListeners();
    }
  }
}
