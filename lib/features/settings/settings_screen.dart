import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../core/contacts/contact_service.dart';
import '../../core/identity/identity_service.dart';
import '../../core/roles/role_enums.dart';
import '../../core/storage/pod_database.dart';
import '../../core/storage/retention_service.dart';
import '../../services/backup_service.dart';
import '../../services/role_service.dart';
import '../invite/redeem_screen.dart';
import '../onboarding/principles_content_screen.dart';
import '../onboarding/restore_backup_screen.dart';
import '../../services/notification_settings_service.dart';
import '../../services/principles_service.dart';
import '../../services/update_service.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/update_bottom_sheet.dart';
import '../chat/chat_provider.dart';
import '../contacts/widgets/trust_badge.dart';
import 'admin_cell_management_screen.dart';
import 'admin_management_screen.dart';
import 'nostr_settings_screen.dart';
import 'notification_settings_screen.dart';

/// Top-level settings hub.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Einstellungen')),
      body: ListView(
        children: [
          _SectionHeader('Transport'),
          ListTile(
            leading: const Icon(Icons.language, color: Colors.lightBlueAccent),
            title: const Text('Nostr-Netzwerk'),
            subtitle: const Text('Internet-Fallback über Nostr-Relays'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ChangeNotifierProvider.value(
                  value: context.read<ChatProvider>(),
                  child: const NostrSettingsScreen(),
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          const _NotificationSection(),
          const Divider(height: 1),
          _NachrichtenSection(chatProvider: context.read<ChatProvider>()),
          const Divider(height: 1),
          const _BackupSection(),
          const Divider(height: 1),
          _SectionHeader('Einladungen'),
          ListTile(
            leading: const Icon(Icons.card_giftcard_outlined, color: AppColors.gold),
            title: const Text('Einladungscode einlösen'),
            subtitle: const Text('Code eines Freundes eingeben'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const RedeemScreen(),
              ),
            ),
          ),
          const Divider(height: 1),
          _SectionHeader('Kontakte'),
          ListTile(
            leading: const Icon(Icons.block, color: Colors.orange),
            title: const Text('Blockierte Kontakte'),
            subtitle: Text(
              '${ContactService.instance.blockedContacts.length} blockiert',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const _BlockedContactsScreen(),
              ),
            ),
          ),
          ListTile(
            leading:
                const Icon(Icons.upload_file, color: AppColors.gold),
            title: const Text('Kontakte exportieren'),
            subtitle: const Text('Als JSON in Dokumente speichern'),
            onTap: () => _exportContacts(context),
          ),
          ListTile(
            leading:
                const Icon(Icons.download_outlined, color: AppColors.gold),
            title: const Text('Kontakte importieren'),
            subtitle: const Text('Kommt bald – benötigt Datei-Picker'),
            enabled: false,
          ),
          const Divider(height: 1),
          const _AdminSection(),
          const Divider(height: 1),
          _SectionHeader('Info'),
          ListTile(
            leading: const Icon(Icons.menu_book_outlined, color: AppColors.gold),
            title: const Text('Unsere Grundsätze'),
            subtitle: _principlesSubtitle(),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const PrinciplesContentScreen(readOnly: true),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline, color: AppColors.gold),
            title: const Text('NEXUS OneApp'),
            subtitle: const Text('Phase 1a – AETHER Protokoll'),
            onTap: () => _showAbout(context),
          ),
          const _AppVersionSection(),
        ],
      ),
    );
  }

  Future<void> _exportContacts(BuildContext context) async {
    try {
      final json = ContactService.instance.exportJson();
      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .substring(0, 19);
      final file = File('${dir.path}/nexus_contacts_$ts.json');
      await file.writeAsString(json);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Exportiert: ${file.path}'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export fehlgeschlagen: $e')),
        );
      }
    }
  }

  Widget? _principlesSubtitle() {
    final svc = PrinciplesService.instance;
    if (svc.isAccepted && svc.acceptedAt != null) {
      final d = svc.acceptedAt!;
      final formatted =
          '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
      return Text('Bestätigt am $formatted');
    }
    return const Text('Die Grundlagen unserer Gemeinschaft');
  }

  Future<void> _showAbout(BuildContext context) async {
    final info = await PackageInfo.fromPlatform();
    if (!context.mounted) return;
    showAboutDialog(
      context: context,
      applicationName: 'NEXUS OneApp',
      applicationVersion: 'v${info.version}',
      applicationLegalese: '© 2025 – Protokoll, nicht Plattform',
      children: const [
        SizedBox(height: 12),
        Text(
          'Eine dezentrale, zensurresistente App für die Menschheitsfamilie.\n'
          'Implementiert das AETHER-Protokoll mit BLE-Mesh, LAN und Nostr.',
        ),
      ],
    );
  }
}

