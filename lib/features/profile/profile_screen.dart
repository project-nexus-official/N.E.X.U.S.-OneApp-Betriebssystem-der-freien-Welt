import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexus_oneapp/core/contacts/contact_service.dart';
import 'package:nexus_oneapp/core/crypto/encryption_keys.dart';
import 'package:nexus_oneapp/core/identity/identity_service.dart';
import 'package:nexus_oneapp/core/identity/profile.dart';
import 'package:nexus_oneapp/core/identity/profile_service.dart';
import 'package:nexus_oneapp/core/storage/pod_database.dart';
import 'package:nexus_oneapp/shared/theme/app_theme.dart';
import 'package:nexus_oneapp/shared/widgets/identicon.dart';

import '../chat/chat_provider.dart';
import '../contacts/contacts_screen.dart';
import '../contacts/qr_contact_payload.dart';
import 'edit_profile_screen.dart';

/// Profile tab – shows the user's identity and extended profile data.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

const _kLastExportKey = 'nexus_last_export_date';

class _ProfileScreenState extends State<ProfileScreen> {
  final _identityService = IdentityService.instance;

  UserProfile? get _profile => ProfileService.instance.currentProfile;

  bool _hasEverExported = true; // start as true to avoid flash; loaded in initState

  @override
  void initState() {
    super.initState();
    _loadExportStatus();
  }

