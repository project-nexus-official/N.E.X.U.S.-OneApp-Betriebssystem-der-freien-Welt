import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Loads and caches the system-level configuration.
///
/// Superadmin DID resolution order:
///   1. SharedPreferences key 'nexus_superadmin_did' (set after a transfer)
///   2. assets/config/system.json "superadmin_did" field
///   3. null → no superadmin, all admin features disabled
class SystemConfig {
  SystemConfig._();
  static final SystemConfig instance = SystemConfig._();

  static const String _prefKey = 'nexus_superadmin_did';
  static const String _placeholder = 'PLACEHOLDER_DID';

  String? _superadminDid;
  bool _loaded = false;

  /// The current superadmin DID, or null if none is configured.
  String? get superadminDid => _loaded ? _superadminDid : null;

  /// Loads the superadmin DID. Must be called before any role checks.
  Future<void> load() async {
    if (_loaded) return;

    // 1. Check SharedPreferences (set by transferSuperadmin).
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_prefKey);
      if (stored != null && stored.isNotEmpty && stored != _placeholder) {
        _superadminDid = stored;
        _loaded = true;
        return;
      }
    } catch (_) {}

    // 2. Fall back to bundled asset.
    try {
      final raw = await rootBundle.loadString('assets/config/system.json');
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final did = json['superadmin_did'] as String?;
      if (did != null && did.isNotEmpty && did != _placeholder) {
        _superadminDid = did;
      }
    } catch (_) {
      // asset missing or malformed → no superadmin
    }

    _loaded = true;
  }

  /// Persists a new superadmin DID to SharedPreferences.
  /// Called by [RoleService.transferSuperadmin].
  Future<void> persistSuperadminDid(String newDid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, newDid);
    _superadminDid = newDid;
  }

  /// Resets loaded state (for testing).
  void reset() {
    _superadminDid = null;
    _loaded = false;
  }

  /// Directly sets the superadmin DID without touching SharedPreferences or
  /// the asset bundle. For unit tests only.
  // ignore: invalid_use_of_visible_for_testing_member
  void forceForTest(String did) {
    _superadminDid = did;
    _loaded = true;
  }
}
