import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/contacts/contact_service.dart';
import '../../core/identity/identity_service.dart';
import '../../core/identity/profile_service.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/identicon.dart';
import '../../shared/widgets/peer_avatar.dart';
import '../contacts/contact_detail_screen.dart';
import '../profile/profile_screen.dart';
import 'create_post_screen.dart';
import 'feed_post.dart';
import 'feed_service.dart';

/// A card representing a single [FeedPost] in the feed.
///
/// Shows header (avatar, pseudonym, timestamp, visibility), content (text,
/// images, poll, link preview), optional repost context, and the interaction
/// footer (reactions, comments, share).
class FeedPostCard extends StatelessWidget {
  final FeedPost post;

  /// Called when the card body is tapped → open PostDetailScreen.
  final VoidCallback onTap;

  /// Called when the comment button is tapped.
  final VoidCallback onCommentTap;

  /// Called when the share button is tapped.
  final VoidCallback? onShareTap;

  /// Called when the three-dot menu is tapped.
  final VoidCallback? onMenuTap;

  const FeedPostCard({
    super.key,
    required this.post,
    required this.onTap,
    required this.onCommentTap,
    this.onShareTap,
    this.onMenuTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: AppColors.onDark.withValues(alpha: 0.08),
          width: 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Header(post: post, onMenuTap: onMenuTap),
              if (post.isRepost) ...[
                const SizedBox(height: 6),
                _RepostIndicator(post: post),
              ],
              if (post.content.isNotEmpty) ...[
                const SizedBox(height: 8),
                _ContentText(content: post.content),
              ],
              if (post.hasImages) ...[
                const SizedBox(height: 8),
                _ImageGrid(images: post.images),
              ],
              if (post.hasPoll) ...[
                const SizedBox(height: 8),
                _PollWidget(post: post),
              ],
              if (post.hasLinkPreview) ...[
                const SizedBox(height: 8),
                _LinkPreviewCard(preview: post.linkPreview!),
              ],
              const SizedBox(height: 10),
              _Footer(
                post: post,
                onCommentTap: onCommentTap,
                onShareTap: onShareTap,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Header ────────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final FeedPost post;
  final VoidCallback? onMenuTap;

  const _Header({required this.post, this.onMenuTap});

  @override
  Widget build(BuildContext context) {
    // Resolve the author's profile image.
    // Own posts: ContactService has no entry for ourselves → use ProfileService.
    // Others: use the visible profile image from ContactService (respects
    //   selective-disclosure visibility; defaults to public for unknown contacts).
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final String? profileImagePath;
    if (post.authorDid == myDid) {
      profileImagePath =
          ProfileService.instance.currentProfile?.profileImage.value;
    } else {
      profileImagePath =
          ContactService.instance.resolveVisibleProfileImage(post.authorDid);
    }

    return Row(
      children: [
        // Avatar – tap navigates to the right screen depending on relationship
        GestureDetector(
          onTap: () => _openAuthorProfile(context, myDid),
          child: PeerAvatar(
            did: post.authorDid,
            profileImage: profileImagePath,
            size: 40,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                post.authorPseudonym,
                style: const TextStyle(
                  color: AppColors.onDark,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              Row(
                children: [
                  Text(
                    _relativeTime(post.createdAt),
                    style: TextStyle(
                      color: AppColors.onDark.withValues(alpha: 0.5),
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(width: 6),
                  _VisibilityIcon(visibility: post.visibility),
                ],
              ),
            ],
          ),
        ),
        // Three-dot menu – horizontal dots, 44×44 touch target
        IconButton(
          onPressed: onMenuTap,
          icon: Icon(
            Icons.more_horiz,
            color: AppColors.onDark.withValues(alpha: 0.5),
            size: 24,
          ),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        ),
      ],
    );
  }

  /// Opens the appropriate screen when the author avatar is tapped:
  /// - Own post       → ProfileScreen (own profile)
  /// - Known contact  → ContactDetailScreen
  /// - Unknown author → bottom sheet with "Kontakt hinzufügen" option
  void _openAuthorProfile(BuildContext context, String myDid) {
    if (post.authorDid == myDid) {
      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(builder: (_) => const ProfileScreen()),
      );
      return;
    }

    final contact = ContactService.instance.findByDid(post.authorDid);
    if (contact != null) {
      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(
          builder: (_) => ContactDetailScreen(did: post.authorDid),
        ),
      );
      return;
    }

    // Author is not yet a contact – offer to add them.
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            ClipOval(
              child: SizedBox(
                width: 56,
                height: 56,
                child: Identicon(
                    bytes: post.authorDid.codeUnits, size: 56),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              post.authorPseudonym,
              style: const TextStyle(
                  color: AppColors.onDark,
                  fontSize: 16,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'Noch nicht in deinen Kontakten',
              style: TextStyle(
                  color: AppColors.onDark.withValues(alpha: 0.5),
                  fontSize: 12),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await ContactService.instance
                        .addContact(post.authorDid, post.authorPseudonym);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                              '${post.authorPseudonym} zu Kontakten hinzugefügt.'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.person_add_outlined),
                  label: const Text('Kontakt hinzufügen'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.gold,
                    foregroundColor: AppColors.deepBlue,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  static String _relativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'gerade eben';
    if (diff.inMinutes < 60) return 'vor ${diff.inMinutes} Min.';
    if (diff.inHours < 24) return 'vor ${diff.inHours} Std.';
    if (diff.inDays < 7) return 'vor ${diff.inDays} Tagen';
    final months = [
      '', 'Jan.', 'Feb.', 'Mär.', 'Apr.', 'Mai', 'Jun.',
      'Jul.', 'Aug.', 'Sep.', 'Okt.', 'Nov.', 'Dez.',
    ];
    return '${dt.day}. ${months[dt.month]}';
  }
}

class _VisibilityIcon extends StatelessWidget {
  final FeedVisibility visibility;
  const _VisibilityIcon({required this.visibility});

  @override
  Widget build(BuildContext context) {
    final (icon, tooltip) = switch (visibility) {
      FeedVisibility.contacts => (Icons.people_outline, 'Kontakte'),
      FeedVisibility.cell => (Icons.group_work_outlined, 'Meine Zelle'),
      FeedVisibility.public => (Icons.public, 'Öffentlich'),
    };
    return Tooltip(
      message: tooltip,
      child: Icon(icon,
          size: 12, color: AppColors.onDark.withValues(alpha: 0.45)),
    );
  }
}

// ── Repost indicator ──────────────────────────────────────────────────────────

class _RepostIndicator extends StatelessWidget {
  final FeedPost post;
  const _RepostIndicator({required this.post});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: AppColors.gold.withValues(alpha: 0.3), width: 1),
      ),
      child: Row(
        children: [
          Icon(Icons.repeat,
              size: 14, color: AppColors.gold.withValues(alpha: 0.7)),
          const SizedBox(width: 6),
          Text(
            post.repostComment?.isNotEmpty == true
                ? post.repostComment!
                : 'Geteilt',
            style: TextStyle(
              color: AppColors.onDark.withValues(alpha: 0.65),
              fontSize: 12,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Content text (expandable) ─────────────────────────────────────────────────

class _ContentText extends StatefulWidget {
  final String content;
  const _ContentText({required this.content});

  @override
  State<_ContentText> createState() => _ContentTextState();
}

class _ContentTextState extends State<_ContentText> {
  bool _expanded = false;
  static const int _maxLines = 5;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final span = TextSpan(
        text: widget.content,
        style: const TextStyle(color: AppColors.onDark, fontSize: 14, height: 1.4),
      );
      final tp = TextPainter(
        text: span,
        maxLines: _maxLines,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: constraints.maxWidth);

      final overflow = tp.didExceedMaxLines;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.content,
            maxLines: _expanded ? null : _maxLines,
            overflow: _expanded ? null : TextOverflow.ellipsis,
            style: const TextStyle(
                color: AppColors.onDark, fontSize: 14, height: 1.4),
          ),
          if (overflow)
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _expanded ? 'Weniger anzeigen' : 'Mehr anzeigen',
                  style: const TextStyle(
                    color: AppColors.gold,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
        ],
      );
    });
  }
}

// ── Image grid ────────────────────────────────────────────────────────────────

class _ImageGrid extends StatelessWidget {
  final List<String> images; // base64 JPEG
  const _ImageGrid({required this.images});

  @override
  Widget build(BuildContext context) {
    if (images.length == 1) {
      // Single image: preserve aspect ratio, full card width.
      return _ImageTile(base64: images[0], squareCrop: false);
    }
    // Multiple images: 2-column grid with square cells (cover crop is fine).
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 4,
      crossAxisSpacing: 4,
      children: images.take(4).toList().asMap().entries.map((entry) {
        final idx = entry.key;
        final b64 = entry.value;
        if (idx == 3 && images.length > 4) {
          return Stack(
            fit: StackFit.expand,
            children: [
              _ImageTile(base64: b64, squareCrop: true),
              Container(
                color: Colors.black54,
                alignment: Alignment.center,
                child: Text('+${images.length - 3}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold)),
              ),
            ],
          );
        }
        return _ImageTile(base64: b64, squareCrop: true);
      }).toList(),
    );
  }
}

class _ImageTile extends StatelessWidget {
  final String base64;

  /// When true (grid cells): BoxFit.cover, no height constraint.
  /// When false (single image): BoxFit.contain, full width, auto height.
  final bool squareCrop;

  const _ImageTile({required this.base64, this.squareCrop = false});

  @override
  Widget build(BuildContext context) {
    try {
      final bytes = base64Decode(base64);
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: squareCrop
            // Grid cell: cover-crop into the square cell.
            // cacheWidth only (no cacheHeight) so the decoded size
            // stays proportional and BoxFit.cover fills correctly.
            ? Image.memory(
                bytes,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                cacheWidth: 400,
                gaplessPlayback: true,
              )
            // Single image: preserve aspect ratio, full card width.
            : Image.memory(
                bytes,
                fit: BoxFit.contain,
                width: double.infinity,
                cacheWidth: 600,
                gaplessPlayback: true,
              ),
      );
    } catch (_) {
      return Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.broken_image_outlined,
            color: AppColors.onDark),
      );
    }
  }
}

// ── Poll widget ───────────────────────────────────────────────────────────────

class _PollWidget extends StatelessWidget {
  final FeedPost post;
  const _PollWidget({required this.post});

