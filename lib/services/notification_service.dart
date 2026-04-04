import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_settings_service.dart';

/// Wraps flutter_local_notifications. Call [init] once at app start.
class NotificationService {
  static final instance = NotificationService._();
  NotificationService._();

  static const _msgChannelId   = 'nexus_messages';
  static const _msgChannelName = 'NEXUS Nachrichten';
  static const _msgChannelDesc = 'Eingehende Nachrichten';
  static const _svcChannelId   = 'nexus_service';
  static const _svcChannelName = 'NEXUS Service';

  final _plugin = FlutterLocalNotificationsPlugin();

  /// Called when user taps a system notification.
  /// Payload is the [conversationId] to navigate to.
  void Function(String? conversationId)? onNotificationTap;

  Future<void> init({void Function(String? payload)? onTap}) async {
    if (!_supported) return;
    onNotificationTap = onTap;

    final initSettings = InitializationSettings(
      android: Platform.isAndroid
          ? const AndroidInitializationSettings('@mipmap/ic_launcher')
          : null,
      linux: Platform.isLinux
          ? const LinuxInitializationSettings(defaultActionName: 'Öffnen')
          : null,
    );

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (r) => onNotificationTap?.call(r.payload),
    );

    if (Platform.isAndroid) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      // Messages channel
      await android?.createNotificationChannel(
        AndroidNotificationChannel(
          _msgChannelId,
          _msgChannelName,
          description: _msgChannelDesc,
          importance: Importance.high,
          ledColor: Color(0xFFD4AF37), // Gold
          enableVibration: true,
          vibrationPattern: Int64List.fromList([0, 100, 50, 100]),
          showBadge: true,
        ),
      );

      // Foreground service channel (silent)
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          _svcChannelId,
          _svcChannelName,
          description: 'Hintergrund-Verbindung',
          importance: Importance.min,
          showBadge: false,
        ),
      );
    }
  }

  /// Show a notification for an incoming direct message.
  Future<void> showMessageNotification({
    required String senderDid,
    required String senderName,
    required String messagePreview,
    required String conversationId,
  }) async {
    final s = NotificationSettingsService.instance;
    if (!s.enabled || s.isInDndWindow()) return;

    final body = s.showPreview
        ? _truncate(messagePreview, 100)
        : 'Neue Nachricht';

    await _show(
      id: senderDid.hashCode.abs() % 100000,
      title: senderName,
      body: body,
      payload: conversationId,
      silent: s.silentMode,
    );
  }

  /// Show a notification for an incoming #mesh broadcast or named channel.
  /// [title] defaults to '#hotnews' when omitted (backward compat).
  Future<void> showBroadcastNotification({
    required String senderName,
    required String messagePreview,
    String? title,
  }) async {
    final s = NotificationSettingsService.instance;
    if (!s.enabled || !s.broadcastEnabled || s.isInDndWindow()) return;

    final notifTitle = title ?? '#hotnews';
    final body = s.showPreview
        ? '$senderName: ${_truncate(messagePreview, 80)}'
        : 'Neue Nachricht in $notifTitle';

    await _show(
      id: notifTitle.hashCode.abs() % 100000,
      title: notifTitle,
      body: body,
      payload: notifTitle,
      silent: s.silentMode,
      groupKey: 'nexus_broadcast',
    );
  }

  /// Show a generic notification (reactions, feed events, etc.).
  Future<void> showGenericNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    final s = NotificationSettingsService.instance;
    if (!s.enabled || s.isInDndWindow()) return;

    await _show(
      id: (title + body).hashCode.abs() % 100000,
      title: title,
      body: _truncate(body, 100),
      payload: payload,
      silent: s.silentMode,
    );
  }

  /// Cancel the notification for a specific sender (call when opening that chat).
  Future<void> cancelForSender(String senderDid) async {
    if (!_supported) return;
    await _plugin.cancel(senderDid.hashCode.abs() % 100000);
  }

  // ── Internal ────────────────────────────────────────────────────────────────

  bool get _supported => Platform.isAndroid || Platform.isLinux;

  Future<void> _show({
    required int id,
    required String title,
    required String body,
    String? payload,
    bool silent = false,
    String? groupKey,
  }) async {
    if (!_supported) return;
    try {
      await _plugin.show(
        id,
        title,
        body,
        NotificationDetails(
          android: Platform.isAndroid
              ? AndroidNotificationDetails(
                  _msgChannelId,
                  _msgChannelName,
                  channelDescription: _msgChannelDesc,
                  importance: Importance.high,
                  priority: Priority.high,
                  playSound: !silent,
                  enableVibration: !silent,
                  ledColor: Color(0xFFD4AF37),
                  ledOnMs: 1000,
                  ledOffMs: 500,
                  groupKey: groupKey,
                  autoCancel: true,
                )
              : null,
          linux: Platform.isLinux
              ? const LinuxNotificationDetails(
                  urgency: LinuxNotificationUrgency.normal,
                )
              : null,
        ),
        payload: payload,
      );
    } catch (e) {
      debugPrint('[NOTIF] show failed: $e');
    }
  }

  static String _truncate(String s, int max) =>
      s.length > max ? '${s.substring(0, max)}…' : s;
}
