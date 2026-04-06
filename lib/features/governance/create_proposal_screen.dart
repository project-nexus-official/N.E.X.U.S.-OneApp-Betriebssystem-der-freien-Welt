import 'package:flutter/material.dart';

import '../../core/identity/identity_service.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/help_icon.dart';
import 'cell.dart';
import 'proposal.dart';
import 'proposal_service.dart';

/// Form to create a new proposal within a cell.
class CreateProposalScreen extends StatefulWidget {
  final Cell cell;
  const CreateProposalScreen({super.key, required this.cell});

  @override
  State<CreateProposalScreen> createState() => _CreateProposalScreenState();
}

class _CreateProposalScreenState extends State<CreateProposalScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();

  String _domain = proposalDomains.last;
  int _discussionDays = 7;
  int _votingDays = 3;
  double _quorum = 0.5;
  ProposalScope _scope = ProposalScope.cell;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit({required bool publish}) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _isSubmitting = true);

    try {
      final myDid = IdentityService.instance.currentIdentity!.did;
      final proposal = Proposal.create(
        title: _titleCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        createdBy: myDid,
        cellId: widget.cell.id,
        scope: _scope,
        domain: _domain,
        discussionDays: _discussionDays,
        votingDays: _votingDays,
        quorum: _quorum,
      );

      await ProposalService.instance.createProposal(proposal);
      if (publish) {
        await ProposalService.instance.publishProposal(proposal.id);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(publish
                ? 'Antrag veröffentlicht!'
                : 'Entwurf gespeichert.'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Neuer Antrag'),
        backgroundColor: AppColors.deepBlue,
        actions: const [
          HelpIcon(contextId: 'proposal_general'),
          SizedBox(width: 8),
        ],
      ),
      backgroundColor: AppColors.deepBlue,
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            // Cell info
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: AppColors.gold.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.gold.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.group_work, color: AppColors.gold, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Zelle: ${widget.cell.name}',
                    style: const TextStyle(
                      color: AppColors.gold,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),

            // Title
            _SectionLabel('Titel *'),
            TextFormField(
              controller: _titleCtrl,
              decoration: _inputDeco('Kurzer, prägnanter Titel (min. 10 Zeichen)'),
              style: const TextStyle(color: AppColors.onDark),
              maxLength: 200,
              validator: (v) {
                if (v == null || v.trim().length < 10) {
                  return 'Mindestens 10 Zeichen.';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // Description
            _SectionLabel('Beschreibung (Markdown unterstützt)'),
            TextFormField(
              controller: _descCtrl,
              decoration: _inputDeco('Beschreibe deinen Antrag ausführlich …'),
              style: const TextStyle(color: AppColors.onDark),
              maxLines: 6,
            ),
            const SizedBox(height: 16),

            // Scope
            _SectionLabel('Reichweite', helpContextId: 'proposal_status'),
            _RadioOption<ProposalScope>(
              label: 'Nur diese Zelle (Standard)',
              value: ProposalScope.cell,
              groupValue: _scope,
              onChanged: (v) => setState(() => _scope = v!),
            ),
            _RadioOption<ProposalScope>(
              label: 'Föderation (in zukünftiger Version)',
              value: ProposalScope.federation,
              groupValue: _scope,
              onChanged: (v) => setState(() => _scope = v!),
              disabled: true,
            ),
            _RadioOption<ProposalScope>(
              label: 'Global — Verfassungsfrage (in zukünftiger Version)',
              value: ProposalScope.global,
              groupValue: _scope,
              onChanged: (v) => setState(() => _scope = v!),
              disabled: true,
            ),
            const SizedBox(height: 16),

            // Domain
            _SectionLabel('Themenbereich'),
            DropdownButtonFormField<String>(
              value: _domain,
              dropdownColor: AppColors.surface,
              style: const TextStyle(color: AppColors.onDark),
              decoration: _inputDeco(''),
              items: proposalDomains
                  .map((d) => DropdownMenuItem(value: d, child: Text(d)))
                  .toList(),
              onChanged: (v) => setState(() => _domain = v!),
            ),
            const SizedBox(height: 16),

            // Discussion duration
            _SectionLabel('Diskussionsdauer'),
            _DurationSelector(
              options: const [1, 3, 7, 14],
              selected: _discussionDays,
              onChanged: (v) => setState(() => _discussionDays = v),
              suffix: 'Tage',
            ),
            const SizedBox(height: 16),

            // Voting duration
            _SectionLabel('Abstimmungsdauer'),
            _DurationSelector(
              options: const [1, 3, 7],
              selected: _votingDays,
              onChanged: (v) => setState(() => _votingDays = v),
              suffix: 'Tage',
            ),
            const SizedBox(height: 16),

            // Quorum
            _SectionLabel(
                'Quorum: ${(_quorum * 100).round()}% der Mitglieder müssen abstimmen'),
            _DurationSelector(
              options: const [25, 50, 75],
              selected: (_quorum * 100).round(),
              onChanged: (v) => setState(() => _quorum = v / 100.0),
              suffix: '%',
            ),
            const SizedBox(height: 32),

            // Action buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        _isSubmitting ? null : () => _submit(publish: false),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.onDark,
                      side: const BorderSide(color: AppColors.surfaceVariant),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('Als Entwurf speichern'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed:
                        _isSubmitting ? null : () => _submit(publish: true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.gold,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _isSubmitting
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.black),
                          )
                        : const Text('Veröffentlichen',
                            style:
                                TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDeco(String hint) => InputDecoration(
        hintText: hint,
        hintStyle:
            TextStyle(color: AppColors.onDark.withValues(alpha: 0.4)),
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.surfaceVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.surfaceVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.gold),
        ),
        counterStyle:
            TextStyle(color: AppColors.onDark.withValues(alpha: 0.4)),
      );
}

// ── Helper widgets ────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  final String? helpContextId;
  const _SectionLabel(this.text, {this.helpContextId});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Text(
              text,
              style: TextStyle(
                color: AppColors.onDark.withValues(alpha: 0.7),
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
            if (helpContextId != null)
              HelpIcon(contextId: helpContextId!, size: 15),
          ],
        ),
      );
}

class _RadioOption<T> extends StatelessWidget {
  final String label;
  final T value;
  final T groupValue;
  final ValueChanged<T?> onChanged;
  final bool disabled;

  const _RadioOption({
    required this.label,
    required this.value,
    required this.groupValue,
    required this.onChanged,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: disabled ? 0.4 : 1.0,
      child: RadioListTile<T>(
        title: Text(
          label,
          style: const TextStyle(color: AppColors.onDark, fontSize: 14),
        ),
        value: value,
        groupValue: groupValue,
        activeColor: AppColors.gold,
        onChanged: disabled ? null : onChanged,
        contentPadding: EdgeInsets.zero,
        dense: true,
      ),
    );
  }
}

class _DurationSelector extends StatelessWidget {
  final List<int> options;
  final int selected;
  final ValueChanged<int> onChanged;
  final String suffix;

  const _DurationSelector({
    required this.options,
    required this.selected,
    required this.onChanged,
    required this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: options
          .map(
            (v) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text('$v $suffix'),
                selected: selected == v,
                onSelected: (_) => onChanged(v),
                selectedColor: AppColors.gold,
                backgroundColor: AppColors.surface,
                labelStyle: TextStyle(
                  color: selected == v ? Colors.black : AppColors.onDark,
                  fontWeight: FontWeight.w600,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(
                    color:
                        selected == v ? AppColors.gold : AppColors.surfaceVariant,
                  ),
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}
