import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/storage/pod_database.dart';
import '../../core/transport/nostr/nostr_event.dart';
import 'feed_post.dart';

/// Callback type for publishing events to Nostr.
/// Returns the assigned Nostr event ID, or null if not connected.
typedef FeedNostrPublisher = String? Function(
  int kind,
  String content,
  List<List<String>> tags,
);

/// Feed tabs on the Dorfplatz screen.
enum FeedTab { contacts, cell, entdecken }

/// Service managing the local Dorfplatz social feed.
///
/// Responsibilities:
/// - CRUD for [FeedPost] and [FeedComment] (local SQLite via [PodDatabase])
/// - Emoji reactions (reuse `message_reactions` table with post ID as key)
/// - Author mutes
/// - Poll voting (local only, stored in post data)
/// - Nostr publishing via injected [FeedNostrPublisher] callback
/// - Incoming post routing from NostrTransport → [handleIncomingPost]
class FeedService {
  FeedService._();
  static FeedService? _instance;
  static FeedService get instance => _instance ??= FeedService._();

  // Visible posts cache (all loaded from DB), sorted newest first.
  final List<FeedPost> _posts = [];

  // Muted author DIDs (loaded from DB on [load]).
  final Set<String> _mutedAuthors = {};

  // Nostr publisher — set from ChatProvider after NostrTransport is ready.
  FeedNostrPublisher? _publisher;

  final _streamController = StreamController<void>.broadcast();

  /// Fires whenever the post list or reactions change.
  Stream<void> get stream => _streamController.stream;

  /// Unmodifiable snapshot of all loaded posts (not filtered by tab/mute).
  List<FeedPost> get allPosts => List.unmodifiable(_posts);

  int get totalPostCount => _posts.where((p) => !_mutedAuthors.contains(p.authorDid)).length;

  /// Sets the Nostr publisher callback (called from ChatProvider on init).
  void setNostrPublisher(FeedNostrPublisher? publisher) {
    _publisher = publisher;
  }

  /// Loads muted authors and the initial set of posts from the local DB.
  Future<void> load() async {
    try {
      _mutedAuthors
        ..clear()
        ..addAll(await PodDatabase.instance.getMutedAuthors());

      final rows = await PodDatabase.instance.listFeedPosts(limit: 20);
      _posts
        ..clear()
        ..addAll(rows.map(FeedPost.fromJson));

      _streamController.add(null);
      debugPrint('[FEED] Loaded ${_posts.length} posts, '
          '${_mutedAuthors.length} mutes');
    } catch (e) {
      debugPrint('[FEED] load error: $e');
    }
  }

  // ── Post creation ─────────────────────────────────────────────────────────

  Future<FeedPost> createPost({
    required String authorDid,
    required String authorPseudonym,
    required String content,
    List<String> images = const [],
    String? voicePath,
    int? voiceDurationMs,
    FeedVisibility visibility = FeedVisibility.contacts,
    Poll? poll,
    String? repostOf,
    String? repostComment,
  }) async {
    var post = FeedPost(
      id: generateFeedId(),
      authorDid: authorDid,
      authorPseudonym: authorPseudonym,
      content: content,
      images: images,
      voicePath: voicePath,
      voiceDurationMs: voiceDurationMs,
      visibility: visibility,
      poll: poll,
      repostOf: repostOf,
      repostComment: repostComment,
      createdAt: DateTime.now(),
    );

    // Store locally first (local-first).
    await PodDatabase.instance.insertFeedPost(post.toJson());

    // Publish to Nostr (best-effort).
    if (_publisher != null) {
      final tags = <List<String>>[
        ['t', 'nexus-dorfplatz'],
        ['visibility', post.visibility.name],
      ];
      if (repostOf != null) tags.add(['e', repostOf]);

      final kind =
          repostOf != null ? NostrKind.repost : NostrKind.textNote;
      final eventId =
          _publisher!(kind, jsonEncode(post.toJson()), tags);

      if (eventId != null) {
        post = post.copyWith(nostrEventId: eventId);
        await PodDatabase.instance.updateFeedPost(post.id, post.toJson());
      }
    }

    _posts.insert(0, post);
    _streamController.add(null);
    return post;
  }

  // ── Feed loading & filtering ──────────────────────────────────────────────

  /// Returns posts for the given [tab], filtered by contact membership and mutes.
  List<FeedPost> getPostsForTab(
    FeedTab tab, {
    required String myDid,
    required Set<String> contactDids,
  }) {
    return _posts.where((p) {
      if (_mutedAuthors.contains(p.authorDid)) return false;
      return switch (tab) {
        FeedTab.contacts =>
          p.authorDid == myDid || contactDids.contains(p.authorDid),
        FeedTab.cell => false, // Phase 2
        FeedTab.entdecken => p.visibility == FeedVisibility.public,
      };
    }).toList();
  }

