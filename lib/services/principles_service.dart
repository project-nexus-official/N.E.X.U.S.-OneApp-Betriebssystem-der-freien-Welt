import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tracks whether the user has seen and accepted the Principles of the
/// Human Family.
///
/// Persisted in SharedPreferences:
/// - [_keyHasSeen]   – true once the user finishes the flow (accept or skip)
/// - [_keyAccepted]  – true if explicitly accepted, false if skipped
/// - [_keyAcceptedAt] – ISO-8601 timestamp of acceptance
class PrinciplesService {
  static final instance = PrinciplesService._();
  PrinciplesService._();

  static const _keyHasSeen = 'principles_seen';
  static const _keyAccepted = 'principles_accepted';
  static const _keyAcceptedAt = 'principles_accepted_at';

  bool _hasSeen = false;
  bool _isAccepted = false;
  DateTime? _acceptedAt;

  /// True once the user has gone through the principles flow at least once
  /// (either accepted or skipped).
  bool get hasSeen => _hasSeen;

  /// True when the user explicitly accepted the principles.
  bool get isAccepted => _isAccepted;

  /// Timestamp of acceptance, or null if the principles were never accepted.
  DateTime? get acceptedAt => _acceptedAt;

  /// Loads persisted state from SharedPreferences.
  /// Must be called once at app startup, before the router is consulted.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _hasSeen = prefs.getBool(_keyHasSeen) ?? false;
      _isAccepted = prefs.getBool(_keyAccepted) ?? false;
      final ts = prefs.getString(_keyAcceptedAt);
      if (ts != null) _acceptedAt = DateTime.tryParse(ts);
    } catch (e) {
      debugPrint('[PRINCIPLES] load failed: $e');
    }
  }

  /// Marks the principles as accepted and persists the timestamp.
  Future<void> accept() async {
    _hasSeen = true;
    _isAccepted = true;
    _acceptedAt = DateTime.now();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyHasSeen, true);
      await prefs.setBool(_keyAccepted, true);
      await prefs.setString(_keyAcceptedAt, _acceptedAt!.toIso8601String());
    } catch (e) {
      debugPrint('[PRINCIPLES] accept save failed: $e');
    }
  }

  /// Marks the flow as seen but not accepted (user tapped "Später").
  Future<void> skip() async {
    _hasSeen = true;
    _isAccepted = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyHasSeen, true);
      await prefs.setBool(_keyAccepted, false);
    } catch (e) {
      debugPrint('[PRINCIPLES] skip save failed: $e');
    }
  }

  /// Resets in-memory state to the initial (unset) values (used in tests).
  @visibleForTesting
  void resetForTest() {
    _hasSeen = false;
    _isAccepted = false;
    _acceptedAt = null;
  }

  /// Sets in-memory state as if the user already accepted (used in tests).
  /// Does NOT touch SharedPreferences to avoid async timer side-effects.
  @visibleForTesting
  void setAcceptedForTest() {
    _hasSeen = true;
    _isAccepted = true;
    _acceptedAt = DateTime(2026, 1, 1);
  }
}
