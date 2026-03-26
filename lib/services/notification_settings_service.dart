import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotificationSettingsService {
  static final instance = NotificationSettingsService._();
  NotificationSettingsService._();

  // SharedPreferences keys
  static const _kEnabled    = 'notif_enabled';
  static const _kPreview    = 'notif_preview';
  static const _kBroadcast  = 'notif_broadcast';
  static const _kSilent     = 'notif_silent';
  static const _kDndEnabled = 'notif_dnd';
  static const _kDndFrom    = 'notif_dnd_from';   // minutes since midnight
  static const _kDndUntil   = 'notif_dnd_until';  // minutes since midnight

  bool _enabled          = true;
  bool _showPreview      = true;
  bool _broadcastEnabled = true;
  bool _silentMode       = false;
  bool _dndEnabled       = false;
  int  _dndFromMin       = 22 * 60; // 22:00
  int  _dndUntilMin      = 7  * 60; // 07:00

  bool get enabled          => _enabled;
  bool get showPreview      => _showPreview;
  bool get broadcastEnabled => _broadcastEnabled;
  bool get silentMode       => _silentMode;
  bool get dndEnabled       => _dndEnabled;
  TimeOfDay get dndFrom  => _toTime(_dndFromMin);
  TimeOfDay get dndUntil => _toTime(_dndUntilMin);

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _enabled          = p.getBool(_kEnabled)    ?? true;
    _showPreview      = p.getBool(_kPreview)    ?? true;
    _broadcastEnabled = p.getBool(_kBroadcast)  ?? true;
    _silentMode       = p.getBool(_kSilent)     ?? false;
    _dndEnabled       = p.getBool(_kDndEnabled) ?? false;
    _dndFromMin       = p.getInt(_kDndFrom)     ?? (22 * 60);
    _dndUntilMin      = p.getInt(_kDndUntil)    ?? (7 * 60);
  }

  Future<void> setEnabled(bool v)          async => _b(_kEnabled,    _enabled = v);
  Future<void> setShowPreview(bool v)      async => _b(_kPreview,    _showPreview = v);
  Future<void> setBroadcastEnabled(bool v) async => _b(_kBroadcast,  _broadcastEnabled = v);
  Future<void> setSilentMode(bool v)       async => _b(_kSilent,     _silentMode = v);
  Future<void> setDndEnabled(bool v)       async => _b(_kDndEnabled, _dndEnabled = v);

  Future<void> setDndFrom(TimeOfDay t) async {
    _dndFromMin = t.hour * 60 + t.minute;
    (await SharedPreferences.getInstance()).setInt(_kDndFrom, _dndFromMin);
  }

  Future<void> setDndUntil(TimeOfDay t) async {
    _dndUntilMin = t.hour * 60 + t.minute;
    (await SharedPreferences.getInstance()).setInt(_kDndUntil, _dndUntilMin);
  }

  /// True if current local time is inside the DND window.
  bool isInDndWindow() {
    if (!_dndEnabled) return false;
    final now    = TimeOfDay.now();
    final nowMin = now.hour * 60 + now.minute;
    if (_dndFromMin > _dndUntilMin) {
      // Overnight: e.g. 22:00 – 07:00
      return nowMin >= _dndFromMin || nowMin < _dndUntilMin;
    }
    return nowMin >= _dndFromMin && nowMin < _dndUntilMin;
  }

  Future<void> _b(String k, bool v) async =>
      (await SharedPreferences.getInstance()).setBool(k, v);

  static TimeOfDay _toTime(int min) =>
      TimeOfDay(hour: min ~/ 60, minute: min % 60);
}
