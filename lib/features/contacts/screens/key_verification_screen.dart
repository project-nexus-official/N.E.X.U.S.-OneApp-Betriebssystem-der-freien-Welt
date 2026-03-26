import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nexus_oneapp/core/contacts/contact.dart';
import 'package:nexus_oneapp/core/contacts/contact_service.dart';
import 'package:nexus_oneapp/core/crypto/encryption_keys.dart';
import 'package:nexus_oneapp/shared/theme/app_theme.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Side-by-side key fingerprint screen (Signal Safety Numbers style).
class KeyVerificationScreen extends StatelessWidget {
  const KeyVerificationScreen({super.key, required this.peerDid});

  final String peerDid;

  @override
  Widget build(BuildContext context) {
    final myPubHex = EncryptionKeys.instance.publicKeyHex ?? '';
    final contact = ContactService.instance.findByDid(peerDid);
    final peerPubHex = contact?.encryptionPublicKey ?? '';

    final myFingerprint = _fingerprint(myPubHex);
    final peerFingerprint = _fingerprint(peerPubHex);
    final allMatch = myPubHex.isNotEmpty && peerPubHex.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Schlüssel verifizieren')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Instructions
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              'Vergleiche diese Sicherheitsnummern persönlich oder per Videoanruf '
              'mit deinem Kontakt. Stimmen beide überein, ist die Verbindung sicher.',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ),
          const SizedBox(height: 24),

          // My key
          _KeyCard(
            title: 'Dein Schlüssel',
            pubHex: myPubHex,
            fingerprint: myFingerprint,
          ),
          const SizedBox(height: 16),

          // Peer key
          _KeyCard(
            title: contact?.pseudonym != null
                ? 'Schlüssel von ${contact!.pseudonym}'
                : 'Schlüssel des Kontakts',
            pubHex: peerPubHex,
            fingerprint: peerFingerprint,
            missing: peerPubHex.isEmpty,
          ),

          if (!allMatch) ...[
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber, color: Colors.orange, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Kein Verschlüsselungsschlüssel für diesen Kontakt vorhanden. '
                      'Nachrichten werden unverschlüsselt gesendet.',
                      style: TextStyle(color: Colors.orange, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Formats pubHex as 8 groups of 4 hex chars: "A1B2 C3D4 …"
  static String _fingerprint(String hex) {
    if (hex.length < 64) return hex.isEmpty ? '—' : hex;
    final groups = <String>[];
    for (var i = 0; i < 64; i += 4) {
      groups.add(hex.substring(i, i + 4).toUpperCase());
    }
    return groups.join(' ');
  }
}

class _KeyCard extends StatelessWidget {
  const _KeyCard({
    required this.title,
    required this.pubHex,
    required this.fingerprint,
    this.missing = false,
  });

  final String title;
  final String pubHex;
  final String fingerprint;
  final bool missing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: missing ? Colors.orange.withValues(alpha: 0.4) : AppColors.gold.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                missing ? Icons.lock_open : Icons.lock,
                color: missing ? Colors.orange : AppColors.gold,
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: AppColors.gold,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (!missing) ...[
            // QR code
            Center(
              child: QrImageView(
                data: pubHex,
                version: QrVersions.auto,
                size: 140,
                backgroundColor: Colors.white,
                padding: const EdgeInsets.all(6),
              ),
            ),
            const SizedBox(height: 12),
          ],
          // Fingerprint display
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: pubHex));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Schlüssel kopiert')),
              );
            },
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                fingerprint,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  color: AppColors.onDark,
                  fontSize: 13,
                  height: 1.6,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
