import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../message_transport.dart';
import '../nexus_message.dart';
import '../nexus_peer.dart';
import 'ble_message_handler.dart';

/// BLE Service and Characteristic UUIDs for the NEXUS mesh protocol.
///
/// 'nexus' in ASCII: 6e 65 78 75 73
/// These UUIDs are stable and must match across all NEXUS node implementations.
class NexusUuids {
  static const String service = '6e657875-7300-0000-0000-000000000001';

  /// Central writes here to send a message to the peripheral.
  static const String msgInChar = '6e657875-7300-4d49-4e00-000000000001';

  /// Peripheral notifies here to push a message to the central.
  static const String msgOutChar = '6e657875-7300-4f55-5400-000000000001';

  /// Peripheral writes its DID + pseudonym here as a JSON announcement.
  static const String announcementChar = '6e657875-7300-4944-4e00-000000000001';
}

/// BLE-based [MessageTransport] implementation, inspired by BitChat.
///
/// Architecture:
///   - Each NEXUS node advertises the NEXUS service UUID so peers can find it.
///   - On discovery, the node connects as a GATT *central* to the remote peer.
///   - Sending  : central writes chunks to [NexusUuids.msgInChar] on the peer.
///   - Receiving : central subscribes to notifications on [NexusUuids.msgOutChar]
///                 of the peer (the peer's GATT server pushes notifications).
///
/// ⚠️  GATT server (peripheral role): flutter_blue_plus provides advertising,
/// but full GATT server setup (hosting characteristics) requires a native
/// method channel on Android/iOS.  The advertising + scanning sides are fully
/// implemented here; the GATT server stub is marked with TODO.
class BleTransport implements MessageTransport {
  BleTransport({required this.localDid, required this.localPseudonym});

  final String localDid;
  final String localPseudonym;

  // ── State ──────────────────────────────────────────────────────────────────

  TransportState _state = TransportState.idle;

  @override
  TransportType get type => TransportType.ble;

  @override
  TransportState get state => _state;

  // ── Streams ────────────────────────────────────────────────────────────────

  final _msgController = StreamController<NexusMessage>.broadcast();
  final _peersController = StreamController<List<NexusPeer>>.broadcast();

  @override
  Stream<NexusMessage> get onMessageReceived => _msgController.stream;

  @override
  Stream<List<NexusPeer>> get onPeersChanged => _peersController.stream;

  // ── Connected peers ────────────────────────────────────────────────────────

  /// remoteDeviceId → NexusPeer
  final Map<String, NexusPeer> _connectedPeers = {};

  /// remoteDeviceId → active BluetoothDevice
  final Map<String, BluetoothDevice> _connectedDevices = {};

  // Message handler per device (for reassembly)
  final Map<String, BleMessageHandler> _handlers = {};

  // Subscriptions
  final List<StreamSubscription<dynamic>> _subs = [];

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  Future<void> start() async {
    if (_state != TransportState.idle) return;

    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      _state = TransportState.error;
      return;
    }

