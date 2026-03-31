import 'dart:math';

/// A named group channel (e.g. #teneriffa) that multiple users can join.
///
/// Channel IDs in the conversation layer use the format "#channelname"
/// (lower-case, letters, digits and hyphens only).
class GroupChannel {
  final String id; // UUID
  final String name; // e.g. "#teneriffa"
  final String description;
  final String createdBy; // DID
  final DateTime createdAt;
  final bool isPublic;
  final String nostrTag; // e.g. "nexus-channel-teneriffa"
  DateTime? joinedAt;

  GroupChannel({
    required this.id,
    required this.name,
    required this.description,
    required this.createdBy,
    required this.createdAt,
    this.isPublic = true,
    required this.nostrTag,
    this.joinedAt,
  });

  /// The conversation_id used to store messages for this channel.
  /// Always starts with '#'.
  String get conversationId => name.startsWith('#') ? name : '#$name';

  /// Creates a new channel with a fresh random ID.
  factory GroupChannel.create({
    required String name,
    required String description,
    required String createdBy,
    bool isPublic = true,
  }) {
    final normalised = normaliseName(name);
    return GroupChannel(
      id: _generateId(),
      name: normalised,
      description: description,
      createdBy: createdBy,
      createdAt: DateTime.now().toUtc(),
      isPublic: isPublic,
      nostrTag: nameToNostrTag(normalised),
      joinedAt: DateTime.now().toUtc(),
    );
  }

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
        'nostrTag': nostrTag,
        if (joinedAt != null) 'joinedAt': joinedAt!.millisecondsSinceEpoch,
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
        nostrTag: (json['nostrTag'] as String?) ??
            nameToNostrTag(json['name'] as String),
        joinedAt: json['joinedAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(
                (json['joinedAt'] as num).toInt(),
                isUtc: true,
              )
            : null,
      );

  @override
  String toString() => 'GroupChannel($name, tag: $nostrTag)';

  static String _generateId() {
    final rng = Random.secure();
    final bytes = List.generate(16, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