// ── App version section ───────────────────────────────────────────────────────

class _AppVersionSection extends StatefulWidget {
  const _AppVersionSection();

  @override
  State<_AppVersionSection> createState() => _AppVersionSectionState();
}

class _AppVersionSectionState extends State<_AppVersionSection> {
  String _version = '…';
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _version = info.version);
  }

  Future<void> _checkNow() async {
    setState(() => _checking = true);
    final result = await UpdateService.instance.checkNow();
    if (!mounted) return;
    setState(() => _checking = false);
    if (result != null) {
      await showUpdateBottomSheet(context, result);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Du hast die neueste Version.'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading:
              const Icon(Icons.verified_outlined, color: AppColors.gold),
          title: Text('App-Version: v$_version'),
          subtitle: const Text('NEXUS OneApp'),
        ),
        ListTile(
          leading: _checking
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.gold),
                )
              : const Icon(Icons.system_update_outlined,
                  color: AppColors.gold),
          title: const Text('Nach Updates suchen'),
          subtitle: const Text('Prüft die neueste GitHub-Version'),
          onTap: _checking ? null : _checkNow,
        ),
      ],
    );
  }
}

// ── Nachrichten section ────────────────────────────────────────────────────────

class _NachrichtenSection extends StatefulWidget {
  const _NachrichtenSection({required this.chatProvider});
  final ChatProvider chatProvider;

  @override
  State<_NachrichtenSection> createState() => _NachrichtenSectionState();
}

class _NachrichtenSectionState extends State<_NachrichtenSection> {
  int _count = 0;
  int _bytes = 0;
  bool _loading = true;
  RetentionPeriod _retention = RetentionService.instance.global;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    try {
      final count = await PodDatabase.instance.getTotalMessageCount();
      final bytes = await PodDatabase.instance.estimateStorageSizeBytes();
      if (mounted) {
        setState(() {
          _count = count;
          _bytes = bytes;
          _retention = RetentionService.instance.global;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _changeRetention() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                child: Text(
                  'Nachrichten aufbewahren',
                  style: const TextStyle(
                    color: AppColors.gold,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
              ...RetentionPeriod.values.map((p) => ListTile(
                    title: Text(p.label),
                    trailing: _retention == p
                        ? const Icon(Icons.check, color: AppColors.gold)
                        : null,
                    onTap: () async {
                      Navigator.pop(ctx);
                      await RetentionService.instance.setGlobal(p);
                      if (mounted) setState(() => _retention = p);
                    },
                  )),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _deleteAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Alle Nachrichten löschen?'),
        content: const Text(
          'Alle gespeicherten Nachrichten werden unwiderruflich gelöscht. '
          'Diese Aktion kann nicht rückgängig gemacht werden.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    await PodDatabase.instance.deleteAllMessages();
    widget.chatProvider.clearAllCaches();
    await _loadStats();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Alle Nachrichten gelöscht.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader('Nachrichten'),
        // Stats
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: LinearProgressIndicator(),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: _StatChip(
                    label: 'Gespeichert',
                    value: '$_count',
                    unit: 'Nachrichten',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _StatChip(
                    label: 'Speicherplatz',
                    value: _formatBytes(_bytes),
                    unit: '(ungefähr)',
                  ),
                ),
              ],
            ),
          ),
        // Retention picker
        ListTile(
          leading:
              const Icon(Icons.timer_outlined, color: AppColors.gold),
          title: const Text('Aufbewahrungsdauer'),
          subtitle: Text(_retention.label),
          trailing: const Icon(Icons.chevron_right),
          onTap: _changeRetention,
        ),
        // Delete all
        ListTile(
          leading: const Icon(
            Icons.delete_sweep_outlined,
            color: Colors.redAccent,
          ),
          title: const Text(
            'Alle Nachrichten löschen',
            style: TextStyle(color: Colors.redAccent),
          ),
          onTap: _deleteAll,
        ),
      ],
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.label,
    required this.value,
    required this.unit,
  });

  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppColors.onDark,
            ),
          ),
          Text(unit, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: AppColors.gold,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
        ),
      ),
    );
  }
}

