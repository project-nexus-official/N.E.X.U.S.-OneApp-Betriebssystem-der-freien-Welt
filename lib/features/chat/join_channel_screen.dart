import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../shared/theme/app_theme.dart';
import 'channel_access_service.dart';
import 'channel_conversation_screen.dart';
import 'chat_provider.dart';
import 'group_channel.dart';
import 'group_channel_service.dart';

/// Screen to discover and join group channels.
///
/// Shows all channels (joined + discovered via Nostr Kind-40) with a
/// join/joined button for each.
class JoinChannelScreen extends StatefulWidget {
  const JoinChannelScreen({super.key});

  @override
  State<JoinChannelScreen> createState() => _JoinChannelScreenState();
}

class _JoinChannelScreenState extends State<JoinChannelScreen> {
  final _searchController = TextEditingController();
  List<GroupChannel> _channels = [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _refreshChannels();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _refreshChannels() {
    setState(() {
      _channels = GroupChannelService.instance.allDiscovered;
    });
  }

  List<GroupChannel> get _filtered {
    // Show all discoverable channels (public + private+visible).
    final discoverable = _channels.where((c) => c.isDiscoverable).toList();
    if (_query.isEmpty) return discoverable;
    return discoverable
        .where((c) =>
            c.name.toLowerCase().contains(_query) ||
            c.description.toLowerCase().contains(_query))
        .toList();
  }

  void _openChannel(GroupChannel channel) {
    // Prefer the up-to-date object from the service (has joinedAt set).
    final live =
        GroupChannelService.instance.findByName(channel.name) ?? channel;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChangeNotifierProvider.value(
          value: context.read<ChatProvider>(),
          child: ChannelConversationScreen(channel: live),
        ),
      ),
    );
  }

  Future<void> _join(GroupChannel channel) async {
    await GroupChannelService.instance.joinChannel(channel);

    // Subscribe Nostr to the channel.
    if (mounted) {
      context
          .read<ChatProvider>()
          .nostrTransport
          ?.subscribeToChannel(channel.nostrTag);
    }

    if (mounted) {
      setState(_refreshChannels);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${channel.name} beigetreten'),
          backgroundColor: AppColors.gold,
        ),
      );
      // Auto-open the channel chat after joining.
      _openChannel(channel);
    }
  }

  Future<void> _sendJoinRequest(GroupChannel channel) async {
    final provider = context.read<ChatProvider>();
    await ChannelAccessService.instance
        .sendJoinRequest(channel, provider.sendSystemDm);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Beitrittsantrag für ${channel.name} gesendet. '
              'Du wirst benachrichtigt wenn der Admin dich freischaltet.'),
          backgroundColor: AppColors.gold,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _leave(GroupChannel channel) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('${channel.name} verlassen?'),
        content: const Text(
          'Du kannst dem Kanal jederzeit wieder beitreten.',
          style: TextStyle(color: AppColors.onDark),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:
                const Text('Abbrechen', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Verlassen'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await GroupChannelService.instance.leaveChannel(channel.name);
      if (mounted) setState(_refreshChannels);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;

    return Scaffold(
      appBar: AppBar(title: const Text('Kanäle entdecken')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: AppColors.onDark),
              decoration: InputDecoration(
                hintText: 'Kanal suchen…',
                prefixIcon: const Icon(Icons.search, color: Colors.grey),
                filled: true,
                fillColor: AppColors.surfaceVariant,
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (filtered.isEmpty)
            const Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.search_off, size: 48, color: Colors.grey),
                    SizedBox(height: 12),
                    Text(
                      'Keine Kanäle gefunden.',
                      style: TextStyle(color: Colors.grey),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Bekannte Kanäle erscheinen hier sobald\njemand einen erstellt.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: filtered.length,
                separatorBuilder: (context2, i2) =>
                    const Divider(height: 1, color: AppColors.surfaceVariant),
                itemBuilder: (ctx, i) {
                  final ch = filtered[i];
                  final joined =
                      GroupChannelService.instance.isJoined(ch.name);
                  final isPrivate = !ch.isPublic;
                  return ListTile(
                    onTap: joined ? () => _openChannel(ch) : null,
                    leading: CircleAvatar(
                      backgroundColor: AppColors.surfaceVariant,
                      child: Icon(
                        isPrivate ? Icons.lock : Icons.tag,
                        color: AppColors.gold,
                        size: 18,
                      ),
                    ),
                    title: Row(
                      children: [
                        Text(
                          ch.name,
                          style: const TextStyle(
                            color: AppColors.gold,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (isPrivate)
                          Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceVariant,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                  color: Colors.grey.withValues(alpha: 0.4)),
                            ),
                            child: const Text(
                              'Privat',
                              style: TextStyle(
                                  color: Colors.grey, fontSize: 10),
                            ),
                          ),
                      ],
                    ),
                    subtitle: ch.description.isNotEmpty
                        ? Text(
                            ch.description,
                            style: const TextStyle(color: AppColors.onDark),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        : null,
                    trailing: joined
                        ? OutlinedButton(
                            onPressed: () => _leave(ch),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.redAccent,
                              side:
                                  const BorderSide(color: Colors.redAccent),
                            ),
                            child: const Text('Verlassen'),
                          )
                        : isPrivate
                            ? ElevatedButton(
                                onPressed: () => _sendJoinRequest(ch),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.surfaceVariant,
                                  foregroundColor: AppColors.onDark,
                                ),
                                child: const Text('Anfragen'),
                              )
                            : ElevatedButton(
                                onPressed: () => _join(ch),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.gold,
                                  foregroundColor: AppColors.deepBlue,
                                ),
                                child: const Text('Beitreten'),
                              ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
