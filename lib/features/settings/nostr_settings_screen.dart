import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/transport/nostr/nostr_relay_manager.dart';
import '../../shared/theme/app_theme.dart';
import '../chat/chat_provider.dart';

/// Nostr-Einstellungen: Relays, Keypair, Geohash.
class NostrSettingsScreen extends StatefulWidget {
  const NostrSettingsScreen({super.key});

  @override
  State<NostrSettingsScreen> createState() => _NostrSettingsScreenState();
}

class _NostrSettingsScreenState extends State<NostrSettingsScreen> {
  final _relayCtrl = TextEditingController();

  @override
  void dispose() {
    _relayCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final nostr = provider.nostrTransport;
        final keys = nostr?.keys;
        final relays = nostr?.relayStatuses ?? [];

        return Scaffold(
          appBar: AppBar(title: const Text('Nostr-Netzwerk')),
          body: ListView(
            children: [
              // ── On/Off Toggle ──────────────────────────────────────────────
              SwitchListTile(
                value: provider.nostrEnabled,
                onChanged: (v) => provider.setNostrEnabled(v),
                title: const Text('Nostr aktivieren'),
                subtitle: const Text(
                  'Internet-Fallback wenn keine lokalen Peers erreichbar sind',
                ),
                secondary: Icon(
                  Icons.language,
                  color: provider.nostrEnabled
                      ? Colors.lightBlueAccent
                      : Colors.grey,
                ),
              ),
              const Divider(height: 1),

              // ── Nostr Public Key ───────────────────────────────────────────
              if (keys != null) ...[
                _SectionHeader('Mein Nostr-Schlüssel'),
                ListTile(
                  leading: const Icon(Icons.vpn_key, color: AppColors.gold),
                  title: const Text('Öffentlicher Schlüssel (npub)'),
                  subtitle: Text(
                    keys.npub,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: keys.npub));
                      _snack(context, 'npub kopiert');
                    },
                  ),
                ),
                const Divider(height: 1),
              ],

              // ── Geohash ────────────────────────────────────────────────────
              if (nostr?.currentGeohash != null) ...[
                _SectionHeader('Mein Standort-Kanal'),
                ListTile(
                  leading: const Icon(Icons.location_on,
                      color: Colors.greenAccent),
                  title: const Text('Aktueller Geohash'),
                  subtitle: Text(
                    '${nostr!.currentGeohash!}  (≈ 5 km Radius)',
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 13),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () {
                      Clipboard.setData(
                          ClipboardData(text: nostr.currentGeohash!));
                      _snack(context, 'Geohash kopiert');
                    },
                  ),
                ),
                const Divider(height: 1),
              ],

              // ── Relay list ─────────────────────────────────────────────────
              _SectionHeader('Relays'),
              if (relays.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Keine Relays konfiguriert.',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              ...relays.map((r) => _RelayTile(relay: r)),
              const Divider(height: 1),

              // ── Add relay ──────────────────────────────────────────────────
              _SectionHeader('Eigenen Relay hinzufügen'),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _relayCtrl,
                        style: const TextStyle(
                            color: AppColors.onDark, fontSize: 14),
                        decoration: InputDecoration(
                          hintText: 'wss://mein-relay.de',
                          hintStyle: TextStyle(
                              color: AppColors.onDark.withValues(alpha: 0.4),
                              fontSize: 13),
                          filled: true,
                          fillColor: AppColors.surfaceVariant,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () {
                        final url = _relayCtrl.text.trim();
                        if (url.isNotEmpty &&
                            (url.startsWith('wss://') ||
                                url.startsWith('ws://'))) {
                          provider.addNostrRelay(url);
                          _relayCtrl.clear();
                          _snack(context, 'Relay hinzugefügt');
                          setState(() {});
                        } else {
                          _snack(context,
                              'Ungültige URL (muss mit wss:// beginnen)');
                        }
                      },
                      child: const Text('Hinzufügen'),
                    ),
                  ],
                ),
              ),

              // ── Default relays hint ────────────────────────────────────────
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: Text(
                  'Standard-Relays: relay.damus.io, relay.snort.social, '
                  'nos.lol, relay.nostr.band, nostr.wine',
                  style: TextStyle(color: Colors.grey, fontSize: 11),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }
}

class _RelayTile extends StatelessWidget {
  const _RelayTile({required this.relay});
  final RelayStatus relay;

  @override
  Widget build(BuildContext context) {
    final color = switch (relay.state) {
      RelayState.connected => Colors.greenAccent,
      RelayState.connecting => Colors.amber,
      RelayState.error => Colors.redAccent,
      RelayState.disconnected => Colors.grey,
    };

    final label = switch (relay.state) {
      RelayState.connected =>
        'Verbunden${relay.latencyMs != null ? ' (${relay.latencyMs} ms)' : ''}',
      RelayState.connecting => 'Verbinde…',
      RelayState.error => 'Fehler',
      RelayState.disconnected => 'Getrennt',
    };

    final domain = _shortUrl(relay.url);

    return ListTile(
      leading: CircleAvatar(
        radius: 5,
        backgroundColor: color,
      ),
      title: Text(domain, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        label,
        style: TextStyle(color: color, fontSize: 11),
      ),
    );
  }

  String _shortUrl(String url) {
    return url
        .replaceAll('wss://', '')
        .replaceAll('ws://', '');
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
