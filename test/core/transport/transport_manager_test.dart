import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/core/transport/message_transport.dart';
import 'package:nexus_oneapp/core/transport/nexus_message.dart';
import 'package:nexus_oneapp/core/transport/nexus_peer.dart';
import 'package:nexus_oneapp/core/transport/transport_manager.dart';

// ── Fake transport for testing ─────────────────────────────────────────────

class FakeTransport implements MessageTransport {
  FakeTransport({
    required this.type,
    this.shouldFailSend = false,
    this.startThrows = false,
  });

  @override
  final TransportType type;

  bool shouldFailSend;
  bool startThrows;
  bool started = false;
  bool stopped = false;

  final _msgCtrl = StreamController<NexusMessage>.broadcast();
  final _peersCtrl = StreamController<List<NexusPeer>>.broadcast();

  final List<NexusMessage> sent = [];

  TransportState _state = TransportState.idle;

  @override
  TransportState get state => _state;

  @override
  Stream<NexusMessage> get onMessageReceived => _msgCtrl.stream;

  @override
  Stream<List<NexusPeer>> get onPeersChanged => _peersCtrl.stream;

  @override
  Future<void> start() async {
    if (startThrows) throw StateError('start failed');
    _state = TransportState.scanning;
    started = true;
  }

  @override
  Future<void> stop() async {
    _state = TransportState.idle;
    stopped = true;
    await _msgCtrl.close();
    await _peersCtrl.close();
  }

  @override
  Future<void> sendMessage(NexusMessage message, {String? recipientDid}) async {
    if (shouldFailSend) throw StateError('send failed');
    sent.add(message);
  }

  /// Simulates receiving a message from the network.
  void simulateReceive(NexusMessage msg) => _msgCtrl.add(msg);

  /// Simulates a peer discovery event.
  void simulatePeers(List<NexusPeer> peers) => _peersCtrl.add(peers);
}

// ── Helper ─────────────────────────────────────────────────────────────────

TransportManager _freshManager() {
  // We can't re-use the singleton in tests without full reset, so we test
  // the manager logic through a fresh isolated instance.
  //
  // Because TransportManager is a singleton, we reset it between tests
  // via stop() + clearTransports().
  final m = TransportManager.instance;
  m.clearTransports();
  return m;
}

// ── Tests ──────────────────────────────────────────────────────────────────

