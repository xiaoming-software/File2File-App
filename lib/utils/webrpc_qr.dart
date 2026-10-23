import 'dart:convert';

/// Official portal login QR: `{"token","password"}`.
class LoginQrCredentials {
  const LoginQrCredentials({required this.token, required this.password});
  final String token;
  final String password;
}

/// Peer connect QR (chat / drive): `{"token","permission"}`.
class PeerQrCredentials {
  const PeerQrCredentials({required this.token, required this.permission});
  final String token;
  final String permission;
}

enum WebrpcQrKind { login, peer, invalid }

class WebrpcQrParse {
  const WebrpcQrParse._(this.kind, {this.login, this.peer});

  final WebrpcQrKind kind;
  final LoginQrCredentials? login;
  final PeerQrCredentials? peer;

  factory WebrpcQrParse.invalid() =>
      const WebrpcQrParse._(WebrpcQrKind.invalid);

  factory WebrpcQrParse.login(LoginQrCredentials c) =>
      WebrpcQrParse._(WebrpcQrKind.login, login: c);

  factory WebrpcQrParse.peer(PeerQrCredentials c) =>
      WebrpcQrParse._(WebrpcQrKind.peer, peer: c);
}

String encodeLoginQr({required String token, required String password}) =>
    jsonEncode({'token': token, 'password': password});

String encodePeerQr({required String token, required String permission}) =>
    jsonEncode({'token': token, 'permission': permission});

LoginQrCredentials? parseLoginQrPayload(String raw) {
  final parsed = parseWebrpcQr(raw);
  return parsed.kind == WebrpcQrKind.login ? parsed.login : null;
}

/// Classify portal login QR vs peer-connect QR.
WebrpcQrParse parseWebrpcQr(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return WebrpcQrParse.invalid();
  try {
    final decoded = jsonDecode(text);
    if (decoded is! Map) return WebrpcQrParse.invalid();
    final map = decoded.map((k, v) => MapEntry('$k', v));
    final token = ('${map['token'] ?? ''}').trim();
    if (token.isEmpty) return WebrpcQrParse.invalid();

    final hasPassword = map.containsKey('password');
    final hasPermission = map.containsKey('permission');
    final password = ('${map['password'] ?? ''}').trim();
    final permission = ('${map['permission'] ?? ''}').trim();

    // Official login QR: password present, no permission field.
    if (hasPassword && !hasPermission) {
      if (password.isEmpty) return WebrpcQrParse.invalid();
      return WebrpcQrParse.login(
        LoginQrCredentials(token: token, password: password),
      );
    }

    // Peer connect QR (permission may be empty string).
    if (hasPermission || !hasPassword) {
      return WebrpcQrParse.peer(
        PeerQrCredentials(token: token, permission: permission),
      );
    }

    return WebrpcQrParse.invalid();
  } catch (_) {
    return WebrpcQrParse.invalid();
  }
}
