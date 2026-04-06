import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as pkg_crypto;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/contacts/contact_service.dart';
import '../core/identity/bip39.dart';
import '../core/identity/identity_service.dart';
import '../core/storage/pod_encryption.dart';
import '../features/chat/group_channel_service.dart';
import '../features/governance/cell_service.dart';
import '../services/notification_settings_service.dart';
import '../services/principles_service.dart';

// ── Keys ──────────────────────────────────────────────────────────────────────

const _kAutoBackup   = 'nexus_backup_auto';
const _kLastBackupAt = 'nexus_backup_last_at';
const _kSetupSeen    = 'nexus_backup_setup_seen';
const _kLastHash     = 'nexus_backup_last_hash';

// ── Public data types ─────────────────────────────────────────────────────────

/// Metadata about a backup file on disk.
class BackupFileInfo {
  final String path;
  final DateTime createdAt;
  final int contactCount;
  final int channelCount;
  final int cellCount;
  final bool hasPrinciples;

  const BackupFileInfo({
    required this.path,
    required this.createdAt,
    required this.contactCount,
    required this.channelCount,
    required this.cellCount,
    required this.hasPrinciples,
  });

  String get filename => path.split(Platform.pathSeparator).last;
}

/// Result of a backup creation attempt.
class BackupResult {
  final bool success;
  final String? path;
  final String? error;

  const BackupResult.ok(String this.path) : success = true, error = null;
  const BackupResult.fail(String this.error) : success = false, path = null;
}

/// Result of a restore attempt.
class RestoreResult {
  final bool success;
  final int restoredContacts;
  final int restoredChannels;
  final int restoredCells;
  final String? error;

  const RestoreResult({
    required this.success,
    this.restoredContacts = 0,
    this.restoredChannels = 0,
    this.restoredCells = 0,
    this.error,
  });
}

// ── Pure helpers (exported for tests) ─────────────────────────────────────────

/// Derives the 32-byte backup encryption key from a BIP-39 mnemonic.
///
/// Uses SHA-256(seed64 || "nexus-backup-v1"), consistent with the pod key
/// derivation pattern used throughout the codebase.
Uint8List deriveBackupKeySync(String mnemonic) {
  final seed64 = Bip39.mnemonicToSeed(mnemonic);
  final digest = pkg_crypto.sha256.convert([
    ...seed64,
    ...utf8.encode('nexus-backup-v1'),
  ]);
  return Uint8List.fromList(digest.bytes);
}

/// Generates a content hash of the serialisable backup payload for change
/// detection.  Excludes [createdAt] so equal data produces equal hashes.
String hashBackupPayload(Map<String, dynamic> payload) {
  final stable = Map<String, dynamic>.from(payload)..remove('createdAt');
  final digest = pkg_crypto.sha256.convert(utf8.encode(jsonEncode(stable)));
  return digest.toString();
}

// ── BackupService ─────────────────────────────────────────────────────────────

/// Manages automatic and manual encrypted backups of user data.
///
/// Backed up: contacts, channel memberships, cell memberships, profile
/// settings, principles state, notification settings.
///
/// NOT backed up: seed phrase / private keys (security), messages,
/// images, voice notes (size).
///
/// Encryption: AES-256-GCM with a key derived from the seed phrase via
/// SHA-256(seed64 || "nexus-backup-v1").  Only the seed phrase holder can
/// decrypt the file.
class BackupService {
  BackupService._();
  static final instance = BackupService._();

  bool _autoBackupEnabled = true;
  bool _setupSeen = false;
  DateTime? _lastBackupAt;
  String? _lastBackupPath;
  Timer? _timer;

  // Injected directory for tests – null means use the real platform path.
  Directory? _testDirectory;

  bool get autoBackupEnabled => _autoBackupEnabled;
  bool get setupSeen => _setupSeen;
  DateTime? get lastBackupAt => _lastBackupAt;
  String? get lastBackupPath => _lastBackupPath;

  /// Whether a backup reminder banner should be shown on the Dashboard.
  bool get shouldShowReminder {
    if (_setupSeen) return false;
    return true;
  }

  /// Whether the most recent backup is older than [hours].
  bool isOlderThan({required int hours}) {
    if (_lastBackupAt == null) return true;
    return DateTime.now().difference(_lastBackupAt!) >
        Duration(hours: hours);
  }

