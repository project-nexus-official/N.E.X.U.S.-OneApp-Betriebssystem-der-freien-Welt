import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/core/transport/nexus_message.dart';
import 'package:nexus_oneapp/core/transport/nostr/nostr_event.dart';
import 'package:nexus_oneapp/core/transport/nostr/nostr_keys.dart';
import 'package:nexus_oneapp/core/transport/nostr/nostr_relay_manager.dart';
import 'package:nexus_oneapp/core/transport/nostr/nostr_transport.dart';
import 'package:nexus_oneapp/core/identity/bip39.dart';

// ── Fake relay manager that captures subscription filters ─────────────────────

class CapturingRelayManager extends NostrRelayManager {
  CapturingRelayManager() : super(relayUrls: []);

  final _eventCtrl = StreamController<NostrEvent>.broadcast();
  final List<Map<String, dynamic>> subscribedFilters = [];
  final List<NostrEvent> published = [];

  @override
  Stream<NostrEvent> get onEvent => _eventCtrl.stream;

  @override
  bool get hasConnectedRelay => true;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  void publish(NostrEvent event) => published.add(event);

  @override
  String subscribe(Map<String, dynamic> filter) {
    subscribedFilters.add(Map<String, dynamic>.from(filter));
    return generateSubId();
  }

  @override
  void closeSubscription(String subId) {}

