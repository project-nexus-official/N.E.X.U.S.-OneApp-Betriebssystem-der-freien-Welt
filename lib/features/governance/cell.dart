import 'dart:math';

/// Physical neighbourhood or virtual interest group.
enum CellType { local, thematic }

/// Who can join the cell.
enum JoinPolicy { approvalRequired, inviteOnly }

/// Minimum trust level an applicant must have with an existing member.
enum MinTrustLevel { none, contact, trusted }

/// Thematic categories for [CellType.thematic] cells.
const cellCategories = [
  'Umwelt',
  'Technik',
  'Bildung',
  'Tiergerechtigkeit',
  'Ernährung',
  'Gesundheit',
  'Wohnen',
  'Kultur',
  'Wirtschaft',
  'Sonstiges',
];

String _generateCellId() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final rng = Random.secure();
  return List.generate(32, (_) => chars[rng.nextInt(chars.length)]).join();
}

/// A NEXUS cell – a community of up to 150 people (Dunbar's number).
///
/// Cells are the primary unit of governance in the AETHER protocol.
/// Members of a cell participate in Proposals, Voting, and Delegation.
class Cell {
  final String id;
  final String name;
  final String description;
  final String createdBy;
  final DateTime createdAt;
  final CellType cellType;

  // LOCAL-specific
  final String? locationName;
  final String? geohash;

  // THEMATIC-specific
  final String? topic;
  final String? category;

  // Nostr sync tag, e.g. "nexus-cell-abc123"
  final String nostrTag;

  // Configurable settings
  final int maxMembers;
  final JoinPolicy joinPolicy;
  final MinTrustLevel minTrustLevel;
  final int proposalWaitDays;

  // Runtime state (populated by CellService after loading members)
  final int memberCount;

  const Cell({
    required this.id,
    required this.name,
    required this.description,
    required this.createdBy,
    required this.createdAt,
    required this.cellType,
    this.locationName,
    this.geohash,
    this.topic,
    this.category,
    required this.nostrTag,
    this.maxMembers = 150,
    this.joinPolicy = JoinPolicy.approvalRequired,
    this.minTrustLevel = MinTrustLevel.none,
    this.proposalWaitDays = 0,
    this.memberCount = 1,
  });

  factory Cell.create({
    required String name,
    required String description,
    required String createdBy,
    required CellType cellType,
    String? locationName,
    String? geohash,
    String? topic,
    String? category,
    int maxMembers = 150,
    JoinPolicy joinPolicy = JoinPolicy.approvalRequired,
    MinTrustLevel minTrustLevel = MinTrustLevel.none,
    int proposalWaitDays = 0,
  }) {
    final id = _generateCellId();
    return Cell(
      id: id,
      name: name,
      description: description,
      createdBy: createdBy,
      createdAt: DateTime.now().toUtc(),
      cellType: cellType,
      locationName: locationName,
      geohash: geohash,
      topic: topic,
      category: category,
      nostrTag: 'nexus-cell-$id',
      maxMembers: maxMembers,
      joinPolicy: joinPolicy,
      minTrustLevel: minTrustLevel,
      proposalWaitDays: proposalWaitDays,
      memberCount: 1,
    );
  }

  /// True if the cell was created less than 7 days ago.
  bool get isNew =>
      DateTime.now().toUtc().difference(createdAt).inDays < 7;

  /// True if the cell has reached its member limit.
  bool get isFull => memberCount >= maxMembers;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'createdBy': createdBy,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'cellType': cellType.name,
        if (locationName != null) 'locationName': locationName,
        if (geohash != null) 'geohash': geohash,
        if (topic != null) 'topic': topic,
        if (category != null) 'category': category,
        'nostrTag': nostrTag,
        'maxMembers': maxMembers,
        'joinPolicy': joinPolicy.name,
        'minTrustLevel': minTrustLevel.name,
        'proposalWaitDays': proposalWaitDays,
        'memberCount': memberCount,
      };

  factory Cell.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    return Cell(
      id: id,
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      createdBy: json['createdBy'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          json['createdAt'] as int,
          isUtc: true),
      cellType: CellType.values.firstWhere(
        (e) => e.name == (json['cellType'] as String? ?? 'thematic'),
        orElse: () => CellType.thematic,
      ),
      locationName: json['locationName'] as String?,
      geohash: json['geohash'] as String?,
      topic: json['topic'] as String?,
      category: json['category'] as String?,
      nostrTag: json['nostrTag'] as String? ?? 'nexus-cell-$id',
      maxMembers: json['maxMembers'] as int? ?? 150,
      joinPolicy: JoinPolicy.values.firstWhere(
        (e) => e.name == (json['joinPolicy'] as String? ?? 'approvalRequired'),
        orElse: () => JoinPolicy.approvalRequired,
      ),
      minTrustLevel: MinTrustLevel.values.firstWhere(
        (e) => e.name == (json['minTrustLevel'] as String? ?? 'none'),
        orElse: () => MinTrustLevel.none,
      ),
      proposalWaitDays: json['proposalWaitDays'] as int? ?? 0,
      memberCount: json['memberCount'] as int? ?? 1,
    );
  }

  Cell copyWith({
    String? name,
    String? description,
    int? maxMembers,
    JoinPolicy? joinPolicy,
    MinTrustLevel? minTrustLevel,
    int? proposalWaitDays,
    int? memberCount,
    String? locationName,
    String? geohash,
    String? topic,
    String? category,
  }) =>
      Cell(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        createdBy: createdBy,
        createdAt: createdAt,
        cellType: cellType,
        locationName: locationName ?? this.locationName,
        geohash: geohash ?? this.geohash,
        topic: topic ?? this.topic,
        category: category ?? this.category,
        nostrTag: nostrTag,
        maxMembers: maxMembers ?? this.maxMembers,
        joinPolicy: joinPolicy ?? this.joinPolicy,
        minTrustLevel: minTrustLevel ?? this.minTrustLevel,
        proposalWaitDays: proposalWaitDays ?? this.proposalWaitDays,
        memberCount: memberCount ?? this.memberCount,
      );
}
