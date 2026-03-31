import 'dart:convert';

/// Represents the data embedded in a NEXUS channel QR code or invite link.
///
/// Wire format (JSON encoded in the QR code):
/// ```json
/// {
///   "type": "channel_invite",
///   "channelId": "...",
///   "channelName": "#teneriffa",
///   "nostrTag": "nexus-channel-teneriffa",
///   "isPublic": true,
///   "isDiscoverable": true,
///   "inviteToken": "..." // only for private+hidden channels (= channelSecret)
/// }
/// ```
///
/// Deep-link format: `nexus://channel?id=...&name=...&public=true&discoverable=true&token=...`
class ChannelInvitePayload {
  static const _type = 'channel_invite';

  final String channelId;
  final String channelName; // e.g. "#teneriffa"
  final String nostrTag; // e.g. "nexus-channel-teneriffa"
  final bool isPublic;
  final bool isDiscoverable;

  /// For private+hidden channels shared by the admin:
  /// equals the channelSecret, granting direct access.
  /// Null for public and private+visible channels.
  final String? inviteToken;

  const ChannelInvitePayload({
    required this.channelId,
    required this.channelName,
    required this.nostrTag,
    required this.isPublic,
    required this.isDiscoverable,
    this.inviteToken,
  });

  // ── Parsing ────────────────────────────────────────────────────────────────

  /// Tries to parse a QR code raw value or a nexus:// deep-link into a
  /// [ChannelInvitePayload]. Returns null if the input is not recognised.
  static ChannelInvitePayload? tryParse(String rawValue) {
    final trimmed = rawValue.trim();
    return _tryParseJson(trimmed) ?? _tryParseDeepLink(trimmed);
  }

  static ChannelInvitePayload? _tryParseJson(String value) {
    try {
      final json = jsonDecode(value) as Map<String, dynamic>;
      if (json['type'] != _type) return null;
      final channelName = json['channelName'] as String?;
      if (channelName == null || channelName.isEmpty) return null;
      return ChannelInvitePayload(
        channelId: json['channelId'] as String? ?? '',
        channelName: channelName,
        nostrTag:
            json['nostrTag'] as String? ?? _nameToNostrTag(channelName),
        isPublic: json['isPublic'] as bool? ?? true,
        isDiscoverable: json['isDiscoverable'] as bool? ?? true,
        inviteToken: json['inviteToken'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  static ChannelInvitePayload? _tryParseDeepLink(String value) {
    try {
      final uri = Uri.parse(value);
      if (uri.scheme != 'nexus' || uri.host != 'channel') return null;
      final name = uri.queryParameters['name'] ?? '';
      if (name.isEmpty) return null;
      final normName =
          name.startsWith('#') ? name : '#$name';
      return ChannelInvitePayload(
        channelId: uri.queryParameters['id'] ?? '',
        channelName: normName,
        nostrTag: _nameToNostrTag(normName),
        isPublic: uri.queryParameters['public'] != 'false',
        isDiscoverable: uri.queryParameters['discoverable'] != 'false',
        inviteToken: uri.queryParameters['token'],
      );
    } catch (_) {
      return null;
    }
  }

  // ── Serialization ──────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'type': _type,
        'channelId': channelId,
        'channelName': channelName,
        'nostrTag': nostrTag,
        'isPublic': isPublic,
        'isDiscoverable': isDiscoverable,
        if (inviteToken != null) 'inviteToken': inviteToken,
      };

  String toJsonString() => jsonEncode(toJson());

  /// Returns a `nexus://` deep-link for this invite.
  String toDeepLink() {
    final params = <String, String>{
      'id': channelId,
      'name': channelName,
      if (!isPublic) 'public': 'false',
      if (!isDiscoverable) 'discoverable': 'false',
      if (inviteToken != null) 'token': inviteToken!,
    };
    return Uri(
      scheme: 'nexus',
      host: 'channel',
      queryParameters: params,
    ).toString();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Short label for UI display (same logic as GroupChannel.nameToNostrTag
  /// but inlined to avoid a dependency on the GroupChannel class).
  static String _nameToNostrTag(String name) {
    final bare = name.startsWith('#') ? name.substring(1) : name;
    return 'nexus-channel-$bare';
  }

  /// Human-readable access type label.
  String get accessLabel {
    if (isPublic) return 'Öffentlicher Kanal';
    if (isDiscoverable) return 'Privater Kanal (Beitritt auf Antrag)';
    return 'Privater Kanal (Einladung)';
  }
}