  @override
  Widget build(BuildContext context) {
    final poll = post.poll!;
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final hasVoted = poll.hasVoted(myDid);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: AppColors.gold.withValues(alpha: 0.3), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            poll.question,
            style: const TextStyle(
              color: AppColors.onDark,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 10),
          ...poll.options.map((option) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: hasVoted
                    ? _PollResultBar(
                        option: option,
                        totalVotes: poll.totalVotes,
                        isMyVote: option.voterDids.contains(myDid),
                      )
                    : _PollOptionButton(
                        option: option,
                        onVote: () => FeedService.instance.voteInPoll(
                          postId: post.id,
                          optionId: option.id,
                          voterDid: myDid,
                          allowMultiple: poll.multipleChoice,
                        ),
                      ),
              )),
          Text(
            '${poll.totalVotes} Stimme${poll.totalVotes == 1 ? '' : 'n'}',
            style: TextStyle(
              color: AppColors.onDark.withValues(alpha: 0.5),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _PollOptionButton extends StatelessWidget {
  final PollOption option;
  final VoidCallback onVote;

  const _PollOptionButton({required this.option, required this.onVote});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: onVote,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.gold,
          side: BorderSide(color: AppColors.gold.withValues(alpha: 0.5)),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          alignment: Alignment.centerLeft,
        ),
        child: Text(option.text),
      ),
    );
  }
}

