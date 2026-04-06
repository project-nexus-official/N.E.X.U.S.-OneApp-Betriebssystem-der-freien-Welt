import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../../core/identity/identity_service.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/help_icon.dart';
import '../../shared/widgets/identicon.dart';
import 'feed_post.dart';
import 'feed_service.dart';

/// Screen for composing a new Dorfplatz post.
class CreatePostScreen extends StatefulWidget {
  /// Pre-filled repost data (optional).
  final String? repostOf;
  final String? repostAuthorPseudonym;
  final String? repostPreview;

  const CreatePostScreen({
    super.key,
    this.repostOf,
    this.repostAuthorPseudonym,
    this.repostPreview,
  });

  @override
  State<CreatePostScreen> createState() => _CreatePostScreenState();
}

class _CreatePostScreenState extends State<CreatePostScreen> {
  final _textCtrl = TextEditingController();
  final _picker = ImagePicker();

  FeedVisibility _visibility = FeedVisibility.contacts;
  final List<String> _images = []; // base64-encoded JPEGs
  bool _posting = false;

  // Poll state
  bool _showPoll = false;
  final _pollQuestionCtrl = TextEditingController();
  final List<TextEditingController> _pollOptionCtrls = [
    TextEditingController(),
    TextEditingController(),
  ];
  bool _pollMultiple = false;
  DateTime? _pollEndsAt;

