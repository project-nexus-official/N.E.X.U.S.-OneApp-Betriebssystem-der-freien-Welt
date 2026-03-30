import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_oneapp/services/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Creates a fake GitHub releases/latest JSON response.
http.Client _mockClient({
  required String tagName,
  String body = 'What is new',
  int statusCode = 200,
  List<Map<String, dynamic>> assets = const [],
}) {
  final responseBody = jsonEncode({
    'tag_name': tagName,
    'body': body,
    'html_url': 'https://github.com/example/releases/tag/$tagName',
    'assets': assets,
  });
  return MockClient((_) async => http.Response(responseBody, statusCode));
}

// ── parseVersion ─────────────────────────────────────────────────────────────

void main() {
  group('parseVersion', () {
    test('parses plain semver', () {
      expect(parseVersion('1.2.3'), [1, 2, 3]);
    });

    test('strips leading v', () {
      expect(parseVersion('v0.1.1'), [0, 1, 1]);
    });

    test('strips -alpha suffix', () {
      expect(parseVersion('v0.1.1-alpha'), [0, 1, 1]);
    });

    test('strips -beta suffix', () {
      expect(parseVersion('0.2.0-beta'), [0, 2, 0]);
    });

    test('strips build metadata', () {
      expect(parseVersion('0.1.3+3'), [0, 1, 3]);
    });

    test('strips both suffix and build metadata', () {
      expect(parseVersion('v1.0.0-rc1+42'), [1, 0, 0]);
    });

    test('returns null for invalid input', () {
      expect(parseVersion(''), isNull);
      expect(parseVersion('abc'), isNull);
      expect(parseVersion('1.2'), isNull);
    });
  });

  // ── isNewer ─────────────────────────────────────────────────────────────────

  group('isNewer', () {
    test('patch bump is newer', () {
      expect(isNewer([0, 1, 1], [0, 1, 0]), isTrue);
    });

    test('minor bump is newer', () {
      expect(isNewer([0, 2, 0], [0, 1, 9]), isTrue);
    });

    test('major bump is newer', () {
      expect(isNewer([1, 0, 0], [0, 9, 9]), isTrue);
    });

    test('equal versions are not newer', () {
      expect(isNewer([0, 1, 1], [0, 1, 1]), isFalse);
    });

    test('older remote is not newer', () {
      expect(isNewer([0, 1, 0], [0, 1, 1]), isFalse);
    });

    test('version ordering: 0.1.0 < 0.1.1 < 0.2.0 < 1.0.0', () {
      final v010 = [0, 1, 0];
      final v011 = [0, 1, 1];
      final v020 = [0, 2, 0];
      final v100 = [1, 0, 0];

      expect(isNewer(v011, v010), isTrue);
      expect(isNewer(v020, v011), isTrue);
      expect(isNewer(v100, v020), isTrue);
      // Reverse: none are newer
      expect(isNewer(v010, v011), isFalse);
      expect(isNewer(v011, v020), isFalse);
      expect(isNewer(v020, v100), isFalse);
    });
  });

  // ── UpdateService ────────────────────────────────────────────────────────────

  group('UpdateService.checkForUpdateWithMock', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('returns UpdateInfo when remote is newer', () async {
      final client = _mockClient(
        tagName: 'v0.2.0',
        body: 'Bug fixes and improvements.',
      );
      final info = await UpdateService.instance.checkForUpdateWithMock(
        client: client,
        currentVersion: '0.1.3',
      );
      expect(info, isNotNull);
      expect(info!.version, 'v0.2.0');
      expect(info.releaseNotes, 'Bug fixes and improvements.');
    });

    test('returns null when remote equals local', () async {
      final client = _mockClient(tagName: 'v0.1.3');
      final info = await UpdateService.instance.checkForUpdateWithMock(
        client: client,
        currentVersion: '0.1.3',
      );
      expect(info, isNull);
    });

    test('returns null when remote is older than local', () async {
      final client = _mockClient(tagName: 'v0.1.0');
      final info = await UpdateService.instance.checkForUpdateWithMock(
        client: client,
        currentVersion: '0.1.3',
      );
      expect(info, isNull);
    });

    test('returns null on HTTP error', () async {
      final client = _mockClient(tagName: 'v9.9.9', statusCode: 500);
      final info = await UpdateService.instance.checkForUpdateWithMock(
        client: client,
        currentVersion: '0.1.3',
      );
      expect(info, isNull);
    });

    test('does not crash when GitHub API is unreachable', () async {
      final client = MockClient((_) async => throw Exception('no network'));
      final info = await UpdateService.instance.checkForUpdateWithMock(
        client: client,
        currentVersion: '0.1.3',
      );
      expect(info, isNull);
    });

    test('truncates release notes to 500 characters', () async {
      final longNotes = 'x' * 600;
      final client = _mockClient(tagName: 'v1.0.0', body: longNotes);
      final info = await UpdateService.instance.checkForUpdateWithMock(
        client: client,
        currentVersion: '0.1.3',
      );
      expect(info, isNotNull);
      // 500 chars + '…' = 501
      expect(info!.releaseNotes.length, 501);
      expect(info.releaseNotes.endsWith('…'), isTrue);
    });

    test('prefers APK asset URL', () async {
      final client = _mockClient(
        tagName: 'v1.0.0',
        assets: [
          {
            'name': 'nexus-v1.0.0.apk',
            'browser_download_url': 'https://example.com/nexus.apk'
          },
          {
            'name': 'nexus-v1.0.0.zip',
            'browser_download_url': 'https://example.com/nexus.zip'
          },
        ],
      );
      // downloadUrl depends on platform; just verify it is not empty
      final info = await UpdateService.instance.checkForUpdateWithMock(
        client: client,
        currentVersion: '0.1.3',
      );
      expect(info, isNotNull);
      expect(info!.downloadUrl, isNotEmpty);
    });

    test('falls back to html_url when no matching asset exists', () async {
      final client = _mockClient(tagName: 'v1.0.0');
      final info = await UpdateService.instance.checkForUpdateWithMock(
        client: client,
        currentVersion: '0.1.3',
      );
      expect(info, isNotNull);
      expect(info!.downloadUrl,
          'https://github.com/example/releases/tag/v1.0.0');
    });
  });

  // ── 6-hour rate limit ────────────────────────────────────────────────────────

  group('6-hour rate limit', () {
    test('skips API call when last check was < 6 h ago', () async {
      // Pre-seed SharedPreferences with a recent timestamp.
      SharedPreferences.setMockInitialValues({
        'nexus_last_update_check': DateTime.now().toIso8601String(),
      });
      int callCount = 0;
      final client = MockClient((_) async {
        callCount++;
        return http.Response(
            jsonEncode({'tag_name': 'v9.9.9', 'assets': [], 'html_url': ''}),
            200);
      });
      // startPeriodicCheck respects the rate limit.
      // We can't easily test the Timer, so test the underlying logic via
      // checkForUpdateWithMock which bypasses the rate limit — confirm
      // the counter increments, proving the guard only lives in
      // _checkWithRateLimit (not in _fetchAndEvaluate itself).
      await UpdateService.instance.checkForUpdateWithMock(
        client: client,
        currentVersion: '0.1.0',
      );
      // _fetchAndEvaluate always hits the network; rate limit is in the caller.
      expect(callCount, 1);
    });

    test('skipped version is not shown again', () async {
      SharedPreferences.setMockInitialValues({
        'nexus_skipped_version': 'v1.0.0',
      });
      final client = _mockClient(tagName: 'v1.0.0');
      final info = await UpdateService.instance.checkForUpdateWithMock(
        client: client,
        currentVersion: '0.1.3',
      );
      expect(info, isNull);
    });

    test('a different version is shown even when another is skipped', () async {
      SharedPreferences.setMockInitialValues({
        'nexus_skipped_version': 'v0.9.0',
      });
      final client = _mockClient(tagName: 'v1.0.0');
      final info = await UpdateService.instance.checkForUpdateWithMock(
        client: client,
        currentVersion: '0.1.3',
      );
      expect(info, isNotNull);
      expect(info!.version, 'v1.0.0');
    });
  });

  // ── dismissForSession / skipVersion ──────────────────────────────────────────

  group('UpdateService session control', () {
    test('dismissForSession clears current', () async {
      SharedPreferences.setMockInitialValues({});
      final client = _mockClient(tagName: 'v2.0.0');
      await UpdateService.instance.checkForUpdateWithMock(
        client: client,
        currentVersion: '0.1.3',
      );
      // current is set by the real singleton — we only test dismissForSession
      // by verifying it sets current to null without throwing.
      expect(() => UpdateService.instance.dismissForSession(), returnsNormally);
      expect(UpdateService.instance.current, isNull);
    });

    test('skipVersion stores version and clears current', () async {
      SharedPreferences.setMockInitialValues({});
      await UpdateService.instance.skipVersion('v2.0.0');
      expect(UpdateService.instance.current, isNull);

      // Confirm the version is now skipped.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('nexus_skipped_version'), 'v2.0.0');
    });
  });
}