class _PollResultBar extends StatelessWidget {
  final PollOption option;
  final int totalVotes;
  final bool isMyVote;

  const _PollResultBar({
    required this.option,
    required this.totalVotes,
    required this.isMyVote,
  });

  @override
  Widget build(BuildContext context) {
    final pct = totalVotes > 0 ? option.voterDids.length / totalVotes : 0.0;
    final pctText = '${(pct * 100).round()}%';

    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
              children: [
                Container(
                  height: 34,
                  color: AppColors.surfaceVariant,
                ),
                FractionallySizedBox(
                  widthFactor: pct,
                  child: Container(
                    height: 34,
                    color: isMyVote
                        ? AppColors.gold.withValues(alpha: 0.25)
                        : AppColors.gold.withValues(alpha: 0.12),
                  ),
                ),
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      children: [
                        if (isMyVote)
                          const Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: Icon(Icons.check_circle,
                                size: 14, color: AppColors.gold),
                          ),
                        Expanded(
                          child: Text(option.text,
                              style: const TextStyle(
                                  color: AppColors.onDark, fontSize: 13)),
                        ),
                        Text(pctText,
                            style: const TextStyle(
                                color: AppColors.gold,
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── Link preview ──────────────────────────────────────────────────────────────

class _LinkPreviewCard extends StatelessWidget {
  final LinkPreview preview;
  const _LinkPreviewCard({required this.preview});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: AppColors.gold.withValues(alpha: 0.2), width: 1),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: const BoxDecoration(
              color: AppColors.surface,
              borderRadius:
                  BorderRadius.only(topLeft: Radius.circular(10), bottomLeft: Radius.circular(10)),
            ),
            child: const Icon(Icons.link, color: AppColors.gold, size: 24),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (preview.title != null)
                    Text(preview.title!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.onDark,
                            fontWeight: FontWeight.w500,
                            fontSize: 13)),
                  Text(preview.displayDomain,
                      style: TextStyle(
                          color: AppColors.onDark.withValues(alpha: 0.5),
                          fontSize: 11)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Footer (reactions + comments + share) ─────────────────────────────────────

class _Footer extends StatefulWidget {
  final FeedPost post;
  final VoidCallback onCommentTap;
  final VoidCallback? onShareTap;

  const _Footer({
    required this.post,
    required this.onCommentTap,
    this.onShareTap,
  });

  @override
  State<_Footer> createState() => _FooterState();
}

class _FooterState extends State<_Footer> {
  Map<String, List<String>> _reactions = {};
  int _commentCount = 0;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void didUpdateWidget(_Footer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only reload if the post changed (avoids spurious DB reads on parent rebuild).
    if (oldWidget.post.id != widget.post.id) _loadData();
  }

  Future<void> _loadData() async {
    final [reactions, comments] = await Future.wait([
      FeedService.instance.getReactions(widget.post.id),
      FeedService.instance.getComments(widget.post.id),
    ]);
    if (!mounted) return;
    setState(() {
      _reactions = reactions as Map<String, List<String>>;
      _commentCount = (comments as List).length;
    });
  }

  void _showEmojiPicker() {
    showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: ['👍', '❤️', '😂', '😮', '😢', '🙏', '🔥', '👏']
              .map((emoji) => GestureDetector(
                    onTap: () {
                      Navigator.of(context).pop();
                      _toggleReaction(emoji);
                    },
                    child: Text(emoji,
                        style: const TextStyle(fontSize: 28)),
                  ))
              .toList(),
        ),
      ),
    );
  }

  Future<void> _toggleReaction(String emoji) async {
    final myDid =
        IdentityService.instance.currentIdentity?.did ?? '';
    await FeedService.instance.toggleReaction(
      postId: widget.post.id,
      emoji: emoji,
      myDid: myDid,
      postNostrEventId: widget.post.nostrEventId,
    );
    await _loadData();
  }

  /// Bottom sheet: repost + DM + channel share options.
  void _showShareSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: const [
                  Icon(Icons.share_outlined, color: AppColors.gold),
                  SizedBox(width: 8),
                  Text('Beitrag teilen',
                      style: TextStyle(
                          color: AppColors.gold,
                          fontWeight: FontWeight.bold,
                          fontSize: 16)),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.repeat, color: AppColors.gold),
              title: const Text('In meinen Feed reposten',
                  style: TextStyle(color: AppColors.onDark)),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute(
                    builder: (_) => CreatePostScreen(
                      repostOf: widget.post.id,
                      repostAuthorPseudonym: widget.post.authorPseudonym,
                      repostPreview: widget.post.content.isNotEmpty
                          ? widget.post.content
                          : widget.post.images.isNotEmpty
                              ? '[Bild]'
                              : null,
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.chat_outlined,
                  color: AppColors.onDark.withValues(alpha: 0.35)),
              title: Text('Per Direktnachricht senden',
                  style: TextStyle(
                      color: AppColors.onDark.withValues(alpha: 0.35))),
              subtitle: Text('Bald verfügbar',
                  style: TextStyle(
                      fontSize: 11,
                      color: AppColors.onDark.withValues(alpha: 0.3))),
              enabled: false,
            ),
            ListTile(
              leading: Icon(Icons.tag,
                  color: AppColors.onDark.withValues(alpha: 0.35)),
              title: Text('In Kanal oder Gruppe teilen',
                  style: TextStyle(
                      color: AppColors.onDark.withValues(alpha: 0.35))),
              subtitle: Text('Bald verfügbar',
                  style: TextStyle(
                      fontSize: 11,
                      color: AppColors.onDark.withValues(alpha: 0.3))),
              enabled: false,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';

    return Row(
      children: [
        // Emoji reaction button – 44×44 touch target
        SizedBox(
          height: 44,
          child: InkWell(
            onTap: _showEmojiPicker,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceVariant,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(Icons.add_reaction_outlined,
                      size: 22, color: AppColors.gold),
                ),
              ),
            ),
          ),
        ),

        // Reaction badges
        ..._reactions.entries.take(4).map((entry) {
          final myVoted = entry.value.contains(myDid);
          return GestureDetector(
            onTap: () => _toggleReaction(entry.key),
            child: Container(
              margin: const EdgeInsets.only(left: 6),
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: myVoted
                    ? AppColors.gold.withValues(alpha: 0.15)
                    : AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(16),
                border: myVoted
                    ? Border.all(
                        color: AppColors.gold.withValues(alpha: 0.4))
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(entry.key,
                      style: const TextStyle(fontSize: 13)),
                  const SizedBox(width: 3),
                  Text('${entry.value.length}',
                      style: TextStyle(
                        color: AppColors.onDark.withValues(alpha: 0.7),
                        fontSize: 11,
                      )),
                ],
              ),
            ),
          );
        }),

        const Spacer(),

        // Comments button – 44×44 touch target
        SizedBox(
          height: 44,
          child: InkWell(
            onTap: widget.onCommentTap,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(Icons.chat_bubble_outline,
                      size: 22,
                      color: AppColors.onDark.withValues(alpha: 0.5)),
                  const SizedBox(width: 5),
                  Text(
                    '$_commentCount',
                    style: TextStyle(
                      color: AppColors.onDark.withValues(alpha: 0.5),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        const SizedBox(width: 24),

        // Share button – 44×44 touch target, opens share sheet
        SizedBox(
          width: 44,
          height: 44,
          child: InkWell(
            onTap: _showShareSheet,
            borderRadius: BorderRadius.circular(8),
            child: Center(
              child: Icon(Icons.share_outlined,
                  size: 22,
                  color: AppColors.onDark.withValues(alpha: 0.5)),
            ),
          ),
        ),
      ],
    );
  }
}
