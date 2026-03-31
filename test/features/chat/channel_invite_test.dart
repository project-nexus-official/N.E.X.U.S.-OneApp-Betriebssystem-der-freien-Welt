import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/features/chat/channel_invite_payload.dart';

void main() {
  // ── ChannelInvitePayload.tryParse – JSON ──────────────────────────────────

  group('tryParse – JSON', () {
    Map<String, dynamic> _base({
      String type = 'channel_invite',
      String channelId = 'abc123',
      String channelName = '#teneriffa',
      String nostrTag = 'nexus-channel-teneriffa',
      bool isPublic = true,
      bool isDiscoverable = true,
      String? inviteToken,
    }) =>
        {
          'type': type,
          'channelId': channelId,
          'channelName': channelName,
          'nostrTag': nostrTag,
          'isPublic': isPublic,
          'isDiscoverable': isDiscoverable,
          if (inviteToken != null) 'inviteToken': inviteToken,
        };

    test('parses a valid public channel invite', () {
      final p = ChannelInvitePayload.tryParse(jsonEncode(_base()))!;
      expect(p.channelId, 'abc123');
      expect(p.channelName, '#teneriffa');
      expect(p.nostrTag, 'nexus-channel-teneriffa');
      expect(p.isPublic, isTrue);
      expect(p.isDiscoverable, isTrue);
      expect(p.inviteToken, isNull);
    });

    test('parses a private+hidden invite with token', () {
      final p = ChannelInvitePayload.tryParse(
        jsonEncode(_base(isPublic: false, isDiscoverable: false, inviteToken: 'secret123')),
      )!;
      expect(p.isPublic, isFalse);
      expect(p.isDiscoverable, isFalse);
      expect(p.inviteToken, 'secret123');
    });

    test('parses a private+visible invite without token', () {
      final p = ChannelInvitePayload.tryParse(
        jsonEncode(_base(isPublic: false, isDiscoverable: true)),
      )!;
      expect(p.isPublic, isFalse);
      expect(p.isDiscoverable, isTrue);
      expect(p.inviteToken, isNull);
    });

    test('returns null for wrong type', () {
      final raw = jsonEncode(_base(type: 'nexus-contact'));
      expect(ChannelInvitePayload.tryParse(raw), isNull);
    });

    test('returns null for missing channelName', () {
      final map = _base()..remove('channelName');
      expect(ChannelInvitePayload.tryParse(jsonEncode(map)), isNull);
    });

    test('returns null for empty channelName', () {
      final raw = jsonEncode(_base(channelName: ''));
      expect(ChannelInvitePayload.tryParse(raw), isNull);
    });

    test('returns null for invalid JSON', () {
      expect(ChannelInvitePayload.tryParse('not-json'), isNull);
    });

    test('infers nostrTag when absent', () {
      final map = _base()..remove('nostrTag');
      final p = ChannelInvitePayload.tryParse(jsonEncode(map))!;
      expect(p.nostrTag, 'nexus-channel-teneriffa');
    });

    test('defaults isPublic to true when absent', () {
      final map = _base()..remove('isPublic');
      final p = ChannelInvitePayload.tryParse(jsonEncode(map))!;
      expect(p.isPublic, isTrue);
    });

    test('leading/trailing whitespace in raw value is trimmed', () {
      final raw = '  ${jsonEncode(_base())}  ';
      expect(ChannelInvitePayload.tryParse(raw), isNotNull);
    });
  });

  // ── ChannelInvitePayload.tryParse – deep-link ─────────────────────────────

  group('tryParse – nexus:// deep-link', () {
    test('parses a basic public channel link', () {
      const link = 'nexus://channel?id=abc&name=%23test';
      final p = ChannelInvitePayload.tryParse(link)!;
      expect(p.channelName, '#test');
      expect(p.channelId, 'abc');
      expect(p.isPublic, isTrue);
    });

    test('parses a private link with public=false', () {
      const link = 'nexus://channel?id=abc&name=%23priv&public=false';
      final p = ChannelInvitePayload.tryParse(link)!;
      expect(p.isPublic, isFalse);
    });

    test('parses a hidden link with discoverable=false', () {
      const link =
          'nexus://channel?id=abc&name=%23hidden&public=false&discoverable=false';
      final p = ChannelInvitePayload.tryParse(link)!;
      expect(p.isDiscoverable, isFalse);
    });

    test('parses a token in the link', () {
      const link =
          'nexus://channel?id=abc&name=%23secret&public=false&discoverable=false&token=tok123';
      final p = ChannelInvitePayload.tryParse(link)!;
      expect(p.inviteToken, 'tok123');
    });

    test('returns null for wrong scheme', () {
      expect(
        ChannelInvitePayload.tryParse('https://example.com/channel?name=test'),
        isNull,
      );
    });

    test('returns null for wrong host', () {
      expect(
        ChannelInvitePayload.tryParse('nexus://contact?name=test'),
        isNull,
      );
    });

    test('returns null when name parameter is missing', () {
      expect(
        ChannelInvitePayload.tryParse('nexus://channel?id=abc'),
        isNull,
      );
    });

    test('normalises name without # prefix', () {
      const link = 'nexus://channel?id=abc&name=test';
      final p = ChannelInvitePayload.tryParse(link)!;
      expect(p.channelName, '#test');
    });
  });

  // ── Round-trip ──────────────────────────────────────────────────────────────

  group('round-trip', () {
    ChannelInvitePayload _make({
      bool isPublic = true,
      bool isDiscoverable = true,
      String? inviteToken,
    }) =>
        ChannelInvitePayload(
          channelId: 'id-1',
          channelName: '#roundtrip',
          nostrTag: 'nexus-channel-roundtrip',
          isPublic: isPublic,
          isDiscoverable: isDiscoverable,
          inviteToken: inviteToken,
        );

    test('toJsonString / tryParse round-trips public channel', () {
      final original = _make();
      final parsed = ChannelInvitePayload.tryParse(original.toJsonString())!;
      expect(parsed.channelId, original.channelId);
      expect(parsed.channelName, original.channelName);
      expect(parsed.isPublic, original.isPublic);
      expect(parsed.inviteToken, isNull);
    });

    test('toJsonString / tryParse round-trips hidden channel with token', () {
      final original = _make(isPublic: false, isDiscoverable: false, inviteToken: 'tok');
      final parsed = ChannelInvitePayload.tryParse(original.toJsonString())!;
      expect(parsed.inviteToken, 'tok');
      expect(parsed.isDiscoverable, isFalse);
    });

    test('toDeepLink / tryParse round-trips public channel', () {
      final original = _make();
      final link = original.toDeepLink();
      expect(link, startsWith('nexus://channel'));
      final parsed = ChannelInvitePayload.tryParse(link)!;
      expect(parsed.channelName, original.channelName);
      expect(parsed.channelId, original.channelId);
    });

    test('toDeepLink excludes token for public channels', () {
      final p = _make();
      expect(p.toDeepLink(), isNot(contains('token')));
    });

    test('toDeepLink includes token for hidden private channels', () {
      final p = _make(isPublic: false, isDiscoverable: false, inviteToken: 'abc');
      expect(p.toDeepLink(), contains('token=abc'));
    });

    test('toJson does not include inviteToken when null', () {
      final p = _make();
      expect(p.toJson().containsKey('inviteToken'), isFalse);
    });

    test('toJson includes inviteToken when set', () {
      final p = _make(inviteToken: 'secret');
      expect(p.toJson()['inviteToken'], 'secret');
    });
  });

  // ── accessLabel ─────────────────────────────────────────────────────────────

  group('accessLabel', () {
    test('public channel', () {
      final p = ChannelInvitePayload(
        channelId: '', channelName: '#x', nostrTag: 'nexus-channel-x',
        isPublic: true, isDiscoverable: true,
      );
      expect(p.accessLabel, 'Öffentlicher Kanal');
    });

    test('private+visible channel', () {
      final p = ChannelInvitePayload(
        channelId: '', channelName: '#x', nostrTag: 'nexus-channel-x',
        isPublic: false, isDiscoverable: true,
      );
      expect(p.accessLabel, contains('Antrag'));
    });

    test('private+hidden channel', () {
      final p = ChannelInvitePayload(
        channelId: '', channelName: '#x', nostrTag: 'nexus-channel-x',
        isPublic: false, isDiscoverable: false,
      );
      expect(p.accessLabel, contains('Einladung'));
    });
  });
}
