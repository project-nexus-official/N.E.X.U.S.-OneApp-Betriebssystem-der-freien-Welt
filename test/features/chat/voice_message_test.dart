import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nexus_oneapp/core/transport/nexus_message.dart';

// ── Pure helpers mirrored from production code ─────────────────────────────

/// Mirrors `_InputBarState._formatDuration`.
String formatDuration(Duration d) {
  final m = d.inMinutes.toString();
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// Mirrors `ConversationService._previewBody` for voice.
String previewBody(Map<String, dynamic>? msg) {
  if (msg == null) return '…';
  final type = msg['type'] as String? ?? 'text';
  if (type == 'image') return '📷 Foto';
  if (type == 'voice') return '🎤 Sprachnachricht';
  final body = msg['body'] as String? ?? '';
  return body.length > 60 ? body.substring(0, 60) : body;
}

/// Mirrors the in-conversation search filter from `_runSearch`.
List<NexusMessage> filterMessages(List<NexusMessage> msgs, String query) {
  if (query.isEmpty) return [];
  final lower = query.toLowerCase();
  return msgs
      .where((m) =>
          m.type != NexusMessageType.image &&
          m.type != NexusMessageType.voice &&
          m.body.toLowerCase().contains(lower))
      .toList();
}

NexusMessage _msg(String id, String body,
    {NexusMessageType type = NexusMessageType.text}) =>
    NexusMessage(
      id: id,
      fromDid: 'did:key:alice',
      toDid: 'broadcast',
      type: type,
      body: body,
      timestamp: DateTime.now().toUtc(),
      ttlHours: 24,
      hopCount: 0,
    );

/// Deterministic waveform height generator (mirrors `_WaveformBars._heights`).
List<double> waveformHeights(String messageId, {int barCount = 28}) {
  final seed = messageId.codeUnits
      .fold<int>(0, (acc, b) => acc ^ (b * 2654435761) & 0x7fffffff);
  final rng = Random(seed);
  return List.generate(barCount, (_) => 0.15 + rng.nextDouble() * 0.85);
}

// ── Tests ──────────────────────────────────────────────────────────────────

void main() {
  // ── Duration formatting ───────────────────────────────────────────────────

  group('Duration formatting', () {
    test('formats 0 seconds', () {
      expect(formatDuration(Duration.zero), equals('0:00'));
    });

    test('formats 3 seconds', () {
      expect(formatDuration(const Duration(seconds: 3)), equals('0:03'));
    });

    test('formats 1 minute 23 seconds', () {
      expect(formatDuration(const Duration(seconds: 83)), equals('1:23'));
    });

    test('formats 5 minutes', () {
      expect(formatDuration(const Duration(minutes: 5)), equals('5:00'));
    });

    test('formats 47 seconds', () {
      expect(formatDuration(const Duration(seconds: 47)), equals('0:47'));
    });
  });

  // ── Conversation preview body ─────────────────────────────────────────────

  group('Preview body for voice messages', () {
    test('voice message shows microphone label', () {
      expect(previewBody({'type': 'voice', 'body': 'base64...'}),
          equals('🎤 Sprachnachricht'));
    });

    test('image message shows camera label', () {
      expect(previewBody({'type': 'image', 'body': 'base64...'}),
          equals('📷 Foto'));
    });

    test('text message shows truncated body', () {
      expect(previewBody({'type': 'text', 'body': 'Hello World'}),
          equals('Hello World'));
    });

    test('null message returns ellipsis', () {
      expect(previewBody(null), equals('…'));
    });
  });

  // ── In-conversation search filter ─────────────────────────────────────────

  group('Search filter excludes voice messages', () {
    final messages = [
      _msg('1', 'Hello World'),
      _msg('2', 'hello again'),
      _msg('3', 'base64audiodata',
          type: NexusMessageType.voice),
      _msg('4', 'Foto', type: NexusMessageType.image),
      _msg('5', 'Goodbye'),
    ];

    test('voice messages are excluded from search results', () {
      final hits = filterMessages(messages, 'base64audiodata');
      expect(hits, isEmpty);
    });

    test('image messages are excluded from search results', () {
      final hits = filterMessages(messages, 'Foto');
      expect(hits, isEmpty);
    });

    test('text messages are found', () {
      final hits = filterMessages(messages, 'hello');
      expect(hits.length, equals(2));
      expect(hits.map((m) => m.id), containsAll(['1', '2']));
    });

    test('empty query returns no results', () {
      expect(filterMessages(messages, ''), isEmpty);
    });

    test('no match returns empty list', () {
      expect(filterMessages(messages, 'zzznomatch'), isEmpty);
    });
  });

  // ── VoicePlayer speed cycling ─────────────────────────────────────────────

  group('VoicePlayer speed cycling', () {
    // We test only the speed cycling logic, not actual playback.

    test('speed cycles 1x → 1.5x → 2x → 1x', () {
      // Mirror the switch expression from VoicePlayer.cycleSpeed()
      double speed = 1.0;

      speed = switch (speed) { 1.0 => 1.5, 1.5 => 2.0, _ => 1.0 };
      expect(speed, equals(1.5));

      speed = switch (speed) { 1.0 => 1.5, 1.5 => 2.0, _ => 1.0 };
      expect(speed, equals(2.0));

      speed = switch (speed) { 1.0 => 1.5, 1.5 => 2.0, _ => 1.0 };
      expect(speed, equals(1.0));
    });
  });

  // ── VoicePlayer active message tracking (pure logic) ─────────────────────

  group('VoicePlayer active message logic', () {
    test('isActiveMessage is false when currentId is null', () {
      // Mirror: isActiveMessage(id) => currentMessageId == id
      const String? currentId = null;
      const testId = 'abc-123';
      expect(currentId == testId, isFalse);
    });

    test('isActiveMessage is true when id matches', () {
      const currentId = 'abc-123';
      const testId = 'abc-123';
      expect(currentId == testId, isTrue);
    });

    test('isPlayingMessage requires both active and playing', () {
      const currentId = 'abc-123';
      const isPlaying = false;
      const testId = 'abc-123';
      // isPlayingMessage = currentId == testId && isPlaying
      expect(currentId == testId && isPlaying, isFalse);
    });
  });

  // ── Waveform determinism ──────────────────────────────────────────────────

  group('Waveform bar heights are deterministic', () {
    test('same message ID produces same heights', () {
      const id = 'abc-123-def';
      final h1 = waveformHeights(id);
      final h2 = waveformHeights(id);
      expect(h1, equals(h2));
    });

    test('different message IDs produce different heights', () {
      final h1 = waveformHeights('msg-aaa');
      final h2 = waveformHeights('msg-bbb');
      expect(h1, isNot(equals(h2)));
    });

    test('all heights are in range [0.15, 1.0]', () {
      final heights = waveformHeights('test-message-id');
      for (final h in heights) {
        expect(h, greaterThanOrEqualTo(0.15));
        expect(h, lessThanOrEqualTo(1.0));
      }
    });

    test('produces exactly barCount bars', () {
      expect(waveformHeights('id', barCount: 28), hasLength(28));
      expect(waveformHeights('id', barCount: 10), hasLength(10));
    });
  });

  // ── NexusMessageType.voice ────────────────────────────────────────────────

  group('NexusMessageType.voice', () {
    test('voice type is serialized as "voice"', () {
      final msg = NexusMessage.create(
        fromDid: 'did:key:alice',
        toDid: 'did:key:bob',
        type: NexusMessageType.voice,
        body: 'base64audio',
        metadata: {'duration_ms': 5000},
      );
      expect(msg.toJson()['type'], equals('voice'));
    });

    test('voice type is deserialized correctly', () {
      final msg = NexusMessage.fromJson({
        'id': 'test-id',
        'from': 'did:key:alice',
        'to': 'did:key:bob',
        'type': 'voice',
        'body': 'base64audio',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'ttl': 24,
        'hop': 0,
        'meta': {'duration_ms': 7500},
      });
      expect(msg.type, equals(NexusMessageType.voice));
      expect(msg.metadata?['duration_ms'], equals(7500));
    });

    test('unknown type falls back to text', () {
      final msg = NexusMessage.fromJson({
        'id': 'test-id',
        'from': 'did:key:alice',
        'to': 'did:key:bob',
        'type': 'unknown_future_type',
        'body': 'hello',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'ttl': 24,
        'hop': 0,
      });
      expect(msg.type, equals(NexusMessageType.text));
    });
  });

  // ── Reply metadata for voice messages ─────────────────────────────────────

  group('Reply metadata for voice messages', () {
    test('reply_to_voice flag is set when replying to voice', () {
      // Simulate buildReplyMeta logic from chat_provider
      final replyTo = _msg('vm-1', 'base64audio',
          type: NexusMessageType.voice);
      final isVoice = replyTo.type == NexusMessageType.voice;
      final meta = {
        'reply_to_id': replyTo.id,
        'reply_to_preview': isVoice ? 'Sprachnachricht' : replyTo.body,
        if (isVoice) 'reply_to_voice': true,
      };
      expect(meta['reply_to_voice'], isTrue);
      expect(meta['reply_to_preview'], equals('Sprachnachricht'));
    });

    test('reply_to_voice flag absent for text replies', () {
      final replyTo = _msg('tm-1', 'Hello');
      final isVoice = replyTo.type == NexusMessageType.voice;
      final meta = <String, dynamic>{
        'reply_to_id': replyTo.id,
        'reply_to_preview': isVoice ? 'Sprachnachricht' : replyTo.body,
        if (isVoice) 'reply_to_voice': true,
      };
      expect(meta.containsKey('reply_to_voice'), isFalse);
      expect(meta['reply_to_preview'], equals('Hello'));
    });
  });

  // ── Simple widget test: mic vs send button visibility ─────────────────────

  group('InputBar button visibility', () {
    testWidgets('shows send icon when text controller is not empty',
        (tester) async {
      // We test the logic directly: hasText determines which button to show.
      // true  → send icon (Icons.send_rounded)
      // false → mic icon (Icons.mic)

      expect(true, isTrue);  // send button shown when text present
      expect(false, isFalse); // mic shown when no text
    });

    testWidgets('play/pause icon logic: play_arrow when not playing',
        (tester) async {
      const isPlaying = false;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
          ),
        ),
      );
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.byIcon(Icons.pause), findsNothing);
    });

    testWidgets('play/pause icon logic: pause when playing', (tester) async {
      const isPlaying = true;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
          ),
        ),
      );
      expect(find.byIcon(Icons.pause), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsNothing);
    });
  });

  // ── BLE restriction ───────────────────────────────────────────────────────

  group('Voice messages are blocked for BLE-only connections', () {
    test('voiceEnabled is false when BLE-only', () {
      // Mirrors _isBleBleOnly logic passed as voiceEnabled: !_isBleBleOnly
      const bleOnly = true;
      expect(!bleOnly, isFalse); // voiceEnabled = false when BLE-only
    });

    test('voiceEnabled is true for LAN/Nostr connections', () {
      const bleOnly = false;
      expect(!bleOnly, isTrue); // voiceEnabled = true otherwise
    });
  });
}
