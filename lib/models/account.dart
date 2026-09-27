class SavedAccount {
  const SavedAccount({
    required this.token,
    required this.password,
    this.passphrase = '',
    this.email,
    this.portalPassword,
    this.expireTimeMs = 0,
    this.autoRegistered = false,
  });

  final String token;
  final String password;
  final String passphrase;
  final String? email;
  final String? portalPassword;
  final int expireTimeMs;
  final bool autoRegistered;

  Map<String, dynamic> toJson() => {
        'token': token,
        'password': password,
        'passphrase': passphrase,
        'email': email,
        'portalPassword': portalPassword,
        'expireTimeMs': expireTimeMs,
        'autoRegistered': autoRegistered,
      };

  factory SavedAccount.fromJson(Map<String, dynamic> json) {
    return SavedAccount(
      token: (json['token'] as String? ?? '').trim(),
      password: (json['password'] as String? ?? '').trim(),
      passphrase: (json['passphrase'] as String? ?? '').trim(),
      email: json['email'] as String?,
      portalPassword: json['portalPassword'] as String?,
      expireTimeMs: (json['expireTimeMs'] as num?)?.toInt() ?? 0,
      autoRegistered: json['autoRegistered'] as bool? ?? false,
    );
  }

  SavedAccount copyWith({
    String? token,
    String? password,
    String? passphrase,
    String? email,
    String? portalPassword,
    int? expireTimeMs,
    bool? autoRegistered,
  }) {
    return SavedAccount(
      token: token ?? this.token,
      password: password ?? this.password,
      passphrase: passphrase ?? this.passphrase,
      email: email ?? this.email,
      portalPassword: portalPassword ?? this.portalPassword,
      expireTimeMs: expireTimeMs ?? this.expireTimeMs,
      autoRegistered: autoRegistered ?? this.autoRegistered,
    );
  }
}

class AutoRegisterResult {
  const AutoRegisterResult({
    required this.email,
    required this.portalPassword,
    required this.deviceToken,
    required this.devicePassword,
    required this.expireTimeMs,
  });

  final String email;
  final String portalPassword;
  final String deviceToken;
  final String devicePassword;
  final int expireTimeMs;
}
