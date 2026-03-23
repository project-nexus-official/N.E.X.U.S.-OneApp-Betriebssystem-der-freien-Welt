import 'message_transport.dart';

/// Signal strength category derived from RSSI.
enum SignalLevel { excellent, good, fair, poor, unknown }

/// A NEXUS peer discovered over any transport.
class NexusPeer {
  final String did;
  final String pseudonym;
  final TransportType transportType;

  /// RSSI in dBm. Only available for BLE; null for Nostr/LoRa/etc.
  final int? signalStrength;

  final DateTime lastSeen;

  const NexusPeer({
    required this.did,
    required this.pseudonym,
    required this.transportType,
    this.signalStrength,
    required this.lastSeen,
  });

  NexusPeer copyWith({
    String? pseudonym,
    TransportType? transportType,
    int? signalStrength,
    DateTime? lastSeen,
  }) {
    return NexusPeer(
      did: did,
      pseudonym: pseudonym ?? this.pseudonym,
      transportType: transportType ?? this.transportType,
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
    if (signalStrength == null) return 'Internet';
    return '$signalStrength dBm';
  }

  @override
  bool operator ==(Object other) => other is NexusPeer && other.did == did;

  @override
  int get hashCode => did.hashCode;

  @override
  String toString() =>
      'NexusPeer(pseudonym: $pseudonym, transport: ${transportType.name}, '
      'rssi: $signalStrength)';
}