  /// Loads an additional page of posts from the DB (pagination).
  Future<void> loadMore() async {
    try {
      final rows = await PodDatabase.instance
          .listFeedPosts(limit: 20, offset: _posts.length);
      for (final row in rows) {
        final post = FeedPost.fromJson(row);
        if (!_posts.any((p) => p.id == post.id)) {
          _posts.add(post);
        }
      }
      _streamController.add(null);
    } catch (e) {
      debugPrint('[FEED] loadMore error: $e');
    }
  }

  /// Loads posts for a specific [authorDid] (used in profile screens).
  Future<List<FeedPost>> getPostsByAuthor(String authorDid) async {
    try {
      final rows = await PodDatabase.instance
          .listFeedPosts(authorDid: authorDid, limit: 50);
      return rows.map(FeedPost.fromJson).toList();
    } catch (e) {
      debugPrint('[FEED] getPostsByAuthor error: $e');
      return [];
    }
  }

  // ── Incoming Nostr posts ──────────────────────────────────────────────────

  /// Processes an incoming feed post from NostrTransport.
  Future<void> handleIncomingPost(Map<String, dynamic> data) async {
    try {
      final post = FeedPost.fromJson(data);
      // Deduplicate
      if (_posts.any((p) =>
          p.id == post.id ||
          (post.nostrEventId != null &&
              p.nostrEventId == post.nostrEventId))) return;

      // Skip muted authors
      if (_mutedAuthors.contains(post.authorDid)) return;

      await PodDatabase.instance.insertFeedPost(post.toJson());
      _posts
        ..insert(0, post)
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _streamController.add(null);
    } catch (e) {
      debugPrint('[FEED] handleIncomingPost error: $e');
    }
  }

  // ── Post actions ──────────────────────────────────────────────────────────

  /// Soft-deletes a post locally and publishes a Kind-5 deletion event.
  Future<void> deletePost(String postId) async {
    final idx = _posts.indexWhere((p) => p.id == postId);
    if (idx == -1) return;
    final post = _posts[idx];

    await PodDatabase.instance.softDeleteFeedPost(postId);
    _posts.removeAt(idx);

    // Publish Kind-5 deletion for the Nostr event (best-effort).
    if (_publisher != null && post.nostrEventId != null) {
      _publisher!(
        NostrKind.deletion,
        'Beitrag gelöscht',
        [['e', post.nostrEventId!]],
      );
    }

    _streamController.add(null);
  }

  /// Expands the visibility of a post to [newVisibility].
  ///
  /// Visibility can only be widened (contacts → cell → public), never
  /// restricted. Publishes a new Kind-1 Nostr event that references the
  /// original via an ["e", id, "", "edit"] tag so peers update their view.
  Future<void> changeVisibility(
      String postId, FeedVisibility newVisibility) async {
    final idx = _posts.indexWhere((p) => p.id == postId);
    if (idx == -1) return;
    final post = _posts[idx];

    // Guard: only allow expanding, never restricting.
    if (newVisibility.index <= post.visibility.index) return;

    final updated = post.copyWith(visibility: newVisibility);
    await PodDatabase.instance.updateFeedPost(postId, updated.toJson());
    _posts[idx] = updated;

    // Republish to Nostr so peers see the updated visibility.
    if (_publisher != null) {
      final tags = <List<String>>[
        ['t', 'nexus-dorfplatz'],
        ['visibility', newVisibility.name],
        if (post.nostrEventId != null)
          ['e', post.nostrEventId!, '', 'edit'],
      ];
      _publisher!(NostrKind.textNote, jsonEncode(updated.toJson()), tags);
    }

    _streamController.add(null);
  }

  /// Updates the text content of a post (only within 24 h).
  Future<void> editPost(String postId, String newContent) async {
    final idx = _posts.indexWhere((p) => p.id == postId);
    if (idx == -1) return;
    final post = _posts[idx];

    if (DateTime.now().difference(post.createdAt) > const Duration(hours: 24)) {
      return; // edit window closed
    }

    final updated = FeedPost(
      id: post.id,
      authorDid: post.authorDid,
      authorPseudonym: post.authorPseudonym,
      authorProfilePic: post.authorProfilePic,
      content: newContent,
      images: post.images,
      voicePath: post.voicePath,
      voiceDurationMs: post.voiceDurationMs,
      linkPreview: post.linkPreview,
      poll: post.poll,
      visibility: post.visibility,
      createdAt: post.createdAt,
      nostrEventId: post.nostrEventId,
      repostOf: post.repostOf,
      repostComment: post.repostComment,
    );

    await PodDatabase.instance.updateFeedPost(postId, updated.toJson());
    _posts[idx] = updated;
    _streamController.add(null);
  }

