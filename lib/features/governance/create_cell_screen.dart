import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../core/identity/identity_service.dart';
import '../../core/roles/permission_helper.dart';
import '../../core/utils/geohash.dart';
import '../../shared/theme/app_theme.dart';
import '../chat/chat_provider.dart';
import 'cell.dart';
import 'cell_service.dart';

/// Form to found a new cell.
class CreateCellScreen extends StatefulWidget {
  const CreateCellScreen({super.key});

  @override
  State<CreateCellScreen> createState() => _CreateCellScreenState();
}

class _CreateCellScreenState extends State<CreateCellScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();
  final _topicCtrl = TextEditingController();

  CellType _cellType = CellType.thematic;
  String _category = cellCategories.first;
  JoinPolicy _joinPolicy = JoinPolicy.approvalRequired;
  MinTrustLevel _minTrust = MinTrustLevel.none;
  int _proposalWaitDays = 0;
  int _maxMembers = 150;
  bool _isCreating = false;

  String? _geohash;
  bool _fetchingLocation = false;
  String? _locationStatus;

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
      _geohash = null;
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() {
          _fetchingLocation = false;
          _locationStatus = 'GPS nicht verfügbar. Aktiviere den Standort in den Systemeinstellungen.';
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
          _locationStatus =
              'Ohne Standort wird deine Zelle nicht in der Nähe-Suche angezeigt.';
        });
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 10),
      );

      final hash = encodeGeohash(pos.latitude, pos.longitude);
      setState(() {
        _geohash = hash;
        _fetchingLocation = false;
        _locationStatus = 'Standort gespeichert ✓';
      });
    } catch (_) {
      setState(() {
        _fetchingLocation = false;
        _locationStatus =
            'Ohne Standort wird deine Zelle nicht in der Nähe-Suche angezeigt.';
      });
    }
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final myDid = IdentityService.instance.currentIdentity!.did;
    if (!PermissionHelper.canCreateCell(myDid)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nur System-Admins können Zellen gründen.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isCreating = true);

    try {
      final cell = Cell.create(
        name: _nameCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        createdBy: myDid,
        cellType: _cellType,
        locationName: _cellType == CellType.local
            ? _locationCtrl.text.trim().isEmpty
                ? null
                : _locationCtrl.text.trim()
            : null,
        geohash: _cellType == CellType.local ? _geohash : null,
        topic: _cellType == CellType.thematic
            ? _topicCtrl.text.trim().isEmpty
                ? null
                : _topicCtrl.text.trim()
            : null,
        category: _cellType == CellType.thematic ? _category : null,
        maxMembers: _maxMembers,
        joinPolicy: _joinPolicy,
        minTrustLevel: _minTrust,
        proposalWaitDays: _proposalWaitDays,
      );

      await CellService.instance.createCell(cell);

      // Publish Nostr announcement so other nodes can discover this cell.
      if (mounted) {
        context.read<ChatProvider>().publishNostrCellAnnouncement(cell);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Zelle "${cell.name}" gegründet!'),
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
      if (mounted) setState(() => _isCreating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Zelle gründen'),
        backgroundColor: AppColors.deepBlue,
      ),
      backgroundColor: AppColors.deepBlue,
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            // Name
            _SectionLabel('Zellenname *'),
            TextFormField(
              controller: _nameCtrl,
              decoration: _inputDecoration('z. B. Hamburg Altona'),
              style: const TextStyle(color: AppColors.onDark),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Name ist Pflichtfeld.';
                if (v.trim().length < 3) return 'Mindestens 3 Zeichen.';
                return null;
              },
            ),
            const SizedBox(height: 16),

            // Description
            _SectionLabel('Beschreibung (optional)'),
            TextFormField(
              controller: _descCtrl,
              decoration: _inputDecoration('Worum geht es in dieser Zelle?'),
              style: const TextStyle(color: AppColors.onDark),
              maxLines: 3,
              maxLength: 500,
            ),
            const SizedBox(height: 16),

            // Cell type
            _SectionLabel('Zellen-Typ *'),
            Row(
              children: [
                Expanded(
                  child: _TypeChip(
                    label: 'Lokale Gemeinschaft',
                    icon: Icons.location_on,
                    selected: _cellType == CellType.local,
                    onTap: () {
                      setState(() => _cellType = CellType.local);
                      if (_geohash == null && !_fetchingLocation) {
                        _fetchGeohash();
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _TypeChip(
                    label: 'Thematische Gemeinschaft',
                    icon: Icons.group_work,
                    selected: _cellType == CellType.thematic,
                    onTap: () => setState(() => _cellType = CellType.thematic),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Type-specific fields
            if (_cellType == CellType.local) ...[
              _SectionLabel('Anzeige-Name des Standorts (optional)'),
              TextFormField(
                controller: _locationCtrl,
                decoration: _inputDecoration('z. B. Teneriffa Nord'),
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
                                strokeWidth: 2,
                                color: AppColors.gold),
                          )
                        : Icon(
                            _geohash != null
                                ? Icons.location_on
                                : Icons.my_location,
                            size: 16,
                          ),
                    label: Text(_fetchingLocation
                        ? 'Ermittle ...'
                        : _geohash != null
                            ? 'GPS gespeichert'
                            : 'GPS-Standort ermitteln'),
                  ),
                ],
              ),
              if (_locationStatus != null) ...[
                const SizedBox(height: 6),
                Text(
                  _locationStatus!,
                  style: TextStyle(
                    color: _geohash != null
                        ? Colors.green
                        : AppColors.onDark.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
              ],
              const SizedBox(height: 16),
            ],

            if (_cellType == CellType.thematic) ...[
              _SectionLabel('Thema (optional)'),
              TextFormField(
                controller: _topicCtrl,
                decoration: _inputDecoration('z. B. Softwareentwicklung'),
                style: const TextStyle(color: AppColors.onDark),
              ),
              const SizedBox(height: 16),
              _SectionLabel('Kategorie'),
              DropdownButtonFormField<String>(
                value: _category,
                dropdownColor: AppColors.surface,
                style: const TextStyle(color: AppColors.onDark),
                decoration: _inputDecoration(''),
                items: cellCategories
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (v) => setState(() => _category = v!),
              ),
              const SizedBox(height: 16),
            ],

            // Join policy
            _SectionLabel('Beitrittspolitik'),
            _RadioOption<JoinPolicy>(
              label: 'Beitritt anfragen (Standard)',
              subtitle: 'Interessierte können eine Anfrage schicken',
              value: JoinPolicy.approvalRequired,
              groupValue: _joinPolicy,
              onChanged: (v) => setState(() => _joinPolicy = v!),
            ),
            _RadioOption<JoinPolicy>(
              label: 'Nur auf Einladung',
              subtitle: 'Mitglieder laden neue Personen direkt ein',
              value: JoinPolicy.inviteOnly,
              groupValue: _joinPolicy,
              onChanged: (v) => setState(() => _joinPolicy = v!),
            ),
            const SizedBox(height: 16),

            // Min trust level
            _SectionLabel('Mindest-Vertrauensstufe'),
            _RadioOption<MinTrustLevel>(
              label: 'Keine Einschränkung (Standard)',
              value: MinTrustLevel.none,
              groupValue: _minTrust,
              onChanged: (v) => setState(() => _minTrust = v!),
            ),
            _RadioOption<MinTrustLevel>(
              label: 'Kontakt eines Mitglieds',
              value: MinTrustLevel.contact,
              groupValue: _minTrust,
              onChanged: (v) => setState(() => _minTrust = v!),
            ),
            _RadioOption<MinTrustLevel>(
              label: 'Vertrauensperson eines Mitglieds',
              value: MinTrustLevel.trusted,
              groupValue: _minTrust,
              onChanged: (v) => setState(() => _minTrust = v!),
            ),
            const SizedBox(height: 16),

            // Proposal wait days
            _SectionLabel('Wartezeit vor Anträgen'),
            _RadioOption<int>(
              label: 'Sofort (Standard)',
              value: 0,
              groupValue: _proposalWaitDays,
              onChanged: (v) => setState(() => _proposalWaitDays = v!),
            ),
            _RadioOption<int>(
              label: '7 Tage nach Beitritt',
              value: 7,
              groupValue: _proposalWaitDays,
              onChanged: (v) => setState(() => _proposalWaitDays = v!),
            ),
            _RadioOption<int>(
              label: '30 Tage nach Beitritt',
              value: 30,
              groupValue: _proposalWaitDays,
              onChanged: (v) => setState(() => _proposalWaitDays = v!),
            ),
            const SizedBox(height: 16),

            // Max members
            _SectionLabel('Max. Mitglieder: $_maxMembers'),
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

            // Submit
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isCreating ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.gold,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isCreating
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text(
                        'Zelle gründen',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) => InputDecoration(
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

// ── Small widgets ─────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

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

class _TypeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _TypeChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.gold.withValues(alpha: 0.15)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.gold : AppColors.surfaceVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                color: selected ? AppColors.gold : AppColors.onDark,
                size: 24),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: selected ? AppColors.gold : AppColors.onDark,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RadioOption<T> extends StatelessWidget {
  final String label;
  final String? subtitle;
  final T value;
  final T groupValue;
  final ValueChanged<T?> onChanged;

  const _RadioOption({
    required this.label,
    this.subtitle,
    required this.value,
    required this.groupValue,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return RadioListTile<T>(
      title: Text(
        label,
        style: const TextStyle(color: AppColors.onDark, fontSize: 14),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle!,
              style: TextStyle(
                color: AppColors.onDark.withValues(alpha: 0.5),
                fontSize: 12,
              ),
            )
          : null,
      value: value,
      groupValue: groupValue,
      activeColor: AppColors.gold,
      onChanged: onChanged,
      contentPadding: EdgeInsets.zero,
      dense: true,
    );
  }
}
