/// Drive / NAS application-layer protocol (App + Desktop + mywebdisk).
///
/// Logical drive session (peerToken) is independent of webrpc rpcSessionId.
/// Transport may reconnect; queued transfers resume via offset when
/// peer advertises caps:["driveResume"].
///
/// Control types (avoid chat 20–22 and videocall 12):
/// - 23 drive ping `{ t }`
/// - 24 drive pong `{ t }`
///
/// Hello extras: `driveProto: 1`, `caps` includes `"driveResume"` (+ chat caps).
///
/// NAS JSON extras:
/// - putFile / getFile: optional `offset` (bytes already transferred)
/// - backPut / backFile: may echo `offset` / `size` / `ok`
library;

class DriveProtocol {
  DriveProtocol._();

  static const int ping = 23;
  static const int pong = 24;

  static const int driveProto = 2;
  static const String capResume = 'driveResume';
  static const String capRange = 'driveRange';

  static const Duration heartbeatInterval = Duration(seconds: 15);
  static const int heartbeatMissLimit = 3;

  static List<String> localCaps() => const [capResume, capRange];

  static bool capsIncludeResume(dynamic caps) {
    if (caps is! List) return false;
    for (final c in caps) {
      if ('$c' == capResume) return true;
    }
    return false;
  }

  static bool capsIncludeRange(dynamic caps) {
    if (caps is! List) return false;
    for (final c in caps) {
      if ('$c' == capRange) return true;
    }
    return false;
  }

  static Map<String, dynamic> helloExtras() => {
        'driveProto': driveProto,
        'caps': localCaps(),
      };

  static Map<String, dynamic> pingPayload(int t) => {'t': t};

  static Map<String, dynamic> pongPayload(int t) => {'t': t};
}