  // ── Comments ──────────────────────────────────────────────────────────────

  Future<List<FeedComment>> getComments(String postId) async {
    try {
      final rows = await PodDatabase.instance.listFeedComments(postId);
      return rows.map(FeedComment.fromJson).toList();
    } catch (e) {
      debugPrint('[FEED] getComments error: $e');
      return [];
    }
  }

  Future<FeedComment> addComment({
    required String postId,
    String? parentCommentId,
    required String authorDid,
    required String authorPseudonym,
    required String content,
    String? postNostrEventId,
    String? parentNostrEventId,
  }) async {
    final comment = FeedComment(
      id: generateFeedId(),
      postId: postId,
      parentCommentId: parentCommentId,
      authorDid: authorDid,
      authorPseudonym: authorPseudonym,
      content: content,
      createdAt: DateTime.now(),
    );

    await PodDatabase.instance.insertFeedComment(comment.toJson());

    // Publish Kind-1 with NIP-10 e-tags (best-effort).
    if (_publisher != null && postNostrEventId != null) {
      final tags = <List<String>>[
        ['t', 'nexus-dorfplatz-comment'],
        ['e', postNostrEventId, '', 'root'],
      ];
      if (parentNostrEventId != null) {
        tags.add(['e', parentNostrEventId, '', 'reply']);
      }
      _publisher!(
        NostrKind.textNote,
        jsonEncode(comment.toJson()),
        tags,
      );
    }

    _streamController.add(null);
    return comment;
  }

  Future<void> deleteComment(String commentId) async {
    await PodDatabase.instance.softDeleteFeedComment(commentId);
    _streamController.add(null);
  }

  // ── Reactions ────────────────────────────────────────────────────────────

  Future<Map<String, List<String>>> getReactions(String postId) {
    return PodDatabase.instance.getReactionsForMessage(postId);
  }

  Future<void> toggleReaction({
    required String postId,
    required String emoji,
    required String myDid,
    String? postNostrEventId,
  }) async {
    final reactions = await PodDatabase.instance.getReactionsForMessage(postId);
    final myVoters = reactions[emoji] ?? [];
    if (myVoters.contains(myDid)) {
      await PodDatabase.instance.deleteReaction(
        messageId: postId,
        emoji: emoji,
        reactorDid: myDid,
      );
    } else {
      await PodDatabase.instance.upsertReaction(
        messageId: postId,
        emoji: emoji,
        reactorDid: myDid,
      );
      // Publish Kind-7 reaction (best-effort).
      if (_publisher != null && postNostrEventId != null) {
        _publisher!(
          NostrKind.reaction,
          emoji,
          [['e', postNostrEventId]],
        );
      }
    }
    _streamController.add(null);
  }

  // ── Poll voting ───────────────────────────────────────────────────────────

  Future<void> voteInPoll({
    required String postId,
    required String optionId,
    required String voterDid,
    bool allowMultiple = false,
  }) async {
    final idx = _posts.indexWhere((p) => p.id == postId);
    if (idx == -1) return;
    final post = _posts[idx];
    if (post.poll == null) return;
    if (post.poll!.isExpired) return;

    // Build updated poll options.
    final options = post.poll!.options.map((opt) {
      if (!allowMultiple) {
        // Remove existing vote from all options before adding new one.
        opt = opt.withoutVote(voterDid);
      }
      if (opt.id == optionId && !opt.voterDids.contains(voterDid)) {
        opt = opt.withVote(voterDid);
      }
      return opt;
    }).toList();

    final updatedPoll = Poll(
      question: post.poll!.question,
      options: options,
      multipleChoice: post.poll!.multipleChoice,
      endsAt: post.poll!.endsAt,
    );

    final updated = post.copyWith(poll: updatedPoll);
    await PodDatabase.instance.updateFeedPost(postId, updated.toJson());
    _posts[idx] = updated;
    _streamController.add(null);
  }

  // ── Mutes ────────────────────────────────────────────────────────────────

  Future<void> muteAuthor(String authorDid) async {
    _mutedAuthors.add(authorDid);
    await PodDatabase.instance.muteAuthor(authorDid);
    _streamController.add(null);
  }

  Future<void> unmuteAuthor(String authorDid) async {
    _mutedAuthors.remove(authorDid);
    await PodDatabase.instance.unmuteAuthor(authorDid);
    _streamController.add(null);
  }

  bool isAuthorMuted(String authorDid) => _mutedAuthors.contains(authorDid);
}
