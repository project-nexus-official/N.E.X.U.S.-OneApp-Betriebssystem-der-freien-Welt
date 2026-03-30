import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nexus_oneapp/core/identity/identity_service.dart';
import 'package:nexus_oneapp/core/identity/profile.dart';
import 'package:nexus_oneapp/core/identity/profile_service.dart';
import 'package:nexus_oneapp/shared/theme/app_theme.dart';
import 'package:nexus_oneapp/shared/widgets/identicon.dart';

import 'profile_image_service.dart';

/// Predefined language options (German labels).
const _kLanguages = [
  'Deutsch',
  'Englisch',
  'Spanisch',
  'Französisch',
  'Arabisch',
  'Russisch',
  'Chinesisch',
  'Portugiesisch',
  'Türkisch',
  'Italiano',
  'Japanisch',
  'Koreanisch',
  'Hindi',
  'Niederländisch',
  'Polnisch',
  'Ukrainisch',
  'Schwedisch',
  'Norwegisch',
  'Dänisch',
  'Finnisch',
];

/// Predefined skill suggestions.
const _kSkills = [
  'Gärtnern',
  'Programmieren',
  'Pflege',
  'Kochen',
  'Unterrichten',
  'Handwerk',
  'Musik',
  'Kunst',
  'Schreiben',
  'Übersetzen',
  'Medizin',
  'Recht',
  'Bauen',
  'Nähen',
  'Fotografie',
  'Design',
  'Buchhaltung',
  'Sport',
  'Kindererziehung',
  'Landwirtschaft',
];

/// Screen for editing the user's extended profile.
///
/// Returns `true` via [Navigator.pop] when changes were saved.
class EditProfileScreen extends StatefulWidget {
  final UserProfile profile;
  final List<int> identiconBytes;

