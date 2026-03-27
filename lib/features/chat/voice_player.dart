import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/transport/nexus_message.dart';

/// Global singleton audio player for voice messages.
///
/// Only one voice message can play at a time: starting a new message
/// automatically stops the previous one.
///
/// Consumers rebuild via [ListenableBuilder(listenable: VoicePlayer.instance)].
class VoicePlayer extends ChangeNotifier {
  VoicePlayer._() {
    _player.onPlayerStateChanged.listen(_onStateChanged);
    _player.onPositionChanged.listen(_onPositionChanged);
    _player.onDurationChanged.listen(_onDurationChanged);
    _player.onPlayerComplete.listen((_) => _onComplete());
  }

  static final instance = VoicePlayer._();

  final _player = AudioPlayer();

  String? _currentMessageId;
  PlayerState _state = PlayerState.stopped;
  Duration _position = Duration.zero;
  Duration _total = Duration.zero;
  double _speed = 1.0;

  String? get currentMessageId => _currentMessageId;
  bool get isPlaying => _state == PlayerState.playing;
  Duration get position => _position;
  Duration get total => _total;
  double get speed => _speed;

  bool isPlayingMessage(String messageId) =>
      _currentMessageId == messageId && isPlaying;

  bool isActiveMessage(String messageId) => _currentMessageId == messageId;

  // ── Playback control ───────────────────────────────────────────────────────

  Future<void> togglePlayPause(NexusMessage msg) async {
    if (_currentMessageId == msg.id && isPlaying) {
      await _player.pause();
    } else if (_currentMessageId == msg.id && !isPlaying) {
      await _player.resume();
    } else {
      await _play(msg);
    }
  }

  Future<void> stop() async {
    await _player.stop();
    _currentMessageId = null;
    _position = Duration.zero;
    notifyListeners();
  }

  /// Cycles playback speed: 1× → 1.5× → 2× → 1×.
  void cycleSpeed() {
    _speed = switch (_speed) {
      1.0 => 1.5,
      1.5 => 2.0,
      _ => 1.0,
    };
    _player.setPlaybackRate(_speed);
    notifyListeners();
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  Future<void> _play(NexusMessage msg) async {
    if (_currentMessageId != null && _currentMessageId != msg.id) {
      await _player.stop();
    }

    _currentMessageId = msg.id;
    _position = Duration.zero;
    _speed = 1.0;

    // Prefer local file (our own recordings or already-cached received audio).
    final localPath = msg.metadata?['audio_local_path'] as String?;
    if (localPath != null && File(localPath).existsSync()) {
      await _player.play(DeviceFileSource(localPath));
    } else {
      // Decode base64 body → temp cache file → play.
      try {
        final bytes = base64Decode(msg.body);
        final path = await _writeTempFile(msg.id, bytes);
        if (path != null) await _player.play(DeviceFileSource(path));
      } catch (e) {
        debugPrint('[VoicePlayer] Failed to decode/play audio: $e');
        return;
      }
    }

    await _player.setPlaybackRate(_speed);
    notifyListeners();
  }

  Future<String?> _writeTempFile(String msgId, Uint8List bytes) async {
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/nexus_voice_$msgId.m4a';
      await File(path).writeAsBytes(bytes);
      return path;
    } catch (e) {
      debugPrint('[VoicePlayer] Failed to write temp file: $e');
      return null;
    }
  }

  void _onStateChanged(PlayerState state) {
    _state = state;
    notifyListeners();
  }

  void _onPositionChanged(Duration pos) {
    _position = pos;
    notifyListeners();
  }

  void _onDurationChanged(Duration dur) {
    _total = dur;
    notifyListeners();
  }

  void _onComplete() {
    _state = PlayerState.stopped;
    _position = Duration.zero;
    notifyListeners();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}
