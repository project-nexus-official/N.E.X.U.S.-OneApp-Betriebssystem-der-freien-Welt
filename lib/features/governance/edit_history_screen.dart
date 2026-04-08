import 'package:flutter/material.dart';

import '../../shared/theme/app_theme.dart';
import 'proposal_edit.dart';
import 'proposal_service.dart';

/// Shows the edit history of a proposal (all edits made during discussion).
class EditHistoryScreen extends StatefulWidget {
  final String proposalId;
  const EditHistoryScreen({super.key, required this.proposalId});

  @override
  State<EditHistoryScreen> createState() => _EditHistoryScreenState();
}

class _EditHistoryScreenState extends State<EditHistoryScreen> {
  List<ProposalEdit>? _edits;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final edits =
        await ProposalService.instance.getEditHistory(widget.proposalId);
    if (mounted) setState(() => _edits = edits);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bearbeitungs-Historie'),
        backgroundColor: AppColors.deepBlue,
      ),
      backgroundColor: AppColors.deepBlue,
      body: _edits == null
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.gold))
          : _edits!.isEmpty
              ? Center(
                  child: Text(
                    'Keine Bearbeitungen vorhanden.',
                    style: TextStyle(
                        color: AppColors.onDark.withValues(alpha: 0.5)),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _edits!.length,
                  itemBuilder: (context, i) =>
                      _EditTile(edit: _edits![i]),
                ),
    );
  }
}

class _EditTile extends StatelessWidget {
  final ProposalEdit edit;
  const _EditTile({required this.edit});

  @override
  Widget build(BuildContext context) {
    final hasReason =
        edit.editReason != null && edit.editReason!.isNotEmpty;
    final titleChanged = edit.oldTitle != edit.newTitle;
    final descChanged = edit.oldDescription != edit.newDescription;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surfaceVariant),
      ),
      child: ExpansionTile(
        collapsedIconColor: AppColors.onDark.withValues(alpha: 0.5),
        iconColor: AppColors.gold,
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Version ${edit.versionBefore} → ${edit.versionAfter}',
              style: const TextStyle(
                color: AppColors.onDark,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '${edit.editorPseudonym} · ${_fmt(edit.editedAt)}',
              style: TextStyle(
                color: AppColors.onDark.withValues(alpha: 0.5),
                fontSize: 12,
              ),
            ),
            if (hasReason) ...[
              const SizedBox(height: 3),
              Text(
                'Grund: ${edit.editReason}',
                style: TextStyle(
                  color: AppColors.onDark.withValues(alpha: 0.6),
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ),
        children: [
          // Title diff
          _DiffSection(
            label: 'Titel',
            oldText: edit.oldTitle,
            newText: edit.newTitle,
            changed: titleChanged,
          ),
          const SizedBox(height: 12),
          // Description diff
          _DiffSection(
            label: 'Beschreibung',
            oldText: edit.oldDescription,
            newText: edit.newDescription,
            changed: descChanged,
          ),
        ],
      ),
    );
  }

  String _fmt(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}.'
        '${dt.month.toString().padLeft(2, '0')}.'
        '${dt.year}  '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }
}

class _DiffSection extends StatelessWidget {
  final String label;
  final String oldText;
  final String newText;
  final bool changed;

  const _DiffSection({
    required this.label,
    required this.oldText,
    required this.newText,
    required this.changed,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label + ':',
          style: TextStyle(
            color: AppColors.onDark.withValues(alpha: 0.6),
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 6),
        if (!changed)
          Text(
            'Unverändert',
            style: TextStyle(
              color: AppColors.onDark.withValues(alpha: 0.4),
              fontSize: 13,
              fontStyle: FontStyle.italic,
            ),
          )
        else ...[
          // Old
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border:
                  Border.all(color: Colors.red.withValues(alpha: 0.2)),
            ),
            child: Text(
              oldText,
              style: TextStyle(
                color: AppColors.onDark.withValues(alpha: 0.6),
                fontSize: 13,
                decoration: TextDecoration.lineThrough,
                decorationColor: Colors.red.withValues(alpha: 0.5),
              ),
            ),
          ),
          const SizedBox(height: 6),
          // New
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: Colors.green.withValues(alpha: 0.2)),
            ),
            child: Text(
              newText,
              style: TextStyle(
                color: AppColors.onDark,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
