import 'package:flutter/material.dart';

import '../../core/contacts/contact_service.dart';
import '../../core/identity/identity_service.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/peer_avatar.dart';
import 'feed_post.dart';
import 'feed_post_card.dart';
import 'feed_service.dart';

/// Full-screen view of a single post with nested comments.
class PostDetailScreen extends StatefulWidget {
  final FeedPost post;

  const PostDetailScreen({super.key, required this.post});

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  final _commentCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _focusNode = FocusNode();

  List<FeedComment> _comments = [];
  bool _loading = true;
  bool _posting = false;

  // Comment being replied to (level 1 reply).
  FeedComment? _replyingTo;

  @override
  void initState() {
    super.initState();
    _loadComments();
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    _scrollCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadComments() async {
    final rows = await FeedService.instance.getComments(widget.post.id);
    if (mounted) {
      setState(() {
        _comments = rows;
        _loading = false;
      });
    }
  }

  Future<void> _submitComment() async {
    final identity = IdentityService.instance.currentIdentity;
    if (identity == null) return;
    final text = _commentCtrl.text.trim();
    if (text.isEmpty) return;

    setState(() => _posting = true);
    _commentCtrl.clear();
    final replyTarget = _replyingTo;
    setState(() => _replyingTo = null);

    try {
      final comment = await FeedService.instance.addComment(
        postId: widget.post.id,
        parentCommentId: replyTarget?.id,
        authorDid: identity.did,
        authorPseudonym: identity.pseudonym,
        content: text,
        postNostrEventId: widget.post.nostrEventId,
        parentNostrEventId: replyTarget?.nostrEventId,
      );

      setState(() => _comments.add(comment));
      // Scroll to bottom.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.animateTo(
            _scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  void _replyTo(FeedComment comment) {
    setState(() => _replyingTo = comment);
    _focusNode.requestFocus();
  }

  void _cancelReply() {
    setState(() => _replyingTo = null);
    _focusNode.unfocus();
  }

  Future<void> _deleteComment(FeedComment comment) async {
    final identity = IdentityService.instance.currentIdentity;
    if (identity == null || comment.authorDid != identity.did) return;
    await FeedService.instance.deleteComment(comment.id);
    setState(() => _comments.removeWhere((c) => c.id == comment.id));
  }

  /// Builds the nested comment tree (max 3 levels of indentation).
  List<Widget> _buildCommentTree(List<FeedComment> comments, int level) {
    // Top-level: parentCommentId == null
    // Replies: find children of each comment
    final topLevel =
        comments.where((c) => c.parentCommentId == null).toList();
    return topLevel.map((c) => _buildCommentNode(c, comments, level)).toList();
  }

  Widget _buildCommentNode(
      FeedComment comment, List<FeedComment> all, int level) {
    final children = all
        .where((c) => c.parentCommentId == comment.id)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CommentTile(
          comment: comment,
          level: level,
          onReply: level < 3 ? () => _replyTo(comment) : null,
          onDelete: () => _deleteComment(comment),
        ),
        if (children.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Column(
              children: children
                  .map((c) => _buildCommentNode(c, all, level + 1))
                  .toList(),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Beitrag')),
      body: Column(
        children: [
          // ── Scrollable content ─────────────────────────────────────
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.only(bottom: 8),
                    children: [
                      // Full post card (non-interactive, already in detail)
                      FeedPostCard(
                        post: widget.post,
                        onTap: () {},
                        onCommentTap: () => _focusNode.requestFocus(),
                      ),
                      const Divider(height: 1),
                      // Comments header
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        child: Text(
                          '${_comments.length} ${_comments.length == 1 ? 'Kommentar' : 'Kommentare'}',
                          style: const TextStyle(
                            color: AppColors.gold,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (_comments.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(
                              horizontal: 16, vertical: 24),
                          child: Text(
                            'Noch keine Kommentare. Sei der Erste!',
                            style: TextStyle(
                              color: AppColors.onDark,
                            ),
                          ),
                        )
                      else
                        ..._buildCommentTree(_comments, 0),
                    ],
                  ),
          ),

          // ── Reply banner ───────────────────────────────────────────
          if (_replyingTo != null)
            Container(
              color: AppColors.surfaceVariant,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  Container(
                    width: 3,
                    height: 30,
                    color: AppColors.gold,
                    margin: const EdgeInsets.only(right: 10),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Antwort an ${_replyingTo!.authorPseudonym}',
                          style: const TextStyle(
                            color: AppColors.gold,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          _replyingTo!.content,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.onDark.withValues(alpha: 0.7),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: AppColors.onDark,
                    onPressed: _cancelReply,
                  ),
                ],
              ),
            ),

          // ── Comment input ──────────────────────────────────────────
          SafeArea(
            child: Container(
              color: AppColors.surface,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _commentCtrl,
                      focusNode: _focusNode,
                      style: const TextStyle(color: AppColors.onDark),
                      decoration: InputDecoration(
                        hintText: _replyingTo != null
                            ? 'Antwort schreiben...'
                            : 'Kommentar schreiben...',
                        hintStyle: TextStyle(
                          color: AppColors.onDark.withValues(alpha: 0.4),
                        ),
                        filled: true,
                        fillColor: AppColors.surfaceVariant,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        isDense: true,
                      ),
                      maxLines: null,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _submitComment(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _posting
                      ? const SizedBox(
                          width: 36,
                          height: 36,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton(
                          icon: const Icon(Icons.send_rounded),
                          color: AppColors.gold,
                          onPressed: _submitComment,
                        ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Comment tile ───────────────────────────────────────────────────────────────

class _CommentTile extends StatelessWidget {
  final FeedComment comment;
  final int level;
  final VoidCallback? onReply;
  final VoidCallback onDelete;

  const _CommentTile({
    required this.comment,
    required this.level,
    this.onReply,
    required this.onDelete,
  });

  String _relativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'Gerade eben';
    if (diff.inMinutes < 60) return 'vor ${diff.inMinutes} Min.';
    if (diff.inHours < 24) return 'vor ${diff.inHours} Std.';
    if (diff.inDays < 7) return 'vor ${diff.inDays} Tag${diff.inDays == 1 ? '' : 'en'}';
    return '${comment.createdAt.day}.${comment.createdAt.month}.${comment.createdAt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final myDid = IdentityService.instance.currentIdentity?.did;
    final isOwn = comment.authorDid == myDid;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Gold indent line (only for nested replies)
          if (level > 0)
            Container(
              width: 2,
              color: AppColors.gold.withValues(alpha: 0.4),
              margin: const EdgeInsets.only(right: 10),
            ),

          // Content
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      PeerAvatar(
                        did: comment.authorDid,
                        profileImage: ContactService.instance
                            .resolveVisibleProfileImage(comment.authorDid),
                        size: 28,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              comment.authorPseudonym,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: AppColors.onDark,
                                fontSize: 13,
                              ),
                            ),
                            Text(
                              _relativeTime(comment.createdAt),
                              style: TextStyle(
                                color:
                                    AppColors.onDark.withValues(alpha: 0.5),
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (isOwn)
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 16),
                          color: AppColors.onDark.withValues(alpha: 0.4),
                          onPressed: () => _confirmDelete(context),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    comment.content,
                    style: const TextStyle(
                        color: AppColors.onDark, fontSize: 14),
                  ),
                  if (onReply != null) ...[
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: onReply,
                      child: Text(
                        'Antworten',
                        style: TextStyle(
                          color: AppColors.gold.withValues(alpha: 0.8),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kommentar löschen?'),
        content:
            const Text('Dieser Kommentar wird unwiderruflich gelöscht.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Löschen',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed == true) onDelete();
  }
}
