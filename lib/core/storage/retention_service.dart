import 'package:shared_preferences/shared_preferences.dart';
import 'pod_database.dart';

/// Retention duration options for chat messages.
enum RetentionPeriod {
  oneWeek('1 Woche', 7),
  oneMonth('1 Monat', 30),
  sixMonths('6 Monate', 180),
  oneYear('1 Jahr', 365),
  forever('Für immer', 0);

  const RetentionPeriod(this.label, this.days);
  final String label;
  final int days; // 0 means keep forever

  static RetentionPeriod fromName(String name) =>
      values.firstWhere((p) => p.name == name, orElse: () => oneYear);
}

/// Manages global and per-conversation message retention settings.
///
/// Settings are stored in SharedPreferences (not sensitive – just duration labels).
/// Cleanup runs asynchronously on the main isolate; each [await] yields to the
/// Flutter event loop so the UI stays responsive.  A true Dart Isolate cannot be
/// used here because sqflite does not support cross-isolate database access.
class RetentionService {
  RetentionService._();
  static final instance = RetentionService._();

  static const _globalKey = 'nexus_retention_global';
  static const _perChatPrefix = 'nexus_retention_conv_';

  RetentionPeriod _global = RetentionPeriod.oneYear;

  /// The current global retention period.
  RetentionPeriod get global => _global;

  // ── Initialisation ────────────────────────────────────────────────────────

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_globalKey);
      if (saved != null) _global = RetentionPeriod.fromName(saved);
    } catch (_) {}
  }

  // ── Global setting ────────────────────────────────────────────────────────

  Future<void> setGlobal(RetentionPeriod period) async {
    _global = period;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_globalKey, period.name);
    } catch (_) {}
  }

  // ── Per-conversation setting ──────────────────────────────────────────────

  /// Returns the retention period for [convId], or null if using global.
  Future<RetentionPeriod?> getForConversation(String convId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('$_perChatPrefix$convId');
      if (saved == null) return null;
      return RetentionPeriod.fromName(saved);
    } catch (_) {
      return null;
    }
  }

  /// Saves [period] for [convId].  Pass null to reset to the global setting.
  Future<void> setForConversation(String convId, RetentionPeriod? period) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (period == null) {
        await prefs.remove('$_perChatPrefix$convId');
      } else {
        await prefs.setString('$_perChatPrefix$convId', period.name);
      }
    } catch (_) {}
  }

  // ── Cleanup ───────────────────────────────────────────────────────────────

  /// Deletes all messages that exceed their retention period.
  ///
  /// Fire-and-forget: call without await from [main] after the database is open.
  Future<void> runCleanup() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final summaries = await PodDatabase.instance.listConversationSummaries();

      for (final summary in summaries) {
        final convId = summary['conversation_id'] as String;

        // Per-chat period overrides global.
        final saved = prefs.getString('$_perChatPrefix$convId');
        final period =
            saved != null ? RetentionPeriod.fromName(saved) : _global;

        if (period == RetentionPeriod.forever) continue;

        final cutoff = DateTime.now()
            .toUtc()
            .subtract(Duration(days: period.days));

        await PodDatabase.instance.deleteMessagesOlderThan(convId, cutoff);
      }
    } catch (_) {
      // Cleanup errors are non-fatal; will retry on next startup.
    }
  }
}
