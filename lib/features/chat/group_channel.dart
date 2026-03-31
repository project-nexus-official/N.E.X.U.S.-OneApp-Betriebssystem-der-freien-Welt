import 'dart:math';

/// A named group channel (e.g. #teneriffa) that multiple users can join.
///
/// Channel IDs in the conversation layer use the format "#channelname"
/// (lower-case, letters, digits and hyphens only).
class GroupChannel {
  final String id; // UUID
  final String name; // e.g. "#teneriffa"
  final String description;
  final String createdBy; // DID (also the admin)
  final DateTime createdAt;

  /// Whether the channel is open for all to join (true) or access-controlled (false).
  final bool isPublic;

  /// Whether the channel appears in discovery results.
  /// Public channels: always true.
  /// Private channels: true = visible (join request needed), false = hidden (invite only).
  final bool isDiscoverable;

  /// 64-char hex shared secret used to derive the AES-256-GCM channel key.
  /// Null for public channels. Generated at creation for private channels.
  /// Distributed to members via encrypted DM on accept/invite.
  final String? channelSecret;

  final String nostrTag; // e.g. "nexus-channel-teneriffa"
  DateTime? joinedAt;

  /// DIDs of members who have been granted access (admin always first).
  List<String> members;

  GroupChannel({
    required this.id,
    required this.name,
    required this.description,
    required this.createdBy,
    required this.createdAt,
    this.isPublic = true,
    this.isDiscoverable = true,
    this.channelSecret,
    required this.nostrTag,
    this.joinedAt,
    List<String>? members,
  }) : members = members ?? [];

  /// The conversation_id used to store messages for this channel.
  /// Always starts with '#'.
  String get conversationId => name.startsWith('#') ? name : '#$name';

  /// Creates a new channel with a fresh random ID and (for private channels)
  /// a cryptographically random [channelSecret].
  factory GroupChannel.create({
    required String name,
    required String description,
    required String createdBy,
    bool isPublic = true,
    bool isDiscoverable = true,
  }) {
    final normalised = normaliseName(name);
    return GroupChannel(
      id: _generateId(),
      name: normalised,
      description: description,
      createdBy: createdBy,
      createdAt: DateTime.now().toUtc(),
      isPublic: isPublic,
      isDiscoverable: isDiscoverable,
      channelSecret: isPublic ? null : _generateSecret(),
      nostrTag: nameToNostrTag(normalised),
      joinedAt: DateTime.now().toUtc(),
      members: [createdBy],
    );
  }

  /// Creates a copy with optional field overrides.
  GroupChannel copyWith({
    bool? isPublic,
    bool? isDiscoverable,
    String? channelSecret,
    DateTime? joinedAt,
    List<String>? members,
  }) =>
      GroupChannel(
        id: id,
        name: name,
        description: description,
        createdBy: createdBy,
        createdAt: createdAt,
        isPublic: isPublic ?? this.isPublic,
        isDiscoverable: isDiscoverable ?? this.isDiscoverable,
        channelSecret: channelSecret ?? this.channelSecret,
        nostrTag: nostrTag,
        joinedAt: joinedAt ?? this.joinedAt,
        members: members ?? List.from(this.members),
      );

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Ensures the name starts with '#' and contains only valid characters.
  static String normaliseName(String raw) {
    var n = raw.trim().toLowerCase();
    if (!n.startsWith('#')) n = '#$n';
    // Keep only #, lowercase letters, digits and hyphens.
    n = '#${n.substring(1).replaceAll(RegExp(r'[^a-z0-9-]'), '-')}';
    // Collapse multiple hyphens.
    n = '#${n.substring(1).replaceAll(RegExp(r'-{2,}'), '-')}';
    return n;
  }

  /// Returns true when [name] (without #) is valid.
  static bool isValidName(String name) {
    final bare = name.startsWith('#') ? name.substring(1) : name;
    return RegExp(r'^[a-z0-9][a-z0-9-]{1,50}$').hasMatch(bare);
  }

  /// Converts a channel name like "#teneriffa" to the Nostr tag
  /// "nexus-channel-teneriffa".
  static String nameToNostrTag(String name) {
    final bare = name.startsWith('#') ? name.substring(1) : name;
    return 'nexus-channel-$bare';
  }

  /// Converts a Nostr tag like "nexus-channel-teneriffa" back to "#teneriffa".
  static String? nostrTagToName(String tag) {
    const prefix = 'nexus-channel-';
    if (!tag.startsWith(prefix)) return null;
    return '#${tag.substring(prefix.length)}';
  }

  // ── Serialization ──────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'createdBy': createdBy,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'isPublic': isPublic,
        'isDiscoverable': isDiscoverable,
        if (channelSecret != null) 'channelSecret': channelSecret,
        'nostrTag': nostrTag,
        if (joinedAt != null) 'joinedAt': joinedAt!.millisecondsSinceEpoch,
        if (members.isNotEmpty) 'members': members,
      };

  factory GroupChannel.fromJson(Map<String, dynamic> json) => GroupChannel(
        id: json['id'] as String,
        name: json['name'] as String,
        description: (json['description'] as String?) ?? '',
        createdBy: (json['createdBy'] as String?) ?? '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (json['createdAt'] as num).toInt(),
          isUtc: true,
        ),
        isPublic: (json['isPublic'] as bool?) ?? true,
        isDiscoverable: (json['isDiscoverable'] as bool?) ?? true,
        channelSecret: json['channelSecret'] as String?,
        nostrTag: (json['nostrTag'] as String?) ??
            nameToNostrTag(json['name'] as String),
        joinedAt: json['joinedAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(
                (json['joinedAt'] as num).toInt(),
                isUtc: true,
              )
            : null,
        members: (json['members'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            [],
      );

  @override
  String toString() => 'GroupChannel($name, tag: $nostrTag)';

  static String _generateId() {
    final rng = Random.secure();
    final bytes = List.generate(16, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Generates a 64-char hex channel secret (32 random bytes).
  static String _generateSecret() {
    final rng = Random.secure();
    final bytes = List.generate(32, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