  const EditProfileScreen({
    super.key,
    required this.profile,
    required this.identiconBytes,
  });

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late UserProfile _p;
  late TextEditingController _pseudonymCtrl;
  late TextEditingController _bioCtrl;
  late TextEditingController _realNameCtrl;
  late TextEditingController _locationCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _p = widget.profile;
    _pseudonymCtrl = TextEditingController(text: _p.pseudonym.value);
    _bioCtrl = TextEditingController(text: _p.bio.value ?? '');
    _realNameCtrl = TextEditingController(text: _p.realName.value ?? '');
    _locationCtrl = TextEditingController(text: _p.location.value ?? '');
  }

  @override
  void dispose() {
    _pseudonymCtrl.dispose();
    _bioCtrl.dispose();
    _realNameCtrl.dispose();
    _locationCtrl.dispose();
    super.dispose();
  }

  // ── Image ─────────────────────────────────────────────────────────────────

  Future<void> _changeImage() async {
    final choice = await showModalBottomSheet<_ImageChoice>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined,
                  color: AppColors.gold),
              title: const Text('Kamera',
                  style: TextStyle(color: AppColors.onDark)),
              onTap: () =>
                  Navigator.pop(context, _ImageChoice.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined,
                  color: AppColors.gold),
              title: const Text('Galerie',
                  style: TextStyle(color: AppColors.onDark)),
              onTap: () =>
                  Navigator.pop(context, _ImageChoice.gallery),
            ),
            if (_p.profileImage.value != null)
              ListTile(
                leading: const Icon(Icons.delete_outline,
                    color: Colors.redAccent),
                title: const Text('Bild entfernen',
                    style: TextStyle(color: Colors.redAccent)),
                onTap: () =>
                    Navigator.pop(context, _ImageChoice.remove),
              ),
          ],
        ),
      ),
    );

    if (choice == null || !mounted) return;

    String? newPath;
    if (choice == _ImageChoice.camera) {
      newPath = await ProfileImageService.instance.pickFromCamera();
    } else if (choice == _ImageChoice.gallery) {
      newPath = await ProfileImageService.instance.pickFromGallery();
    } else {
      // Remove image
      await ProfileImageService.instance
          .deleteImage(_p.profileImage.value);
      newPath = null;
    }

    if (!mounted) return;
    if (choice != _ImageChoice.remove && newPath == null) return;

    // Delete old file when replacing
    if (choice != _ImageChoice.remove) {
      await ProfileImageService.instance
          .deleteImage(_p.profileImage.value);
    }

    setState(() {
      _p.profileImage = _p.profileImage.copyWith(value: newPath);
    });
  }

  // ── Save ──────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    setState(() => _saving = true);

    _p.pseudonym =
        _p.pseudonym.copyWith(value: _pseudonymCtrl.text.trim());
    _p.bio = _p.bio.copyWith(
        value: _bioCtrl.text.trim().isEmpty
            ? null
            : _bioCtrl.text.trim());
    _p.realName = _p.realName.copyWith(
        value: _realNameCtrl.text.trim().isEmpty
            ? null
            : _realNameCtrl.text.trim());
    _p.location = _p.location.copyWith(
        value: _locationCtrl.text.trim().isEmpty
            ? null
            : _locationCtrl.text.trim());

    await ProfileService.instance.save(_p);
    // Sync the pseudonym to secure storage so all transports use the correct
    // name after the next app start (IdentityService is the source of truth
    // for the name used in Kind-0 and presence broadcasts).
    await IdentityService.instance.updatePseudonym(_p.pseudonym.value);
    if (mounted) Navigator.of(context).pop(true);
  }

  // ── Visibility picker ─────────────────────────────────────────────────────

  void _pickVisibility(
      VisibilityLevel current, void Function(VisibilityLevel) onPicked) {
    showModalBottomSheet<VisibilityLevel>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Sichtbarkeit',
                  style: TextStyle(
                      color: AppColors.gold,
                      fontWeight: FontWeight.bold,
                      fontSize: 16)),
            ),
            ...VisibilityLevel.values.map((level) => ListTile(
                  leading: Icon(_visibilityIcon(level),
                      color: current == level
                          ? AppColors.gold
                          : AppColors.onDark.withValues(alpha: 0.5)),
                  title: Text(level.label,
                      style: TextStyle(
                          color: current == level
                              ? AppColors.gold
                              : AppColors.onDark)),
                  trailing: current == level
                      ? const Icon(Icons.check, color: AppColors.gold)
                      : null,
                  onTap: () {
                    Navigator.pop(context);
                    onPicked(level);
                  },
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _lockIcon<T>(ProfileField<T> field,
      void Function(VisibilityLevel) onChanged) {
    return GestureDetector(
      onTap: () => _pickVisibility(field.visibility, onChanged),
      child: Icon(
        _visibilityIcon(field.visibility),
        color: AppColors.gold.withValues(alpha: 0.8),
        size: 20,
      ),
    );
  }

  static IconData _visibilityIcon(VisibilityLevel l) {
    switch (l) {
      case VisibilityLevel.public:
        return Icons.public;
      case VisibilityLevel.contacts:
        return Icons.people_outline;
      case VisibilityLevel.trusted:
        return Icons.star_outline;
      case VisibilityLevel.private:
        return Icons.lock_outline;
    }
  }

  // ── Birth date ────────────────────────────────────────────────────────────

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final initial = _p.birthDate.value ?? DateTime(now.year - 25, 1, 1);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1900),
      lastDate: now,
      helpText: 'Geburtsdatum wählen',
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: AppColors.gold,
            onPrimary: AppColors.deepBlue,
            surface: AppColors.surface,
            onSurface: AppColors.onDark,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        _p.birthDate = _p.birthDate.copyWith(value: picked);
      });
    }
  }

  // ── Chip editors ──────────────────────────────────────────────────────────

  Future<void> _editChips({
    required String title,
    required List<String> selected,
    required List<String> suggestions,
    required void Function(List<String>) onSaved,
  }) async {
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _ChipEditorSheet(
        title: title,
        selected: List<String>.from(selected),
        suggestions: suggestions,
      ),
    );
    if (result != null) {
      setState(() => onSaved(result));
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final imagePath = _p.profileImage.value;

    return Scaffold(
      backgroundColor: AppColors.deepBlue,
      appBar: AppBar(
        title: const Text('Profil bearbeiten'),
        backgroundColor: AppColors.deepBlue,
        foregroundColor: AppColors.gold,
        centerTitle: true,
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.gold)),
            )
          else
            IconButton(
              icon: const Icon(Icons.check),
              tooltip: 'Speichern',
              onPressed: _save,
            ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Profile image ────────────────────────────────────────
              Center(
                child: GestureDetector(
                  onTap: _changeImage,
                  child: Stack(
                    children: [
                      Container(
                        width: 110,
                        height: 110,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: AppColors.gold, width: 2.5),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: imagePath != null &&
                                File(imagePath).existsSync()
                            ? Image.file(File(imagePath),
                                fit: BoxFit.cover)
                            : Identicon(
                                bytes: widget.identiconBytes,
                                size: 110,
                              ),
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.gold,
                          ),
                          child: const Icon(Icons.camera_alt,
                              color: AppColors.deepBlue, size: 16),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 32),

              // ── Pseudonym ────────────────────────────────────────────
              _sectionLabel('Pseudonym'),
              _fieldRow(
                child: TextField(
                  controller: _pseudonymCtrl,
                  style: const TextStyle(color: AppColors.onDark),
                  decoration: _inputDecoration('Pseudonym'),
                ),
                field: _p.pseudonym,
                onVisibilityChanged: (v) => setState(
                    () => _p.pseudonym = _p.pseudonym.copyWith(visibility: v)),
              ),
              const SizedBox(height: 16),

              // ── Bio ──────────────────────────────────────────────────
              _sectionLabel('Bio'),
              _fieldRow(
                child: TextField(
                  controller: _bioCtrl,
                  style: const TextStyle(color: AppColors.onDark),
                  maxLength: 200,
                  maxLines: 3,
                  decoration: _inputDecoration('Kurze Beschreibung…'),
                ),
                field: _p.bio,
                onVisibilityChanged: (v) =>
                    setState(() => _p.bio = _p.bio.copyWith(visibility: v)),
              ),
              const SizedBox(height: 16),

              // ── Real name ────────────────────────────────────────────
              _sectionLabel('Klarname'),
              _hint('Nur sichtbar für deine Kontakte'),
              _fieldRow(
                child: TextField(
                  controller: _realNameCtrl,
                  style: const TextStyle(color: AppColors.onDark),
                  decoration: _inputDecoration('Vorname Nachname'),
                ),
                field: _p.realName,
                onVisibilityChanged: (v) => setState(
                    () => _p.realName = _p.realName.copyWith(visibility: v)),
              ),
              const SizedBox(height: 16),

              // ── Location ─────────────────────────────────────────────
              _sectionLabel('Standort'),
              _hint('Nur sichtbar für Kontakte'),
              _fieldRow(
                child: TextField(
                  controller: _locationCtrl,
                  style: const TextStyle(color: AppColors.onDark),
                  decoration: _inputDecoration('z.B. Berlin-Kreuzberg'),
                ),
                field: _p.location,
                onVisibilityChanged: (v) => setState(
                    () => _p.location = _p.location.copyWith(visibility: v)),
              ),
              const SizedBox(height: 16),

              // ── Birth date ───────────────────────────────────────────
              _sectionLabel('Geburtsdatum'),
              _hint('Wird niemals geteilt. Dient nur zur Altersverifikation.'),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: _pickBirthDate,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceVariant,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.cake_outlined,
                                color: AppColors.gold, size: 18),
                            const SizedBox(width: 12),
                            Text(
                              _p.birthDate.value != null
                                  ? _formatDate(
                                      _p.birthDate.value!)
                                  : 'Datum auswählen',
                              style: TextStyle(
                                color: _p.birthDate.value != null
                                    ? AppColors.onDark
                                    : AppColors.onDark
                                        .withValues(alpha: 0.5),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Birthdate is always private – show lock icon, no picker
                  const Icon(Icons.lock_outline,
                      color: AppColors.gold, size: 20),
                ],
              ),
              const SizedBox(height: 16),

              // ── Languages ────────────────────────────────────────────
              _sectionLabel('Sprachen'),
              _chipFieldRow(
                chips: _p.languages.value,
                onTap: () => _editChips(
                  title: 'Sprachen',
                  selected: _p.languages.value,
                  suggestions: _kLanguages,
                  onSaved: (v) =>
                      _p.languages = _p.languages.copyWith(value: v),
                ),
                field: _p.languages,
                onVisibilityChanged: (v) => setState(() =>
                    _p.languages = _p.languages.copyWith(visibility: v)),
              ),
              const SizedBox(height: 16),

              // ── Skills ───────────────────────────────────────────────
              _sectionLabel('Fähigkeiten'),
              _chipFieldRow(
                chips: _p.skills.value,
                onTap: () => _editChips(
                  title: 'Fähigkeiten',
                  selected: _p.skills.value,
                  suggestions: _kSkills,
                  onSaved: (v) =>
                      _p.skills = _p.skills.copyWith(value: v),
                ),
                field: _p.skills,
                onVisibilityChanged: (v) => setState(
                    () => _p.skills = _p.skills.copyWith(visibility: v)),
              ),
              const SizedBox(height: 40),

              // ── Save button ──────────────────────────────────────────
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.gold,
                    foregroundColor: AppColors.deepBlue,
                    padding:
                        const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Speichern',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  // ── Helper widgets ────────────────────────────────────────────────────────

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: const TextStyle(
            color: AppColors.gold,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
      );

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: TextStyle(
            color: AppColors.onDark.withValues(alpha: 0.5),
            fontSize: 11,
          ),
        ),
      );

  Widget _fieldRow<T>({
    required Widget child,
    required ProfileField<T> field,
    required void Function(VisibilityLevel) onVisibilityChanged,
  }) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: child),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: _lockIcon(field, onVisibilityChanged),
          ),
        ],
      );

  Widget _chipFieldRow<T>({
    required List<String> chips,
    required VoidCallback onTap,
    required ProfileField<T> field,
    required void Function(VisibilityLevel) onVisibilityChanged,
  }) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: GestureDetector(
              onTap: onTap,
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: chips.isEmpty
                    ? Text(
                        'Antippen zum Hinzufügen…',
                        style: TextStyle(
                            color:
                                AppColors.onDark.withValues(alpha: 0.4)),
                      )
                    : Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: chips
                            .map((c) => Chip(
                                  label: Text(c,
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: AppColors.deepBlue)),
                                  backgroundColor: AppColors.gold,
                                  padding: EdgeInsets.zero,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ))
                            .toList(),
                      ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _lockIcon(field, onVisibilityChanged),
          ),
        ],
      );

  static InputDecoration _inputDecoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
            color: AppColors.onDark.withValues(alpha: 0.4), fontSize: 14),
        filled: true,
        fillColor: AppColors.surfaceVariant,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        counterStyle:
            TextStyle(color: AppColors.onDark.withValues(alpha: 0.5)),
      );

  static String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
}

