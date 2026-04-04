import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../services/backup_service.dart';
import '../../shared/theme/app_theme.dart';

/// Shown once after the Principles flow for new users.
///
/// Lets the user configure (or skip) the automatic encrypted backup.
class BackupSetupScreen extends StatefulWidget {
  const BackupSetupScreen({super.key});

  @override
  State<BackupSetupScreen> createState() => _BackupSetupScreenState();
}

class _BackupSetupScreenState extends State<BackupSetupScreen> {
  bool _autoBackup = true;
  bool _loading = false;
  bool _done = false;
  String? _savedPath;
  String? _error;

  String get _platformFolderLabel {
    if (Platform.isAndroid) return 'Externer App-Speicher (sichtbar im Datei-Manager)';
    if (Platform.isWindows) return 'Dokumente-Ordner';
    return 'Dokumente-Ordner';
  }

  Future<void> _setup() async {
    setState(() {
      _loading = true;
      _error   = null;
    });
    await BackupService.instance.markSetupSeen(autoBackupEnabled: _autoBackup);
    final result = await BackupService.instance.createBackup();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result.success) {
        _done       = true;
        _savedPath  = result.path;
      } else {
        _error = result.error;
      }
    });
  }

  Future<void> _skipForNow() async {
    await BackupService.instance.markSetupSeen(autoBackupEnabled: false);
    if (mounted) context.go('/home');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.deepBlue,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: _done ? _buildSuccess() : _buildSetup(),
        ),
      ),
    );
  }

  Widget _buildSetup() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        const Icon(Icons.shield_outlined, color: AppColors.gold, size: 56),
        const SizedBox(height: 20),
        const Text(
          'Deine Daten sichern',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.gold,
            fontSize: 26,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'Die OneApp speichert alles auf deinem Gerät — nirgendwo sonst. '
          'Damit du bei einem Gerätewechsel oder einer Neuinstallation nichts '
          'verlierst, kann die App regelmäßig ein verschlüsseltes Backup erstellen.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.onDark, fontSize: 14, height: 1.6),
        ),
        const SizedBox(height: 28),
        // Recommended storage option
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.gold, width: 1.5),
          ),
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Text('📁', style: TextStyle(fontSize: 26)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Empfohlen',
                      style: TextStyle(
                        color: AppColors.gold,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _platformFolderLabel,
                      style: const TextStyle(
                        color: AppColors.onDark,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Sichtbar im Datei-Manager – kopiere es in die Cloud für maximale Sicherheit.',
                      style: TextStyle(
                        color: AppColors.onDark,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        // Info box
        Container(
          decoration: BoxDecoration(
            color: AppColors.gold.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: AppColors.gold.withValues(alpha: 0.3)),
          ),
          padding: const EdgeInsets.all(14),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('💡', style: TextStyle(fontSize: 16)),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Das Backup ist verschlüsselt — nur mit deiner Seed Phrase '
                  'kann es geöffnet werden. Selbst wenn jemand die Datei findet, '
                  'kann er nichts damit anfangen.',
                  style: TextStyle(
                      color: AppColors.onDark, fontSize: 12, height: 1.5),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        // Auto-backup toggle
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SwitchListTile(
            title: const Text(
              'Automatisch alle 24 Stunden sichern',
              style: TextStyle(color: AppColors.onDark, fontSize: 14),
            ),
            subtitle: const Text(
              'Empfohlen',
              style: TextStyle(color: AppColors.gold, fontSize: 12),
            ),
            value: _autoBackup,
            onChanged: (v) => setState(() => _autoBackup = v),
            activeColor: AppColors.gold,
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF3D0000),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'Fehler: $_error',
              style:
                  const TextStyle(color: Colors.redAccent, fontSize: 13),
            ),
          ),
        ],
        const SizedBox(height: 28),
        ElevatedButton(
          onPressed: _loading ? null : _setup,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.gold,
            foregroundColor: AppColors.deepBlue,
            disabledBackgroundColor:
                AppColors.gold.withValues(alpha: 0.5),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          child: _loading
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.deepBlue),
                )
              : const Text(
                  'Backup einrichten',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
        ),
        const SizedBox(height: 14),
        TextButton(
          onPressed: _loading ? null : _skipForNow,
          child: const Text(
            'Später einrichten',
            style: TextStyle(
              color: AppColors.onDark,
              decoration: TextDecoration.underline,
              decorationColor: AppColors.onDark,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSuccess() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 60),
        Container(
          alignment: Alignment.center,
          child: Container(
            width: 90,
            height: 90,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.gold.withValues(alpha: 0.15),
              border: Border.all(color: AppColors.gold, width: 2),
            ),
            child: const Icon(Icons.check_rounded,
                color: AppColors.gold, size: 50),
          ),
        ),
        const SizedBox(height: 28),
        const Text(
          'Geschafft!',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.gold,
            fontSize: 26,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Dein erstes Backup wurde erstellt.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.onDark, fontSize: 15),
        ),
        if (_savedPath != null) ...[
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Icon(Icons.folder_outlined,
                    color: AppColors.gold, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _savedPath!,
                    style: const TextStyle(
                        color: AppColors.onDark,
                        fontSize: 11,
                        fontFamily: 'monospace'),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 3,
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 40),
        ElevatedButton(
          onPressed: () => context.go('/home'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.gold,
            foregroundColor: AppColors.deepBlue,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text(
            'Weiter zum Dashboard',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
