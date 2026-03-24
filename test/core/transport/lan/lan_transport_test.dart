import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/core/transport/lan/lan_message_channel.dart';
import 'package:nexus_oneapp/core/transport/message_transport.dart';
import 'package:nexus_oneapp/core/transport/nexus_message.dart';
import 'package:nexus_oneapp/core/transport/nexus_peer.dart';

/// Picks a free TCP port for tests (avoids collisions with port 51001).
Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

void main() {
  // ── LanMessageChannel – framing & TCP transfer ──────────────────────────────

  group('LanMessageChannel', () {
    test('sends a NexusMessage and receives it on the same machine', () async {
      final port = await _freePort();
      final channel = LanMessageChannel(tcpPort: port);
      await channel.start();

      final msg = NexusMessage.create(
        fromDid: 'did:key:zAlice',
        toDid: 'did:key:zBob',
        body: 'Hello via LAN',
      );

      final receivedFuture = channel.onMessageReceived.first;

      await channel.sendTo(msg, InternetAddress.loopbackIPv4, port);

      final received =
          await receivedFuture.timeout(const Duration(seconds: 3));

      expect(received.id, msg.id);
      expect(received.body, 'Hello via LAN');
      expect(received.fromDid, 'did:key:zAlice');

      await channel.stop();
    });

    test('handles multiple sequential messages correctly', () async {
      final port = await _freePort();
      final channel = LanMessageChannel(tcpPort: port);
      await channel.start();

      final received = <NexusMessage>[];
      final sub = channel.onMessageReceived.listen(received.add);

      for (var i = 1; i <= 3; i++) {
        final msg = NexusMessage.create(
          fromDid: 'did:key:zA',
          body: 'Message $i',
        );
        await channel.sendTo(msg, InternetAddress.loopbackIPv4, port);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, hasLength(3));
      expect(received.map((m) => m.body).toSet(),
          {'Message 1', 'Message 2', 'Message 3'});

      await sub.cancel();
      await channel.stop();
    });

    test('does not crash on malformed incoming bytes', () async {
      final port = await _freePort();
      final channel = LanMessageChannel(tcpPort: port);
      await channel.start();

      final received = <NexusMessage>[];
      final sub = channel.onMessageReceived.listen(received.add);

      // Connect and send garbage
      final socket =
          await Socket.connect(InternetAddress.loopbackIPv4, port);
      socket.add([0, 0, 0, 5, 0xff, 0xfe, 0xfd, 0xfc, 0xfb]); // bad ZLib
      await socket.flush();
      socket.destroy();

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, isEmpty, reason: 'Malformed bytes should be silently dropped');

      await sub.cancel();
      await channel.stop();
    });
  });

  // ── NexusPeer – availableTransports ──────────────────────────────────────────

  group('NexusPeer.availableTransports', () {
    test('defaults availableTransports to the primary transport', () {
      final peer = NexusPeer(
        did: 'did:key:zA',
        pseudonym: 'Alice',
        transportType: TransportType.ble,
        lastSeen: DateTime.now(),
      );
      expect(peer.availableTransports, {TransportType.ble});
    });

    test('can hold multiple transport types', () {
      final peer = NexusPeer(
        did: 'did:key:zA',
        pseudonym: 'Alice',
        transportType: TransportType.lan,
        availableTransports: {TransportType.lan, TransportType.ble},
        lastSeen: DateTime.now(),
      );
      expect(peer.availableTransports,
          containsAll([TransportType.lan, TransportType.ble]));
    });

    test('signalLabel returns "LAN" for LAN transport', () {
      final peer = NexusPeer(
        did: 'did:key:zA',
        pseudonym: 'Alice',
        transportType: TransportType.lan,
        lastSeen: DateTime.now(),
      );
      expect(peer.signalLabel, 'LAN');
    });
  });
}