void main() {
  tearDown(() async {
    await TransportManager.instance.stop();
    TransportManager.instance.clearTransports();
  });

  group('TransportManager – registration and start', () {
    test('registers transports and starts them', () async {
      final manager = _freshManager();
      final ble = FakeTransport(type: TransportType.ble);
      final nostr = FakeTransport(type: TransportType.nostr);

      manager.registerTransport(ble);
      manager.registerTransport(nostr);
      await manager.start();

      expect(ble.started, isTrue);
      expect(nostr.started, isTrue);
    });

    test('a failing transport does not prevent others from starting', () async {
      final manager = _freshManager();
      final failing = FakeTransport(type: TransportType.ble, startThrows: true);
      final working = FakeTransport(type: TransportType.nostr);

      manager.registerTransport(failing);
      manager.registerTransport(working);

      await expectLater(manager.start(), completes);
      expect(working.started, isTrue);
    });
  });

  group('TransportManager – message sending (fallback cascade)', () {
    test('sends via first (BLE) transport when available', () async {
      final manager = _freshManager();
      final ble = FakeTransport(type: TransportType.ble);
      final nostr = FakeTransport(type: TransportType.nostr);

      manager.registerTransport(ble);
      manager.registerTransport(nostr);
      await manager.start();

      final msg = NexusMessage.create(fromDid: 'did:key:zA', body: 'hello');
      await manager.sendMessage(msg);

      expect(ble.sent, hasLength(1));
      expect(nostr.sent, isEmpty);
    });

    test('falls back to Nostr when BLE send fails', () async {
      final manager = _freshManager();
      final ble = FakeTransport(
        type: TransportType.ble,
        shouldFailSend: true,
      );
      final nostr = FakeTransport(type: TransportType.nostr);

      manager.registerTransport(ble);
      manager.registerTransport(nostr);
      await manager.start();

      final msg = NexusMessage.create(fromDid: 'did:key:zA', body: 'fallback');
      await manager.sendMessage(msg);

      expect(nostr.sent, hasLength(1));
    });

    test('throws when all transports fail to send', () async {
      final manager = _freshManager();
      final ble = FakeTransport(type: TransportType.ble, shouldFailSend: true);
      final nostr = FakeTransport(type: TransportType.nostr, shouldFailSend: true);

      manager.registerTransport(ble);
      manager.registerTransport(nostr);
      await manager.start();

      final msg = NexusMessage.create(fromDid: 'did:key:zA', body: 'none');
      await expectLater(
        manager.sendMessage(msg),
        throwsA(isA<StateError>()),
      );
    });

    test('throws when no transport is registered', () async {
      final manager = _freshManager();
      // Do NOT register any transport

      final msg = NexusMessage.create(fromDid: 'did:key:zA', body: 'nobody');
      await expectLater(
        manager.sendMessage(msg),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('TransportManager – incoming messages', () {
    test('forwards received messages to onMessageReceived stream', () async {
      final manager = _freshManager();
      final ble = FakeTransport(type: TransportType.ble);
      manager.registerTransport(ble);
      await manager.start();

      final msg = NexusMessage.create(fromDid: 'did:key:zAlice', body: 'hi!');

      final received = <NexusMessage>[];
      final sub = manager.onMessageReceived.listen(received.add);

      ble.simulateReceive(msg);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();

      expect(received, hasLength(1));
      expect(received.first.id, msg.id);
    });

    test('deduplicates: same message from two transports counted once', () async {
      final manager = _freshManager();
      final ble = FakeTransport(type: TransportType.ble);
      final nostr = FakeTransport(type: TransportType.nostr);
      manager.registerTransport(ble);
      manager.registerTransport(nostr);
      await manager.start();

      final msg = NexusMessage.create(fromDid: 'did:key:zAlice', body: 'dup');

      final received = <NexusMessage>[];
      final sub = manager.onMessageReceived.listen(received.add);

      ble.simulateReceive(msg);
      nostr.simulateReceive(msg); // same message, different transport

      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();

      expect(received, hasLength(1));
    });

    test('drops expired messages', () async {
      final manager = _freshManager();
      final ble = FakeTransport(type: TransportType.ble);
      manager.registerTransport(ble);
      await manager.start();

      final expired = NexusMessage(
        id: 'expired-id',
        fromDid: 'did:key:zA',
        toDid: NexusMessage.broadcastDid,
        type: NexusMessageType.text,
        body: 'old news',
        timestamp: DateTime.now().toUtc().subtract(const Duration(hours: 13)),
        ttlHours: 12,
      );

      final received = <NexusMessage>[];
      final sub = manager.onMessageReceived.listen(received.add);

      ble.simulateReceive(expired);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();

      expect(received, isEmpty);
    });

    test('does not echo own sent messages back', () async {
      final manager = _freshManager();
      final ble = FakeTransport(type: TransportType.ble);
      manager.registerTransport(ble);
      await manager.start();

      final msg = NexusMessage.create(fromDid: 'did:key:zA', body: 'no echo');

      final received = <NexusMessage>[];
      final sub = manager.onMessageReceived.listen(received.add);

      // Send (this marks msg.id as seen)
      await manager.sendMessage(msg);
      // Simulate the BLE layer echoing it back
      ble.simulateReceive(msg);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();

      expect(received, isEmpty);
    });
  });

  group('TransportManager – peer tracking', () {
    test('merges peers from multiple transports', () async {
      final manager = _freshManager();
      final ble = FakeTransport(type: TransportType.ble);
      final nostr = FakeTransport(type: TransportType.nostr);
      manager.registerTransport(ble);
      manager.registerTransport(nostr);
      await manager.start();

      final blePeer = NexusPeer(
        did: 'did:key:zAlice',
        pseudonym: 'Alice',
        transportType: TransportType.ble,
        lastSeen: DateTime.now(),
      );
      final nostrPeer = NexusPeer(
        did: 'did:key:zBob',
        pseudonym: 'Bob',
        transportType: TransportType.nostr,
        lastSeen: DateTime.now(),
      );

      ble.simulatePeers([blePeer]);
      nostr.simulatePeers([nostrPeer]);

      await Future<void>.delayed(const Duration(milliseconds: 10));

      final peers = manager.peers;
      expect(peers.length, 2);
      expect(peers.any((p) => p.did == blePeer.did), isTrue);
      expect(peers.any((p) => p.did == nostrPeer.did), isTrue);
    });
  });
}
