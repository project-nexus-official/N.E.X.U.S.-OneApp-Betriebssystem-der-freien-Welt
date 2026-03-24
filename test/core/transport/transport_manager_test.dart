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
  final List<NexusPeer> _currentPeers = [];

  TransportState _state = TransportState.idle;

  @override
  TransportState get state => _state;

  @override
  Stream<NexusMessage> get onMessageReceived => _msgCtrl.stream;

  @override
  Stream<List<NexusPeer>> get onPeersChanged => _peersCtrl.stream;

  @override
  List<NexusPeer> get currentPeers => List.unmodifiable(_currentPeers);

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

  /// Simulates a peer discovery event and updates [currentPeers].
  void simulatePeers(List<NexusPeer> peers) {
    _currentPeers
      ..clear()
      ..addAll(peers);
    _peersCtrl.add(peers);
  }
}

// ── Helper ──────────────────────────────────────────────────────────────────

TransportManager _freshManager() {
  final m = TransportManager.instance;
  m.clearTransports();
  return m;
}

NexusPeer _peer(String did, TransportType type) => NexusPeer(
      did: did,
      pseudonym: did.substring(did.length - 5),
      transportType: type,
      lastSeen: DateTime.now(),
    );

// ── Tests ────────────────────────────────────────────────────────────────────

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

      manager
        ..registerTransport(ble)
        ..registerTransport(nostr);
      await manager.start();

      expect(ble.started, isTrue);
      expect(nostr.started, isTrue);
    });

    test('a failing transport does not prevent others from starting', () async {
      final manager = _freshManager();
      final failing =
          FakeTransport(type: TransportType.ble, startThrows: true);
      final working = FakeTransport(type: TransportType.nostr);

      manager
        ..registerTransport(failing)
        ..registerTransport(working);

      await expectLater(manager.start(), completes);
      expect(working.started, isTrue);
    });
  });

  group('TransportManager – message sending (fallback cascade)', () {
    test('sends via first (BLE) transport when available', () async {
      final manager = _freshManager();
      final ble = FakeTransport(type: TransportType.ble);
      final nostr = FakeTransport(type: TransportType.nostr);

      manager
        ..registerTransport(ble)
        ..registerTransport(nostr);
      await manager.start();

      final msg = NexusMessage.create(fromDid: 'did:key:zA', body: 'hello');
      await manager.sendMessage(msg);

      expect(ble.sent, hasLength(1));
      expect(nostr.sent, isEmpty);
    });

    test('falls back to Nostr when BLE send fails', () async {
      final manager = _freshManager();
      final ble = FakeTransport(type: TransportType.ble, shouldFailSend: true);
      final nostr = FakeTransport(type: TransportType.nostr);

      manager
        ..registerTransport(ble)
        ..registerTransport(nostr);
      await manager.start();

      final msg =
          NexusMessage.create(fromDid: 'did:key:zA', body: 'fallback');
      await manager.sendMessage(msg);

      expect(nostr.sent, hasLength(1));
    });

    test('throws when all transports fail to send', () async {
      final manager = _freshManager();
      final ble =
          FakeTransport(type: TransportType.ble, shouldFailSend: true);
      final nostr =
          FakeTransport(type: TransportType.nostr, shouldFailSend: true);

      manager
        ..registerTransport(ble)
        ..registerTransport(nostr);
      await manager.start();

      final msg = NexusMessage.create(fromDid: 'did:key:zA', body: 'none');
      await expectLater(
        manager.sendMessage(msg),
        throwsA(isA<StateError>()),
      );
    });

    test('throws when no transport is registered', () async {
      final manager = _freshManager();

      final msg =
          NexusMessage.create(fromDid: 'did:key:zA', body: 'nobody');
      await expectLater(
        manager.sendMessage(msg),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('TransportManager – LAN prefer logic', () {
    test('prefers LAN over BLE when recipient is reachable via LAN', () async {
      final manager = _freshManager();
      final ble = FakeTransport(type: TransportType.ble);
      final lan = FakeTransport(type: TransportType.lan);

      manager
        ..registerTransport(ble)
        ..registerTransport(lan);
      await manager.start();

      // Simulate: Bob is visible via LAN
      final bob = _peer('did:key:zBob', TransportType.lan);
      lan.simulatePeers([bob]);
      ble.simulatePeers([]); // BLE doesn't see Bob

      await Future<void>.delayed(const Duration(milliseconds: 10));

      final msg = NexusMessage.create(fromDid: 'did:key:zA', body: 'hi Bob');
      await manager.sendMessage(msg, recipientDid: 'did:key:zBob');

      expect(lan.sent, hasLength(1), reason: 'LAN should be preferred');
      expect(ble.sent, isEmpty);
    });

    test('falls back to BLE when peer is not on LAN', () async {
      final manager = _freshManager();
      final ble = FakeTransport(type: TransportType.ble);
      final lan = FakeTransport(type: TransportType.lan);

      manager
        ..registerTransport(ble)
        ..registerTransport(lan);
      await manager.start();

      // Bob is only visible via BLE
      final bob = _peer('did:key:zBob', TransportType.ble);
      ble.simulatePeers([bob]);
      lan.simulatePeers([]);

      await Future<void>.delayed(const Duration(milliseconds: 10));

      final msg = NexusMessage.create(fromDid: 'did:key:zA', body: 'hi Bob');
      // Send broadcast (no recipientDid) → should go via BLE (first registered)
      await manager.sendMessage(msg);

      expect(ble.sent, hasLength(1));
      expect(lan.sent, isEmpty);
    });

    test('LAN-prefer falls back to BLE if LAN send fails', () async {
      final manager = _freshManager();
      final ble = FakeTransport(type: TransportType.ble);
      final lan = FakeTransport(type: TransportType.lan, shouldFailSend: true);

      manager
        ..registerTransport(ble)
        ..registerTransport(lan);
      await manager.start();

      final bob = _peer('did:key:zBob', TransportType.lan);
      lan.simulatePeers([bob]);

      await Future<void>.delayed(const Duration(milliseconds: 10));

      final msg = NexusMessage.create(fromDid: 'did:key:zA', body: 'retry');
      await manager.sendMessage(msg, recipientDid: 'did:key:zBob');

      expect(ble.sent, hasLength(1),
          reason: 'Should fall back to BLE when LAN send throws');
    });
  });

  group('TransportManager – incoming messages', () {
    test('forwards received messages to onMessageReceived stream', () async {
      final manager = _freshManager();
      final ble = FakeTransport(type: TransportType.ble);
      manager.registerTransport(ble);
      await manager.start();

      final msg =
          NexusMessage.create(fromDid: 'did:key:zAlice', body: 'hi!');

      final received = <NexusMessage>[];
      final sub = manager.onMessageReceived.listen(received.add);

      ble.simulateReceive(msg);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();

      expect(received, hasLength(1));
      expect(received.first.id, msg.id);
    });

    test('deduplicates: same message from two transports counted once',
        () async {
      final manager = _freshManager();
      final ble = FakeTransport(type: TransportType.ble);
      final lan = FakeTransport(type: TransportType.lan);
      manager
        ..registerTransport(ble)
        ..registerTransport(lan);
      await manager.start();

      final msg =
          NexusMessage.create(fromDid: 'did:key:zAlice', body: 'dup');

      final received = <NexusMessage>[];
      final sub = manager.onMessageReceived.listen(received.add);

      ble.simulateReceive(msg);
      lan.simulateReceive(msg); // same message, different transport

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

      final msg =
          NexusMessage.create(fromDid: 'did:key:zA', body: 'no echo');

      final received = <NexusMessage>[];
      final sub = manager.onMessageReceived.listen(received.add);

      await manager.sendMessage(msg);
      ble.simulateReceive(msg); // simulate echo

      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();

      expect(received, isEmpty);
    });
  });

  group('TransportManager – peer tracking & merging', () {
    test('merges peers from multiple transports', () async {
      final manager = _freshManager();
      final ble = FakeTransport(type: TransportType.ble);
      final lan = FakeTransport(type: TransportType.lan);
      manager
        ..registerTransport(ble)
        ..registerTransport(lan);
      await manager.start();

      ble.simulatePeers([_peer('did:key:zAlice', TransportType.ble)]);
      lan.simulatePeers([_peer('did:key:zBob', TransportType.lan)]);

      await Future<void>.delayed(const Duration(milliseconds: 10));

      final peers = manager.peers;
      expect(peers.length, 2);
      expect(peers.any((p) => p.did == 'did:key:zAlice'), isTrue);
      expect(peers.any((p) => p.did == 'did:key:zBob'), isTrue);
    });

    test('same peer via BLE and LAN: availableTransports contains both', () async {
      final manager = _freshManager();
      final ble = FakeTransport(type: TransportType.ble);
      final lan = FakeTransport(type: TransportType.lan);
      manager
        ..registerTransport(ble)
        ..registerTransport(lan);
      await manager.start();

      ble.simulatePeers([_peer('did:key:zAlice', TransportType.ble)]);
      lan.simulatePeers([_peer('did:key:zAlice', TransportType.lan)]);

      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(manager.peers, hasLength(1),
          reason: 'Same DID should be merged into one peer');

      final alice = manager.peers.first;
      expect(alice.availableTransports,
          containsAll([TransportType.ble, TransportType.lan]));
      // LAN should be the primary (preferred)
      expect(alice.transportType, TransportType.lan);
    });

    test('peer demoted when it disappears from LAN but still visible via BLE',
        () async {
      final manager = _freshManager();
      final ble = FakeTransport(type: TransportType.ble);
      final lan = FakeTransport(type: TransportType.lan);
      manager
        ..registerTransport(ble)
        ..registerTransport(lan);
      await manager.start();

      // Alice visible on both
      ble.simulatePeers([_peer('did:key:zAlice', TransportType.ble)]);
      lan.simulatePeers([_peer('did:key:zAlice', TransportType.lan)]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(manager.peers.first.transportType, TransportType.lan);

      // Alice disappears from LAN
      lan.simulatePeers([]);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final alice = manager.peers.firstWhere((p) => p.did == 'did:key:zAlice');
      expect(alice.transportType, TransportType.ble,
          reason: 'Should fall back to BLE when LAN peer disappears');
      expect(alice.availableTransports, {TransportType.ble});
    });
  });
}
