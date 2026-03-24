import 'nexus_message.dart';
import 'nexus_peer.dart';

/// The physical channel a transport uses.
enum TransportType { ble, lan, nostr, wifiDirect, lora }

/// Lifecycle state of a transport.
enum TransportState { idle, scanning, connected, error }

/// Abstract interface for all NEXUS transport backends.
///
/// Implementations (BleTransport, NostrTransport, …) must:
///   - Expose their type and current state.
///   - Provide two streams: incoming messages and peer-list changes.
///   - Implement [sendMessage], [start], and [stop].
///
/// **The chat layer MUST ONLY talk to [TransportManager], never to a
/// concrete transport directly.**
abstract class MessageTransport {
  TransportType get type;
  TransportState get state;

  /// Sends [message] over this transport.
  ///
  /// [recipientDid] hints at a specific peer; implementations may use it
  /// to prefer a direct connection over broadcast. Pass null for broadcast.
  Future<void> sendMessage(NexusMessage message, {String? recipientDid});

  /// Emits every valid [NexusMessage] received on this transport.
  Stream<NexusMessage> get onMessageReceived;

  /// Emits an updated list of peers whenever the peer set changes.
  Stream<List<NexusPeer>> get onPeersChanged;

  /// Current snapshot of peers known to this transport.
  List<NexusPeer> get currentPeers;

  /// Starts scanning / advertising / connecting.
  Future<void> start();

  /// Stops all activity and releases resources.
  Future<void> stop();
}
