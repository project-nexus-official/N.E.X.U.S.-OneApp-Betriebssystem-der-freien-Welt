import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds information about an available update.
class UpdateInfo {
  final String version;
  final String releaseNotes;
  final String downloadUrl;

  const UpdateInfo({
    required this.version,
    required this.releaseNotes,
    required this.downloadUrl,
  });
}

/// Checks GitHub Releases for available updates.
///
/// Usage:
/// ```dart
/// await UpdateService.instance.startPeriodicCheck();
/// UpdateService.instance.updateStream.listen((info) { … });
/// ```
class UpdateService {
  UpdateService._();
  static final instance = UpdateService._();

  static const _kApiUrl =
      'https://api.github.com/repos/project-nexus-official/oneapp/releases/latest';
  static const _kLastCheckKey = 'nexus_last_update_check';
  static const _kSkippedVersionKey = 'nexus_skipped_version';
  static const _checkIntervalHours = 6;

  final _controller = StreamController<UpdateInfo?>.broadcast();

  /// Broadcast stream: emits whenever [current] changes (new update or dismissed).
  Stream<UpdateInfo?> get updateStream => _controller.stream;

  UpdateInfo? _current;

  /// Last known update info, or null if up to date / not yet checked.
  UpdateInfo? get current => _current;

  Timer? _timer;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Starts the periodic check cycle.
  ///
  /// The first check respects the 6-hour rate limit — it is a no-op if the
  /// last API call happened less than 6 h ago.  Subsequent checks run every
  /// 6 hours via a background [Timer].
  Future<void> startPeriodicCheck() async {
    await _checkWithRateLimit();
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(hours: _checkIntervalHours),
      (_) => _checkWithRateLimit(),
    );
  }

  /// Stops the periodic timer (e.g. when the app is paused).
  void stopPeriodicCheck() {
    _timer?.cancel();
    _timer = null;
  }

  /// Forces an immediate GitHub API call regardless of the 6-hour rate limit.
  /// Returns [UpdateInfo] if a newer version is available, null otherwise.
  Future<UpdateInfo?> checkNow() => _fetchAndEvaluate();

  /// Hides the update banner for this session only (until next cold start).
  void dismissForSession() {
    _current = null;
    _controller.add(null);
  }

  /// Permanently skips [version]: stores it in SharedPreferences so the banner
  /// is never shown again for this specific release tag.
  Future<void> skipVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSkippedVersionKey, version);
    _current = null;
    _controller.add(null);
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  Future<void> _checkWithRateLimit() async {
    final prefs = await SharedPreferences.getInstance();
    final lastCheck = prefs.getString(_kLastCheckKey);
    if (lastCheck != null) {
      final last = DateTime.tryParse(lastCheck);
      if (last != null &&
          DateTime.now().difference(last).inHours < _checkIntervalHours) {
        return; // too soon — respect rate limit
      }
    }
    await _fetchAndEvaluate();
  }

  /// Fetches the latest release from GitHub, compares with the installed
  /// version and updates [current] / [updateStream] if a newer version is
  /// available.
  ///
  /// [clientOverride] and [currentVersionOverride] are used in tests only.
  Future<UpdateInfo?> _fetchAndEvaluate({
    http.Client? clientOverride,
    String? currentVersionOverride,
  }) async {
    final ownClient = clientOverride == null;
    final client = clientOverride ?? http.Client();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _kLastCheckKey, DateTime.now().toIso8601String());

      final response = await client
          .get(
            Uri.parse(_kApiUrl),
            headers: {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final tagName = (data['tag_name'] as String? ?? '').trim();
      final body = data['body'] as String? ?? '';
      final releaseNotes =
          body.length > 500 ? '${body.substring(0, 500)}…' : body;

      // Find the best download URL for the current platform.
      final assets = (data['assets'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      final downloadUrl =
          _platformAssetUrl(assets) ?? (data['html_url'] as String? ?? _kApiUrl);

      // Compare with the installed version.
      final currentVer = currentVersionOverride ??
          (await PackageInfo.fromPlatform()).version;
      final remote = parseVersion(tagName);
      final local = parseVersion(currentVer);
      if (remote == null || local == null) return null;
      if (!isNewer(remote, local)) return null;

      // Check whether the user has permanently skipped this release.
      final skipped = prefs.getString(_kSkippedVersionKey);
      if (skipped == tagName) return null;

      final info = UpdateInfo(
        version: tagName,
        releaseNotes: releaseNotes,
        downloadUrl: downloadUrl,
      );
      _current = info;
      _controller.add(info);
      return info;
    } catch (e) {
      debugPrint('[UPDATE] check failed: $e');
      return null;
    } finally {
      if (ownClient) client.close();
    }
  }

  /// Returns the browser_download_url of the first asset matching the current
  /// platform's extension (.apk for Android, .zip for Windows), or null if
  /// none is found.
  String? _platformAssetUrl(List<Map<String, dynamic>> assets) {
    String? suffix;
    if (!kIsWeb) {
      if (Platform.isAndroid) suffix = '.apk';
      if (Platform.isWindows) suffix = '.zip';
    }
    if (suffix == null) return null;
    for (final a in assets) {
      final name = (a['name'] as String? ?? '').toLowerCase();
      if (name.endsWith(suffix)) {
        return a['browser_download_url'] as String?;
      }
    }
    return null;
  }

  // ── Test helpers ───────────────────────────────────────────────────────────

  /// For unit tests only: bypasses SharedPreferences rate limit and
  /// [PackageInfo.fromPlatform].
  @visibleForTesting
  Future<UpdateInfo?> checkForUpdateWithMock({
    required http.Client client,
    required String currentVersion,
  }) =>
      _fetchAndEvaluate(
        clientOverride: client,
        currentVersionOverride: currentVersion,
      );
}

// ── Pure version helpers (top-level, exported for testing) ───────────────────

/// Parses a semver-ish string into [major, minor, patch].
///
/// Handles:
/// - Leading "v": `"v0.1.1"` → `[0, 1, 1]`
/// - Build metadata: `"0.1.3+3"` → `[0, 1, 3]`
/// - Pre-release suffix: `"0.1.1-alpha"` → `[0, 1, 1]`
///
/// Returns null if parsing fails.
@visibleForTesting
List<int>? parseVersion(String raw) {
  var s = raw.trim();
  if (s.startsWith('v')) s = s.substring(1);
  // Strip build metadata
  final plusIdx = s.indexOf('+');
  if (plusIdx >= 0) s = s.substring(0, plusIdx);
  // Strip pre-release suffix
  final dashIdx = s.indexOf('-');
  if (dashIdx >= 0) s = s.substring(0, dashIdx);

  final parts = s.split('.');
  if (parts.length < 3) return null;
  final nums = <int>[];
  for (final p in parts.take(3)) {
    final n = int.tryParse(p);
    if (n == null) return null;
    nums.add(n);
  }
  return nums;
}

/// Returns true if [remote] is strictly newer than [local].
/// Compares major → minor → patch in order.
@visibleForTesting
bool isNewer(List<int> remote, List<int> local) {
  for (int i = 0; i < 3; i++) {
    if (remote[i] > local[i]) return true;
    if (remote[i] < local[i]) return false;
  }
  return false; // equal versions
}