  Future<void> _loadExportStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final lastExport = prefs.getString(_kLastExportKey);
    if (mounted) setState(() => _hasEverExported = lastExport != null);
  }

  Future<void> _markExported() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kLastExportKey, DateTime.now().toIso8601String());
    if (mounted) setState(() => _hasEverExported = true);
  }

  // ── QR data builder ───────────────────────────────────────────────────────

  /// Builds the JSON payload for the own QR code.
  String _buildQrData(BuildContext context, dynamic identity, UserProfile? profile) {
    final pseudonym = profile?.pseudonym.value ?? identity.pseudonym as String;
    final x25519Key = EncryptionKeys.instance.publicKeyHex;
    final nostrKey = context.read<ChatProvider>().nostrTransport?.keys?.publicKeyHex;
    final payload = QrContactPayload(
      did: identity.did as String,
      pseudonym: pseudonym,
      publicKey: x25519Key,
      nostrPubkey: nostrKey,
    );
    return payload.toJsonString();
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  void _copyPublicKey() {
    final identity = _identityService.currentIdentity;
    if (identity == null) return;
    Clipboard.setData(ClipboardData(text: identity.publicKeyHex));
    _snack('Öffentlicher Schlüssel kopiert');
  }

  void _copyDid() {
    final identity = _identityService.currentIdentity;
    if (identity == null) return;
    Clipboard.setData(ClipboardData(text: identity.did));
    _snack('DID kopiert');
  }

  Future<void> _showSeedPhrase() async {
    final seedPhrase = await _identityService.loadSeedPhrase();
    if (!mounted) return;
    if (seedPhrase == null) {
      _snack('Keine Seed Phrase gefunden.');
      return;
    }
    final words = seedPhrase.split(' ');
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Seed Phrase',
            style: TextStyle(
                color: AppColors.gold, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF3D2000),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: Colors.orange.withValues(alpha: 0.5)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      color: Colors.orange, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Teile diese Wörter niemals mit anderen!',
                      style: TextStyle(
                          color: Colors.orange,
                          fontSize: 12,
                          height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                childAspectRatio: 2.4,
              ),
              itemCount: words.length,
              itemBuilder: (context, index) => Container(
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(6),
                ),
                padding: const EdgeInsets.symmetric(
                    horizontal: 4, vertical: 4),
                child: Row(
                  children: [
                    Text('${index + 1}.',
                        style: const TextStyle(
                            color: AppColors.gold,
                            fontSize: 10,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(width: 3),
                    Expanded(
                      child: Text(words[index],
                          style: const TextStyle(
                              color: AppColors.onDark, fontSize: 11),
                          overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Schließen',
                style: TextStyle(color: AppColors.gold)),
          ),
        ],
      ),
    );
  }

  Future<void> _exportData() async {
    try {
      final blob = await PodDatabase.instance.exportEncrypted();
      await Clipboard.setData(ClipboardData(text: blob));
      _snack('Export in Zwischenablage kopiert');
      await _markExported();
    } catch (e) {
      _snack('Export fehlgeschlagen: $e');
    }
  }

  void _openContacts() {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => const ContactsScreen()),
    );
  }

  Future<void> _openEditProfile() async {
    final identity = _identityService.currentIdentity;
    if (identity == null) return;
    // Profile may still be null if the POD opened after the screen was built.
    final profile = _profile ?? UserProfile.defaults(identity.pseudonym);
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EditProfileScreen(
          profile: profile,
          identiconBytes: _hexToBytes(identity.publicKeyHex),
        ),
      ),
    );
    if (saved == true && mounted) setState(() {});
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static List<int> _hexToBytes(String hex) {
    final result = <int>[];
    for (int i = 0; i + 1 < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return result;
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

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final identity = _identityService.currentIdentity;
    final profile = _profile;

    return Scaffold(
      backgroundColor: AppColors.deepBlue,
      appBar: AppBar(
        title: const Text('Profil'),
        backgroundColor: AppColors.deepBlue,
        foregroundColor: AppColors.gold,
        centerTitle: true,
        automaticallyImplyLeading: false,
        actions: [
          if (identity != null)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Profil bearbeiten',
              onPressed: _openEditProfile,
            ),
        ],
      ),
      body: SafeArea(
        child: identity == null
            ? const Center(
                child: Text('Keine Identität gefunden.',
                    style: TextStyle(color: AppColors.onDark)))
            : _buildBody(identity, profile),
      ),
    );
  }

  Widget _buildBody(dynamic identity, UserProfile? profile) {
    final identiconBytes = _hexToBytes(identity.publicKeyHex);
    final imagePath = profile?.profileImage.value;
    final hasImage =
        imagePath != null && File(imagePath).existsSync();

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ── Avatar ─────────────────────────────────────────────────
          GestureDetector(
            onTap: _openEditProfile,
            child: Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.gold, width: 2.5),
              ),
              clipBehavior: Clip.antiAlias,
              child: hasImage
                  ? Image.file(File(imagePath), fit: BoxFit.cover)
                  : Identicon(bytes: identiconBytes, size: 100),
            ),
          ),
          const SizedBox(height: 16),

          // ── Pseudonym ───────────────────────────────────────────────
          Text(
            profile?.pseudonym.value ?? identity.pseudonym,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.onDark,
              fontSize: 26,
              fontWeight: FontWeight.bold,
            ),
          ),

          // ── Bio ─────────────────────────────────────────────────────
          if (profile?.bio.value != null) ...[
            const SizedBox(height: 8),
            Text(
              profile!.bio.value!,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.onDark.withValues(alpha: 0.7),
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 24),

          // ── DID card ────────────────────────────────────────────────
          _infoCard(
            label: 'Dezentrale ID (DID)',
            child: GestureDetector(
              onTap: _copyDid,
              child: Row(
                children: [
                  Expanded(
                    child: Text(identity.shortDid,
                        style: const TextStyle(
                            color: AppColors.onDark,
                            fontSize: 14,
                            fontFamily: 'monospace',
                            letterSpacing: 0.8)),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.copy_outlined,
                      color: AppColors.gold, size: 18),
                ],
              ),
            ),
            hint: 'Tippe zum Kopieren',
          ),
          const SizedBox(height: 16),

          // ── QR code ─────────────────────────────────────────────────
          _infoCard(
            label: 'QR-Code zum Hinzufügen',
            child: Column(
              children: [
                Center(
                  child: QrImageView(
                    data: _buildQrData(context, identity, profile),
                    version: QrVersions.auto,
                    size: 180,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(
                        eyeShape: QrEyeShape.square,
                        color: Color(0xFF000000)),
                    dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: Color(0xFF000000)),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => context.push('/qr-scanner'),
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Kontakt scannen'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.gold,
                      side: const BorderSide(color: AppColors.gold),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ── Public key ──────────────────────────────────────────────
          _infoCard(
            label: 'Öffentlicher Schlüssel',
            child: GestureDetector(
              onTap: _copyPublicKey,
              child: Row(
                children: [
                  Expanded(
                    child: Text(identity.shortPublicKey,
                        style: const TextStyle(
                            color: AppColors.onDark,
                            fontSize: 16,
                            fontFamily: 'monospace',
                            letterSpacing: 1.2)),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.copy_outlined,
                      color: AppColors.gold, size: 18),
                ],
              ),
            ),
            hint: 'Tippe zum Kopieren',
          ),

          // ── Meine Daten ─────────────────────────────────────────────
          if (profile != null) ...[
            const SizedBox(height: 24),
            _sectionHeader('Meine Daten'),
            const SizedBox(height: 12),
            _dataCard(profile),
          ],
          const SizedBox(height: 24),

          // ── Contacts shortcut ───────────────────────────────────────
          _contactsCard(),
          const SizedBox(height: 24),

          // ── Backup reminder (shown until first export) ───────────────
          if (!_hasEverExported) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF2A1E00),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: Colors.orange.withValues(alpha: 0.5)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.backup_outlined,
                      color: Colors.orange, size: 20),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Tipp: Exportiere regelmäßig deine Daten über '
                      '"Daten exportieren", um sie bei einem Gerätewechsel '
                      'wiederherstellen zu können.',
                      style: TextStyle(
                          color: Colors.orange,
                          fontSize: 13,
                          height: 1.45),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // ── Actions ─────────────────────────────────────────────────
          _actionButton(
            icon: Icons.key_outlined,
            label: 'Seed Phrase anzeigen',
            onPressed: _showSeedPhrase,
          ),
          const SizedBox(height: 12),
          _actionButton(
            icon: Icons.upload_outlined,
            label: 'Daten exportieren',
            onPressed: _exportData,
          ),
          const SizedBox(height: 40),

          // ── Branding ────────────────────────────────────────────────
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.gold, width: 1.5),
              color: AppColors.surface,
            ),
            child: const Center(
              child: Text('N',
                  style: TextStyle(
                      color: AppColors.gold,
                      fontSize: 28,
                      fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'N.E.X.U.S. OneApp  v0.1.0',
            style: TextStyle(
                color: AppColors.onDark.withValues(alpha: 0.5),
                fontSize: 12,
                letterSpacing: 1.2),
          ),
        ],
      ),
    );
  }

  Widget _dataCard(UserProfile p) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.25)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (p.realName.value != null)
            _dataRow(Icons.person_outline, 'Klarname', p.realName.value!,
                p.realName.visibility),
          if (p.location.value != null)
            _dataRow(Icons.place_outlined, 'Standort', p.location.value!,
                p.location.visibility),
          if (p.languages.value.isNotEmpty) ...[
            _dataLabel(Icons.language, 'Sprachen', p.languages.visibility),
            const SizedBox(height: 6),
            _chipRow(p.languages.value),
            const SizedBox(height: 12),
          ],
          if (p.skills.value.isNotEmpty) ...[
            _dataLabel(Icons.build_outlined, 'Fähigkeiten',
                p.skills.visibility),
            const SizedBox(height: 6),
            _chipRow(p.skills.value),
            const SizedBox(height: 12),
          ],
          _dataRow(
            Icons.cake_outlined,
            'Geburtsdatum',
            p.birthDate.value != null ? 'Gesetzt ✓' : 'Nicht gesetzt',
            p.birthDate.visibility,
            valueColor: p.birthDate.value != null
                ? Colors.greenAccent.shade700
                : AppColors.onDark.withValues(alpha: 0.5),
          ),
        ],
      ),
    );
  }

  Widget _dataRow(
    IconData icon,
    String label,
    String value,
    VisibilityLevel visibility, {
    Color? valueColor,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon,
              color: AppColors.onDark.withValues(alpha: 0.5), size: 16),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(
                      color: AppColors.onDark.withValues(alpha: 0.5),
                      fontSize: 11)),
              Text(value,
                  style: TextStyle(
                      color: valueColor ?? AppColors.onDark,
                      fontSize: 14)),
            ],
          ),
          const Spacer(),
          Icon(_visibilityIcon(visibility),
              color: AppColors.gold.withValues(alpha: 0.6), size: 14),
        ],
      ),
    );
  }

  Widget _dataLabel(
      IconData icon, String label, VisibilityLevel visibility) {
    return Row(
      children: [
        Icon(icon,
            color: AppColors.onDark.withValues(alpha: 0.5), size: 16),
        const SizedBox(width: 8),
        Text(label,
            style: TextStyle(
                color: AppColors.onDark.withValues(alpha: 0.5),
                fontSize: 11)),
        const Spacer(),
        Icon(_visibilityIcon(visibility),
            color: AppColors.gold.withValues(alpha: 0.6), size: 14),
      ],
    );
  }

  Widget _chipRow(List<String> items) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: items
          .map((c) => Chip(
                label: Text(c,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.deepBlue)),
                backgroundColor: AppColors.gold.withValues(alpha: 0.85),
                padding: EdgeInsets.zero,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ))
          .toList(),
    );
  }

  Widget _infoCard({
    required String label,
    required Widget child,
    String? hint,
  }) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border:
            Border.all(color: AppColors.gold.withValues(alpha: 0.25)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppColors.gold,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8)),
          const SizedBox(height: 8),
          child,
          if (hint != null) ...[
            const SizedBox(height: 4),
            Text(hint,
                style: TextStyle(
                    color: AppColors.onDark.withValues(alpha: 0.5),
                    fontSize: 11)),
          ],
        ],
      ),
    );
  }

  Widget _sectionHeader(String text) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.gold,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  Widget _contactsCard() {
    final count = ContactService.instance.contacts.length;
    return GestureDetector(
      onTap: _openContacts,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.gold.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.gold.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.people_outline,
                  color: AppColors.gold, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Meine Kontakte',
                    style: TextStyle(
                      color: AppColors.onDark,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  Text(
                    '$count Kontakt${count == 1 ? '' : 'e'}',
                    style: TextStyle(
                      color: AppColors.onDark.withValues(alpha: 0.6),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.gold),
          ],
        ),
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, color: AppColors.gold),
        label: Text(label, style: const TextStyle(color: AppColors.gold)),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14),
          side:
              BorderSide(color: AppColors.gold.withValues(alpha: 0.5)),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }
}