// ── Notifications section ─────────────────────────────────────────────────────

class _NotificationSection extends StatefulWidget {
  const _NotificationSection();

  @override
  State<_NotificationSection> createState() => _NotificationSectionState();
}

class _NotificationSectionState extends State<_NotificationSection> {
  final _svc = NotificationSettingsService.instance;

  String _formatTime(TimeOfDay t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Future<void> _pickTime({required bool isFrom}) async {
    final current = isFrom ? _svc.dndFrom : _svc.dndUntil;
    final picked = await showTimePicker(
      context: context,
      initialTime: current,
    );
    if (picked == null || !mounted) return;
    if (isFrom) {
      await _svc.setDndFrom(picked);
    } else {
      await _svc.setDndUntil(picked);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader('Benachrichtigungen'),
        ListTile(
          leading: const Icon(Icons.tune_outlined, color: AppColors.gold),
          title: const Text('Benachrichtigungs-Kategorien'),
          subtitle: const Text('Chat, Kanäle, Dorfplatz'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const NotificationSettingsScreen(),
            ),
          ),
        ),
        const Divider(height: 1, indent: 16),
        SwitchListTile(
          secondary: const Icon(Icons.notifications_outlined, color: AppColors.gold),
          title: const Text('Benachrichtigungen aktivieren'),
          value: _svc.enabled,
          activeColor: AppColors.gold,
          onChanged: (v) async {
            await _svc.setEnabled(v);
            setState(() {});
          },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.preview_outlined, color: AppColors.gold),
          title: const Text('Nachrichtenvorschau anzeigen'),
          value: _svc.showPreview,
          activeColor: AppColors.gold,
          onChanged: _svc.enabled
              ? (v) async {
                  await _svc.setShowPreview(v);
                  setState(() {});
                }
              : null,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.campaign_outlined, color: AppColors.gold),
          title: const Text('#hotnews Ankündigungen'),
          value: _svc.broadcastEnabled,
          activeColor: AppColors.gold,
          onChanged: _svc.enabled
              ? (v) async {
                  await _svc.setBroadcastEnabled(v);
                  setState(() {});
                }
              : null,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.volume_off_outlined, color: AppColors.gold),
          title: const Text('Stiller Modus'),
          subtitle: const Text('Kein Ton, keine Vibration'),
          value: _svc.silentMode,
          activeColor: AppColors.gold,
          onChanged: _svc.enabled
              ? (v) async {
                  await _svc.setSilentMode(v);
                  setState(() {});
                }
              : null,
        ),
        const Divider(height: 1, indent: 16),
        SwitchListTile(
          secondary: const Icon(Icons.do_not_disturb_on_outlined,
              color: AppColors.gold),
          title: const Text('Nicht stören'),
          subtitle: _svc.dndEnabled
              ? Text(
                  '${_formatTime(_svc.dndFrom)} – ${_formatTime(_svc.dndUntil)}')
              : const Text('Deaktiviert'),
          value: _svc.dndEnabled,
          activeColor: AppColors.gold,
          onChanged: _svc.enabled
              ? (v) async {
                  await _svc.setDndEnabled(v);
                  setState(() {});
                }
              : null,
        ),
        if (_svc.dndEnabled) ...[
          ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
            leading: const SizedBox(width: 24),
            title: const Text('Von'),
            trailing: TextButton(
              onPressed: () => _pickTime(isFrom: true),
              child: Text(
                _formatTime(_svc.dndFrom),
                style: const TextStyle(color: AppColors.gold),
              ),
            ),
          ),
          ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
            leading: const SizedBox(width: 24),
            title: const Text('Bis'),
            trailing: TextButton(
              onPressed: () => _pickTime(isFrom: false),
              child: Text(
                _formatTime(_svc.dndUntil),
                style: const TextStyle(color: AppColors.gold),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ── Admin section ─────────────────────────────────────────────────────────────

/// Visible only for superadmin and system admins.
class _AdminSection extends StatelessWidget {
  const _AdminSection();

  @override
  Widget build(BuildContext context) {
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final svc = RoleService.instance;
    final role = svc.getSystemRole(myDid);

    if (role == SystemRole.user) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader('Administration'),
        // Role badge
        ListTile(
          leading: Icon(
            role == SystemRole.superadmin
                ? Icons.shield
                : Icons.shield_outlined,
            color: AppColors.gold,
          ),
          title: Text(
            role == SystemRole.superadmin ? 'Superadmin' : 'System-Admin',
            style: const TextStyle(color: AppColors.gold),
          ),
          subtitle: Text(
            role == SystemRole.superadmin
                ? 'Gründer-Rolle – Genesis-Phase'
                : 'Ernannt vom Superadmin',
            style: const TextStyle(fontSize: 12),
          ),
        ),
        // Superadmin-only options
        if (role == SystemRole.superadmin) ...[
          ListTile(
            leading: const Icon(Icons.manage_accounts, color: AppColors.gold),
            title: const Text('System-Admins verwalten'),
            subtitle: Text(
              '${svc.systemAdmins.length} aktive Admin'
              '${svc.systemAdmins.length == 1 ? "" : "s"}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AdminManagementScreen(),
              ),
            ),
          ),
          ListTile(
            leading:
                const Icon(Icons.hexagon_outlined, color: Colors.redAccent),
            title: const Text(
              'Zellen verwalten',
              style: TextStyle(color: Colors.redAccent),
            ),
            subtitle: const Text(
                'Verwaiste Zellen löschen · Kind-5 Dissolution senden'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AdminCellManagementScreen(),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.swap_horiz, color: Colors.orange),
            title: const Text(
              'Superadmin übertragen',
              style: TextStyle(color: Colors.orange),
            ),
            subtitle: const Text('Unwiderruflich in der Genesis-Phase'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _confirmTransfer(context, myDid),
          ),
        ],
      ],
    );
  }

  Future<void> _confirmTransfer(BuildContext context, String myDid) async {
    final TextEditingController ctrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Superadmin übertragen?',
          style: TextStyle(color: Colors.orange),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Diese Aktion ist IRREVERSIBEL in der Genesis-Phase.\n\n'
              'Du verlierst alle Superadmin-Rechte sofort.',
              style: TextStyle(color: AppColors.onDark),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              style: const TextStyle(color: AppColors.onDark, fontSize: 13),
              decoration: InputDecoration(
                labelText: 'DID des neuen Superadmins',
                filled: true,
                fillColor: AppColors.surfaceVariant,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen',
                style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Übertragen'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    final newDid = ctrl.text.trim();
    if (newDid.isEmpty || !context.mounted) return;

    // Second confirmation
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Bist du sicher?',
            style: TextStyle(color: Colors.orange)),
        content: Text(
          'Du überträgst die Superadmin-Rolle an:\n$newDid\n\n'
          'Das kann nicht rückgängig gemacht werden.',
          style: const TextStyle(color: AppColors.onDark),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen',
                style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Endgültig übertragen'),
          ),
        ],
      ),
    );

    if (sure != true || !context.mounted) return;

    try {
      await RoleService.instance.transferSuperadmin(myDid, newDid);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Superadmin-Rolle übertragen.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler: $e')),
        );
      }
    }
  }
}

