import '../roles/role_enums.dart';
import '../../services/role_service.dart';

/// Centralised permission checks for the NEXUS role hierarchy.
///
/// All methods are pure functions – they receive the resolved role information
/// from [RoleService] and return a boolean. No async I/O.
class PermissionHelper {
  const PermissionHelper._();

  // ── Channel posting ───────────────────────────────────────────────────────

  /// Whether [did] may post in [channelId].
  ///
  /// - discussion mode → any member
  /// - announcement mode → only channel admin, system admin, or superadmin
  static bool canPostInChannel({
    required String channelId,
    required String did,
    required ChannelMode channelMode,
    required String channelAdminDid,
  }) {
    if (channelMode == ChannelMode.discussion) return true;

    // Announcement channel: privileged users only.
    final svc = RoleService.instance;
    if (svc.isSystemAdmin(did)) return true;
    final chRole = svc.getChannelRole(channelId, did, channelAdminDid: channelAdminDid);
    return chRole == ChannelRole.channelAdmin;
  }

  // ── Channel creation ──────────────────────────────────────────────────────

  /// Whether [did] may create an announcement channel.
  static bool canCreateAnnouncementChannel(String did) =>
      RoleService.instance.isSystemAdmin(did);

  // ── Cell creation ─────────────────────────────────────────────────────────

  /// Whether [did] may found a new cell.
  ///
  /// Restricted to system admins and the superadmin to prevent cell spam
  /// during the early rollout phase.
  static bool canCreateCell(String did) =>
      RoleService.instance.isSystemAdmin(did);

  // ── Message deletion ──────────────────────────────────────────────────────

  /// Whether [requesterDid] may delete a message sent by [messageSenderDid].
  ///
  /// Rules:
  ///  - Own message: always
  ///  - Foreign message: channel moderator, channel admin, system admin, superadmin
  static bool canDeleteMessage({
    required String channelId,
    required String messageSenderDid,
    required String requesterDid,
    required String channelAdminDid,
  }) {
    if (requesterDid == messageSenderDid) return true;
    return _hasModeratorOrAbove(requesterDid, channelId, channelAdminDid);
  }

  // ── Member muting ─────────────────────────────────────────────────────────

  /// Whether [did] may mute a member in [channelId].
  static bool canMuteUser({
    required String channelId,
    required String did,
    required String channelAdminDid,
  }) =>
      _hasModeratorOrAbove(did, channelId, channelAdminDid);

  // ── Admin management ──────────────────────────────────────────────────────

  /// Whether [did] may manage system admins (grant/revoke).
  static bool canManageSystemAdmins(String did) =>
      RoleService.instance.isSuperadmin(did);

  /// Whether [did] may manage channel moderators in [channelId].
  static bool canManageChannelModerators({
    required String channelId,
    required String did,
    required String channelAdminDid,
  }) {
    final svc = RoleService.instance;
    if (svc.isSystemAdmin(did)) return true;
    return did == channelAdminDid;
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  static bool _hasModeratorOrAbove(
      String did, String channelId, String channelAdminDid) {
    final svc = RoleService.instance;
    if (svc.isSystemAdmin(did)) return true;
    final chRole =
        svc.getChannelRole(channelId, did, channelAdminDid: channelAdminDid);
    return chRole == ChannelRole.channelAdmin ||
        chRole == ChannelRole.channelModerator;
  }
}
