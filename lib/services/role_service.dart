import 'package:flutter/foundation.dart';

import '../core/config/system_config.dart';
import '../core/roles/role_enums.dart';
import '../core/storage/pod_database.dart';

/// Record of a system-level role grant.
class SystemRoleRecord {
  final String did;
  final SystemRole role;
  final String grantedBy;
  final DateTime grantedAt;

  const SystemRoleRecord({
    required this.did,
    required this.role,
    required this.grantedBy,
    required this.grantedAt,
  });

  Map<String, dynamic> toJson() => {
        'did': did,
        'role': role.name,
        'granted_by': grantedBy,
        'granted_at': grantedAt.millisecondsSinceEpoch,
      };
}

/// Record of a channel-level role grant.
class ChannelRoleRecord {
  final String channelId;
  final String did;
  final ChannelRole role;
  final String grantedBy;
  final DateTime grantedAt;

  const ChannelRoleRecord({
    required this.channelId,
    required this.did,
    required this.role,
    required this.grantedBy,
    required this.grantedAt,
  });
}

/// Manages system-wide and channel-level roles.
///
/// Must be initialised once after the POD is open:
/// ```dart
/// await RoleService.instance.init();
/// ```
class RoleService {
  RoleService._();
  static final RoleService instance = RoleService._();

  // Cache of system admins (DIDs), populated from the DB.
  final Set<String> _systemAdmins = {};

  // Cache of channel roles: channelId → (did → ChannelRole).
  final Map<String, Map<String, ChannelRole>> _channelRoles = {};

  bool _ready = false;

  // ── Initialisation ────────────────────────────────────────────────────────

  Future<void> init() async {
    await SystemConfig.instance.load();
    await _loadSystemAdmins();
    await _loadChannelRoles();
    _ready = true;
    debugPrint('[RoleService] Loaded. superadmin=${SystemConfig.instance.superadminDid} sysAdmins=${_systemAdmins.length}');
  }

  Future<void> _loadSystemAdmins() async {
    try {
      final rows = await PodDatabase.instance.listSystemRoles();
      _systemAdmins.clear();
      for (final row in rows) {
        if (row['role'] == SystemRole.systemAdmin.name) {
          _systemAdmins.add(row['did'] as String);
        }
      }
    } catch (e) {
      debugPrint('[RoleService] Could not load system admins: $e');
    }
  }

  Future<void> _loadChannelRoles() async {
    try {
      final rows = await PodDatabase.instance.listChannelRoles();
      _channelRoles.clear();
      for (final row in rows) {
        final channelId = row['channel_id'] as String;
        final did = row['did'] as String;
        final roleStr = row['role'] as String;
        final role = ChannelRole.values.firstWhere(
          (r) => r.name == roleStr,
          orElse: () => ChannelRole.channelMember,
        );
        _channelRoles.putIfAbsent(channelId, () => {})[did] = role;
      }
    } catch (e) {
      debugPrint('[RoleService] Could not load channel roles: $e');
    }
  }

  // ── System Role Queries ───────────────────────────────────────────────────

  bool isSuperadmin(String did) {
    final superDid = SystemConfig.instance.superadminDid;
    return superDid != null && did == superDid;
  }

  /// Returns true when [did] is either the superadmin or a system admin.
  bool isSystemAdmin(String did) =>
      isSuperadmin(did) || _systemAdmins.contains(did);

  SystemRole getSystemRole(String did) {
    if (isSuperadmin(did)) return SystemRole.superadmin;
    if (_systemAdmins.contains(did)) return SystemRole.systemAdmin;
    return SystemRole.user;
  }

  // ── Channel Role Queries ──────────────────────────────────────────────────

  /// Returns the channel-level role for [did] in [channelId].
  ///
  /// [channelAdminDid] is the creator of the channel (from GroupChannel.createdBy).
  /// Falls back to [ChannelRole.channelMember] for all other members.
  ChannelRole getChannelRole(
    String channelId,
    String did, {
    String? channelAdminDid,
  }) {
    if (channelAdminDid != null && did == channelAdminDid) {
      return ChannelRole.channelAdmin;
    }
    return _channelRoles[channelId]?[did] ?? ChannelRole.channelMember;
  }

  // ── Superadmin Mutations ──────────────────────────────────────────────────