enum _ImageChoice { camera, gallery, remove }

// ── Chip editor bottom sheet ───────────────────────────────────────────────

class _ChipEditorSheet extends StatefulWidget {
  final String title;
  final List<String> selected;
  final List<String> suggestions;

  const _ChipEditorSheet({
    required this.title,
    required this.selected,
    required this.suggestions,
  });

  @override
  State<_ChipEditorSheet> createState() => _ChipEditorSheetState();
}

class _ChipEditorSheetState extends State<_ChipEditorSheet> {
  late List<String> _selected;
  final _customCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _selected = List<String>.from(widget.selected);
  }

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  void _toggle(String item) {
    setState(() {
      if (_selected.contains(item)) {
        _selected.remove(item);
      } else {
        _selected.add(item);
      }
    });
  }

  void _addCustom() {
    final text = _customCtrl.text.trim();
    if (text.isEmpty || _selected.contains(text)) return;
    setState(() {
      _selected.add(text);
      _customCtrl.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final all = {...widget.suggestions, ..._selected}.toList()..sort();

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      minChildSize: 0.4,
      expand: false,
      builder: (_, scrollCtrl) => Column(
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.onDark.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(widget.title,
                    style: const TextStyle(
                        color: AppColors.gold,
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context, _selected),
                  child: const Text('Fertig',
                      style: TextStyle(color: AppColors.gold)),
                ),
              ],
            ),
          ),
          // Custom input
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _customCtrl,
                    style: const TextStyle(color: AppColors.onDark),
                    decoration: InputDecoration(
                      hintText: 'Eigene Eingabe…',
                      hintStyle: TextStyle(
                          color: AppColors.onDark.withValues(alpha: 0.4)),
                      filled: true,
                      fillColor: AppColors.surfaceVariant,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (_) => _addCustom(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.add, color: AppColors.gold),
                  onPressed: _addCustom,
                ),
              ],
            ),
          ),
          // Chip list
          Expanded(
            child: SingleChildScrollView(
              controller: scrollCtrl,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: all
                    .map((item) => FilterChip(
                          label: Text(item),
                          selected: _selected.contains(item),
                          onSelected: (_) => _toggle(item),
                          selectedColor: AppColors.gold,
                          checkmarkColor: AppColors.deepBlue,
                          labelStyle: TextStyle(
                            color: _selected.contains(item)
                                ? AppColors.deepBlue
                                : AppColors.onDark,
                          ),
                          backgroundColor: AppColors.surfaceVariant,
                          side: BorderSide.none,
                        ))
                    .toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