    _state = TransportState.scanning;
    await _startAdvertising();
    _startScanning();
  }

  @override
  Future<void> stop() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();

    for (final device in _connectedDevices.values) {
      try {
        await device.disconnect();
      } catch (_) {}
    }
    _connectedDevices.clear();
    _connectedPeers.clear();
    _handlers.clear();

    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }

    _state = TransportState.idle;
  }

  // ── Advertising ────────────────────────────────────────────────────────────

  Future<void> _startAdvertising() async {
    // TODO: BLE peripheral advertising requires native platform support.
    // flutter_blue_plus ≥ 2.x will expose startAdvertising() directly.
    // Until then, advertising is handled by the native plugin registration
    // (Android: BluetoothLeAdvertiser via method channel, iOS: CBPeripheralManager).
    //
    // Scanning still works without advertising from this side; the remote peer
    // only needs to advertise the NEXUS service UUID for us to discover them.
    //
    // Workaround: ensure the native side calls startAdvertising with
    // serviceUuid = NexusUuids.service and manufacturerData containing
    // the local DID hash (see buildAnnouncementBytes()).
  }

  // ── Scanning ───────────────────────────────────────────────────────────────

  void _startScanning() {
    _subs.add(
      FlutterBluePlus.onScanResults.listen(_onScanResults),
    );

    FlutterBluePlus.startScan(
      withServices: [Guid(NexusUuids.service)],
      continuousUpdates: true,
      androidScanMode: AndroidScanMode.balanced,
    );
  }

  void _onScanResults(List<ScanResult> results) {
    for (final result in results) {
      final deviceId = result.device.remoteId.str;

      // Skip already-connected devices
      if (_connectedDevices.containsKey(deviceId)) {
        // Update RSSI
        final existing = _connectedPeers[deviceId];
        if (existing != null) {
          _connectedPeers[deviceId] = existing.copyWith(
            signalStrength: result.rssi,
            lastSeen: DateTime.now(),
          );
          _peersController.add(List.from(_connectedPeers.values));
        }
        continue;
      }

      // Try to extract a DID hint from manufacturer data
      final mfData = result.advertisementData.manufacturerData;
      final didHint = mfData.containsKey(0x4e58)
          ? _advertBytesToDidHint(mfData[0x4e58]!)
          : null;

      // Create a preliminary peer entry while we connect
      final peer = NexusPeer(
        did: didHint ?? 'ble:${deviceId.replaceAll(':', '')}',
        pseudonym: result.device.platformName.isNotEmpty
            ? result.device.platformName
            : 'Peer…',
        transportType: TransportType.ble,
        signalStrength: result.rssi,
        lastSeen: DateTime.now(),
      );
      _connectedPeers[deviceId] = peer;
      _peersController.add(List.from(_connectedPeers.values));

      // Connect and exchange proper identity
      _connectToDevice(result.device);
    }
  }

  // ── Connection & GATT ──────────────────────────────────────────────────────

  Future<void> _connectToDevice(BluetoothDevice device) async {
    final deviceId = device.remoteId.str;
    if (_connectedDevices.containsKey(deviceId)) return;

    try {
      await device.connect(
        timeout: const Duration(seconds: 8),
        autoConnect: false,
      );
    } catch (_) {
      return;
    }

    _connectedDevices[deviceId] = device;
    _handlers[deviceId] = BleMessageHandler();

    // Monitor disconnection
    _subs.add(device.connectionState.listen((connectionState) {
      if (connectionState == BluetoothConnectionState.disconnected) {
        _connectedDevices.remove(deviceId);
        _connectedPeers.remove(deviceId);
        _handlers.remove(deviceId);
        _peersController.add(List.from(_connectedPeers.values));
      }
    }));

    // Discover services and set up notifications
    try {
      final services = await device.discoverServices();
      final nexusSvc = services.where(
        (s) => s.serviceUuid == Guid(NexusUuids.service),
      ).firstOrNull;

      if (nexusSvc == null) {
        await device.disconnect();
        return;
      }

      // Read peer identity from announcement characteristic
      final announceChar = nexusSvc.characteristics.where(
        (c) => c.characteristicUuid == Guid(NexusUuids.announcementChar),
      ).firstOrNull;

      if (announceChar != null && announceChar.properties.read) {
        try {
          final value = await announceChar.read();
          _processAnnouncement(deviceId, Uint8List.fromList(value));
        } catch (_) {}
      }

      // Subscribe to outgoing message notifications from the peer's GATT server
      final msgOutChar = nexusSvc.characteristics.where(
        (c) => c.characteristicUuid == Guid(NexusUuids.msgOutChar),
      ).firstOrNull;

      if (msgOutChar != null && msgOutChar.properties.notify) {
        await msgOutChar.setNotifyValue(true);
        _subs.add(msgOutChar.lastValueStream.listen((value) {
          if (value.isEmpty) return;
          _processIncomingChunk(deviceId, Uint8List.fromList(value));
        }));
      }
    } catch (_) {
      // Could not set up GATT; still keep connection for sending.
    }
  }

  void _processAnnouncement(String deviceId, Uint8List data) {
    try {
      final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      final did = json['did'] as String? ?? _connectedPeers[deviceId]?.did ?? deviceId;
      final pseudonym = json['name'] as String? ?? 'Peer';
      final rssi = _connectedPeers[deviceId]?.signalStrength;

      _connectedPeers[deviceId] = NexusPeer(
        did: did,
        pseudonym: pseudonym,
        transportType: TransportType.ble,
        signalStrength: rssi,
        lastSeen: DateTime.now(),
      );
      _peersController.add(List.from(_connectedPeers.values));
    } catch (_) {}
  }

  void _processIncomingChunk(String deviceId, Uint8List chunk) {
    final handler = _handlers[deviceId];
    if (handler == null) return;

    final assembled = handler.processChunk(chunk);
    if (assembled == null) return;

    try {
      final msg = NexusMessage.fromWireBytes(assembled);
      if (!handler.isDuplicate(msg.id)) {
        _msgController.add(msg);
      }
    } catch (_) {
      // Corrupt or unknown message format – discard silently.
    }
  }

  // ── Sending ────────────────────────────────────────────────────────────────

  @override
  Future<void> sendMessage(NexusMessage message, {String? recipientDid}) async {
    final wireBytes = message.toWireBytes();
    final chunks = BleMessageHandler.fragment(wireBytes, message.id);

    if (recipientDid != null) {
      // Direct message: find the device with matching DID and send there
      final deviceId = _connectedPeers.entries
          .where((e) => e.value.did == recipientDid)
          .map((e) => e.key)
          .firstOrNull;

      if (deviceId != null) {
        await _sendChunksToDevice(deviceId, chunks);
        return;
      }
    }

    // Broadcast: send to all connected peers
    for (final deviceId in _connectedDevices.keys) {
      try {
        await _sendChunksToDevice(deviceId, chunks);
      } catch (_) {
        // One failed peer must not block the others.
      }
    }
  }

  Future<void> _sendChunksToDevice(
    String deviceId,
    List<Uint8List> chunks,
  ) async {
    final device = _connectedDevices[deviceId];
    if (device == null) return;

    try {
      final services = await device.discoverServices();
      final nexusSvc = services.where(
        (s) => s.serviceUuid == Guid(NexusUuids.service),
      ).firstOrNull;
      if (nexusSvc == null) return;

      final msgInChar = nexusSvc.characteristics.where(
        (c) => c.characteristicUuid == Guid(NexusUuids.msgInChar),
      ).firstOrNull;
      if (msgInChar == null || !msgInChar.properties.writeWithoutResponse) return;

      for (final chunk in chunks) {
        await msgInChar.write(chunk, withoutResponse: true);
        // Small delay to avoid overwhelming the BLE stack
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    } catch (_) {}
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Reconstructs a DID hint string from BLE advertisement manufacturer bytes.
  static String? _advertBytesToDidHint(List<int> bytes) {
    if (bytes.isEmpty) return null;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'ble:hint:$hex';
  }

  /// Returns an announcement payload JSON for the local node.
  ///
  /// When the native GATT server is implemented, this JSON should be written
  /// to [NexusUuids.announcementChar] so that connecting centrals can read
  /// the DID and pseudonym without an additional round-trip.
  Uint8List buildAnnouncementBytes() {
    return Uint8List.fromList(
      utf8.encode(jsonEncode({'did': localDid, 'name': localPseudonym})),
    );
  }
}
