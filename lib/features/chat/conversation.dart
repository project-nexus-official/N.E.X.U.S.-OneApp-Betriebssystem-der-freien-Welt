import '../../core/transport/message_transport.dart';
import '../../core/transport/nexus_message.dart';

/// Summary of a single conversation thread (direct or broadcast).
class Conversation {
  /// Deterministic key used in [PodDatabase] and navigation.
  /// "broadcast" for #mesh, otherwise sorted(didA, didB) joined by "||".
  final String id;

  /// 'broadcast' for the #mesh channel, otherwise the peer's DID.
  final String peerDid;

  final String peerPseudonym;

  /// Cached local path to the peer's profile image, if available.
  final String? peerProfileImage;

  /// Preview text of the last message. For image messages: "📷 Foto".
  final String lastMessage;

  final DateTime lastMessageTime;

  final int unreadCount;

  /// Primary transport the peer was last reached on.
  final TransportType? transportType;

  /// Pinned conversations (e.g. #mesh) always sort to the top.
  final bool isPinned;

  const Conversation({
    required this.id,
    required this.peerDid,
    required this.peerPseudonym,
    this.peerProfileImage,
    required this.lastMessage,
    required this.lastMessageTime,
    this.unreadCount = 0,
    this.transportType,
    this.isPinned = false,
  });

  bool get isBroadcast => peerDid == NexusMessage.broadcastDid;

  /// Canonical conversation ID for a direct chat between two DIDs.
  /// Matches [ChatProvider._conversationId] — sorted DIDs joined with ':'.
  static String directId(String didA, String didB) {
    final sorted = [didA, didB]..sort();
    return '${sorted[0]}:${sorted[1]}';
  }

  /// Extracts the peer DID from a direct [convId] given the local [myDid].
  /// ConvId format: "didA:didB" where both DIDs start with "did:key:".
  /// We find the second occurrence of "did:key:" to split.
  static String? peerDidFrom(String convId, String myDid) {
    if (convId == 'broadcast') return 'broadcast';
    final second = convId.indexOf('did:', 1);
    if (second <= 0) return null;
    final didA = convId.substring(0, second - 1);
    final didB = convId.substring(second);
    return didA == myDid ? didB : didA;
  }

  Conversation copyWith({
    int? unreadCount,
    String? lastMessage,
    DateTime? lastMessageTime,
    TransportType? transportType,
  }) {
    return Conversation(
      id: id,
      peerDid: peerDid,
      peerPseudonym: peerPseudonym,
      peerProfileImage: peerProfileImage,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      unreadCount: unreadCount ?? this.unreadCount,
      transportType: transportType ?? this.transportType,
      isPinned: isPinned,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Conversation && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