  @override
  void dispose() {
    _textCtrl.dispose();
    _pollQuestionCtrl.dispose();
    for (final c in _pollOptionCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _canPost {
    if (_posting) return false;
    final hasText = _textCtrl.text.trim().isNotEmpty;
    final hasImages = _images.isNotEmpty;
    final hasRepost = widget.repostOf != null;
    if (_showPoll) {
      final validPoll = _pollQuestionCtrl.text.trim().isNotEmpty &&
          _pollOptionCtrls.where((c) => c.text.trim().isNotEmpty).length >= 2;
      return validPoll;
    }
    return hasText || hasImages || hasRepost;
  }

  Future<void> _pickImage() async {
    if (_images.length >= 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Maximal 4 Bilder pro Beitrag.')),
      );
      return;
    }
    final source = await _showImageSourceSheet();
    if (source == null) return;

    final file = await _picker.pickImage(source: source);
    if (file == null) return;

    final bytes = await file.readAsBytes();
    final compressed = await _compressImage(bytes);
    setState(() => _images.add(base64Encode(compressed)));
  }

  Future<ImageSource?> _showImageSourceSheet() async {
    return showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('Kamera'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Galerie'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
  }

  Future<Uint8List> _compressImage(Uint8List bytes) async {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    final resized = decoded.width > 1024 || decoded.height > 1024
        ? img.copyResize(
            decoded,
            width: decoded.width > decoded.height ? 1024 : -1,
            height: decoded.height >= decoded.width ? 1024 : -1,
          )
        : decoded;
    return Uint8List.fromList(img.encodeJpg(resized, quality: 75));
  }

  void _removeImage(int index) {
    setState(() => _images.removeAt(index));
  }

  void _togglePoll() {
    setState(() {
      _showPoll = !_showPoll;
      if (!_showPoll) {
        _pollQuestionCtrl.clear();
        for (final c in _pollOptionCtrls) {
          c.clear();
        }
        _pollEndsAt = null;
      }
    });
  }

  void _addPollOption() {
    if (_pollOptionCtrls.length >= 6) return;
    setState(() => _pollOptionCtrls.add(TextEditingController()));
  }

  void _removePollOption(int idx) {
    if (_pollOptionCtrls.length <= 2) return;
    setState(() {
      _pollOptionCtrls[idx].dispose();
      _pollOptionCtrls.removeAt(idx);
    });
  }

  Future<void> _pickPollEndDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 30)),
    );
    if (date == null) return;
    setState(() => _pollEndsAt = date.add(const Duration(hours: 23, minutes: 59)));
  }

  Future<void> _post() async {
    final identity = IdentityService.instance.currentIdentity;
    if (identity == null) return;

    setState(() => _posting = true);

    try {
      Poll? poll;
      if (_showPoll && _pollQuestionCtrl.text.trim().isNotEmpty) {
        final options = _pollOptionCtrls
            .where((c) => c.text.trim().isNotEmpty)
            .map((c) => PollOption(
                  id: generateFeedId(),
                  text: c.text.trim(),
                ))
            .toList();
        poll = Poll(
          question: _pollQuestionCtrl.text.trim(),
          options: options,
          multipleChoice: _pollMultiple,
          endsAt: _pollEndsAt,
        );
      }

      await FeedService.instance.createPost(
        authorDid: identity.did,
        authorPseudonym: identity.pseudonym,
        content: _textCtrl.text.trim(),
        images: List.from(_images),
        visibility: _visibility,
        poll: poll,
        repostOf: widget.repostOf,
        repostComment:
            widget.repostOf != null && _textCtrl.text.trim().isNotEmpty
                ? _textCtrl.text.trim()
                : null,
      );

      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final identity = IdentityService.instance.currentIdentity;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Neuer Beitrag'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: _canPost ? _post : null,
              child: _posting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text(
                      'Posten',
                      style: TextStyle(
                        color: AppColors.gold,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Author row ────────────────────────────────────────────────
          if (identity != null)
            Row(
              children: [
                Identicon(bytes: identity.did.codeUnits, size: 40),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      identity.pseudonym,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: AppColors.onDark,
                      ),
                    ),
                    _VisibilitySelector(
                      value: _visibility,
                      onChanged: (v) => setState(() => _visibility = v),
                    ),
                  ],
                ),
              ],
            ),
          const SizedBox(height: 16),

          // ── Repost indicator ──────────────────────────────────────────
          if (widget.repostOf != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.gold.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.repeat, size: 16, color: AppColors.gold),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (widget.repostAuthorPseudonym != null)
                          Text(
                            widget.repostAuthorPseudonym!,
                            style: const TextStyle(
                              color: AppColors.gold,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        if (widget.repostPreview != null)
                          Text(
                            widget.repostPreview!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.onDark.withValues(alpha: 0.7),
                              fontSize: 13,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          // ── Text input ────────────────────────────────────────────────
          TextField(
            controller: _textCtrl,
            autofocus: widget.repostOf == null,
            maxLines: null,
            minLines: 4,
            style: const TextStyle(color: AppColors.onDark, fontSize: 16),
            decoration: InputDecoration(
              hintText: widget.repostOf != null
                  ? 'Kommentar hinzufügen (optional)...'
                  : 'Was bewegt dich?',
              hintStyle:
                  TextStyle(color: AppColors.onDark.withValues(alpha: 0.4)),
              border: InputBorder.none,
            ),
            onChanged: (_) => setState(() {}),
          ),

          // ── Image preview grid ────────────────────────────────────────
          if (_images.isNotEmpty) ...[
            const SizedBox(height: 12),
            _ImagePreviewGrid(
              images: _images,
              onRemove: _removeImage,
            ),
          ],

          // ── Poll editor ───────────────────────────────────────────────
          if (_showPoll) ...[
            const SizedBox(height: 16),
            _PollEditor(
              questionCtrl: _pollQuestionCtrl,
              optionCtrls: _pollOptionCtrls,
              multipleChoice: _pollMultiple,
              endsAt: _pollEndsAt,
              onMultipleChanged: (v) => setState(() => _pollMultiple = v),
              onAddOption: _addPollOption,
              onRemoveOption: _removePollOption,
              onPickEndDate: _pickPollEndDate,
              onClearEndDate: () => setState(() => _pollEndsAt = null),
            ),
          ],

          const SizedBox(height: 80), // space for toolbar
        ],
      ),

      // ── Bottom toolbar ────────────────────────────────────────────────
      bottomNavigationBar: SafeArea(
        child: Container(
          color: AppColors.surface,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              _ToolbarButton(
                icon: Icons.photo_library_outlined,
                label: 'Bild',
                onTap: _images.length < 4 && !_showPoll ? _pickImage : null,
              ),
              _ToolbarButton(
                icon: Icons.bar_chart_outlined,
                label: 'Umfrage',
                isActive: _showPoll,
                onTap: _images.isEmpty ? _togglePoll : null,
              ),
              const Spacer(),
              if (_textCtrl.text.isNotEmpty)
                Text(
                  '${_textCtrl.text.length}',
                  style: TextStyle(
                    color: _textCtrl.text.length > 1000
                        ? Colors.redAccent
                        : AppColors.onDark.withValues(alpha: 0.5),
                    fontSize: 12,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Visibility selector ────────────────────────────────────────────────────────

class _VisibilitySelector extends StatelessWidget {
  final FeedVisibility value;
  final ValueChanged<FeedVisibility> onChanged;

  const _VisibilitySelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showPicker(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_iconFor(value), size: 14, color: AppColors.gold),
          const SizedBox(width: 4),
          Text(
            _labelFor(value),
            style: const TextStyle(color: AppColors.gold, fontSize: 12),
          ),
          const Icon(Icons.arrow_drop_down, size: 16, color: AppColors.gold),
        ],
      ),
    );
  }

  Future<void> _showPicker(BuildContext context) async {
    final result = await showModalBottomSheet<FeedVisibility>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: const [
                  Text(
                    'Sichtbarkeit',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppColors.gold,
                    ),
                  ),
                  HelpIcon(contextId: 'dorfplatz_visibility', size: 15),
                ],
              ),
            ),
            for (final v in FeedVisibility.values)
              ListTile(
                leading: Icon(_iconFor(v), color: AppColors.gold),
                title: Text(_labelFor(v)),
                subtitle: Text(_descFor(v)),
                trailing:
                    v == value ? const Icon(Icons.check, color: AppColors.gold) : null,
                onTap: () => Navigator.pop(ctx, v),
              ),
          ],
        ),
      ),
    );
    if (result != null) onChanged(result);
  }

  IconData _iconFor(FeedVisibility v) => switch (v) {
        FeedVisibility.contacts => Icons.people_outline,
        FeedVisibility.cell => Icons.group_work_outlined,
        FeedVisibility.public => Icons.public,
      };

  String _labelFor(FeedVisibility v) => switch (v) {
        FeedVisibility.contacts => 'Kontakte',
        FeedVisibility.cell => 'Meine Zelle',
        FeedVisibility.public => 'Öffentlich',
      };

  String _descFor(FeedVisibility v) => switch (v) {
        FeedVisibility.contacts => 'Nur deine Kontakte sehen diesen Beitrag',
        FeedVisibility.cell => 'Alle Zellen-Mitglieder sehen diesen Beitrag',
        FeedVisibility.public => 'Alle NEXUS-Nutzer sehen diesen Beitrag',
      };
}

