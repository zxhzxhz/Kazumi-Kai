import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 播放器角标：实时呈现帧率与增强管线状态。
///
/// 帧率取自 native 渲染器实际交给 Flutter 的不同帧数（不是 Flutter 的 UI
/// 帧率），因此能真实反映 VT 插帧 / 解码是否生效。第二行是渲染器上报的管线
/// 状态，用于诊断"开关开了但没效果"。
class PlayerFpsOverlay extends StatefulWidget {
  const PlayerFpsOverlay({super.key, required this.playerController});

  final PlayerController playerController;

  @override
  State<PlayerFpsOverlay> createState() => _PlayerFpsOverlayState();
}

class _PlayerFpsOverlayState extends State<PlayerFpsOverlay> {
  static const _sampleInterval = Duration(milliseconds: 500);

  Timer? _timer;
  StreamSubscription<void>? _subscription;
  bool _visible = false;
  double _fps = 0;
  String _status = '';
  int? _lastFrames;
  DateTime _lastSample = DateTime.now();

  @override
  void initState() {
    super.initState();
    _visible = GStorage.getSetting<bool>(SettingsKeys.playerShowFps);
    _subscription = GStorage.watchSettings([SettingsKeys.playerShowFps])
        .listen((_) {
      if (!mounted) return;
      setState(() {
        _visible = GStorage.getSetting<bool>(SettingsKeys.playerShowFps);
        if (!_visible) {
          _fps = 0;
          _status = '';
          _lastFrames = null;
        }
      });
      _syncTimer();
    });
    _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _subscription?.cancel();
    super.dispose();
  }

  void _syncTimer() {
    if (_visible && _timer == null) {
      _lastSample = DateTime.now();
      _lastFrames = null;
      _timer = Timer.periodic(_sampleInterval, (_) => _sample());
    } else if (!_visible && _timer != null) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _sample() async {
    final controller = widget.playerController.playback.videoController;
    if (controller == null) {
      return;
    }
    final stats = await controller.getEnhanceStats();
    final now = DateTime.now();
    final elapsed = now.difference(_lastSample).inMilliseconds / 1000.0;
    if (elapsed <= 0) {
      return;
    }
    final previous = _lastFrames;
    _lastFrames = stats.presentedFrames;
    _lastSample = now;
    if (!mounted) {
      return;
    }
    setState(() {
      _status = stats.status;
      if (previous != null) {
        // presentedFrames 是累计值，两次采样的差值除以时间就是呈现帧率。
        _fps = (stats.presentedFrames - previous) / elapsed;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${_fps.toStringAsFixed(1)} fps',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (_status.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  _status,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(color: Colors.white70, fontSize: 9),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
