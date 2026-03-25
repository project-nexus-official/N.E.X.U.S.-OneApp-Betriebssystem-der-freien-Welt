import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/core/identity/bip39.dart';
import 'package:nexus_oneapp/core/transport/nexus_message.dart';
import 'package:nexus_oneapp/core/transport/nostr/nostr_event.dart';
import 'package:nexus_oneapp/core/transport/nostr/nostr_keys.dart';
import 'package:nexus_oneapp/core/transport/nostr/nostr_relay_manager.dart';
import 'package:nexus_oneapp/core/transport/nostr/nostr_transport.dart';

// ── Fake relay manager ────────────────────────────────────────────────────────

class FakeRelayManager extends NostrRelayManager {
  FakeRelayManager() : super(relayUrls: []);

  final _eventCtrl = StreamController<NostrEvent>.broadcast();
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
  String subscribe(Map<String, dynamic> filter) => generateSubId();

  @override
  void closeSubscription(String subId) {}

  void injectEvent(NostrEvent event) => _eventCtrl.add(event);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

NostrKeys _keysFromMnemonic(String mnemonic) {
  final seed = Uint8List.fromList(Bip39.mnemonicToSeed(mnemonic));
  return NostrKeys.fromBip39Seed(seed);
}

const _mnemonicAlice =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const _mnemonicBob =
    'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong';

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late NostrKeys aliceKeys;
  late NostrKeys bobKeys;

  setUpAll(() {
    aliceKeys = _keysFromMnemonic(_mnemonicAlice);
    bobKeys = _keysFromMnemonic(_mnemonicBob);
  });

  // ── Presence event structure ───────────────────────────────────────────────

  group('Presence event - structure', () {
    test('start() publishes a presence event immediately', () async {
      final relay = FakeRelayManager();
      final transport = NostrTransport(
        localDid: 'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK',
        localPseudonym: 'Alice',
        relayManager: relay,
        presenceInterval: const Duration(hours: 1), // don't fire during test
      );

      await transport.start(keysOverride: aliceKeys);

      final presenceEvents =
          relay.published.where((e) => e.kind == NostrKind.presence).toList();
      expect(presenceEvents, hasLength(1));

      await transport.stop();
    });

    test('presence event has correct kind (30078)', () async {
      final relay = FakeRelayManager();
      final transport = NostrTransport(
        localDid: 'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK',
        localPseudonym: 'Alice',
        relayManager: relay,
        presenceInterval: const Duration(hours: 1),
      );

      await transport.start(keysOverride: aliceKeys);

      final ev = relay.published.firstWhere((e) => e.kind == NostrKind.presence);
      expect(ev.kind, equals(30078));

      await transport.stop();
    });

    test('presence event contains nexus-presence tag', () async {
      final relay = FakeRelayManager();
      final transport = NostrTransport(
        localDid: 'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK',
        localPseudonym: 'Alice',
        relayManager: relay,
        presenceInterval: const Duration(hours: 1),
      );

      await transport.start(keysOverride: aliceKeys);

      final ev = relay.published.firstWhere((e) => e.kind == NostrKind.presence);
      expect(ev.tagValues('t'), contains('nexus-presence'));

      await transport.stop();
    });

    test('presence event content contains DID and pseudonym', () async {
      const did = 'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK';
      const pseudonym = 'Alice';
      final relay = FakeRelayManager();
      final transport = NostrTransport(
        localDid: did,
        localPseudonym: pseudonym,
        relayManager: relay,
        presenceInterval: const Duration(hours: 1),
      );

      await transport.start(keysOverride: aliceKeys);

      final ev = relay.published.firstWhere((e) => e.kind == NostrKind.presence);
      final content = jsonDecode(ev.content) as Map<String, dynamic>;
      expect(content['did'], equals(did));
      expect(content['pseudonym'], equals(pseudonym));

      await transport.stop();
    });

    test('presence event contains geohash tag when geohash is set', () async {
      final relay = FakeRelayManager();
      final transport = NostrTransport(
        localDid: 'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK',
        localPseudonym: 'Alice',
        relayManager: relay,
        presenceInterval: const Duration(hours: 1),
      );
      transport.currentGeohash = 'u33d8';

      await transport.start(keysOverride: aliceKeys);

      final ev = relay.published.firstWhere((e) => e.kind == NostrKind.presence);
      expect(ev.tagValues('t'), contains('nexus-geo-u33d8'));

      await transport.stop();
    });

    test('presence event has d-tag "nexus-presence" (NIP-78 replaceable)', () async {
      final relay = FakeRelayManager();
      final transport = NostrTransport(
        localDid: 'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK',
        localPseudonym: 'Alice',
        relayManager: relay,
        presenceInterval: const Duration(hours: 1),
      );

      await transport.start(keysOverride: aliceKeys);

      final ev = relay.published.firstWhere((e) => e.kind == NostrKind.presence);
      expect(ev.tagValue('d'), equals('nexus-presence'));

      await transport.stop();
    });

    test('presence event is signed and verifies', () async {
      final relay = FakeRelayManager();
      final transport = NostrTransport(
        localDid: 'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK',
        localPseudonym: 'Alice',
        relayManager: relay,
        presenceInterval: const Duration(hours: 1),
      );

      await transport.start(keysOverride: aliceKeys);

      final ev = relay.published.firstWhere((e) => e.kind == NostrKind.presence);
      expect(ev.verify(), isTrue);

      await transport.stop();
    });
  });

