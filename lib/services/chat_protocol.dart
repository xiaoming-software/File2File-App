/// Shared chat application-layer protocol (App + Desktop).
///
/// webrpc only transports JSON frames. Delivery reliability is app-layer:
/// outbox + delivery ACK after peer persists, with optional heartbeat + read.
///
/// Numeric `type` map (existing + new):
/// - 1 hello (extended with chatProto / caps)
/// - 2 text — data `{ msgId, text, ts }` (legacy bare string still accepted)
/// - 3 / 4 file query / progress (msgId required for reliable mode)
/// - 6 / 11 voice …
/// - 7 / 8 / 9 / 12 desktop / videocall (reserved — do not reuse)
/// - 20 delivery_ack — `{ msgId }`
/// - 21 ping — `{ t }`
/// - 22 pong — `{ t }`
/// - 25 read_receipt — `{ msgIds: string[] }` (viewport-seen → read)
///
/// Caps in hello: `"ack"` (delivery), `"read"` (read receipts).
/// Peers without `"read"`: local UI keeps own messages as unread forever.
///
/// Note: plan draft used 12/13/14; Desktop already uses type 12 for videocall
/// session signal, so reliable-chat control uses 20/21/22/25 instead.
library;

class ChatProtocol {
  ChatProtocol._();

  static const int hello = 1;
  static const int text = 2;
  static const int fileQuery = 3;
  static const int fileReply = 4;
  static const int deliveryAck = 20;
  static const int ping = 21;
  static const int pong = 22;
  static const int readReceipt = 25;

  /// Current chat application protocol version advertised in hello.
  static const int chatProto = 1;

  static const String capAck = 'ack';
  static const String capRead = 'read';

  static const Duration heartbeatInterval = Duration(seconds: 15);
  static const int heartbeatMissLimit = 3;

  static List<String> localCaps() => const [capAck, capRead];

  static bool capsIncludeAck(dynamic caps) {
    if (caps is! List) return false;
    for (final c in caps) {
      if ('$c' == capAck) return true;
    }
    return false;
  }

  static bool capsIncludeRead(dynamic caps) {
    if (caps is! List) return false;
    for (final c in caps) {
      if ('$c' == capRead) return true;
    }
    return false;
  }

  static Map<String, dynamic> helloExtras() => {
        'chatProto': chatProto,
        'caps': localCaps(),
      };

  static Map<String, dynamic> textPayload({
    required String msgId,
    required String text,
    int? ts,
  }) =>
      {
        'msgId': msgId,
        'text': text,
        'ts': ts ?? DateTime.now().millisecondsSinceEpoch,
      };

  static Map<String, dynamic> ackPayload(String msgId) => {'msgId': msgId};

  static Map<String, dynamic> readPayload(List<String> msgIds) => {
        'msgIds': msgIds,
      };

  static Map<String, dynamic> pingPayload(int t) => {'t': t};

  static Map<String, dynamic> pongPayload(int t) => {'t': t};
}
