import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/storage/pod_database.dart';
import '../../core/storage/retention_service.dart';
import '../../shared/theme/app_theme.dart';
import '../chat/chat_provider.dart';
import 'nostr_settings_screen.dart';

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
          _NachrichtenSection(chatProvider: context.read<ChatProvider>()),
          const Divider(height: 1),
          _SectionHeader('Info'),
          ListTile(
            leading: const Icon(Icons.info_outline, color: AppColors.gold),
            title: const Text('NEXUS OneApp'),
            subtitle: const Text('Phase 1a – AETHER Protokoll'),
            onTap: () => _showAbout(context),
          ),
        ],
      ),
    );
  }

  void _showAbout(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: 'NEXUS OneApp',
      applicationVersion: '0.1.0',
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
