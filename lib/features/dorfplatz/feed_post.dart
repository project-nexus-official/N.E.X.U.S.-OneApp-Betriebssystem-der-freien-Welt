import 'dart:math';

/// Feed post visibility levels.
enum FeedVisibility {
  /// Only contacts (TrustLevel ≥ contact) can see this post.
  contacts,

  /// All members of the author's Zelle(n) can see this post.
  cell,

  /// All NEXUS users can see this post.
  public,
}

// ── Poll ─────────────────────────────────────────────────────────────────────

class PollOption {
  final String id;
  final String text;
  final List<String> voterDids;

  const PollOption({
    required this.id,
    required this.text,
    this.voterDids = const [],
  });

  PollOption withVote(String did) => PollOption(
        id: id,
        text: text,
        voterDids: [...voterDids, did],
      );

  PollOption withoutVote(String did) => PollOption(
        id: id,
        text: text,
        voterDids: voterDids.where((d) => d != did).toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'voterDids': voterDids,
      };

  factory PollOption.fromJson(Map<String, dynamic> json) => PollOption(
        id: json['id'] as String,
        text: json['text'] as String,
        voterDids:
            (json['voterDids'] as List<dynamic>?)?.cast<String>() ?? [],
      );
}

class Poll {
  final String question;
  final List<PollOption> options;
  final bool multipleChoice;
  final DateTime? endsAt;

  const Poll({
    required this.question,
    required this.options,
    this.multipleChoice = false,
    this.endsAt,
  });

  int get totalVotes =>
      options.fold(0, (sum, o) => sum + o.voterDids.length);

  bool get isExpired =>
      endsAt != null && DateTime.now().isAfter(endsAt!);

  double percentFor(PollOption option) {
    final total = totalVotes;
    if (total == 0) return 0;
    return option.voterDids.length / total;
  }

  bool hasVoted(String did) =>
      options.any((o) => o.voterDids.contains(did));

  Map<String, dynamic> toJson() => {
        'question': question,
        'options': options.map((o) => o.toJson()).toList(),
        'multipleChoice': multipleChoice,
        if (endsAt != null) 'endsAt': endsAt!.millisecondsSinceEpoch,
      };

  factory Poll.fromJson(Map<String, dynamic> json) => Poll(
        question: json['question'] as String,
        options: (json['options'] as List<dynamic>)
            .map((o) => PollOption.fromJson(o as Map<String, dynamic>))
            .toList(),
        multipleChoice: json['multipleChoice'] as bool? ?? false,
        endsAt: json['endsAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['endsAt'] as int)
            : null,
      );
}

// ── LinkPreview ───────────────────────────────────────────────────────────────

class LinkPreview {
  final String url;
  final String? title;
  final String? description;
  final String? imageUrl;

  const LinkPreview({
    required this.url,
    this.title,
    this.description,
    this.imageUrl,
  });

  String get displayDomain {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url;
    }
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        if (title != null) 'title': title,
        if (description != null) 'description': description,
        if (imageUrl != null) 'imageUrl': imageUrl,
      };

  factory LinkPreview.fromJson(Map<String, dynamic> json) => LinkPreview(
        url: json['url'] as String,
        title: json['title'] as String?,
        description: json['description'] as String?,
        imageUrl: json['imageUrl'] as String?,
      );
}

// ── FeedPost ─────────────────────────────────────────────────────────────────

class FeedPost {
  final String id;
  final String authorDid;
  final String authorPseudonym;
  final String? authorProfilePic;
  final String content;

  /// Base64-encoded JPEG images (max 4, each max 1 MB compressed).
  final List<String> images;

  /// Absolute path to a local voice recording file, if any.
  final String? voicePath;

  /// Voice duration in milliseconds, if voicePath is set.
  final int? voiceDurationMs;

  final LinkPreview? linkPreview;
  final Poll? poll;
  final FeedVisibility visibility;
  final DateTime createdAt;
  final String? nostrEventId;

  /// ID of the original post being reposted (Kind-6 reposts).
  final String? repostOf;

  /// Optional comment added when reposting.
  final String? repostComment;

  /// Pseudonym of the original post's author (stored for offline display).
  final String? repostOriginalAuthorPseudonym;

  /// Short text preview of the original post's content (stored for offline display).
  final String? repostOriginalPreview;

  /// Base64-encoded JPEG of the first image from the original post (if any).
  final String? repostOriginalImage;

  const FeedPost({
    required this.id,
    required this.authorDid,
    required this.authorPseudonym,
    this.authorProfilePic,
    required this.content,
    this.images = const [],
    this.voicePath,
    this.voiceDurationMs,
    this.linkPreview,
    this.poll,
    required this.visibility,
    required this.createdAt,
    this.nostrEventId,
    this.repostOf,
    this.repostComment,
    this.repostOriginalAuthorPseudonym,
    this.repostOriginalPreview,
    this.repostOriginalImage,
  });