  void injectEvent(NostrEvent event) => _eventCtrl.add(event);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

NostrTransport _makeTransport(CapturingRelayManager relay) => NostrTransport(
      localDid: 'did:key:alice',
      localPseudonym: 'Alice',
      relayManager: relay,
    );

NostrKeys _makeKeys() {
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
  return NostrKeys.fromBip39Seed(
    Uint8List.fromList(Bip39.mnemonicToSeed(mnemonic)),
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('NostrTransport – missed message catch-up', () {
    test('setLastMessageTimestamp is stored and exposed via since filter',
        () async {
      final relay = CapturingRelayManager();
      final transport = _makeTransport(relay);

      // 10 minutes ago
      final tenMinutesAgo =
          DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 - 600;
      transport.setLastMessageTimestamp(tenMinutesAgo);

      await transport.start(keysOverride: _makeKeys());

      // DM and mesh subscriptions should use tenMinutesAgo - 60 as since
      final expectedSince = tenMinutesAgo - 60;
      final dmFilter =
          relay.subscribedFilters.firstWhere((f) => f['kinds']?.contains(4) == true);
      final meshFilter =
          relay.subscribedFilters.firstWhere((f) => f['kinds']?.contains(1) == true);

      expect(dmFilter['since'], equals(expectedSince),
          reason: 'DM subscription must use saved timestamp');
      expect(meshFilter['since'], equals(expectedSince),
          reason: 'Broadcast subscription must use saved timestamp');

      await transport.stop();
    });

    test('without saved timestamp, since defaults to ~24 hours ago', () async {
      final relay = CapturingRelayManager();
      final transport = _makeTransport(relay);

      await transport.start(keysOverride: _makeKeys());

      final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      final dmFilter =
          relay.subscribedFilters.firstWhere((f) => f['kinds']?.contains(4) == true);

      // Should be roughly now - 86400 (within 30s tolerance for test execution time)
      final dmSince = dmFilter['since'] as int;
      expect(dmSince, greaterThan(nowSec - 86430));
      expect(dmSince, lessThan(nowSec - 86370));

      await transport.stop();
    });

    test('setLastMessageTimestamp only advances – never goes backward', () async {
      final relay = CapturingRelayManager();
      final transport = _makeTransport(relay);

      final t1 = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 - 1000;
      final t2 = t1 - 500; // older timestamp

      transport.setLastMessageTimestamp(t1);
      transport.setLastMessageTimestamp(t2); // should be ignored

      await transport.start(keysOverride: _makeKeys());

      final dmFilter =
          relay.subscribedFilters.firstWhere((f) => f['kinds']?.contains(4) == true);
      // Since should be t1 - 60, not t2 - 60
      expect(dmFilter['since'], equals(t1 - 60));

      await transport.stop();
    });

    test('DM and broadcast subscriptions both use the same msgSince value',
        () async {
      final relay = CapturingRelayManager();
      final transport = _makeTransport(relay);

      final ts =
          DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 - 7200; // 2h ago
      transport.setLastMessageTimestamp(ts);

      await transport.start(keysOverride: _makeKeys());

      final dmFilter =
          relay.subscribedFilters.firstWhere((f) => f['kinds']?.contains(4) == true);
      final meshFilter =
          relay.subscribedFilters.firstWhere((f) => f['kinds']?.contains(1) == true);

      expect(dmFilter['since'], equals(meshFilter['since']),
          reason: 'DM and broadcast must share the same since value');

      await transport.stop();
    });

    test('presence subscription always uses now - 300, not msgSince', () async {
      final relay = CapturingRelayManager();
      final transport = _makeTransport(relay);

      // Set a very old timestamp
      final oneDayAgo =
          DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 - 86400;
      transport.setLastMessageTimestamp(oneDayAgo);

      await transport.start(keysOverride: _makeKeys());

      final presenceFilter = relay.subscribedFilters
          .firstWhere((f) => f['kinds']?.contains(30078) == true);

      final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      final presenceSince = presenceFilter['since'] as int;

      // Presence should be recent (~5 min), not one day ago
      expect(presenceSince, greaterThan(nowSec - 330));
      expect(presenceSince, lessThan(nowSec - 270));

      await transport.stop();
    });

    test('received messages are delivered to stream after transport start',
        () async {
      final relay = CapturingRelayManager();
      final keys = _makeKeys();
      final transport = _makeTransport(relay);

      final received = <NexusMessage>[];
      final sub = transport.onMessageReceived.listen(received.add);

      await transport.start(keysOverride: keys);

      // Inject a broadcast event from a different peer
      const otherMnemonic =
          'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong';
      final otherKeys = NostrKeys.fromBip39Seed(
        Uint8List.fromList(Bip39.mnemonicToSeed(otherMnemonic)),
      );

      final msg = NexusMessage.create(
        fromDid: 'did:key:z6MkpTHR8VNsBxYAAWHut2Geadd9jSwuias8sisDArDJF69k',
        toDid: NexusMessage.broadcastDid,
        body: 'verpasste Nachricht',
        channel: '#mesh',
      );

      final event = NostrEvent.create(
        keys: otherKeys,
        kind: NostrKind.textNote,
        content: jsonEncode(msg.toJson()),
        tags: [
          ['t', 'nexus-mesh'],
        ],
      );

      relay.injectEvent(event);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(received, hasLength(1));
      expect(received.first.body, equals('verpasste Nachricht'));

      await sub.cancel();
      await transport.stop();
    });
  });

  group('Nostr catch-up – end-to-end missed message scenario', () {
    // Simulates the real scenario:
    // 1. App was previously running (T_last = now - 1h)
    // 2. App was closed
    // 3. Phone sends a broadcast at T_msg = now - 30min (while app was closed)
    // 4. App restarts with saved T_last, subscribes with since = T_last - 60
    // 5. Relay returns the historical event → app receives it

    test('historical broadcast is delivered after app restart with saved timestamp',
        () async {
      final relay = CapturingRelayManager();
      final keys = _makeKeys();
      final transport = _makeTransport(relay);

      final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      final tLast = nowSec - 3600; // last received message: 1 hour ago
      final tMsg = nowSec - 1800;  // missed message: sent 30 min ago

      // Simulate restored timestamp from SharedPreferences
      transport.setLastMessageTimestamp(tLast);

      final received = <NexusMessage>[];
      final sub = transport.onMessageReceived.listen(received.add);

      await transport.start(keysOverride: keys);

      // Verify since = tLast - 60 (with buffer) is in the filter
      final meshFilter = relay.subscribedFilters
          .firstWhere((f) => f['kinds']?.contains(1) == true);
      final since = meshFilter['since'] as int;
      expect(since, equals(tLast - 60),
          reason: 'since must be tLast - 60 (60 s relay-latency buffer)');
      expect(since, lessThan(tMsg),
          reason: 'since must be before the missed message timestamp');

      // Relay returns the historical event (created 30 min ago)
      const otherMnemonic =
          'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong';
      final otherKeys = NostrKeys.fromBip39Seed(
        Uint8List.fromList(Bip39.mnemonicToSeed(otherMnemonic)),
      );

      final missedMsg = NexusMessage.create(
        fromDid: 'did:key:z6MkpTHR8VNsBxYAAWHut2Geadd9jSwuias8sisDArDJF69k',
        toDid: NexusMessage.broadcastDid,
        body: 'Verpasste Nachricht (30 min alt)',
        channel: '#mesh',
      );

      final event = NostrEvent.create(
        keys: otherKeys,
        kind: NostrKind.textNote,
        content: jsonEncode(missedMsg.toJson()),
        tags: [['t', 'nexus-mesh']],
        // Use a timestamp in the past to simulate a historical event
        timestamp: DateTime.fromMillisecondsSinceEpoch(tMsg * 1000, isUtc: true),
      );

      relay.injectEvent(event);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(received, hasLength(1),
          reason: 'Historical broadcast must be delivered');
      expect(received.first.body, equals('Verpasste Nachricht (30 min alt)'));

      await sub.cancel();
      await transport.stop();
    });

    test('message predating since window is NOT delivered (relay would not return it)',
        () {
      // This test documents relay behavior: a since filter means
      // "only events where created_at >= since". We verify the math:
      final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      final tLast = nowSec - 3600; // 1 hour ago
      final since = tLast - 60;    // since = 1h + 60s ago

      // A message sent 2 hours ago would be excluded by the relay
      final tOldMsg = nowSec - 7200; // 2 hours ago
      expect(tOldMsg, lessThan(since),
          reason: 'Message from 2h ago is before the since filter and would be excluded');

      // A message sent 30 min ago would be included
      final tRecentMsg = nowSec - 1800; // 30 min ago
      expect(tRecentMsg, greaterThan(since),
          reason: 'Message from 30 min ago is after since and would be included');
    });

    test('app with no prior history fetches last 24 hours by default', () async {
      final relay = CapturingRelayManager();
      final transport = _makeTransport(relay);
      // No setLastMessageTimestamp call → null → default 24h

      await transport.start(keysOverride: _makeKeys());

      final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      final dmFilter = relay.subscribedFilters
          .firstWhere((f) => f['kinds']?.contains(4) == true);
      final since = dmFilter['since'] as int;

      expect(since, greaterThan(nowSec - 86430),
          reason: 'Default since must be roughly 24h ago');
      expect(since, lessThan(nowSec - 86370),
          reason: 'Default since must be roughly 24h ago');

      await transport.stop();
    });
  });

  group('Nostr catch-up – chronological ordering', () {
    test('messages are sorted by timestamp ascending', () {
      final now = DateTime.now().toUtc();
      final messages = [
        NexusMessage(
          id: '3',
          fromDid: 'did:key:alice',
          toDid: NexusMessage.broadcastDid,
          type: NexusMessageType.text,
          body: 'dritte',
          timestamp: now,
          ttlHours: 24,
          hopCount: 0,
        ),
        NexusMessage(
          id: '1',
          fromDid: 'did:key:alice',
          toDid: NexusMessage.broadcastDid,
          type: NexusMessageType.text,
          body: 'erste',
          timestamp: now.subtract(const Duration(hours: 2)),
          ttlHours: 24,
          hopCount: 0,
        ),
        NexusMessage(
          id: '2',
          fromDid: 'did:key:alice',
          toDid: NexusMessage.broadcastDid,
          type: NexusMessageType.text,
          body: 'zweite',
          timestamp: now.subtract(const Duration(hours: 1)),
          ttlHours: 24,
          hopCount: 0,
        ),
      ];

      final sorted = [...messages]
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

      expect(sorted[0].body, equals('erste'));
      expect(sorted[1].body, equals('zweite'));
      expect(sorted[2].body, equals('dritte'));
    });
  });
}