// ── Image preview grid ─────────────────────────────────────────────────────────

class _ImagePreviewGrid extends StatelessWidget {
  final List<String> images;
  final void Function(int) onRemove;

  const _ImagePreviewGrid({required this.images, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: images.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemBuilder: (_, i) => Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              base64Decode(images[i]),
              fit: BoxFit.cover,
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: GestureDetector(
              onTap: () => onRemove(i),
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                padding: const EdgeInsets.all(4),
                child: const Icon(Icons.close, size: 16, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Poll editor ────────────────────────────────────────────────────────────────

class _PollEditor extends StatelessWidget {
  final TextEditingController questionCtrl;
  final List<TextEditingController> optionCtrls;
  final bool multipleChoice;
  final DateTime? endsAt;
  final ValueChanged<bool> onMultipleChanged;
  final VoidCallback onAddOption;
  final void Function(int) onRemoveOption;
  final VoidCallback onPickEndDate;
  final VoidCallback onClearEndDate;

  const _PollEditor({
    required this.questionCtrl,
    required this.optionCtrls,
    required this.multipleChoice,
    required this.endsAt,
    required this.onMultipleChanged,
    required this.onAddOption,
    required this.onRemoveOption,
    required this.onPickEndDate,
    required this.onClearEndDate,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bar_chart, color: AppColors.gold, size: 18),
              const SizedBox(width: 8),
              const Text(
                'Umfrage',
                style: TextStyle(
                  color: AppColors.gold,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: questionCtrl,
            style: const TextStyle(color: AppColors.onDark),
            decoration: const InputDecoration(
              hintText: 'Frage...',
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          ...List.generate(optionCtrls.length, (i) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: optionCtrls[i],
                    style: const TextStyle(color: AppColors.onDark),
                    decoration: InputDecoration(
                      hintText: 'Option ${i + 1}',
                      isDense: true,
                    ),
                  ),
                ),
                if (optionCtrls.length > 2)
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline,
                        color: Colors.redAccent, size: 20),
                    onPressed: () => onRemoveOption(i),
                  ),
              ],
            ),
          )),
          if (optionCtrls.length < 6)
            TextButton.icon(
              onPressed: onAddOption,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Option hinzufügen'),
              style: TextButton.styleFrom(foregroundColor: AppColors.gold),
            ),
          const Divider(),
          SwitchListTile(
            value: multipleChoice,
            onChanged: onMultipleChanged,
            title: const Text('Mehrfachauswahl', style: TextStyle(fontSize: 13)),
            contentPadding: EdgeInsets.zero,
            activeThumbColor: AppColors.gold,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Ablauf', style: TextStyle(fontSize: 13)),
            subtitle: Text(
              endsAt != null
                  ? '${endsAt!.day}.${endsAt!.month}.${endsAt!.year}'
                  : 'Kein Ablauf',
              style: TextStyle(color: AppColors.onDark.withValues(alpha: 0.6)),
            ),
            trailing: endsAt != null
                ? IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: onClearEndDate,
                  )
                : TextButton(
                    onPressed: onPickEndDate,
                    child: const Text('Festlegen',
                        style: TextStyle(color: AppColors.gold, fontSize: 12)),
                  ),
          ),
        ],
      ),
    );
  }
}

// ── Toolbar button ─────────────────────────────────────────────────────────────

class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool isActive;

  const _ToolbarButton({
    required this.icon,
    required this.label,
    this.onTap,
    this.isActive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = onTap == null
        ? AppColors.onDark.withValues(alpha: 0.25)
        : isActive
            ? AppColors.gold
            : AppColors.onDark.withValues(alpha: 0.7);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: color, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
