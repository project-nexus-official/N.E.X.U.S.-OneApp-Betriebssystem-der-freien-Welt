import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/identity/identity_service.dart';
import '../../shared/theme/app_theme.dart';
import 'channel_invite_payload.dart';
import 'group_channel.dart';

/// Bottom sheet that lets users share a channel via QR code or a copied link.
///
/// For public / private+visible channels: shows QR code without a token.
/// For private+hidden channels (admin only): shows QR code with inviteToken
/// (= channelSecret) embedded, granting direct access.
class ChannelShareSheet extends StatelessWidget {
  const ChannelShareSheet({super.key, required this.channel});

  final GroupChannel channel;

  @override
  Widget build(BuildContext context) {
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final isAdmin = channel.createdBy == myDid;
    final isHidden = !channel.isPublic && !channel.isDiscoverable;

    // Include the channelSecret only when the admin shares a hidden channel.
    final includeToken = isAdmin && isHidden && channel.channelSecret != null;

    final payload = ChannelInvitePayload(
      channelId: channel.id,
      channelName: channel.name,
      nostrTag: channel.nostrTag,
      isPublic: channel.isPublic,
      isDiscoverable: channel.isDiscoverable,
      inviteToken: includeToken ? channel.channelSecret : null,
    );

    final qrData = payload.toJsonString();
    final deepLink = payload.toDeepLink();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Header ──────────────────────────────────────────────────────
            Row(
              children: [
                Icon(
                  channel.isPublic ? Icons.tag : Icons.lock,
                  color: AppColors.gold,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    channel.name,
                    style: const TextStyle(
                      color: AppColors.gold,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.grey),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            Text(
              payload.accessLabel,
              style: TextStyle(color: Colors.grey[500], fontSize: 12),
            ),
            if (includeToken) ...[
              const SizedBox(height: 4),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'QR-Code enthält Einladungs-Token',
                  style: TextStyle(color: AppColors.gold, fontSize: 11),
                ),
              ),
            ],
            const SizedBox(height: 20),

            // ── QR Code ─────────────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.gold, width: 2),
              ),
              child: QrImageView(
                data: qrData,
                version: QrVersions.auto,
                size: 220,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: AppColors.deepBlue,
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: AppColors.deepBlue,
                ),
              ),
            ),
            const SizedBox(height: 24),

            // ── Action Buttons ───────────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Link kopieren'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.gold,
                      side: const BorderSide(color: AppColors.gold),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: deepLink));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Link in die Zwischenablage kopiert'),
                            backgroundColor: AppColors.gold,
                          ),
                        );
                        Navigator.of(context).pop();
                      }
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.share, size: 18),
                    label: const Text('Teilen'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.gold,
                      foregroundColor: AppColors.deepBlue,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () async {
                      Navigator.of(context).pop();
                      await Share.share(
                        deepLink,
                        subject: 'NEXUS-Kanal: ${channel.name}',
                      );
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