  /// Grants system-admin role to [targetDid].
  ///
  /// Throws [StateError] if [callerDid] is not the superadmin.
  Future<void> grantSystemAdmin(String callerDid, String targetDid) async {
    if (!isSuperadmin(callerDid)) {
      throw StateError('Only the superadmin can grant system admin roles.');
    }
    await PodDatabase.instance.upsertSystemRole(
      did: targetDid,
      roleName: SystemRole.systemAdmin.name,
      grantedBy: callerDid,
      grantedAt: DateTime.now(),
    );
    _systemAdmins.add(targetDid);
    debugPrint('[RoleService] Granted systemAdmin to $targetDid');
  }

  /// Revokes system-admin role from [targetDid].
  ///
  /// Throws [StateError] if [callerDid] is not the superadmin.
  Future<void> revokeSystemAdmin(String callerDid, String targetDid) async {
    if (!isSuperadmin(callerDid)) {
      throw StateError('Only the superadmin can revoke system admin roles.');
    }
    if (isSuperadmin(targetDid)) {
      throw StateError('Cannot revoke the superadmin role via this method.');
    }
    await PodDatabase.instance.deleteSystemRole(targetDid);
    _systemAdmins.remove(targetDid);
    debugPrint('[RoleService] Revoked systemAdmin from $targetDid');
  }

  /// Transfers the superadmin role to [newDid]. IRREVERSIBLE in genesis phase.
  ///
  /// Throws [StateError] if [callerDid] is not the superadmin.
  Future<void> transferSuperadmin(String callerDid, String newDid) async {
    if (!isSuperadmin(callerDid)) {
      throw StateError('Only the superadmin can transfer the superadmin role.');
    }
    await SystemConfig.instance.persistSuperadminDid(newDid);
    debugPrint('[RoleService] Superadmin transferred from $callerDid to $newDid');
  }

  // ── Channel Admin Mutations ───────────────────────────────────────────────

  /// Grants the moderator role in [channelId] to [targetDid].
  ///
  /// Requires [callerDid] to be the channel admin or a system-level admin.
  Future<void> grantChannelModerator(
    String callerDid,
    String channelId,
    String targetDid, {
    required String channelAdminDid,
  }) async {
    if (!_canManageChannelModerators(callerDid, channelId, channelAdminDid: channelAdminDid)) {
      throw StateError('Insufficient permissions to grant channel moderator.');
    }
    await PodDatabase.instance.upsertChannelRole(
      channelId: channelId,
      did: targetDid,
      roleName: ChannelRole.channelModerator.name,
      grantedBy: callerDid,
      grantedAt: DateTime.now(),
    );
    _channelRoles.putIfAbsent(channelId, () => {})[targetDid] =
        ChannelRole.channelModerator;
    debugPrint('[RoleService] Granted channelModerator in $channelId to $targetDid');
  }

  /// Revokes the moderator role in [channelId] from [targetDid].
  Future<void> revokeChannelModerator(
    String callerDid,
    String channelId,
    String targetDid, {
    required String channelAdminDid,
  }) async {
    if (!_canManageChannelModerators(callerDid, channelId, channelAdminDid: channelAdminDid)) {
      throw StateError('Insufficient permissions to revoke channel moderator.');
    }
    await PodDatabase.instance.deleteChannelRole(channelId, targetDid);
    _channelRoles[channelId]?.remove(targetDid);
    debugPrint('[RoleService] Revoked channelModerator in $channelId from $targetDid');
  }

  bool _canManageChannelModerators(
    String callerDid,
    String channelId, {
    required String channelAdminDid,
  }) {
    if (isSystemAdmin(callerDid)) return true;
    if (callerDid == channelAdminDid) return true;
    return false;
  }

  // ── List helpers ─────────────────────────────────────────────────────────

  /// Returns a list of all current system admin DIDs (not including superadmin).
  List<String> get systemAdmins => List.unmodifiable(_systemAdmins);

  /// Returns a snapshot of all channel-role records for [channelId].
  Map<String, ChannelRole> channelRolesFor(String channelId) =>
      Map.unmodifiable(_channelRoles[channelId] ?? {});

  // ── For testing ───────────────────────────────────────────────────────────

  /// Resets all in-memory state (for unit tests).
  void reset() {
    _systemAdmins.clear();
    _channelRoles.clear();
    _ready = false;
    SystemConfig.instance.reset();
  }
}
