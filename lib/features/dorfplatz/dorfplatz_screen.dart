import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/contacts/contact_service.dart';
import '../../core/identity/identity_service.dart';
import '../../shared/theme/app_theme.dart';
import 'create_post_screen.dart';
import 'feed_post.dart';
import 'feed_post_card.dart';
import 'feed_service.dart';
import 'post_detail_screen.dart';

/// Main Dorfplatz screen with three feed tabs:
/// Kontakte | Meine Zelle | Entdecken
class DorfplatzScreen extends StatefulWidget {
  const DorfplatzScreen({super.key});

  @override
  State<DorfplatzScreen> createState() => _DorfplatzScreenState();
}

class _DorfplatzScreenState extends State<DorfplatzScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;
  StreamSubscription<void>? _feedSub;

  bool _loading = true;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
    _tabCtrl.addListener(() => setState(() {}));
    _feedSub = FeedService.instance.stream.listen((_) {
      if (mounted) setState(() {});
    });
    _init();
  }

  Future<void> _init() async {
    // Feed already loaded in main.dart initServicesAfterIdentity; just refresh
    // the loading indicator.
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _feedSub?.cancel();
    super.dispose();
  }

  String get _myDid =>
      IdentityService.instance.currentIdentity?.did ?? '';

  Set<String> get _contactDids =>
      ContactService.instance.contacts.map((c) => c.did).toSet();

  FeedTab get _currentFeedTab => switch (_tabCtrl.index) {
        0 => FeedTab.contacts,
        1 => FeedTab.cell,
        _ => FeedTab.entdecken,
      };

  List<FeedPost> get _posts => FeedService.instance.getPostsForTab(
        _currentFeedTab,
        myDid: _myDid,
        contactDids: _contactDids,
      );

  Future<void> _refresh() async {
    await FeedService.instance.load();
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    await FeedService.instance.loadMore();
    if (mounted) setState(() => _loadingMore = false);
  }

  void _openCreatePost() {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => const CreatePostScreen()),
    );
  }

  void _openDetail(FeedPost post) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => PostDetailScreen(post: post)),
    );
  }

  void _openDetailComments(FeedPost post) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => PostDetailScreen(post: post)),
    );
  }

  Future<void> _onMenuTap(FeedPost post) async {
    final myDid = _myDid;
    final isOwn = post.authorDid == myDid;

    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isOwn) ...[
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Bearbeiten'),
                onTap: () => Navigator.pop(ctx, 'edit'),
              ),
              ListTile(
                leading: const Icon(Icons.lock_open_outlined),
                title: const Text('Sichtbarkeit ändern'),
                onTap: () => Navigator.pop(ctx, 'changeVisibility'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline,
                    color: Colors.redAccent),
                title: const Text('Löschen',
                    style: TextStyle(color: Colors.redAccent)),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
            ] else ...[
              ListTile(
                leading: const Icon(Icons.repeat),
                title: const Text('Reposten'),
                onTap: () => Navigator.pop(ctx, 'repost'),
              ),
              ListTile(
                leading: const Icon(Icons.volume_off_outlined),
                title: const Text('Autor stumm schalten'),
                onTap: () => Navigator.pop(ctx, 'mute'),
              ),
            ],
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Abbrechen'),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );

    if (action == null || !mounted) return;

    switch (action) {
      case 'delete':
        final confirmed = await _confirmDelete(post);
        if (confirmed) await FeedService.instance.deletePost(post.id);
      case 'repost':
        Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute(
            builder: (_) => CreatePostScreen(
              repostOf: post.id,
              repostAuthorPseudonym: post.authorPseudonym,
              repostPreview: post.content.isNotEmpty
                  ? post.content
                  : post.images.isNotEmpty
                      ? '[Bild]'
                      : null,
            ),
          ),
        );
      case 'mute':
        await FeedService.instance.muteAuthor(post.authorDid);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content:
                    Text('${post.authorPseudonym} wurde stumm geschaltet.')),
          );
        }
      case 'edit':
        _showEditDialog(post);
      case 'changeVisibility':
        await _showVisibilityPicker(post);
    }
  }

  /// Bottom sheet to expand the visibility of an own post.
  /// Visibility can only be widened (contacts → cell → public).
  Future<void> _showVisibilityPicker(FeedPost post) async {
    final options = [
      (FeedVisibility.contacts, Icons.people_outline, 'Meine Kontakte'),
      (FeedVisibility.cell,     Icons.group_work_outlined, 'Meine Zelle'),
      (FeedVisibility.public,   Icons.public,  'Öffentlich'),
    ];

    final chosen = await showModalBottomSheet<FeedVisibility>(
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
                  Icon(Icons.lock_open_outlined, color: AppColors.gold),
                  SizedBox(width: 8),
                  Text('Sichtbarkeit erweitern',
                      style: TextStyle(
                          color: AppColors.gold,
                          fontWeight: FontWeight.bold,
                          fontSize: 16)),
                ],
              ),
            ),
            ...options.map((entry) {
              final (vis, icon, label) = entry;
              final isCurrent = vis == post.visibility;
              final isLower   = vis.index < post.visibility.index;
              final disabled  = isCurrent || isLower;
              return ListTile(
                leading: Icon(icon,
                    color: disabled
                        ? AppColors.onDark.withValues(alpha: 0.3)
                        : AppColors.gold),
                title: Text(label,
                    style: TextStyle(
                        color: disabled
                            ? AppColors.onDark.withValues(alpha: 0.35)
                            : AppColors.onDark)),
                trailing: isCurrent
                    ? const Icon(Icons.check, color: AppColors.gold, size: 18)
                    : null,
                enabled: !disabled,
                onTap: disabled ? null : () => Navigator.pop(ctx, vis),
              );
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (chosen == null || !mounted) return;

    // Confirmation dialog – this action is irreversible.
    final visLabel = switch (chosen) {
      FeedVisibility.contacts => 'Meine Kontakte',
      FeedVisibility.cell     => 'Meine Zelle',
      FeedVisibility.public   => 'Öffentlich',
    };
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Sichtbarkeit erweitern?',
            style: TextStyle(color: AppColors.onDark)),
        content: Text(
          'Sichtbarkeit auf „$visLabel" erweitern?\n'
          'Das kann nicht rückgängig gemacht werden.',
          style: TextStyle(
              color: AppColors.onDark.withValues(alpha: 0.8)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen',
                style: TextStyle(color: AppColors.onDark)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Erweitern',
                style: TextStyle(color: AppColors.gold)),
          ),
        ],
      ),
    ) ?? false;

    if (confirmed) {
      await FeedService.instance.changeVisibility(post.id, chosen);
    }
  }

  Future<bool> _confirmDelete(FeedPost post) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Beitrag löschen?'),
            content: const Text(
                'Dieser Beitrag wird unwiderruflich gelöscht.'),
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
        ) ??
        false;
  }

  Future<void> _showEditDialog(FeedPost post) async {
    final ctrl = TextEditingController(text: post.content);
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Beitrag bearbeiten'),
        content: TextField(
          controller: ctrl,
          maxLines: null,
          autofocus: true,
          style: const TextStyle(color: AppColors.onDark),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Speichern',
                style: TextStyle(color: AppColors.gold)),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (saved != null && saved.isNotEmpty) {
      await FeedService.instance.editPost(post.id, saved);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dorfplatz'),
        bottom: TabBar(
          controller: _tabCtrl,
          indicatorColor: AppColors.gold,
          labelColor: AppColors.gold,
          unselectedLabelColor: AppColors.onDark,
          tabs: const [
            Tab(text: 'Kontakte'),
            Tab(text: 'Meine Zelle'),
            Tab(text: 'Entdecken'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabCtrl,
              children: [
                _FeedList(
                  posts: _posts,
                  emptyMessage: 'Noch keine Beiträge von deinen Kontakten.',
                  onRefresh: _refresh,
                  onLoadMore: _loadMore,
                  loadingMore: _loadingMore,
                  onTap: _openDetail,
                  onCommentTap: _openDetailComments,
                  onMenuTap: _onMenuTap,
                ),
                const _ComingSoonTab(
                  message:
                      'Deine Zelle ist noch nicht aktiv.\nTritt einer Zelle bei, um lokale Beiträge zu sehen.',
                ),
                _FeedList(
                  posts: FeedService.instance.getPostsForTab(
                    FeedTab.entdecken,
                    myDid: _myDid,
                    contactDids: _contactDids,
                  ),
                  emptyMessage:
                      'Noch keine öffentlichen Beiträge im Netzwerk.',
                  onRefresh: _refresh,
                  onLoadMore: _loadMore,
                  loadingMore: _loadingMore,
                  onTap: _openDetail,
                  onCommentTap: _openDetailComments,
                  onMenuTap: _onMenuTap,
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openCreatePost,
        backgroundColor: AppColors.gold,
        foregroundColor: AppColors.deepBlue,
        child: const Icon(Icons.edit_outlined),
      ),
    );
  }
}

// ── Feed list ──────────────────────────────────────────────────────────────────

class _FeedList extends StatelessWidget {
  final List<FeedPost> posts;
  final String emptyMessage;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onLoadMore;
  final bool loadingMore;
  final void Function(FeedPost) onTap;
  final void Function(FeedPost) onCommentTap;
  final Future<void> Function(FeedPost) onMenuTap;

  const _FeedList({
    required this.posts,
    required this.emptyMessage,
    required this.onRefresh,
    required this.onLoadMore,
    required this.loadingMore,
    required this.onTap,
    required this.onCommentTap,
    required this.onMenuTap,
  });

  @override
  Widget build(BuildContext context) {
    if (posts.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRefresh,
        color: AppColors.gold,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: 300,
            child: Center(
              child: Text(
                emptyMessage,
                style: TextStyle(
                  color: AppColors.onDark.withValues(alpha: 0.5),
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: onRefresh,
      color: AppColors.gold,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n is ScrollEndNotification &&
              n.metrics.extentAfter < 200) {
            onLoadMore();
          }
          return false;
        },
        child: ListView.builder(
          itemCount: posts.length + (loadingMore ? 1 : 0),
          itemBuilder: (ctx, i) {
            if (i == posts.length) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final post = posts[i];
            return FeedPostCard(
              key: ValueKey(post.id),
              post: post,
              onTap: () => onTap(post),
              onCommentTap: () => onCommentTap(post),
              onMenuTap: () => onMenuTap(post),
            );
          },
        ),
      ),
    );
  }
}

// ── Coming soon tab ────────────────────────────────────────────────────────────

class _ComingSoonTab extends StatelessWidget {
  final String message;

  const _ComingSoonTab({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.group_work_outlined,
              size: 60,
              color: AppColors.gold.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              style: TextStyle(
                color: AppColors.onDark.withValues(alpha: 0.55),
                fontSize: 15,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
