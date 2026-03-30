import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/update_service.dart';
import '../theme/app_theme.dart';

/// Shows the update details bottom sheet.
///
/// Contains release notes, a "Download" button, a "Later" button and a
/// "Skip this version" button.  All three paths call [onDismiss].
Future<void> showUpdateBottomSheet(
  BuildContext context,
  UpdateInfo info,
) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _UpdateSheet(info: info),
  );
}

class _UpdateSheet extends StatelessWidget {
  final UpdateInfo info;

  const _UpdateSheet({required this.info});

  Future<void> _download(BuildContext context) async {
    final uri = Uri.parse(info.downloadUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Download-Link konnte nicht geöffnet werden.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasNotes = info.releaseNotes.trim().isNotEmpty;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Header ──────────────────────────────────────────────────────
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.gold.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.system_update_outlined,
                      color: AppColors.gold, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Update verfügbar',
                        style: TextStyle(
                          color: AppColors.gold,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        'Neue Version: ${info.version}',
                        style: TextStyle(
                          color: AppColors.onDark.withValues(alpha: 0.7),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            // ── Release notes ───────────────────────────────────────────────
            if (hasNotes) ...[
              const SizedBox(height: 16),
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.deepBlue,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: AppColors.gold.withValues(alpha: 0.2)),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    info.releaseNotes,
                    style: TextStyle(
                      color: AppColors.onDark.withValues(alpha: 0.85),
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            ],

            const SizedBox(height: 20),

            // ── Download button ─────────────────────────────────────────────
            ElevatedButton.icon(
              onPressed: () => _download(context),
              icon: const Icon(Icons.download_outlined),
              label: const Text(
                'Jetzt herunterladen',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.gold,
                foregroundColor: AppColors.deepBlue,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),

            const SizedBox(height: 8),

            // ── Later ───────────────────────────────────────────────────────
            TextButton(
              onPressed: () {
                UpdateService.instance.dismissForSession();
                Navigator.pop(context);
              },
              child: const Text(
                'Später',
                style: TextStyle(color: AppColors.gold),
              ),
            ),

            // ── Skip version ────────────────────────────────────────────────
            TextButton(
              onPressed: () {
                UpdateService.instance.skipVersion(info.version);
                Navigator.pop(context);
              },
              style: TextButton.styleFrom(foregroundColor: Colors.grey),
              child: Text('Version ${info.version} überspringen'),
            ),
          ],
        ),
      ),
    );
  }
}
