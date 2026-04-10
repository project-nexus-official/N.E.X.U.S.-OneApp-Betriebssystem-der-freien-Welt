import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

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
import '../../features/governance/cell.dart';
import '../../features/governance/cell_member.dart';
import '../../features/governance/cell_service.dart';
import '../../features/governance/proposal.dart';
import '../../features/governance/proposal_service.dart';
import '../../features/governance/vote.dart';
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
          const _G2DebugSection(),
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

    // Always show debug reset when there is local cell data to clean up.
    final hasCellData = CellService.instance.myCells.isNotEmpty ||
        CellService.instance.discoveredCells.isNotEmpty ||
        CellService.instance.myOutgoingRequests.isNotEmpty;

    if (role == SystemRole.user) {
      // Non-admin: only show debug cleanup when there is stale cell data.
      if (!hasCellData) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader('Debug'),
          ListTile(
            leading: const Icon(Icons.cleaning_services, color: Colors.grey),
            title: const Text(
              '🧹 Alle Zellen-Daten zurücksetzen',
              style: TextStyle(color: Colors.grey),
            ),
            subtitle: const Text('Testdaten bereinigen',
                style: TextStyle(fontSize: 11)),
            onTap: () => _resetCellData(context),
          ),
        ],
      );
    }

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
          // ── CELL WIPE ───────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.redAccent),
            title: const Text(
              '☢️ Alle Zellen löschen (Nuclear Wipe)',
              style: TextStyle(color: Colors.redAccent),
            ),
            subtitle: const Text(
              'DB + SharedPrefs + Memory — unabhängig vom Zustand',
              style: TextStyle(fontSize: 11),
            ),
            onTap: () => _nuclearWipeCells(context),
          ),
          // ── END CELL WIPE ────────────────────────────────────────────────
          // ── MEMBERSHIP REPAIR ────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.build, color: Colors.green),
            title: const Text('🔧 Membership reparieren'),
            subtitle: const Text(
              'Stellt FOUNDER-Status für eigene Cells wieder her '
              '(nach Nuclear Wipe Vorfall)',
              style: TextStyle(fontSize: 11),
            ),
            onTap: () => _runMembershipRepair(context),
          ),
          // ── END MEMBERSHIP REPAIR ────────────────────────────────────────
          // ── CLAIM DISCOVERED CELL ────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.home_work, color: Colors.green),
            title: const Text('🏠 Discovered Cell übernehmen'),
            subtitle: const Text(
              'Nimmt eine entdeckte Cell als eigene Zelle (Founder) zurück',
              style: TextStyle(fontSize: 11),
            ),
            onTap: () => _claimDiscoveredCell(context),
          ),
          // ── END CLAIM DISCOVERED CELL ─────────────────────────────────────
          // ── ZOMBIE TOMBSTONE ─────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.delete_sweep, color: Colors.orange),
            title: const Text('🪦 Discovered Zombies tombstonen'),
            subtitle: const Text(
              'Markiert alle aktuell entdeckten Cells als gelöscht '
              'damit sie nicht zurückkommen',
              style: TextStyle(fontSize: 11),
            ),
            onTap: () => _tombstoneZombies(context),
          ),
          // ── END ZOMBIE TOMBSTONE ─────────────────────────────────────────
        ],
      ],
    );
  }

  Future<void> _claimDiscoveredCell(BuildContext context) async {
    final discovered = CellService.instance.discoveredCells;
    if (discovered.isEmpty) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Keine entdeckten Cells vorhanden.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Let the user pick a cell.
    final cell = await showDialog<Cell>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('🏠 Welche Cell übernehmen?'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: discovered.length,
            itemBuilder: (_, i) {
              final c = discovered[i];
              final shortId = c.id.length > 16
                  ? '${c.id.substring(0, 8)}…${c.id.substring(c.id.length - 8)}'
                  : c.id;
              return ListTile(
                title: Text(c.name,
                    style: const TextStyle(color: AppColors.onDark)),
                subtitle: Text(shortId,
                    style:
                        const TextStyle(fontSize: 11, color: Colors.white54)),
                onTap: () => Navigator.of(ctx).pop(c),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Abbrechen'),
          ),
        ],
      ),
    );

    if (cell == null || !context.mounted) return;

    // Confirmation dialog.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Cell als Founder übernehmen?'),
        content: Text(
          '"${cell.name}" wird in deine eigenen Zellen aufgenommen '
          'und du wirst als Founder eingetragen.\n\n'
          'Du solltest nur Cells übernehmen, die du selbst erstellt hast.',
          style: const TextStyle(color: AppColors.onDark),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Abbrechen'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.gold),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Cell übernehmen',
                style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final ok = await CellService.instance.claimDiscoveredCell(cell.id);

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? '✅ Cell "${cell.name}" wiederhergestellt'
            : '❌ Fehler: Cell nicht gefunden'),
        backgroundColor: ok ? Colors.green : Colors.red,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _tombstoneZombies(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Discovered Zombies tombstonen?'),
        content: const Text(
          'Alle aktuell im Cell-Hub angezeigten "entdeckten" '
          'Cells werden dauerhaft als gelöscht markiert. '
          'Sie kommen auch nach einem Neustart nicht zurück.\n\n'
          'Eigene Cells in der DB werden NICHT angetastet.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Tombstonen'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final count = await CellService.instance.tombstoneAllDiscovered();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('🪦 $count Zombie-Cells tombstoned'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _runMembershipRepair(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Membership reparieren?'),
        content: const Text(
          'Diese Aktion prüft alle Cells in deiner DB und fügt einen '
          'FOUNDER-Eintrag hinzu, wenn deine DID die createdBy-DID ist '
          'und noch kein Membership-Eintrag existiert.\n\n'
          'Es werden nur Einträge HINZUGEFÜGT, niemals gelöscht oder '
          'überschrieben.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reparatur starten'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    try {
      final result =
          await CellService.instance.repairFounderMemberships();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '✅ Reparatur abgeschlossen: '
              '${result['checked']} geprüft, '
              '${result['repaired']} repariert, '
              '${result['skipped']} übersprungen',
            ),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } catch (e, stack) {
      print('[REPAIR] EXCEPTION: $e');
      print('[REPAIR] Stack: $stack');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Fehler: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
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

  Future<void> _nuclearWipeCells(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('☢️ Alle Zellen löschen?',
            style: TextStyle(color: Colors.redAccent)),
        content: const Text(
          'Löscht ALLE Zell-Daten:\n'
          '• Datenbank (cells, members, requests)\n'
          '• SharedPreferences (Block-Listen, Wipe-Timestamp)\n'
          '• In-Memory-Zustand\n\n'
          'Nostr-Relay-Events älter als JETZT werden dauerhaft ignoriert.\n\n'
          'Nicht rückgängig zu machen!',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Löschen',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    await CellService.instance.nuclearWipe();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('☢️ Alle Zellen-Daten gelöscht.')),
      );
    }
  }

  Future<void> _resetCellData(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Zellen-Daten zurücksetzen?',
            style: TextStyle(color: Colors.grey)),
        content: const Text(
          'Alle Zellen, Zell-Kanäle und offene Beitrittsanfragen '
          'werden lokal gelöscht. Dieser Vorgang kann nicht '
          'rückgängig gemacht werden.',
          style: TextStyle(color: AppColors.onDark),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen',
                style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.grey.shade700,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    try {
      final db = PodDatabase.instance;
      final myDid = IdentityService.instance.currentIdentity?.did ?? '';

      // Read cells BEFORE any deletion so we can publish Nostr events.
      final cells = await db.listCells();
      final cellCount = cells.length;

      // IMPORTANT: also include in-memory discovered cells — they are NOT
      // persisted to DB, so their IDs would otherwise never enter the block list
      // and would re-appear on the next Nostr subscription round.
      final discoveredIds =
          CellService.instance.discoveredCells.map((c) => c.id).toList();
      final allCellIds = {
        ...cells.map((c) => c['id'] as String? ?? '').where((id) => id.isNotEmpty),
        ...discoveredIds,
      }.toList();

      // ── ZOMBIE-DIAG: Cleanup pressed ────────────────────────────────────
      print('[ZOMBIE-DIAG] === CLEANUP PRESSED ===');
      print('[ZOMBIE-DIAG] DB cells to clean: $cellCount');
      for (final c in cells) {
        print('[ZOMBIE-DIAG]   DB cell: "${c['name']}" id=${c['id']}');
      }
      print('[ZOMBIE-DIAG] Discovered cells (in-memory): ${discoveredIds.length}');
      for (final id in discoveredIds) {
        print('[ZOMBIE-DIAG]   Discovered id: $id');
      }
      print('[ZOMBIE-DIAG] allCellIds to block: $allCellIds');
      // ────────────────────────────────────────────────────────────────────

      // ── STEP 1: Block ALL cell IDs + record wipe timestamp ──
      // The wipe timestamp causes any cell announcement older than NOW to be
      // silently ignored on future Nostr deliveries — covering zombie cells
      // whose IDs we don't even know yet (e.g., not discovered in this session).
      await CellService.instance.recordWipe();
      await CellService.instance.dismissCells(allCellIds);
      print('[CLEANUP] Blocked ${allCellIds.length} cellIds from re-import'
          ' (${cellCount} persisted + ${discoveredIds.length} discovered)');

      // ── ZOMBIE-DIAG: Verify what was actually saved ───────────────────
      final verifyPrefs = await SharedPreferences.getInstance();
      final savedRaw = verifyPrefs.getString('nexus_dismissed_cell_ids');
      final savedWipe = verifyPrefs.getInt('nexus_cell_wipe_at');
      final savedIds = savedRaw != null
          ? (jsonDecode(savedRaw) as List<dynamic>).cast<String>()
          : <String>[];
      print('[ZOMBIE-DIAG] Block list AFTER save: ${savedIds.length} entries');
      print('[ZOMBIE-DIAG] Block list content: $savedIds');
      print('[ZOMBIE-DIAG] Wipe timestamp saved: ${savedWipe ?? "NOT SAVED"}');
      // ─────────────────────────────────────────────────────────────────

      // ── STEP 2: Publish dissolution events for cells where we are founder ──
      final founderCells =
          cells.where((c) => (c['createdBy'] as String? ?? '') == myDid).toList();
      if (founderCells.isNotEmpty && context.mounted) {
        final chatProvider = context.read<ChatProvider>();
        for (final cellJson in founderCells) {
          final cellId = cellJson['id'] as String? ?? '';
          final cellName = cellJson['name'] as String? ?? cellId;
          if (cellId.isEmpty) continue;
          // Kind-5 NIP-09: tells relays to delete the original announcement.
          chatProvider.publishNostrCellDeletion(cellId, cellName);
          // Kind-30000 with deleted:true + tag: propagates to all member devices.
          chatProvider.publishNostrCellDissolution(cellJson);
        }
        print('[CLEANUP] Publishing delete events for ${founderCells.length} owned cells');
      }

      // ── STEP 3: Delete all cells and their members from local DB ──
      for (final cellJson in cells) {
        final cellId = cellJson['id'] as String? ?? '';
        if (cellId.isEmpty) continue;
        final members = await db.listCellMembers(cellId);
        for (final m in members) {
          final did = m['did'] as String? ?? '';
          if (did.isNotEmpty) await db.deleteCellMember(cellId, did);
        }
        await db.deleteCellJoinRequestsByCell(cellId);
        await db.deleteCell(cellId);
      }
      print('[CLEANUP] Deleted $cellCount cells');

      // Delete all cell-internal channels (cell_id NOT NULL).
      final channelCount = await db.deleteAllCellChannels();
      print('[CLEANUP] Deleted $channelCount cell channels');

      // Any remaining join requests (outgoing).
      await db.deleteAllCellJoinRequests();
      print('[CLEANUP] Deleted pending join requests');

      // ── STEP 4: Reset in-memory state (block list is preserved!) ──
      await CellService.instance.resetForDebug();

      // Reset Nostr subscriptions.
      if (context.mounted) {
        context.read<ChatProvider>().resetNostrSubscriptions();
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Zellen-Daten zurückgesetzt'
              '${founderCells.isNotEmpty ? ' · ${founderCells.length} Delete-Events gesendet' : ''}',
            ),
            backgroundColor: Colors.grey,
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

// ── G2 Debug Section (temporär – wird nach Prompt 1C entfernt) ─────────────────

/// Nur sichtbar für Superadmin.  Enthält Buttons zum manuellen Testen der
/// G2-Governance-Funktionalität ohne UI (Prompt 1C kommt später).
class _G2DebugSection extends StatelessWidget {
  const _G2DebugSection();

  @override
  Widget build(BuildContext context) {
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    if (!RoleService.instance.isSuperadmin(myDid)) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('🧪 G2 Debug (temporär)'),
        _debugTile(
          context,
          icon: Icons.add_task,
          label: 'G2 Test-Antrag erstellen',
          onTap: () => _createTestProposal(context),
        ),
        _debugTile(
          context,
          icon: Icons.how_to_vote_outlined,
          label: 'G2 Test-Antrag → Voting starten',
          onTap: () => _startTestVoting(context),
        ),
        _debugTile(
          context,
          icon: Icons.thumb_up_outlined,
          label: 'G2 Test-Vote: JA',
          onTap: () => _castTestVote(context, VoteChoice.YES, 'Debug Test JA'),
        ),
        _debugTile(
          context,
          icon: Icons.thumb_down_outlined,
          label: 'G2 Test-Vote: NEIN',
          onTap: () => _castTestVote(context, VoteChoice.NO, 'Debug Test NEIN'),
        ),
        _debugTile(
          context,
          icon: Icons.fast_forward,
          label: 'G2 Test-Voting beenden (Force)',
          onTap: () => _forceFinalize(context),
        ),
        _debugTile(
          context,
          icon: Icons.receipt_long,
          label: 'G2 Audit-Log anzeigen',
          onTap: () => _showAuditLog(context),
        ),
        _debugTile(
          context,
          icon: Icons.delete_sweep,
          label: '🗑️ G2 Test-Anträge löschen',
          onTap: () => _cleanupTestProposals(context),
        ),
        _debugTile(
          context,
          icon: Icons.delete_forever,
          label: '☢️ ALLE Anträge löschen (Debug)',
          onTap: () => _confirmDeleteAllProposals(context),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            'Diese Buttons werden nach Prompt 1C (UI) entfernt.',
            style: TextStyle(
              fontSize: 11,
              color: Colors.amber.withValues(alpha: 0.6),
            ),
          ),
        ),
      ],
    );
  }

  Widget _debugTile(BuildContext context,
      {required IconData icon,
      required String label,
      required VoidCallback onTap}) {
    return ListTile(
      dense: true,
      leading: Icon(icon, color: Colors.amber, size: 20),
      title: Text(label,
          style: const TextStyle(color: Colors.amber, fontSize: 14)),
      onTap: onTap,
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  /// Finds the newest proposal (ANY title) in [status], across all known proposals.
  Proposal? _findAnyProposal(ProposalStatus status) {
    final all = ProposalService.instance.allProposals;
    print('[G2-DEBUG] All proposals: ${all.length}');
    for (final p in all) {
      print('[G2-DEBUG]   - "${p.title}" status=${p.status.name} cell=${p.cellId}');
    }
    print('[G2-DEBUG] Searching for status: ${status.name}');

    final matching = all
        .where((p) => p.status == status)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final found = matching.firstOrNull;
    if (found != null) {
      print('[G2-DEBUG] Found: ${found.title} (${found.id})');
    } else {
      print('[G2-DEBUG] None found in status ${status.name}');
    }
    return found;
  }

  /// Finds the newest proposal overall (any status, any title).
  Proposal? _findNewestProposal() {
    print('[G2-DEBUG] Searching for newest proposal (any status)');
    final proposals = List<Proposal>.from(ProposalService.instance.allProposals)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final found = proposals.firstOrNull;
    if (found != null) {
      print('[G2-DEBUG] Found: ${found.title}');
    } else {
      print('[G2-DEBUG] None found');
    }
    return found;
  }

  void _snack(BuildContext context, String msg,
      {bool error = false}) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade700 : Colors.green.shade700,
      duration: const Duration(seconds: 4),
    ));
  }

  // ── Button handlers ──────────────────────────────────────────────────────────

  Future<void> _createTestProposal(BuildContext context) async {
    print('[G2-DEBUG] _createTestProposal called');
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final myPseudonym = IdentityService.instance.currentIdentity?.pseudonym ?? '';

    // Finde erste Zelle in der der User bestätigtes Mitglied ist.
    final cells = CellService.instance.myCells;
    String? cellId;
    for (final cell in cells) {
      final membership = CellService.instance.myMembershipIn(cell.id);
      if (membership != null &&
          membership.isConfirmed &&
          membership.role != MemberRole.pending) {
        cellId = cell.id;
        break;
      }
    }

    if (cellId == null) {
      print('[G2-DEBUG] No cell found');
      _snack(context, 'Erstelle zuerst eine Zelle', error: true);
      return;
    }

    try {
      final proposal = await ProposalService.instance.createDraft(
        cellId: cellId,
        creatorDid: myDid,
        creatorPseudonym: myPseudonym,
        title: 'G2 Test-Antrag ${DateTime.now().toIso8601String().substring(0, 19)}',
        description: 'Dies ist ein automatischer Test-Antrag für G2. '
            'Status wird sofort auf DISCUSSION gesetzt.',
        category: 'Sonstiges',
      );
      print('[G2-DEBUG] Draft created: ${proposal.id}');

      await ProposalService.instance.publishToDiscussion(proposal.id);
      print('[G2-DEBUG] Published to DISCUSSION: ${proposal.id}');

      _snack(context,
          '✅ Test-Antrag erstellt und publiziert: ${proposal.id.substring(0, 8)}…');
    } catch (e) {
      print('[G2-DEBUG] _createTestProposal error: $e');
      _snack(context, '❌ Fehler: $e', error: true);
    }
  }

  Future<void> _startTestVoting(BuildContext context) async {
    print('[G2-DEBUG] _startTestVoting called');
    final p = _findAnyProposal(ProposalStatus.DISCUSSION);
    if (p == null) {
      _snack(context,
          'Kein passender Antrag gefunden (Status: DISCUSSION)',
          error: true);
      return;
    }
    try {
      await ProposalService.instance.startVoting(p.id);
      print('[G2-DEBUG] Voting started: ${p.id}');
      _snack(context, '✅ Voting starten: ${p.title}');
    } catch (e) {
      print('[G2-DEBUG] _startTestVoting error: $e');
      _snack(context, '❌ Fehler: $e', error: true);
    }
  }

  Future<void> _castTestVote(
      BuildContext context, VoteChoice choice, String reasoning) async {
    print('[G2-DEBUG] _castTestVote: $choice');
    final p = _findAnyProposal(ProposalStatus.VOTING);
    if (p == null) {
      _snack(context,
          'Kein passender Antrag gefunden (Status: VOTING)',
          error: true);
      return;
    }
    try {
      await ProposalService.instance.castVote(p.id, choice, reasoning: reasoning);
      print('[G2-DEBUG] Vote cast: $choice on ${p.id}');
      _snack(context, '✅ ${choice.name}: ${p.title}');
    } catch (e) {
      print('[G2-DEBUG] _castTestVote error: $e');
      _snack(context, '❌ Fehler: $e', error: true);
    }
  }

  Future<void> _forceFinalize(BuildContext context) async {
    print('[G2-DEBUG] _forceFinalize called');
    final p = _findAnyProposal(ProposalStatus.VOTING);
    if (p == null) {
      _snack(context,
          'Kein passender Antrag gefunden (Status: VOTING)',
          error: true);
      return;
    }
    try {
      // Voting-Deadline auf jetzt setzen damit Grace-Period sofort endet.
      p.votingEndsAt = DateTime.now().toUtc().subtract(const Duration(seconds: 1));
      p.gracePeriodHours = 0;
      await PodDatabase.instance.upsertProposal(p.id, p.cellId, p.toMap());
      print('[G2-DEBUG] votingEndsAt forced to now, gracePeriodHours=0');

      await ProposalService.instance.processGracePeriodStart(p.id);
      print('[G2-DEBUG] Grace period started');

      await ProposalService.instance.finalizeProposal(p.id);
      print('[G2-DEBUG] Proposal finalized');

      final result = p.resultSummary ?? '?';
      _snack(context, '✅ Finalisiert: ${p.title} → $result '
          '(J:${p.resultYes ?? 0} N:${p.resultNo ?? 0} '
          'E:${p.resultAbstain ?? 0})');
    } catch (e) {
      print('[G2-DEBUG] _forceFinalize error: $e');
      _snack(context, '❌ Fehler: $e', error: true);
    }
  }

  Future<void> _showAuditLog(BuildContext context) async {
    print('[G2-DEBUG] _showAuditLog called');

    // Finde neuesten Antrag (beliebiger Titel, beliebiger Status).
    final p = _findNewestProposal();

    if (p == null) {
      _snack(context, 'Kein Antrag gefunden', error: true);
      return;
    }
    final entries = await ProposalService.instance.getAuditLog(p.id);
    final recent = entries.reversed.take(20).toList();

    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(
          'Audit-Log: ${p.title.substring(0, p.title.length.clamp(0, 30))}…',
          style: const TextStyle(color: Colors.amber, fontSize: 14),
        ),
        content: SizedBox(
          width: 400,
          height: 400,
          child: recent.isEmpty
              ? const Center(
                  child: Text('Keine Einträge',
                      style: TextStyle(color: Colors.white54)))
              : ListView.separated(
                  itemCount: recent.length,
                  separatorBuilder: (_, __) => const Divider(
                      height: 1, color: Colors.white12),
                  itemBuilder: (_, i) {
                    final e = recent[i];
                    final ts = e.timestamp
                        .toLocal()
                        .toIso8601String()
                        .substring(11, 19);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        '[$ts] ${e.eventType.name}\n  → ${e.actorPseudonym.isEmpty ? e.actorDid.substring(0, 12) : e.actorPseudonym}',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 11),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Schließen',
                style: TextStyle(color: Colors.amber)),
          ),
        ],
      ),
    );
  }

  Future<void> _cleanupTestProposals(BuildContext context) async {
    print('[G2-DEBUG] _cleanupTestProposals called');
    final all = ProposalService.instance.allProposals
        .where((p) => p.title.startsWith('G2 Test-Antrag'))
        .toList();

    print('[G2-DEBUG] Cleanup found ${all.length} test proposals');

    if (all.isEmpty) {
      _snack(context, 'Keine Test-Anträge gefunden');
      return;
    }

    int deleted = 0;
    for (final p in all) {
      try {
        print('[G2-DEBUG] Tombstoning and withdrawing test proposal: ${p.id}');

        // 1. Force status to WITHDRAWN so the published Kind-31010 carries
        //    status=WITHDRAWN — peer devices tombstone it on receipt.
        p.status = ProposalStatus.WITHDRAWN;
        p.withdrawnAt = DateTime.now().toUtc();
        await PodDatabase.instance.upsertProposal(p.id, p.cellId, p.toMap());

        // 2. Publish withdrawal event BEFORE local delete so the publish fn
        //    can still read the proposal from _proposals cache.
        await ProposalService.instance.publishProposalWithdrawal(p.id);

        // 3. tombstoneAndDelete: sets tombstone synchronously, removes from
        //    cache, notifies stream, then async DB cleanup.
        await ProposalService.instance.tombstoneAndDelete(p.id);

        deleted++;
      } catch (e) {
        print('[G2-DEBUG] Cleanup error for ${p.id}: $e');
      }
    }

    print('[G2-DEBUG] Cleanup complete: $deleted deleted and tombstoned');
    if (context.mounted) {
      _snack(context, '✅ $deleted Test-Anträge gelöscht und tombstoned');
    }
  }

  Future<void> _confirmDeleteAllProposals(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text(
          'Alle Anträge löschen?',
          style: TextStyle(color: Colors.red),
        ),
        content: const Text(
          'Dies löscht ALLE Anträge, Stimmen, Decision Records '
          'und Audit-Einträge — lokal UND via Withdrawal-Events '
          'auf den Relays. Diese Aktion kann nicht rückgängig '
          'gemacht werden.\n\n'
          'Nur für Test-Zwecke verwenden!',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen',
                style: TextStyle(color: Colors.amber)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade800,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ja, alle löschen'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await _deleteAllProposals(context);
    }
  }

  Future<void> _deleteAllProposals(BuildContext context) async {
    print('[CLEANUP] === Starting full proposal cleanup ===');

    final all = List<Proposal>.from(ProposalService.instance.allProposals);
    print('[CLEANUP] Found ${all.length} proposals to delete');

    if (all.isEmpty) {
      _snack(context, 'Keine Anträge gefunden');
      return;
    }

    int deleted = 0;
    for (final p in all) {
      try {
        print('[CLEANUP] Tombstoning and withdrawing: ${p.id}');

        p.status = ProposalStatus.WITHDRAWN;
        p.withdrawnAt = DateTime.now().toUtc();
        await PodDatabase.instance.upsertProposal(p.id, p.cellId, p.toMap());

        await ProposalService.instance.publishProposalWithdrawal(p.id);
        await ProposalService.instance.tombstoneAndDelete(p.id);

        deleted++;
      } catch (e) {
        print('[CLEANUP] Error for ${p.id}: $e');
      }
    }

    print('[CLEANUP] Done: $deleted proposals deleted and tombstoned');
    if (context.mounted) {
      _snack(context, '✅ $deleted Anträge gelöscht und tombstoned');
    }
  }
}
