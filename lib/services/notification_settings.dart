import 'package:shared_preferences/shared_preferences.dart';

/// Thin helper that reads the per-category notification preference flags.
/// Each method returns `true` when the category is enabled (default values
/// match the spec: most ON, channel/feed reactions OFF).
class NotificationSettings {
  NotificationSettings._();

  // ── Keys ──────────────────────────────────────────────────────────────────
  static const kChatReactions      = 'notif_chat_reactions';
  static const kChannelMessages    = 'notif_channel_messages';
  static const kChannelReplies     = 'notif_channel_replies';
  static const kChannelReactions   = 'notif_channel_reactions';
  static const kFeedLikes          = 'notif_feed_likes';
  static const kFeedComments       = 'notif_feed_comments';
  static const kFeedReplies        = 'notif_feed_replies';
  static const kFeedReposts        = 'notif_feed_reposts';

  // ── Readers ───────────────────────────────────────────────────────────────
  static Future<bool> chatReactions()    => _get(kChatReactions,    def: true);
  static Future<bool> channelMessages()  => _get(kChannelMessages,  def: true);
  static Future<bool> channelReplies()   => _get(kChannelReplies,   def: true);
  static Future<bool> channelReactions() => _get(kChannelReactions, def: false);
  static Future<bool> feedLikes()        => _get(kFeedLikes,        def: true);
  static Future<bool> feedComments()     => _get(kFeedComments,     def: true);
  static Future<bool> feedReplies()      => _get(kFeedReplies,      def: true);
  static Future<bool> feedReposts()      => _get(kFeedReposts,      def: false);

  // ── Writer ────────────────────────────────────────────────────────────────
  static Future<void> set(String key, bool value) async =>
      (await SharedPreferences.getInstance()).setBool(key, value);

  // ── Internal ──────────────────────────────────────────────────────────────
  static Future<bool> _get(String key, {required bool def}) async =>
      (await SharedPreferences.getInstance()).getBool(key) ?? def;
}
