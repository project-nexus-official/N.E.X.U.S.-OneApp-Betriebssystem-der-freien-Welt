import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/identity/identity_service.dart';
import '../../core/roles/permission_helper.dart';
import '../../core/roles/role_enums.dart';
import '../../services/role_service.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/help_icon.dart';
import 'chat_provider.dart';
import 'group_channel.dart';
import 'group_channel_service.dart';

/// Screen to create a new named group channel.
class CreateChannelScreen extends StatefulWidget {
  const CreateChannelScreen({super.key});

  @override
  State<CreateChannelScreen> createState() => _CreateChannelScreenState();
}

class _CreateChannelScreenState extends State<CreateChannelScreen> {
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _creating = false;
  bool _isPublic = true;
  bool _isDiscoverable = true;
  ChannelMode _channelMode = ChannelMode.discussion;
  String? _nameError;

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  String _normalisedName() {
    final raw = _nameController.text.trim();
    return GroupChannel.normaliseName(raw);
  }

  Future<void> _create() async {
    setState(() => _nameError = null);

    final name = _normalisedName();
    final bare = name.startsWith('#') ? name.substring(1) : name;

    if (!GroupChannel.isValidName(bare)) {
      setState(() => _nameError =
          'Nur Kleinbuchstaben, Ziffern und Bindestriche erlaubt (2–50 Zeichen).');
      return;
    }

    if (GroupChannelService.instance.isJoined(name)) {
      setState(() => _nameError = 'Du bist diesem Kanal bereits beigetreten.');
      return;
    }

    setState(() => _creating = true);

    final myDid =
        IdentityService.instance.currentIdentity?.did ?? 'unknown';

    final channel = GroupChannel.create(
      name: name,
      description: _descController.text.trim(),
      createdBy: myDid,
      isPublic: _isPublic,
      isDiscoverable: _isPublic ? true : _isDiscoverable,
      channelMode: _channelMode,
    );

    await GroupChannelService.instance.createChannel(channel);

    if (!mounted) return;

    // ALL channels (public and private) are announced on Nostr (Kind-40) and
    // subscribed to. Private messages are encrypted with the channelSecret.
    final nostr = context.read<ChatProvider>().nostrTransport;
    // publishChannelCreate now returns the Nostr event ID so we can store it
    // for NIP-09 compliant deletion events later.
    final nostrEventId = await nostr?.publishChannelCreate(channel.toJson());
    if (nostrEventId != null) {
      await GroupChannelService.instance.setNostrEventId(channel.id, nostrEventId);
      print('[CHANNEL-CREATE] Stored nostrEventId for ${channel.name}: '
          '${nostrEventId.substring(0, 8)}…');
    }
    nostr?.subscribeToChannel(channel.nostrTag);

    Navigator.of(context).pop(channel);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Kanal erstellen')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Neuen Gruppenkanal erstellen',
              style: TextStyle(
                color: AppColors.gold,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Erstelle einen Kanal für Gruppen-Gespräche. Öffentliche Kanäle '
              'können von allen NEXUS-Nutzern entdeckt werden.',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _nameController,
              autofocus: true,
              textInputAction: TextInputAction.next,
              style: const TextStyle(color: AppColors.onDark),
              onChanged: (_) {
                if (_nameError != null) setState(() => _nameError = null);
              },
              decoration: InputDecoration(
                labelText: 'Kanalname',
                hintText: 'teneriffa',
                prefixText: '#',
                prefixStyle: const TextStyle(
                    color: AppColors.gold, fontWeight: FontWeight.bold),
                errorText: _nameError,
                helperText: 'Kleinbuchstaben, Ziffern, Bindestriche',
                filled: true,
                fillColor: AppColors.surfaceVariant,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descController,
              maxLines: 3,
              textInputAction: TextInputAction.done,
              style: const TextStyle(color: AppColors.onDark),
              decoration: InputDecoration(
                labelText: 'Beschreibung (optional)',
                hintText: 'Worum geht es in diesem Kanal?',
                filled: true,
                fillColor: AppColors.surfaceVariant,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 24),
            // Zugangstyp selector.
            Row(
              children: [
                Text(
                  'Zugangstyp',
                  style: TextStyle(
                    color: Colors.grey[500],
                    fontSize: 11,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(width: 4),
                const HelpIcon(contextId: 'channel_privacy', size: 14),
              ],
            ),
            const SizedBox(height: 6),
            Container(
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _VisibilityOption(
                    icon: Icons.public,
                    title: 'Öffentlich',
                    subtitle: 'Jeder kann beitreten und den Kanal entdecken',
                    selected: _isPublic,
                    onTap: () => setState(() => _isPublic = true),
                    topRounded: true,
                    bottomRounded: _isPublic,
                  ),
                  const Divider(height: 1, color: AppColors.surface),
                  _VisibilityOption(
                    icon: Icons.lock,
                    title: 'Privat',
                    subtitle: 'Zugang nur für zugelassene Mitglieder',
                    selected: !_isPublic,
                    onTap: () => setState(() => _isPublic = false),
                    bottomRounded: _isPublic, // rounded only if no sub-options
                  ),
                ],
              ),
            ),
            // When private is selected: show discoverable sub-option.
            if (!_isPublic) ...[
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: AppColors.gold.withValues(alpha: 0.25)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                      child: Text(
                        'Auffindbarkeit',
                        style: TextStyle(
                            color: Colors.grey[500], fontSize: 11),
                      ),
                    ),
                    _VisibilityOption(
                      icon: Icons.visibility,
                      title: 'Sichtbar',
                      subtitle:
                          'Kanal ist auffindbar – Beitritt nur auf Antrag',
                      selected: _isDiscoverable,
                      onTap: () =>
                          setState(() => _isDiscoverable = true),
                      topRounded: true,
                    ),
                    const Divider(height: 1, color: AppColors.surface),
                    _VisibilityOption(
                      icon: Icons.visibility_off,
                      title: 'Unsichtbar',
                      subtitle: 'Kanal ist nicht auffindbar – nur per Einladung',
                      selected: !_isDiscoverable,
                      onTap: () =>
                          setState(() => _isDiscoverable = false),
                      bottomRounded: true,
                    ),
                  ],
                ),
              ),
            ],
            // Channel mode selector – only visible for system admins/superadmin.
            Builder(builder: (ctx) {
              final myDid =
                  IdentityService.instance.currentIdentity?.did ?? '';
              if (!PermissionHelper.canCreateAnnouncementChannel(myDid)) {
                return const SizedBox.shrink();
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 16),
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.surfaceVariant,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: AppColors.gold.withValues(alpha: 0.25)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                          child: Row(
                            children: [
                              Text(
                                'Kanal-Modus',
                                style: TextStyle(
                                    color: Colors.grey[500], fontSize: 11),
                              ),
                              const SizedBox(width: 4),
                              const HelpIcon(contextId: 'channel_types', size: 14),
                            ],
                          ),
                        ),
                        _VisibilityOption(
                          icon: Icons.forum,
                          title: 'Diskussion',
                          subtitle: 'Alle Mitglieder können Nachrichten senden',
                          selected:
                              _channelMode == ChannelMode.discussion,
                          onTap: () => setState(
                              () => _channelMode = ChannelMode.discussion),
                          topRounded: true,
                        ),
                        const Divider(height: 1, color: AppColors.surface),
                        _VisibilityOption(
                          icon: Icons.campaign,
                          title: 'Ankündigung',
                          subtitle:
                              'Nur Admins können posten – Mitglieder lesen nur',
                          selected:
                              _channelMode == ChannelMode.announcement,
                          onTap: () => setState(
                              () => _channelMode = ChannelMode.announcement),
                          bottomRounded: true,
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }),
            const SizedBox(height: 24),
            // Preview of the channel name.
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _nameController,
              builder: (context2, value, child2) {
                if (value.text.trim().isEmpty) return const SizedBox.shrink();
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceVariant,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.tag, color: AppColors.gold, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        _normalisedName(),
                        style: const TextStyle(
                          color: AppColors.gold,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: _creating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add),
                label: const Text('Kanal erstellen'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.gold,
                  foregroundColor: AppColors.deepBlue,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _creating ? null : _create,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Visibility option tile ───────────────────────────────────────────────────

class _VisibilityOption extends StatelessWidget {
  const _VisibilityOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.topRounded = false,
    this.bottomRounded = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final bool topRounded;
  final bool bottomRounded;

  @override
  Widget build(BuildContext context) {
    final radius = Radius.circular(topRounded || bottomRounded ? 12 : 0);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.only(
        topLeft: topRounded ? radius : Radius.zero,
        topRight: topRounded ? radius : Radius.zero,
        bottomLeft: bottomRounded ? radius : Radius.zero,
        bottomRight: bottomRounded ? radius : Radius.zero,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon,
                color: selected ? AppColors.gold : Colors.grey, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color:
                          selected ? AppColors.onDark : Colors.grey,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                        color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
            ),
            Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              color: selected ? AppColors.gold : Colors.grey,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}