  // ── Init ───────────────────────────────────────────────────────────────────

  /// Loads persisted state and starts the periodic backup timer.
  /// Call inside [initServicesAfterIdentity].
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _autoBackupEnabled = prefs.getBool(_kAutoBackup) ?? true;
      _setupSeen         = prefs.getBool(_kSetupSeen)  ?? false;
      final ts = prefs.getString(_kLastBackupAt);
      if (ts != null) _lastBackupAt = DateTime.tryParse(ts);
      // Find most recent backup file to populate _lastBackupPath.
      final files = await findBackups();
      if (files.isNotEmpty) _lastBackupPath = files.first.path;
    } catch (e) {
      debugPrint('[BACKUP] init error: $e');
    }
    _schedulePeriodicBackup();
    // First backup: 1 hour after first setup.
    if (_lastBackupAt == null && _autoBackupEnabled) {
      Future.delayed(const Duration(hours: 1), _maybeAutoBackup);
    }
  }

  /// Injects a test directory so tests don't touch the filesystem.
  @visibleForTesting
  void setTestDirectory(Directory dir) => _testDirectory = dir;

  // ── Setup ──────────────────────────────────────────────────────────────────

  Future<void> markSetupSeen({required bool autoBackupEnabled}) async {
    _setupSeen         = true;
    _autoBackupEnabled = autoBackupEnabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSetupSeen, true);
      await prefs.setBool(_kAutoBackup, autoBackupEnabled);
    } catch (e) {
      debugPrint('[BACKUP] markSetupSeen error: $e');
    }
    if (autoBackupEnabled) _schedulePeriodicBackup();
  }

  Future<void> setAutoBackupEnabled(bool value) async {
    _autoBackupEnabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAutoBackup, value);
    } catch (e) {
      debugPrint('[BACKUP] setAutoBackup error: $e');
    }
    if (value) {
      _schedulePeriodicBackup();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  // ── Backup ─────────────────────────────────────────────────────────────────

  /// Creates an encrypted backup immediately.  Returns the path on success.
  Future<BackupResult> createBackup() async {
    try {
      final mnemonic = await IdentityService.instance.loadSeedPhrase();
      if (mnemonic == null) {
        return const BackupResult.fail('Keine Seed Phrase gefunden.');
      }

      final payload = _collectData();
      // Skip if content hasn't changed.
      final hash = hashBackupPayload(payload);
      final prefs = await SharedPreferences.getInstance();
      final lastHash = prefs.getString(_kLastHash);
      if (hash == lastHash && _lastBackupAt != null) {
        debugPrint('[BACKUP] No changes since last backup, skipping.');
        return BackupResult.ok(_lastBackupPath ?? '');
      }

      payload['createdAt'] = DateTime.now().toUtc().toIso8601String();
      final key = deriveBackupKeySync(mnemonic);
      final encrypted = await PodEncryption.encrypt(jsonEncode(payload), key);

      final dir = await _backupDirectory();
      await dir.create(recursive: true);

      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('.', '')
          .replaceAll('T', '_')
          .substring(0, 15);
      final file = File('${dir.path}${Platform.pathSeparator}nexus_backup_$ts.enc');
      await file.writeAsString(encrypted);

      _lastBackupAt   = DateTime.now();
      _lastBackupPath = file.path;
      await prefs.setString(_kLastBackupAt, _lastBackupAt!.toIso8601String());
      await prefs.setString(_kLastHash, hash);

      await _pruneOldBackups(dir);

      debugPrint('[BACKUP] Saved to ${file.path}');
      return BackupResult.ok(file.path);
    } catch (e, st) {
      debugPrint('[BACKUP] createBackup error: $e\n$st');
      return BackupResult.fail('$e');
    }
  }

  // ── Discovery ──────────────────────────────────────────────────────────────

  /// Lists backup files in the backup directory, sorted newest first.
  Future<List<BackupFileInfo>> findBackups() async {
    try {
      final dir = await _backupDirectory();
      if (!dir.existsSync()) return [];
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.enc'))
          .toList()
        ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      final result = <BackupFileInfo>[];
      for (final file in files) {
        final info = await _peekBackupFile(file.path);
        if (info != null) result.add(info);
      }
      return result;
    } catch (e) {
      debugPrint('[BACKUP] findBackups error: $e');
      return [];
    }
  }

  /// Returns preview info for a backup file without restoring.
  /// Returns null if the file cannot be decrypted (wrong key / corrupted).
  Future<BackupFileInfo?> previewBackup(String path, String mnemonic) async {
    try {
      final key = deriveBackupKeySync(mnemonic);
      final encrypted = await File(path).readAsString();
      final plain = await PodEncryption.decrypt(encrypted, key);
      final data = jsonDecode(plain) as Map<String, dynamic>;
      return _backupInfoFromData(path, data);
    } catch (_) {
      return null;
    }
  }

  // ── Restore ────────────────────────────────────────────────────────────────

  /// Decrypts and merges the backup at [path] into the running services.
  ///
  /// Merge semantics: existing data is NEVER overwritten; only missing items
  /// are added.
  /// [onRestored] is called after all data has been merged into memory.
  /// Use it to trigger side-effects that require a live context, e.g.
  /// resetting Nostr subscriptions via `ChatProvider`.
  Future<RestoreResult> restoreFromFile(
    String path,
    String mnemonic, {
    Future<void> Function()? onRestored,
  }) async {
    try {
      final key = deriveBackupKeySync(mnemonic);
      final encrypted = await File(path).readAsString();
      final plain = await PodEncryption.decrypt(encrypted, key);
      final data = jsonDecode(plain) as Map<String, dynamic>;
      final result = await _applyBackup(data);
      if (result.success && onRestored != null) {
        await onRestored();
      }
      return result;
    } catch (e) {
      debugPrint('[BACKUP] restoreFromFile error: $e');
      return RestoreResult(success: false, error: '$e');
    }
  }

  // ── Internals ─────────────────────────────────────────────────────────────

  Map<String, dynamic> _collectData() {
    final identity = IdentityService.instance.currentIdentity;
    final principles = PrinciplesService.instance;
    final notif = NotificationSettingsService.instance;

    // Contacts: all (including blocked, so restore is complete).
    final allContacts = [
      ...ContactService.instance.contacts,
      ...ContactService.instance.blockedContacts,
    ];

    return {
      'version': 1,
      'did': identity?.did ?? '',
      'pseudonym': identity?.pseudonym ?? '',
      'contacts': allContacts.map((c) {
        final j = c.toJson();
        j.remove('profileImage'); // don't backup local file paths
        return j;
      }).toList(),
      'channels': GroupChannelService.instance.joinedChannels
          .map((ch) => ch.toJson())
          .toList(),
      'cells': CellService.instance.myCells
          .map((cell) => cell.toJson())
          .toList(),
      'principles': {
        'hasSeen': principles.hasSeen,
        'isAccepted': principles.isAccepted,
        'acceptedAt': principles.acceptedAt?.toIso8601String(),
      },
      'settings': {
        'notificationsEnabled': notif.enabled,
        'showPreview': notif.showPreview,
        'broadcastEnabled': notif.broadcastEnabled,
        'silentMode': notif.silentMode,
        'dndEnabled': notif.dndEnabled,
        'autoBackupEnabled': _autoBackupEnabled,
      },
    };
  }

  Future<RestoreResult> _applyBackup(Map<String, dynamic> data) async {
    int restoredContacts = 0;
    int restoredChannels = 0;
    int restoredCells = 0;

    // Contacts: merge by DID.
    final contactsJson = data['contacts'] as List<dynamic>? ?? [];
    final existingDids =
        {...ContactService.instance.contacts.map((c) => c.did),
         ...ContactService.instance.blockedContacts.map((c) => c.did)};
    for (final cJson in contactsJson) {
      final map = Map<String, dynamic>.from(cJson as Map);
      final did = map['did'] as String? ?? '';
      if (did.isEmpty || existingDids.contains(did)) continue;
      await ContactService.instance.addContactFromBackup(map);
      restoredContacts++;
    }

    // Channels: merge by ID.
    final channelsJson = data['channels'] as List<dynamic>? ?? [];
    final existingChannelIds = GroupChannelService.instance.joinedChannels
        .map((ch) => ch.id)
        .toSet();
    for (final chJson in channelsJson) {
      final map = Map<String, dynamic>.from(chJson as Map);
      final id = map['id'] as String? ?? '';
      if (id.isEmpty || existingChannelIds.contains(id)) continue;
      await GroupChannelService.instance.restoreFromBackup(map);
      restoredChannels++;
    }

    // Cells: merge by ID.
    final cellsJson = data['cells'] as List<dynamic>? ?? [];
    final existingCellIds =
        CellService.instance.myCells.map((c) => c.id).toSet();
    for (final cellJson in cellsJson) {
      final map = Map<String, dynamic>.from(cellJson as Map);
      final id = map['id'] as String? ?? '';
      if (id.isEmpty || existingCellIds.contains(id)) continue;
      await CellService.instance.restoreFromBackup(map);
      restoredCells++;
    }

    // Principles: only restore if user hasn't already gone through the flow.
    final principlesData = data['principles'] as Map<String, dynamic>?;
    if (principlesData != null && !PrinciplesService.instance.hasSeen) {
      await PrinciplesService.instance.restoreFromBackup(principlesData);
    }

    print('[RESTORE] Backup applied: $restoredContacts contacts, '
        '$restoredChannels channels, $restoredCells cells restored');

    return RestoreResult(
      success: true,
      restoredContacts: restoredContacts,
      restoredChannels: restoredChannels,
      restoredCells: restoredCells,
    );
  }

  // ── Filesystem ────────────────────────────────────────────────────────────

  Future<Directory> _backupDirectory() async {
    if (_testDirectory != null) return _testDirectory!;
    if (Platform.isAndroid) {
      try {
        final ext = await getExternalStorageDirectory();
        if (ext != null) {
          return Directory('${ext.path}/nexus_backups');
        }
      } catch (_) {}
      // Fallback: internal documents (won't survive reinstall but always works).
      final docs = await getApplicationDocumentsDirectory();
      return Directory('${docs.path}/nexus_backups');
    } else {
      // Windows / Linux / macOS / iOS: documents directory.
      final docs = await getApplicationDocumentsDirectory();
      return Directory('${docs.path}/nexus_backups');
    }
  }

  /// Keep at most [maxCount] backups, deleting the oldest.
  Future<void> _pruneOldBackups(Directory dir, {int maxCount = 3}) async {
    try {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.enc'))
          .toList()
        ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      for (int i = maxCount; i < files.length; i++) {
        await files[i].delete();
        debugPrint('[BACKUP] Pruned old backup: ${files[i].path}');
      }
    } catch (e) {
      debugPrint('[BACKUP] pruneOldBackups error: $e');
    }
  }

  Future<BackupFileInfo?> _peekBackupFile(String path) async {
    try {
      final mnemonic = await IdentityService.instance.loadSeedPhrase();
      if (mnemonic == null) return null;
      final key = deriveBackupKeySync(mnemonic);
      final encrypted = await File(path).readAsString();
      final plain = await PodEncryption.decrypt(encrypted, key);
      final data = jsonDecode(plain) as Map<String, dynamic>;
      return _backupInfoFromData(path, data);
    } catch (_) {
      // File belongs to a different identity – skip.
      return null;
    }
  }

  BackupFileInfo _backupInfoFromData(String path, Map<String, dynamic> data) {
    final contacts = (data['contacts'] as List<dynamic>?)?.length ?? 0;
    final channels = (data['channels'] as List<dynamic>?)?.length ?? 0;
    final cells    = (data['cells']    as List<dynamic>?)?.length ?? 0;
    final principles = data['principles'] as Map<String, dynamic>?;
    final ts = data['createdAt'] as String?;
    return BackupFileInfo(
      path: path,
      createdAt: ts != null ? (DateTime.tryParse(ts) ?? DateTime.fromMillisecondsSinceEpoch(0)) : DateTime.fromMillisecondsSinceEpoch(0),
      contactCount: contacts,
      channelCount: channels,
      cellCount: cells,
      hasPrinciples: principles != null,
    );
  }

  // ── Periodic timer ────────────────────────────────────────────────────────

  void _schedulePeriodicBackup() {
    _timer?.cancel();
    if (!_autoBackupEnabled) return;
    _timer = Timer.periodic(const Duration(hours: 24), (_) => _maybeAutoBackup());
  }

  Future<void> _maybeAutoBackup() async {
    if (!_autoBackupEnabled) return;
    if (!IdentityService.instance.hasIdentity) return;
    debugPrint('[BACKUP] Running periodic backup check…');
    final result = await createBackup();
    if (result.success && result.path != null && result.path!.isNotEmpty) {
      debugPrint('[BACKUP] Periodic backup saved: ${result.path}');
    }
  }
}