// ── Blocked contacts screen ───────────────────────────────────────────────────

class _BlockedContactsScreen extends StatefulWidget {
  const _BlockedContactsScreen();

  @override
  State<_BlockedContactsScreen> createState() => _BlockedContactsScreenState();
}

class _BlockedContactsScreenState extends State<_BlockedContactsScreen> {
  void _reload() => setState(() {});

  Future<void> _unblock(String did, String pseudonym) async {
    await ContactService.instance.unblockContact(did);
    _reload();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$pseudonym wurde entsperrt.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocked = ContactService.instance.blockedContacts;

    return Scaffold(
      appBar: AppBar(title: const Text('Blockierte Kontakte')),
      body: blocked.isEmpty
          ? const Center(
              child: Text(
                'Keine blockierten Kontakte.',
                style: TextStyle(color: Colors.grey),
              ),
            )
          : ListView.separated(
              itemCount: blocked.length,
              separatorBuilder: (_, __) => const Divider(
                height: 1,
                indent: 56,
                color: AppColors.surfaceVariant,
              ),
              itemBuilder: (ctx, i) {
                final c = blocked[i];
                return ListTile(
                  leading: const Icon(Icons.block, color: Colors.orange),
                  title: Text(c.pseudonym),
                  subtitle: Text(
                    c.did.length > 20
                        ? '${c.did.substring(0, 10)}…${c.did.substring(c.did.length - 8)}'
                        : c.did,
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: TextButton(
                    onPressed: () => _unblock(c.did, c.pseudonym),
                    child: const Text(
                      'Entsperren',
                      style: TextStyle(color: AppColors.gold),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

// ── Backup section ────────────────────────────────────────────────────────────

class _BackupSection extends StatefulWidget {
  const _BackupSection();

  @override
  State<_BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends State<_BackupSection> {
  bool _creatingBackup = false;

  String _formatDate(DateTime? dt) {
    if (dt == null) return 'Noch kein Backup';
    return '${dt.day.toString().padLeft(2, '0')}.'
        '${dt.month.toString().padLeft(2, '0')}.'
        '${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _backupNow() async {
    setState(() => _creatingBackup = true);
    final result = await BackupService.instance.createBackup();
    if (!mounted) return;
    setState(() => _creatingBackup = false);
    if (result.success && result.path != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Backup gespeichert: ${result.path}'),
          duration: const Duration(seconds: 6),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Backup fehlgeschlagen: ${result.error ?? "Unbekannter Fehler"}'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _restoreFromFile() async {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const RestoreBackupScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final svc = BackupService.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader('Datensicherung'),
        ListTile(
          leading: const Icon(Icons.backup_outlined, color: AppColors.gold),
          title: const Text('Letztes Backup'),
          subtitle: Text(_formatDate(svc.lastBackupAt)),
        ),
        ListTile(
          leading: _creatingBackup
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.gold),
                )
              : const Icon(Icons.save_outlined, color: AppColors.gold),
          title: const Text('Jetzt sichern'),
          subtitle: const Text('Erstellt sofort ein verschlüsseltes Backup'),
          onTap: _creatingBackup ? null : _backupNow,
        ),
        ListTile(
          leading: const Icon(Icons.restore_outlined, color: AppColors.gold),
          title: const Text('Backup wiederherstellen'),
          subtitle: const Text('Daten aus einem Backup importieren'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _restoreFromFile,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.schedule_outlined,
              color: AppColors.gold),
          title: const Text('Automatisches Backup'),
          subtitle: const Text('Alle 24 Stunden wenn Daten geändert'),
          value: svc.autoBackupEnabled,
          onChanged: (v) {
            BackupService.instance.setAutoBackupEnabled(v);
            setState(() {});
          },
          activeColor: AppColors.gold,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Backups sind verschlüsselt und können nur mit deiner Seed Phrase '
            'geöffnet werden.',
            style: TextStyle(
                color: AppColors.onDark.withValues(alpha: 0.55),
                fontSize: 12,
                height: 1.5),
          ),
        ),
      ],
    );
  }
}
