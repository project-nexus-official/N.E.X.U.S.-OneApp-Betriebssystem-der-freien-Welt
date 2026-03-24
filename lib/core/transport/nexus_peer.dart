import 'message_transport.dart';

/// Signal strength category derived from RSSI.
enum SignalLevel { excellent, good, fair, poor, unknown }

/// A NEXUS peer discovered over any transport.
///
/// [transportType] is the *primary* transport (used for display and routing).
/// [availableTransports] contains ALL transports on which this peer is visible;
/// when a peer is reachable via both BLE and LAN this set contains both.
class NexusPeer {
  final String did;
  final String pseudonym;
  final TransportType transportType;
  final Set<TransportType> availableTransports;

  /// RSSI in dBm. Only available for BLE; null for LAN/Nostr/etc.
  final int? signalStrength;

  final DateTime lastSeen;

  NexusPeer({
    required this.did,
    required this.pseudonym,
    required this.transportType,
    Set<TransportType>? availableTransports,
    this.signalStrength,
    required this.lastSeen,
  }) : availableTransports = availableTransports ?? {transportType};

  NexusPeer copyWith({
    String? pseudonym,
    TransportType? transportType,
    Set<TransportType>? availableTransports,
    int? signalStrength,
    DateTime? lastSeen,
  }) {
    return NexusPeer(
      did: did,
      pseudonym: pseudonym ?? this.pseudonym,
      transportType: transportType ?? this.transportType,
      availableTransports: availableTransports ?? this.availableTransports,
      signalStrength: signalStrength ?? this.signalStrength,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  /// Human-readable signal quality category.
  SignalLevel get signalLevel {
    if (signalStrength == null) return SignalLevel.unknown;
    if (signalStrength! >= -60) return SignalLevel.excellent;
    if (signalStrength! >= -75) return SignalLevel.good;
    if (signalStrength! >= -90) return SignalLevel.fair;
    return SignalLevel.poor;
  }

  /// Returns a display string for signal strength.
  String get signalLabel {
    if (transportType == TransportType.lan) return 'LAN';
    if (signalStrength == null) return 'Internet';
    return '$signalStrength dBm';
  }

  @override
  bool operator ==(Object other) => other is NexusPeer && other.did == did;

  @override
  int get hashCode => did.hashCode;

  @override
  String toString() =>
      'NexusPeer(pseudonym: $pseudonym, transports: ${availableTransports.map((t) => t.name).join('+')}, '
      'rssi: $signalStrength)';
}
