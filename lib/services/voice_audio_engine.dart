import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:record/record.dart' hide IosAudioCategory;

import 'voice_protocol.dart';

typedef VoiceFrameSender = void Function(Uint8List opusPacket);

/// Mic capture → Opus encode → send; recv Opus → decode → speaker.
class VoiceAudioEngine {
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _micSub;
  SimpleOpusEncoder? _encoder;
  SimpleOpusDecoder? _decoder;
  final BytesBuilder _pcmPending = BytesBuilder(copy: false);
  int _seq = 0;
  bool _muted = false;
  bool _running = false;
  VoiceFrameSender? _onEncode;
  String _callId = '';
  DateTime? _startedAt;
  static bool _opusReady = false;

  bool get isRunning => _running;

  set muted(bool value) => _muted = value;

  static Future<void> ensureOpus() async {
    if (_opusReady) return;
    final lib = await opus_flutter.load();
    initOpus(lib);
    _opusReady = true;
    debugPrint('voice: opus ready ${getOpusVersion()}');
  }

  Future<void> start({
    required String callId,
    required VoiceFrameSender onEncode,
  }) async {
    await stop();
    await ensureOpus();
    _callId = callId;
    _onEncode = onEncode;
    _seq = 0;
    _startedAt = DateTime.now();
    _pcmPending.clear();
    _encoder = SimpleOpusEncoder(
      sampleRate: kVoiceSampleRate,
      channels: 1,
      application: Application.voip,
    );
    _decoder = SimpleOpusDecoder(
      sampleRate: kVoiceSampleRate,
      channels: 1,
    );

    await FlutterPcmSound.setLogLevel(LogLevel.none);
    await FlutterPcmSound.setup(
      sampleRate: kVoiceSampleRate,
      channelCount: 1,
      iosAudioCategory: IosAudioCategory.playAndRecord,
    );
    await FlutterPcmSound.setFeedThreshold(kVoiceFrameSamples);
    FlutterPcmSound.setFeedCallback((_) {});
    FlutterPcmSound.start();

    final recorder = AudioRecorder();
    _recorder = recorder;
    final hasMic = await recorder.hasPermission();
    if (!hasMic) {
      throw StateError('需要麦克风权限才能进行语音通话');
    }

    final stream = await recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: kVoiceSampleRate,
        numChannels: 1,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
      ),
    );
    _micSub = stream.listen(_onMicBytes, onError: (Object e) {
      debugPrint('voice mic error: $e');
    });
    _running = true;
  }

  void pushRemoteOpus(Uint8List opus) {
    final decoder = _decoder;
    if (!_running || decoder == null || opus.isEmpty) return;
    try {
      final pcm = decoder.decode(input: opus);
      if (pcm.isEmpty) return;
      final bd = ByteData(pcm.length * 2);
      for (var i = 0; i < pcm.length; i++) {
        bd.setInt16(i * 2, pcm[i], Endian.little);
      }
      unawaited(FlutterPcmSound.feed(PcmArrayInt16(bytes: bd)));
    } catch (e) {
      debugPrint('voice decode error: $e');
    }
  }

  void _onMicBytes(Uint8List chunk) {
    if (!_running || chunk.isEmpty) return;
    _pcmPending.add(chunk);
    final needBytes = kVoiceFrameSamples * 2;
    while (_pcmPending.length >= needBytes) {
      final all = _pcmPending.takeBytes();
      final frameBytes = Uint8List.sublistView(all, 0, needBytes);
      if (all.length > needBytes) {
        _pcmPending.add(Uint8List.sublistView(all, needBytes));
      }
      _encodeAndSend(frameBytes);
    }
  }

  void _encodeAndSend(Uint8List pcmBytes) {
    final encoder = _encoder;
    final send = _onEncode;
    if (encoder == null || send == null) return;
    final samples = Int16List(kVoiceFrameSamples);
    final bd = ByteData.sublistView(pcmBytes);
    for (var i = 0; i < kVoiceFrameSamples; i++) {
      samples[i] = _muted ? 0 : bd.getInt16(i * 2, Endian.little);
    }
    try {
      final opus = encoder.encode(input: samples);
      if (opus.isEmpty) return;
      final seq = _seq++;
      final started = _startedAt ?? DateTime.now();
      final ts = DateTime.now().difference(started).inMilliseconds;
      final packed = packVoiceBinary(
        callId: _callId,
        seq: seq,
        timestampMs: ts < 0 ? 0 : ts,
        opus: opus,
      );
      if (packed != null) send(packed);
    } catch (e) {
      debugPrint('voice encode error: $e');
    }
  }

  Future<void> stop() async {
    _running = false;
    await _micSub?.cancel();
    _micSub = null;
    try {
      await _recorder?.stop();
    } catch (_) {}
    try {
      await _recorder?.dispose();
    } catch (_) {}
    _recorder = null;
    _encoder?.destroy();
    _decoder?.destroy();
    _encoder = null;
    _decoder = null;
    _pcmPending.clear();
    _onEncode = null;
    FlutterPcmSound.setFeedCallback(null);
    try {
      await FlutterPcmSound.release();
    } catch (_) {}
  }
}