  // ── Peer discovery via presence ────────────────────────────────────────────

  group('Peer discovery via presence', () {
    test('incoming presence event adds peer to currentPeers', () async {
      final relay = FakeRelayManager();
      final transport = NostrTransport(
        localDid: 'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK',
        localPseudonym: 'Alice',
        relayManager: relay,
        presenceInterval: const Duration(hours: 1),
      );

      await transport.start(keysOverride: aliceKeys);

      // Simulate Bob's presence event arriving from a relay
      const bobDid = 'did:key:z6MkpTHR8VNsBxYAAWHut2Geadd9jSwuias8sisDArDJF69k';
      final bobPresence = NostrEvent.create(
        keys: bobKeys,
        kind: NostrKind.presence,
        content: jsonEncode({'did': bobDid, 'pseudonym': 'Bob'}),
        tags: [
          ['d', 'nexus-presence'],
          ['t', 'nexus-presence'],
          ['did', bobDid],
          ['name', 'Bob'],
        ],
      );
      relay.injectEvent(bobPresence);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(transport.currentPeers, hasLength(1));
      expect(transport.currentPeers.first.did, equals(bobDid));
      expect(transport.currentPeers.first.pseudonym, equals('Bob'));

      await transport.stop();
    });

    test('presence event stores DID-to-Nostr-pubkey mapping', () async {
      final relay = FakeRelayManager();
      final transport = NostrTransport(
        localDid: 'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK',
        localPseudonym: 'Alice',
        relayManager: relay,
        presenceInterval: const Duration(hours: 1),
      );

      await transport.start(keysOverride: aliceKeys);

      const bobDid = 'did:key:z6MkpTHR8VNsBxYAAWHut2Geadd9jSwuias8sisDArDJF69k';
      final bobPresence = NostrEvent.create(
        keys: bobKeys,
        kind: NostrKind.presence,
        content: jsonEncode({'did': bobDid, 'pseudonym': 'Bob'}),
        tags: [
          ['d', 'nexus-presence'],
          ['t', 'nexus-presence'],
          ['did', bobDid],
          ['name', 'Bob'],
        ],
      );
      relay.injectEvent(bobPresence);
      await Future.delayed(const Duration(milliseconds: 50));

      // After presence is learned, a DM to Bob's DID should be published
      // (transport looks up DID → Nostr pubkey → can send Kind-4 event)
      final dmMsg = _makeMessage(
        fromDid: 'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK',
        toDid: bobDid,
        body: 'hello bob',
      );
      relay.published.clear();
      await transport.sendMessage(dmMsg, recipientDid: bobDid);

      // Should have published a Kind-4 DM (mapping was learned)
      expect(relay.published, hasLength(1));
      expect(relay.published.first.kind, equals(NostrKind.encryptedDm));

      await transport.stop();
    });

    test('own presence event is ignored (not added as peer)', () async {
      final relay = FakeRelayManager();
      final transport = NostrTransport(
        localDid: 'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK',
        localPseudonym: 'Alice',
        relayManager: relay,
        presenceInterval: const Duration(hours: 1),
      );

      await transport.start(keysOverride: aliceKeys);

      // Inject Alice's own presence event back (relay echo)
      final ownPresence = relay.published
          .firstWhere((e) => e.kind == NostrKind.presence);
      relay.injectEvent(ownPresence);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(transport.currentPeers, isEmpty);

      await transport.stop();
    });

    test('multiple presence events from different peers add multiple peers',
        () async {
      final relay = FakeRelayManager();
      final transport = NostrTransport(
        localDid: 'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK',
        localPseudonym: 'Alice',
        relayManager: relay,
        presenceInterval: const Duration(hours: 1),
      );

      await transport.start(keysOverride: aliceKeys);

      const bobDid = 'did:key:z6MkpTHR8VNsBxYAAWHut2Geadd9jSwuias8sisDArDJF69k';
      const charlieMnemonic =
          'legal winner thank year wave sausage worth useful legal winner thank yellow';
      final charlieKeys = _keysFromMnemonic(charlieMnemonic);
      const charlieDid = 'did:key:z6Mkk7oqU9EA9LcC7MHn4HG3LBgzBLEiMN6FxdmGCYaewKH';

      relay.injectEvent(NostrEvent.create(
        keys: bobKeys,
        kind: NostrKind.presence,
        content: jsonEncode({'did': bobDid, 'pseudonym': 'Bob'}),
        tags: [
          ['d', 'nexus-presence'],
          ['t', 'nexus-presence'],
          ['did', bobDid],
          ['name', 'Bob'],
        ],
      ));
      relay.injectEvent(NostrEvent.create(
        keys: charlieKeys,
        kind: NostrKind.presence,
        content: jsonEncode({'did': charlieDid, 'pseudonym': 'Charlie'}),
        tags: [
          ['d', 'nexus-presence'],
          ['t', 'nexus-presence'],
          ['did', charlieDid],
          ['name', 'Charlie'],
        ],
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      expect(transport.currentPeers, hasLength(2));

      await transport.stop();
    });
  });

  // ── Peer timeout / eviction ────────────────────────────────────────────────

  group('Peer timeout', () {
    test('peer is evicted after peerTimeout with no new presence', () async {
      final relay = FakeRelayManager();
      // Very short timeout so the test doesn't have to wait long
      final transport = NostrTransport(
        localDid: 'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK',
        localPseudonym: 'Alice',
        relayManager: relay,
        presenceInterval: const Duration(milliseconds: 120),
        peerTimeout: const Duration(milliseconds: 80),
      );

      await transport.start(keysOverride: aliceKeys);

      const bobDid = 'did:key:z6MkpTHR8VNsBxYAAWHut2Geadd9jSwuias8sisDArDJF69k';
      relay.injectEvent(NostrEvent.create(
        keys: bobKeys,
        kind: NostrKind.presence,
        content: jsonEncode({'did': bobDid, 'pseudonym': 'Bob'}),
        tags: [
          ['d', 'nexus-presence'],
          ['t', 'nexus-presence'],
          ['did', bobDid],
          ['name', 'Bob'],
        ],
      ));
      await Future.delayed(const Duration(milliseconds: 30));
      expect(transport.currentPeers, hasLength(1), reason: 'Bob should be present');

      // Wait for presence timer to fire and evict the stale peer
      await Future.delayed(const Duration(milliseconds: 200));
      expect(transport.currentPeers, isEmpty, reason: 'Bob should be evicted');

      await transport.stop();
    });

    test('peer is kept alive when presence events keep arriving', () async {
      final relay = FakeRelayManager();
      final transport = NostrTransport(
        localDid: 'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK',
        localPseudonym: 'Alice',
        relayManager: relay,
        presenceInterval: const Duration(milliseconds: 80),
        peerTimeout: const Duration(milliseconds: 150),
      );

      await transport.start(keysOverride: aliceKeys);

      const bobDid = 'did:key:z6MkpTHR8VNsBxYAAWHut2Geadd9jSwuias8sisDArDJF69k';

      Future<void> injectBobPresence() async {
        relay.injectEvent(NostrEvent.create(
          keys: bobKeys,
          kind: NostrKind.presence,
          content: jsonEncode({'did': bobDid, 'pseudonym': 'Bob'}),
          tags: [
            ['d', 'nexus-presence'],
            ['t', 'nexus-presence'],
            ['did', bobDid],
            ['name', 'Bob'],
          ],
        ));
      }

      // Inject presence repeatedly to keep Bob alive
      await injectBobPresence();
      await Future.delayed(const Duration(milliseconds: 60));
      await injectBobPresence();
      await Future.delayed(const Duration(milliseconds: 60));
      await injectBobPresence();
      await Future.delayed(const Duration(milliseconds: 60));

      expect(transport.currentPeers, hasLength(1),
          reason: 'Bob refreshed presence – should still be present');

      await transport.stop();
    });

    test('onPeersChanged emits when a stale peer is evicted', () async {
      final relay = FakeRelayManager();
      final transport = NostrTransport(
        localDid: 'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK',
        localPseudonym: 'Alice',
        relayManager: relay,
        presenceInterval: const Duration(milliseconds: 120),
        peerTimeout: const Duration(milliseconds: 80),
      );

      await transport.start(keysOverride: aliceKeys);

      final peerSnapshots = <int>[];
      final sub = transport.onPeersChanged.listen((p) => peerSnapshots.add(p.length));

      const bobDid = 'did:key:z6MkpTHR8VNsBxYAAWHut2Geadd9jSwuias8sisDArDJF69k';
      relay.injectEvent(NostrEvent.create(
        keys: bobKeys,
        kind: NostrKind.presence,
        content: jsonEncode({'did': bobDid, 'pseudonym': 'Bob'}),
        tags: [
          ['d', 'nexus-presence'],
          ['t', 'nexus-presence'],
          ['did', bobDid],
          ['name', 'Bob'],
        ],
      ));

      // Wait for peer to arrive, then for eviction timer
      await Future.delayed(const Duration(milliseconds: 300));

      // First emission: Bob added (1), second: Bob evicted (0)
      expect(peerSnapshots, containsAllInOrder([1, 0]));

      await sub.cancel();
      await transport.stop();
    });
  });

  // ── Periodic re-announcement ───────────────────────────────────────────────

  group('Periodic presence re-announcement', () {
    test('presence event is re-published after presenceInterval', () async {
      final relay = FakeRelayManager();
      final transport = NostrTransport(
        localDid: 'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK',
        localPseudonym: 'Alice',
        relayManager: relay,
        presenceInterval: const Duration(milliseconds: 100),
        peerTimeout: const Duration(minutes: 2),
      );

      await transport.start(keysOverride: aliceKeys);

      // At t=0: 1 presence event published
      final countBefore = relay.published
          .where((e) => e.kind == NostrKind.presence)
          .length;

      // Wait for two timer ticks
      await Future.delayed(const Duration(milliseconds: 250));

      final countAfter = relay.published
          .where((e) => e.kind == NostrKind.presence)
          .length;

      expect(countAfter, greaterThan(countBefore),
          reason: 'Should have re-published presence at least once');

      await transport.stop();
    });

    test('no more presence events published after stop()', () async {
      final relay = FakeRelayManager();
      final transport = NostrTransport(
        localDid: 'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK',
        localPseudonym: 'Alice',
        relayManager: relay,
        presenceInterval: const Duration(milliseconds: 80),
        peerTimeout: const Duration(minutes: 2),
      );

      await transport.start(keysOverride: aliceKeys);
      await Future.delayed(const Duration(milliseconds: 50));
      await transport.stop();

      final countAtStop =
          relay.published.where((e) => e.kind == NostrKind.presence).length;

      // Timer should be cancelled – no new events
      await Future.delayed(const Duration(milliseconds: 200));

      final countAfterStop =
          relay.published.where((e) => e.kind == NostrKind.presence).length;

      expect(countAfterStop, equals(countAtStop));
    });
  });
}

// ── Helper ────────────────────────────────────────────────────────────────────

NexusMessage _makeMessage({
  required String fromDid,
  required String toDid,
  required String body,
}) =>
    NexusMessage.create(fromDid: fromDid, toDid: toDid, body: body);
