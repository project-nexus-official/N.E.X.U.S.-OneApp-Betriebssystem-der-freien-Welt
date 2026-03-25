import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
