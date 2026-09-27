import 'dart:convert';
import 'dart:typed_data';

/// Desktop-compatible voice framing (see File2File-Desktop `voice.rs`).
const int kVoiceBinVer = 2;
const int kVoiceSampleRate = 16000;
const int kVoiceFrameMs = 20;
const int kVoiceFrameSamples = kVoiceSampleRate * kVoiceFrameMs ~/ 1000; // 320
const int kVoiceRingTimeoutMs = 45000;

bool isVoiceBinary(Uint8List bytes) {
  return bytes.length >= 4 &&
      bytes[0] == 0 &&
      bytes[1] == 0 &&
      bytes[2] == 0 &&
      bytes[3] == kVoiceBinVer;
}

/// Pack: `00 00 00 02` | callLen | callId | seq(le) | ts(le) | opusLen(le u16) | opus
Uint8List? packVoiceBinary({
  required String callId,
  required int seq,
  required int timestampMs,
  required Uint8List opus,
}) {
  final callBytes = utf8.encode(callId);
  if (callBytes.length > 255 || opus.length > 0xFFFF) return null;
  final out = BytesBuilder(copy: false);
  out.add([0, 0, 0, kVoiceBinVer]);
  out.addByte(callBytes.length);
  out.add(callBytes);
  final hdr = ByteData(10);
  hdr.setUint32(0, seq, Endian.little);
  hdr.setUint32(4, timestampMs, Endian.little);
  hdr.setUint16(8, opus.length, Endian.little);
  out.add(hdr.buffer.asUint8List());
  out.add(opus);
  return out.toBytes();
}

/// Returns `(callId, seq, timestampMs, opus)` or null.
({String callId, int seq, int timestampMs, Uint8List opus})? parseVoiceBinary(
  Uint8List payload,
) {
  if (!isVoiceBinary(payload) || payload.length < 15) return null;
  final callLen = payload[4];
  final header = 5 + callLen + 4 + 4 + 2;
  if (payload.length < header) return null;
  final callId = utf8.decode(payload.sublist(5, 5 + callLen), allowMalformed: true);
  var off = 5 + callLen;
  final bd = ByteData.sublistView(payload);
  final seq = bd.getUint32(off, Endian.little);
  off += 4;
  final ts = bd.getUint32(off, Endian.little);
  off += 4;
  final opusLen = bd.getUint16(off, Endian.little);
  off += 2;
  if (payload.length < off + opusLen) return null;
  return (
    callId: callId,
    seq: seq,
    timestampMs: ts,
    opus: Uint8List.sublistView(payload, off, off + opusLen),
  );
}

Map<String, dynamic> voiceSignalJson(String op, String callId) => {
      'type': 6,
      'data': {'op': op, 'callId': callId},
    };

Map<String, dynamic> voiceSessionSignalJson({
  required String op,
  required String callId,
  required int sessionId,
}) =>
    {
      'type': 11,
      'data': {
        'op': op,
        'callId': callId,
        'sessionId': sessionId,
      },
    };