  bool get isRepost => repostOf != null;
  bool get hasImages => images.isNotEmpty;
  bool get hasVoice => voicePath != null;
  bool get hasPoll => poll != null;
  bool get hasLinkPreview => linkPreview != null;
  bool get isEmpty =>
      content.isEmpty && !hasImages && !hasVoice && !hasPoll && !isRepost;

  FeedPost copyWith({
    String? nostrEventId,
    Poll? poll,
    FeedVisibility? visibility,
  }) =>
      FeedPost(
        id: id,
        authorDid: authorDid,
        authorPseudonym: authorPseudonym,
        authorProfilePic: authorProfilePic,
        content: content,
        images: images,
        voicePath: voicePath,
        voiceDurationMs: voiceDurationMs,
        linkPreview: linkPreview,
        poll: poll ?? this.poll,
        visibility: visibility ?? this.visibility,
        createdAt: createdAt,
        nostrEventId: nostrEventId ?? this.nostrEventId,
        repostOf: repostOf,
        repostComment: repostComment,
        repostOriginalAuthorPseudonym: repostOriginalAuthorPseudonym,
        repostOriginalPreview: repostOriginalPreview,
        repostOriginalImage: repostOriginalImage,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'authorDid': authorDid,
        'authorPseudonym': authorPseudonym,
        if (authorProfilePic != null) 'authorProfilePic': authorProfilePic,
        'content': content,
        'images': images,
        if (voicePath != null) 'voicePath': voicePath,
        if (voiceDurationMs != null) 'voiceDurationMs': voiceDurationMs,
        if (linkPreview != null) 'linkPreview': linkPreview!.toJson(),
        if (poll != null) 'poll': poll!.toJson(),
        'visibility': visibility.name,
        'createdAt': createdAt.millisecondsSinceEpoch,
        if (nostrEventId != null) 'nostrEventId': nostrEventId,
        if (repostOf != null) 'repostOf': repostOf,
        if (repostComment != null) 'repostComment': repostComment,
        if (repostOriginalAuthorPseudonym != null)
          'repostOriginalAuthorPseudonym': repostOriginalAuthorPseudonym,
        if (repostOriginalPreview != null)
          'repostOriginalPreview': repostOriginalPreview,
        if (repostOriginalImage != null)
          'repostOriginalImage': repostOriginalImage,
      };

  factory FeedPost.fromJson(Map<String, dynamic> json) => FeedPost(
        id: json['id'] as String,
        authorDid: json['authorDid'] as String,
        authorPseudonym: json['authorPseudonym'] as String,
        authorProfilePic: json['authorProfilePic'] as String?,
        content: json['content'] as String? ?? '',
        images:
            (json['images'] as List<dynamic>?)?.cast<String>() ?? [],
        voicePath: json['voicePath'] as String?,
        voiceDurationMs: json['voiceDurationMs'] as int?,
        linkPreview: json['linkPreview'] != null
            ? LinkPreview.fromJson(
                json['linkPreview'] as Map<String, dynamic>)
            : null,
        poll: json['poll'] != null
            ? Poll.fromJson(json['poll'] as Map<String, dynamic>)
            : null,
        visibility: FeedVisibility.values.firstWhere(
          (v) => v.name == json['visibility'],
          orElse: () => FeedVisibility.contacts,
        ),
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
        nostrEventId: json['nostrEventId'] as String?,
        repostOf: json['repostOf'] as String?,
        repostComment: json['repostComment'] as String?,
        repostOriginalAuthorPseudonym:
            json['repostOriginalAuthorPseudonym'] as String?,
        repostOriginalPreview: json['repostOriginalPreview'] as String?,
        repostOriginalImage: json['repostOriginalImage'] as String?,
      );
}

// ── FeedComment ───────────────────────────────────────────────────────────────

class FeedComment {
  final String id;
  final String postId;
  final String? parentCommentId;
  final String authorDid;
  final String authorPseudonym;
  final String content;
  final DateTime createdAt;
  final String? nostrEventId;

  const FeedComment({
    required this.id,
    required this.postId,
    this.parentCommentId,
    required this.authorDid,
    required this.authorPseudonym,
    required this.content,
    required this.createdAt,
    this.nostrEventId,
  });

  bool get isReply => parentCommentId != null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'postId': postId,
        if (parentCommentId != null) 'parentCommentId': parentCommentId,
        'authorDid': authorDid,
        'authorPseudonym': authorPseudonym,
        'content': content,
        'createdAt': createdAt.millisecondsSinceEpoch,
        if (nostrEventId != null) 'nostrEventId': nostrEventId,
      };

  factory FeedComment.fromJson(Map<String, dynamic> json) => FeedComment(
        id: json['id'] as String,
        postId: json['postId'] as String,
        parentCommentId: json['parentCommentId'] as String?,
        authorDid: json['authorDid'] as String,
        authorPseudonym: json['authorPseudonym'] as String,
        content: json['content'] as String,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
        nostrEventId: json['nostrEventId'] as String?,
      );
}

// ── UUID helper ───────────────────────────────────────────────────────────────

String generateFeedId() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex =
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}
