import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../core/utils/geohash.dart';
import '../../shared/theme/app_theme.dart';
import '../chat/chat_provider.dart';
import 'cell.dart';
import 'cell_service.dart';

/// Edit screen for the cell founder to modify cell settings.
///
/// The cell type (local ↔ thematic) cannot be changed after creation.
class CellEditScreen extends StatefulWidget {
  final Cell cell;
  const CellEditScreen({super.key, required this.cell});

  @override
  State<CellEditScreen> createState() => _CellEditScreenState();
}

class _CellEditScreenState extends State<CellEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _locationCtrl;
  late final TextEditingController _topicCtrl;

  late String _category;
  late JoinPolicy _joinPolicy;
  late MinTrustLevel _minTrust;
  late int _proposalWaitDays;
  late int _maxMembers;

  String? _geohash;
  bool _fetchingLocation = false;
  String? _locationStatus;

  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final c = widget.cell;
    _nameCtrl = TextEditingController(text: c.name);
    _descCtrl = TextEditingController(text: c.description);
    _locationCtrl = TextEditingController(text: c.locationName ?? '');
    _topicCtrl = TextEditingController(text: c.topic ?? '');
    _category = c.category ?? cellCategories.first;
    _joinPolicy = c.joinPolicy;
    _minTrust = c.minTrustLevel;
    _proposalWaitDays = c.proposalWaitDays;
    _maxMembers = c.maxMembers;
    _geohash = c.geohash;
    if (_geohash != null) {
      _locationStatus = 'Aktueller GPS-Standort gespeichert ✓';
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _locationCtrl.dispose();
    _topicCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchGeohash() async {
    setState(() {
      _fetchingLocation = true;
      _locationStatus = null;
    });
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() {
          _fetchingLocation = false;
          _locationStatus = 'GPS nicht verfügbar.';
        });
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        setState(() {
          _fetchingLocation = false;
          _locationStatus = 'Standort-Berechtigung verweigert.';
        });
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 10),
      );
      setState(() {
        _geohash = encodeGeohash(pos.latitude, pos.longitude);
        _fetchingLocation = false;
        _locationStatus = 'Neuer GPS-Standort gespeichert ✓';
      });
    } catch (_) {
      setState(() {
        _fetchingLocation = false;
        _locationStatus = 'Standort konnte nicht ermittelt werden.';
      });
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _isSaving = true);
    try {
      final updated = widget.cell.copyWith(
        name: _nameCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        locationName: widget.cell.cellType == CellType.local
            ? (_locationCtrl.text.trim().isEmpty
                ? null
                : _locationCtrl.text.trim())
            : null,
        geohash: widget.cell.cellType == CellType.local ? _geohash : null,
        topic: widget.cell.cellType == CellType.thematic
            ? (_topicCtrl.text.trim().isEmpty ? null : _topicCtrl.text.trim())
            : null,
        category: widget.cell.cellType == CellType.thematic ? _category : null,
        joinPolicy: _joinPolicy,
        minTrustLevel: _minTrust,
        proposalWaitDays: _proposalWaitDays,
        maxMembers: _maxMembers,
      );

      await CellService.instance.updateCell(updated);

      if (mounted) {
        context.read<ChatProvider>().publishNostrCellAnnouncement(updated);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Zelle aktualisiert ✓'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Fehler: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Zelle bearbeiten'),
        backgroundColor: AppColors.deepBlue,
      ),
      backgroundColor: AppColors.deepBlue,
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            // Name
            _Label('Zellenname *'),
            TextFormField(
              controller: _nameCtrl,
              decoration: _deco('z. B. Hamburg Altona'),
              style: const TextStyle(color: AppColors.onDark),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Name ist Pflichtfeld.';
                if (v.trim().length < 3) return 'Mindestens 3 Zeichen.';
                return null;
              },
            ),
            const SizedBox(height: 16),

            // Description
            _Label('Beschreibung (optional)'),
            TextFormField(
              controller: _descCtrl,
              decoration: _deco('Worum geht es in dieser Zelle?'),
              style: const TextStyle(color: AppColors.onDark),
              maxLines: 3,
              maxLength: 500,
            ),
            const SizedBox(height: 16),

            // Type-specific fields
            if (widget.cell.cellType == CellType.local) ...[
              _Label('Anzeige-Name des Standorts (optional)'),
              TextFormField(
                controller: _locationCtrl,
                decoration: _deco('z. B. Teneriffa Nord'),
                style: const TextStyle(color: AppColors.onDark),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: _fetchingLocation ? null : _fetchGeohash,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.surface,
                      foregroundColor: AppColors.gold,
                      side: const BorderSide(color: AppColors.gold),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: _fetchingLocation
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: AppColors.gold),
                          )
                        : Icon(
                            _geohash != null
                                ? Icons.location_on
                                : Icons.my_location,
                            size: 16),
                    label: Text(_fetchingLocation
                        ? 'Ermittle …'
                        : _geohash != null
                            ? 'GPS aktualisieren'
                            : 'GPS-Standort ermitteln'),
                  ),
                ],
              ),
              if (_locationStatus != null) ...[
                const SizedBox(height: 6),
                Text(
                  _locationStatus!,
                  style: TextStyle(
                    color: _locationStatus!.contains('✓')
                        ? Colors.green
                        : AppColors.onDark.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
              ],
              const SizedBox(height: 16),
            ],

            if (widget.cell.cellType == CellType.thematic) ...[
              _Label('Thema (optional)'),
              TextFormField(
                controller: _topicCtrl,
                decoration: _deco('z. B. Softwareentwicklung'),
                style: const TextStyle(color: AppColors.onDark),
              ),
              const SizedBox(height: 16),
              _Label('Kategorie'),
              DropdownButtonFormField<String>(
                value: _category,
                dropdownColor: AppColors.surface,
                style: const TextStyle(color: AppColors.onDark),
                decoration: _deco(''),
                items: cellCategories
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (v) => setState(() => _category = v!),
              ),
              const SizedBox(height: 16),
            ],

            // Join policy
            _Label('Beitrittspolitik'),
            _Radio<JoinPolicy>(
              label: 'Beitritt anfragen (Standard)',
              subtitle: 'Interessierte können eine Anfrage schicken',
              value: JoinPolicy.approvalRequired,
              groupValue: _joinPolicy,
              onChanged: (v) => setState(() => _joinPolicy = v!),
            ),
            _Radio<JoinPolicy>(
              label: 'Nur auf Einladung',
              subtitle: 'Mitglieder laden neue Personen direkt ein',
              value: JoinPolicy.inviteOnly,
              groupValue: _joinPolicy,
              onChanged: (v) => setState(() => _joinPolicy = v!),
            ),
            const SizedBox(height: 16),

            // Min trust level
            _Label('Mindest-Vertrauensstufe'),
            _Radio<MinTrustLevel>(
              label: 'Keine Einschränkung',
              value: MinTrustLevel.none,
              groupValue: _minTrust,
              onChanged: (v) => setState(() => _minTrust = v!),
            ),
            _Radio<MinTrustLevel>(
              label: 'Kontakt eines Mitglieds',
              value: MinTrustLevel.contact,
              groupValue: _minTrust,
              onChanged: (v) => setState(() => _minTrust = v!),
            ),
            _Radio<MinTrustLevel>(
              label: 'Vertrauensperson eines Mitglieds',
              value: MinTrustLevel.trusted,
              groupValue: _minTrust,
              onChanged: (v) => setState(() => _minTrust = v!),
            ),
            const SizedBox(height: 16),

            // Proposal wait days
            _Label('Wartezeit vor Anträgen'),
            _Radio<int>(
              label: 'Sofort',
              value: 0,
              groupValue: _proposalWaitDays,
              onChanged: (v) => setState(() => _proposalWaitDays = v!),
            ),
            _Radio<int>(
              label: '7 Tage nach Beitritt',
              value: 7,
              groupValue: _proposalWaitDays,
              onChanged: (v) => setState(() => _proposalWaitDays = v!),
            ),
            _Radio<int>(
              label: '30 Tage nach Beitritt',
              value: 30,
              groupValue: _proposalWaitDays,
              onChanged: (v) => setState(() => _proposalWaitDays = v!),
            ),
            const SizedBox(height: 16),

            // Max members
            _Label('Max. Mitglieder: $_maxMembers'),
            Slider(
              value: _maxMembers.toDouble(),
              min: 5,
              max: 150,
              divisions: 29,
              activeColor: AppColors.gold,
              label: _maxMembers.toString(),
              onChanged: (v) => setState(() => _maxMembers = v.round()),
            ),
            const SizedBox(height: 32),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isSaving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.gold,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: _isSaving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Änderungen speichern',
                        style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  InputDecoration _deco(String hint) => InputDecoration(
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
        counterStyle:
            TextStyle(color: AppColors.onDark.withValues(alpha: 0.4)),
      );
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

class _Radio<T> extends StatelessWidget {
  final String label;
  final String? subtitle;
  final T value;
  final T groupValue;
  final ValueChanged<T?> onChanged;

  const _Radio({
    required this.label,
    this.subtitle,
    required this.value,
    required this.groupValue,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => RadioListTile<T>(
        title: Text(label,
            style: const TextStyle(color: AppColors.onDark, fontSize: 14)),
        subtitle: subtitle != null
            ? Text(subtitle!,
                style: TextStyle(
                    color: AppColors.onDark.withValues(alpha: 0.5),
                    fontSize: 12))
            : null,
        value: value,
        groupValue: groupValue,
        activeColor: AppColors.gold,
        onChanged: onChanged,
        contentPadding: EdgeInsets.zero,
        dense: true,
      );
}
