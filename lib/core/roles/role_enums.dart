/// System-wide role hierarchy for NEXUS OneApp.
///
/// Genesis-phase: SUPERADMIN is determined by a hardcoded DID loaded from
/// assets/config/system.json. In a future governance phase (G2), this will be
/// abdicable via Grundstimm-Recht.

/// Roles that apply across the entire app.
enum SystemRole {
  /// The founding admin. Exactly one; loaded from assets/config/system.json.
  /// Can do everything a SYSTEM_ADMIN can, plus manage system admins and
  /// transfer the superadmin role.
  superadmin,

  /// Appointed by the superadmin. Multiple allowed.
  /// Can moderate content and create announcement channels.
  systemAdmin,

  /// Every regular user (default).
  user,
}

/// Roles within a specific named group channel.
enum ChannelRole {
  /// The creator of the channel. Can do everything in that channel.
  channelAdmin,

  /// Appointed by the channel admin. Can delete messages and mute members.
  channelModerator,

  /// Regular member of the channel.
  channelMember,
}

/// Channel posting mode.
enum ChannelMode {
  /// All members can post (default).
  discussion,

  /// Only channel admins, system admins and superadmin can post.
  announcement,
}

extension ChannelModeJson on ChannelMode {
  String get value => name; // 'discussion' | 'announcement'

  static ChannelMode fromString(String? s) {
    if (s == 'announcement') return ChannelMode.announcement;
    return ChannelMode.discussion;
  }
}
