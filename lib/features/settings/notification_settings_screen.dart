import 'package:flutter/material.dart';

import '../../services/notification_settings.dart';
import '../../shared/theme/app_theme.dart';

/// Granular notification preferences screen.
/// Accessible via Settings → Benachrichtigungen (chevron row).
class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  // Chat
  bool _chatReactions = true;

  // Kanäle & Gruppen
  bool _channelMessages  = true;
  bool _channelReplies   = true;
  bool _channelReactions = false;

  // Dorfplatz
  bool _feedLikes    = true;
  bool _feedComments = true;
  bool _feedReplies  = true;
  bool _feedReposts  = false;

  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      NotificationSettings.chatReactions(),
      NotificationSettings.channelMessages(),
      NotificationSettings.channelReplies(),
      NotificationSettings.channelReactions(),
      NotificationSettings.feedLikes(),
      NotificationSettings.feedComments(),
      NotificationSettings.feedReplies(),
      NotificationSettings.feedReposts(),
    ]);
    if (!mounted) return;
    setState(() {
      _chatReactions    = results[0];
      _channelMessages  = results[1];
      _channelReplies   = results[2];
      _channelReactions = results[3];
      _feedLikes        = results[4];
      _feedComments     = results[5];
      _feedReplies      = results[6];
      _feedReposts      = results[7];
      _loaded           = true;
    });
  }

  Future<void> _toggle(String key, bool value) async {
    await NotificationSettings.set(key, value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.deepBlue,
      appBar: AppBar(
        title: const Text('Benachrichtigungen'),
      ),
      body: _loaded
          ? ListView(
              children: [
                // ── Chat ───────────────────────────────────────────────────
                _SectionHeader('CHAT'),
                SwitchListTile(
                  secondary: const Icon(Icons.chat_bubble_outline,
                      color: AppColors.gold),
                  title: const Text('Neue Nachrichten'),
                  subtitle: const Text('Direkt-Nachrichten von Kontakten'),
                  value: true,
                  activeColor: AppColors.gold,
                  onChanged: null, // Always on — controlled by global toggle
                ),
                const Divider(height: 1, indent: 16),
                SwitchListTile(
                  secondary: const Icon(Icons.emoji_emotions_outlined,
                      color: AppColors.gold),
                  title: const Text('Emoji-Reaktionen auf meine Nachrichten'),
                  value: _chatReactions,
                  activeColor: AppColors.gold,
                  onChanged: (v) {
                    setState(() => _chatReactions = v);
                    _toggle(NotificationSettings.kChatReactions, v);
                  },
                ),

                // ── Kanäle & Gruppen ───────────────────────────────────────
                _SectionHeader('KANÄLE & GRUPPEN'),
                SwitchListTile(
                  secondary: const Icon(Icons.tag, color: AppColors.gold),
                  title: const Text('Neue Nachrichten in meinen Kanälen'),
                  value: _channelMessages,
                  activeColor: AppColors.gold,
                  onChanged: (v) {
                    setState(() => _channelMessages = v);
                    _toggle(NotificationSettings.kChannelMessages, v);
                  },
                ),
                const Divider(height: 1, indent: 16),
                SwitchListTile(
                  secondary: const Icon(Icons.reply, color: AppColors.gold),
                  title: const Text('Antworten auf meine Kanal-Nachrichten'),
                  value: _channelReplies,
                  activeColor: AppColors.gold,
                  onChanged: (v) {
                    setState(() => _channelReplies = v);
                    _toggle(NotificationSettings.kChannelReplies, v);
                  },
                ),
                const Divider(height: 1, indent: 16),
                SwitchListTile(
                  secondary: const Icon(Icons.emoji_emotions_outlined,
                      color: AppColors.gold),
                  title:
                      const Text('Emoji-Reaktionen auf meine Kanal-Nachrichten'),
                  value: _channelReactions,
                  activeColor: AppColors.gold,
                  onChanged: (v) {
                    setState(() => _channelReactions = v);
                    _toggle(NotificationSettings.kChannelReactions, v);
                  },
                ),

                // ── Dorfplatz ──────────────────────────────────────────────
                _SectionHeader('DORFPLATZ'),
                SwitchListTile(
                  secondary:
                      const Icon(Icons.thumb_up_outlined, color: AppColors.gold),
                  title: const Text('Likes auf meine Beiträge'),
                  value: _feedLikes,
                  activeColor: AppColors.gold,
                  onChanged: (v) {
                    setState(() => _feedLikes = v);
                    _toggle(NotificationSettings.kFeedLikes, v);
                  },
                ),
                const Divider(height: 1, indent: 16),
                SwitchListTile(
                  secondary: const Icon(Icons.comment_outlined,
                      color: AppColors.gold),
                  title: const Text('Kommentare auf meine Beiträge'),
                  value: _feedComments,
                  activeColor: AppColors.gold,
                  onChanged: (v) {
                    setState(() => _feedComments = v);
                    _toggle(NotificationSettings.kFeedComments, v);
                  },
                ),
                const Divider(height: 1, indent: 16),
                SwitchListTile(
                  secondary: const Icon(Icons.reply, color: AppColors.gold),
                  title: const Text('Antworten auf meine Kommentare'),
                  value: _feedReplies,
                  activeColor: AppColors.gold,
                  onChanged: (v) {
                    setState(() => _feedReplies = v);
                    _toggle(NotificationSettings.kFeedReplies, v);
                  },
                ),
                const Divider(height: 1, indent: 16),
                SwitchListTile(
                  secondary: const Icon(Icons.repeat, color: AppColors.gold),
                  title: const Text('Reposts meiner Beiträge'),
                  value: _feedReposts,
                  activeColor: AppColors.gold,
                  onChanged: (v) {
                    setState(() => _feedReposts = v);
                    _toggle(NotificationSettings.kFeedReposts, v);
                  },
                ),
                const SizedBox(height: 24),
              ],
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }
}

// ── Section header ─────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label,
        style: TextStyle(
          color: AppColors.gold.withValues(alpha: 0.7),
          fontSize: 10,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.4,
        ),
      ),
    );
  }
}
