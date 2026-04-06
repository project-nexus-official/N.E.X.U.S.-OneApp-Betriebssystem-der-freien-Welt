import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/identity/identity_service.dart';
import '../../features/chat/chat_provider.dart';
import '../../services/backup_service.dart';
import '../../shared/theme/app_theme.dart';

/// Shown after a successful seed-phrase restore.
///
/// Searches the backup directory for files belonging to this identity and
/// offers to import them.  Skips itself (navigates to [/home]) if no
/// compatible backup is found.
class RestoreBackupScreen extends StatefulWidget {
  const RestoreBackupScreen({super.key});

  @override
  State<RestoreBackupScreen> createState() => _RestoreBackupScreenState();
}

class _RestoreBackupScreenState extends State<RestoreBackupScreen> {
  bool _searching = true;
  List<BackupFileInfo> _backups = [];
  bool _restoring = false;
  String? _error;
  RestoreResult? _result;

  @override
  void initState() {
    super.initState();
    _searchForBackups();
  }

  Future<void> _searchForBackups() async {
    final found = await BackupService.instance.findBackups();
    if (!mounted) return;
    if (found.isEmpty) {
      // No backup found → go straight to home.
      context.go('/home');
      return;
    }
    setState(() {
      _searching = false;
      _backups   = found;
    });
  }

  Future<void> _restore(BackupFileInfo info) async {
    final mnemonic = await IdentityService.instance.loadSeedPhrase();
    if (mnemonic == null || !mounted) return;
    setState(() {
      _restoring = true;
      _error     = null;
    });
    final chat = mounted ? context.read<ChatProvider>() : null;
    final result = await BackupService.instance.restoreFromFile(
      info.path,
      mnemonic,
      onRestored: () async {
        print('[RESTORE] Backup applied, triggering subscription reset...');
        chat?.nostrTransport?.resetSubscriptions();
        print('[RESTORE] Subscriptions successfully reset');
      },
    );
    if (!mounted) return;
    if (result.success) {
      setState(() {
        _restoring = false;
        _result    = result;
      });
    } else {
      setState(() {
        _restoring = false;
        _error     = result.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_searching) {
      return const Scaffold(
        backgroundColor: AppColors.deepBlue,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: AppColors.gold),
              SizedBox(height: 20),
              Text('Backup wird gesucht…',
                  style: TextStyle(color: AppColors.onDark)),
            ],
          ),
        ),
      );
    }

    if (_result != null) return _buildSuccess(_result!);
    return _buildFound();
  }

  Widget _buildFound() {
    final best = _backups.first;
    final d    = best.createdAt;
    final dateStr =
        '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

    return Scaffold(
      backgroundColor: AppColors.deepBlue,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.backup_outlined,
                  color: AppColors.gold, size: 56),
              const SizedBox(height: 20),
              const Text(
                'Backup gefunden!',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.gold,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Ein Backup vom $dateStr wurde gefunden.',
                textAlign: TextAlign.center,
                style:
                    const TextStyle(color: AppColors.onDark, fontSize: 14),
              ),
              const SizedBox(height: 28),
              // Backup summary
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: AppColors.gold.withValues(alpha: 0.4)),
                ),
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 16),
                child: Column(
                  children: [
                    _summaryRow(
                        Icons.people_outline,
                        'Kontakte',
                        '${best.contactCount}'),
                    const Divider(height: 1),
                    _summaryRow(
                        Icons.tag,
                        'Kanäle',
                        '${best.channelCount}'),
                    const Divider(height: 1),
                    _summaryRow(
                        Icons.groups_outlined,
                        'Zellen',
                        '${best.cellCount}'),
                    const Divider(height: 1),
                    _summaryRow(
                        Icons.menu_book_outlined,
                        'Grundsätze',
                        best.hasPrinciples ? '✓' : '–'),
                  ],
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
                    style: const TextStyle(
                        color: Colors.redAccent, fontSize: 13),
                  ),
                ),
              ],
              const SizedBox(height: 28),
              ElevatedButton(
                onPressed: _restoring ? null : () => _restore(best),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.gold,
                  foregroundColor: AppColors.deepBlue,
                  disabledBackgroundColor:
                      AppColors.gold.withValues(alpha: 0.5),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: _restoring
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.deepBlue),
                      )
                    : const Text(
                        'Backup wiederherstellen',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold),
                      ),
              ),
              const SizedBox(height: 14),
              TextButton(
                onPressed: _restoring ? null : () => context.go('/home'),
                child: const Text(
                  'Ohne Backup fortfahren',
                  style: TextStyle(
                    color: AppColors.onDark,
                    decoration: TextDecoration.underline,
                    decorationColor: AppColors.onDark,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSuccess(RestoreResult result) {
    return Scaffold(
      backgroundColor: AppColors.deepBlue,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Center(
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
                'Wiederhergestellt!',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.gold,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '${result.restoredContacts} Kontakte, '
                '${result.restoredChannels} Kanäle und '
                '${result.restoredCells} Zellen wiederhergestellt.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.onDark, fontSize: 15, height: 1.5),
              ),
              const Spacer(),
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
                  'Zum Dashboard',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _summaryRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Icon(icon, color: AppColors.gold, size: 20),
          const SizedBox(width: 12),
          Text(label,
              style: const TextStyle(
                  color: AppColors.onDark, fontSize: 14)),
          const Spacer(),
          Text(value,
              style: const TextStyle(
                color: AppColors.gold,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              )),
        ],
      ),
    );
  }
}
