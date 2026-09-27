import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/voice_controller.dart';

/// Full-screen overlay for outgoing / incoming / active voice calls.
class VoiceCallOverlay extends StatefulWidget {
  const VoiceCallOverlay({super.key, required this.child});
  final Widget child;

  @override
  State<VoiceCallOverlay> createState() => _VoiceCallOverlayState();
}

class _VoiceCallOverlayState extends State<VoiceCallOverlay> {
  Timer? _tick;
  String _lastError = '';

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _ensureTick(VoicePhase phase) {
    if (phase == VoicePhase.active || phase == VoicePhase.outgoing) {
      _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Consumer<VoiceController>(
          builder: (context, voice, _) {
            final s = voice.state;
            _ensureTick(s.phase);
            if (s.error.isNotEmpty && s.error != _lastError) {
              _lastError = s.error;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  SnackBar(content: Text(s.error)),
                );
                voice.clearError();
              });
            }
            if (s.phase == VoicePhase.idle) {
              return const SizedBox.shrink();
            }
            return Positioned.fill(
              child: Material(
                color: const Color(0xE6121A22),
                child: SafeArea(
                  child: _VoicePanel(voice: voice),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _VoicePanel extends StatelessWidget {
  const _VoicePanel({required this.voice});
  final VoiceController voice;

  @override
  Widget build(BuildContext context) {
    final s = voice.state;
    final peer = s.peerToken.isEmpty
        ? '对方'
        : (s.peerToken.length <= 12
            ? s.peerToken
            : '${s.peerToken.substring(0, 6)}…${s.peerToken.substring(s.peerToken.length - 4)}');
    final title = switch (s.phase) {
      VoicePhase.outgoing => '正在呼叫…',
      VoicePhase.incoming => '来电',
      VoicePhase.active => '语音通话中',
      VoicePhase.idle => '',
    };
    final elapsed = s.startedAt == null
        ? ''
        : _fmtElapsed(DateTime.now().difference(s.startedAt!));

    return Column(
      children: [
        const Spacer(flex: 2),
        const Icon(Icons.phone_in_talk, size: 72, color: Colors.white70),
        const SizedBox(height: 20),
        Text(
          peer,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          s.phase == VoicePhase.active
              ? (elapsed.isEmpty ? title : elapsed)
              : title,
          style: const TextStyle(color: Colors.white70, fontSize: 16),
        ),
        const Spacer(flex: 3),
        if (s.phase == VoicePhase.incoming)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _RoundAction(
                color: const Color(0xFFE53935),
                icon: Icons.call_end,
                label: '拒绝',
                onTap: () => voice.rejectOrCancel(),
              ),
              _RoundAction(
                color: const Color(0xFF43A047),
                icon: Icons.call,
                label: '接听',
                onTap: () async {
                  try {
                    await voice.accept();
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('$e')),
                      );
                    }
                  }
                },
              ),
            ],
          )
        else
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (s.phase == VoicePhase.active)
                _RoundAction(
                  color: s.muted ? Colors.white24 : Colors.white12,
                  icon: s.muted ? Icons.mic_off : Icons.mic,
                  label: s.muted ? '取消静音' : '静音',
                  onTap: () => voice.setMuted(!s.muted),
                ),
              _RoundAction(
                color: const Color(0xFFE53935),
                icon: Icons.call_end,
                label: s.phase == VoicePhase.outgoing ? '取消' : '挂断',
                onTap: () => s.phase == VoicePhase.outgoing
                    ? voice.rejectOrCancel()
                    : voice.hangup(),
              ),
            ],
          ),
        const SizedBox(height: 48),
      ],
    );
  }

  String _fmtElapsed(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final sec = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    if (h > 0) return '$h:$m:$sec';
    return '$m:$sec';
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.color,
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 68,
              height: 68,
              child: Icon(icon, color: Colors.white, size: 30),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(label, style: const TextStyle(color: Colors.white70)),
      ],
    );
  }
}
