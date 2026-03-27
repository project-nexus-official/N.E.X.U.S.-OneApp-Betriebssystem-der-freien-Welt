import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

/// Thin wrapper around the `record` package.
///
/// Usage:
///   1. Check / request permission once via [hasPermission] / [requestPermission].
///   2. Call [start] → UI shows recording indicator.
///   3. Call [stop] → returns the file path; caller sends the file.
///      OR call [cancel] → discards the partial file.
class VoiceRecorder {
  final _recorder = AudioRecorder();

  bool _isRecording = false;
  String? _currentPath;

  bool get isRecording => _isRecording;

  // ── Permission ─────────────────────────────────────────────────────────────

  Future<bool> hasPermission() => _recorder.hasPermission();

  Future<bool> requestPermission() async {
    // Desktop platforms don't use permission_handler for microphone.
    if (!Platform.isAndroid && !Platform.isIOS) return true;
    final status = await Permission.microphone.request();
    return status == PermissionStatus.granted;
  }

  // ── Recording lifecycle ────────────────────────────────────────────────────

  /// Starts recording and returns the file path where audio will be saved.
  /// Returns null if the recorder is already active or fails to start.
  Future<String?> start() async {
    if (_isRecording) return null;

    final dir = await getApplicationDocumentsDirectory();
    final voiceDir = Directory('${dir.path}/nexus_voice');
    if (!voiceDir.existsSync()) voiceDir.createSync(recursive: true);

    final ts = DateTime.now().millisecondsSinceEpoch;
    final ext = (Platform.isAndroid || Platform.isIOS) ? 'm4a' : 'wav';
    final path = '${voiceDir.path}/voice_$ts.$ext';

    final encoder =
        (Platform.isAndroid || Platform.isIOS) ? AudioEncoder.aacLc : AudioEncoder.wav;

    await _recorder.start(
      RecordConfig(
        encoder: encoder,
        sampleRate: 16000,
        bitRate: 32000,
        numChannels: 1,
      ),
      path: path,
    );

    _isRecording = true;
    _currentPath = path;
    return path;
  }

  /// Stops recording and returns the final file path, or null on failure.
  Future<String?> stop() async {
    if (!_isRecording) return null;
    _isRecording = false;
    final path = await _recorder.stop();
    _currentPath = null;
    return path;
  }

  /// Cancels the current recording and deletes the partial file.
  Future<void> cancel() async {
    if (!_isRecording) return;
    _isRecording = false;
    await _recorder.cancel();
    if (_currentPath != null) {
      final file = File(_currentPath!);
      if (file.existsSync()) file.deleteSync();
      _currentPath = null;
    }
  }

  void dispose() => _recorder.dispose();
}
