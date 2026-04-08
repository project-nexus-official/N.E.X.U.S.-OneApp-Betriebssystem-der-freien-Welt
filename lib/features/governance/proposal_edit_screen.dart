import 'package:flutter/material.dart';

import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/help_icon.dart';
import 'proposal.dart';
import 'proposal_service.dart';

/// Screen for editing a proposal (DRAFT or DISCUSSION phase).
class ProposalEditScreen extends StatefulWidget {
  final Proposal proposal;
  const ProposalEditScreen({super.key, required this.proposal});

  @override
  State<ProposalEditScreen> createState() => _ProposalEditScreenState();
}

class _ProposalEditScreenState extends State<ProposalEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleCtrl;
  late final TextEditingController _descCtrl;
  final _reasonCtrl = TextEditingController();

  String? _category;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.proposal.title);
    _descCtrl = TextEditingController(text: widget.proposal.description);
    _category = widget.proposal.category;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  bool get _isDraft => widget.proposal.status == ProposalStatus.DRAFT;

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _isSaving = true);
    print('[G2-UI] Edit screen saving: ${widget.proposal.id}');

    try {
      final p = widget.proposal;
      if (_isDraft) {
        // Update draft in-place
        p.title = _titleCtrl.text.trim();
        p.description = _descCtrl.text.trim();
        p.category = _category;
        await ProposalService.instance.updateDraft(p);
      } else {
        // Edit during discussion
        await ProposalService.instance.editInDiscussion(
          p.id,
          _titleCtrl.text.trim(),
          _descCtrl.text.trim(),
          _reasonCtrl.text.trim().isEmpty ? null : _reasonCtrl.text.trim(),
        );
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Antrag gespeichert.'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  InputDecoration _inputDeco(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: AppColors.onDark.withValues(alpha: 0.4)),
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
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Colors.red),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Antrag bearbeiten'),
        backgroundColor: AppColors.deepBlue,
      ),
      backgroundColor: AppColors.deepBlue,
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _Label('Titel *'),
            TextFormField(
              controller: _titleCtrl,
              decoration: _inputDeco('Worum geht es?'),
              style: const TextStyle(color: AppColors.onDark),
              maxLength: 100,
              buildCounter: (context,
                      {required currentLength,
                      required isFocused,
                      maxLength}) =>
                  Text(
                '$currentLength / ${maxLength ?? 100}',
                style: TextStyle(
                    color: AppColors.onDark.withValues(alpha: 0.4),
                    fontSize: 12),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Bitte Titel eingeben.' : null,
            ),
            const SizedBox(height: 16),

            _Label('Beschreibung *'),
            TextFormField(
              controller: _descCtrl,
              decoration: _inputDeco('Beschreibe deinen Antrag genauer…'),
              style: const TextStyle(color: AppColors.onDark),
              maxLines: 8,
              maxLength: 2000,
              buildCounter: (context,
                      {required currentLength,
                      required isFocused,
                      maxLength}) =>
                  Text(
                '$currentLength / ${maxLength ?? 2000}',
                style: TextStyle(
                    color: AppColors.onDark.withValues(alpha: 0.4),
                    fontSize: 12),
              ),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Bitte Beschreibung eingeben.'
                  : null,
            ),
            const SizedBox(height: 16),

            _Label('Kategorie (optional)'),
            DropdownButtonFormField<String?>(
              value: _category,
              dropdownColor: AppColors.surface,
              style: const TextStyle(color: AppColors.onDark),
              decoration: _inputDeco(''),
              items: const [
                DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Keine Kategorie',
                        style: TextStyle(color: AppColors.onDark))),
                DropdownMenuItem<String?>(
                    value: 'umwelt',
                    child: Text('🌱 Umwelt',
                        style: TextStyle(color: AppColors.onDark))),
                DropdownMenuItem<String?>(
                    value: 'finanzen',
                    child: Text('💰 Finanzen',
                        style: TextStyle(color: AppColors.onDark))),
                DropdownMenuItem<String?>(
                    value: 'it',
                    child: Text('💻 IT',
                        style: TextStyle(color: AppColors.onDark))),
                DropdownMenuItem<String?>(
                    value: 'soziales',
                    child: Text('🤝 Soziales',
                        style: TextStyle(color: AppColors.onDark))),
                DropdownMenuItem<String?>(
                    value: 'gesundheit',
                    child: Text('❤️ Gesundheit',
                        style: TextStyle(color: AppColors.onDark))),
                DropdownMenuItem<String?>(
                    value: 'bildung',
                    child: Text('📚 Bildung',
                        style: TextStyle(color: AppColors.onDark))),
                DropdownMenuItem<String?>(
                    value: 'sonstiges',
                    child: Text('📋 Sonstiges',
                        style: TextStyle(color: AppColors.onDark))),
              ],
              onChanged: (v) => setState(() => _category = v),
            ),
            const SizedBox(height: 16),

            // Reason field only during discussion
            if (!_isDraft) ...[
              Row(
                children: [
                  _Label('Grund für Änderung (empfohlen)'),
                  HelpIcon(contextId: 'proposal_edit', size: 15),
                ],
              ),
              TextFormField(
                controller: _reasonCtrl,
                decoration: _inputDeco(
                    'Z.B.: Tippfehler korrigiert, Argument ergänzt'),
                style: const TextStyle(color: AppColors.onDark),
                maxLines: 2,
                maxLength: 200,
                buildCounter: (context,
                        {required currentLength,
                        required isFocused,
                        maxLength}) =>
                    Text(
                  '$currentLength / ${maxLength ?? 200}',
                  style: TextStyle(
                      color: AppColors.onDark.withValues(alpha: 0.4),
                      fontSize: 12),
                ),
              ),
              const SizedBox(height: 12),

              // Notice card for discussion edit
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: Colors.orange.withValues(alpha: 0.3)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline,
                        color: Colors.orange, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Alle Mitglieder werden über deine Änderungen '
                        'benachrichtigt und können sie in der Edit-Historie '
                        'nachvollziehen.',
                        style: TextStyle(
                          color: Colors.orange.shade200,
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            const SizedBox(height: 12),

            // Save button
            Row(
              children: [
                TextButton(
                  onPressed:
                      _isSaving ? null : () => Navigator.of(context).pop(),
                  child: Text(
                    'Abbrechen',
                    style: TextStyle(
                        color: AppColors.onDark.withValues(alpha: 0.6)),
                  ),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _isSaving ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.gold,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _isSaving
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.black),
                        )
                      : const Text(
                          'Speichern',
                          style: TextStyle(fontWeight: FontWeight.bold),
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
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: TextStyle(
            color: AppColors.onDark.withValues(alpha: 0.7),
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      );
}
