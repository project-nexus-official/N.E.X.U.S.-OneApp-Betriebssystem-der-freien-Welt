import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/contacts/contact_service.dart';
import '../../core/identity/identity_service.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/peer_avatar.dart';
import 'chat_provider.dart';
import 'group_channel.dart';
import 'group_channel_service.dart';

/// 0 = public, 1 = private+visible, 2 = private+hidden
enum _ChannelType { public, privateVisible, privateHidden }

_ChannelType _typeFromChannel(GroupChannel ch) {
  if (ch.isPublic) return _ChannelType.public;
  if (ch.isDiscoverable) return _ChannelType.privateVisible;
  return _ChannelType.privateHidden;
}

/// Admin-only settings screen for a group channel.
///
/// Shown only when currentUserDid == channel.createdBy.
class ChannelAdminScreen extends StatefulWidget {
  const ChannelAdminScreen({super.key, required this.channel});
  final GroupChannel channel;

  @override
  State<ChannelAdminScreen> createState() => _ChannelAdminScreenState();
}

class _ChannelAdminScreenState extends State<ChannelAdminScreen> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  late _ChannelType _type;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(
        text: widget.channel.name.startsWith('#')
            ? widget.channel.name.substring(1)
            : widget.channel.name);
    _descCtrl = TextEditingController(text: widget.channel.description);
    _type = _typeFromChannel(widget.channel);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String get _myDid =>
      IdentityService.instance.currentIdentity?.did ?? '';

  List<String> get _otherMembers =>
      widget.channel.members.where((d) => d != _myDid).toList();

  // ── Save ──────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    final rawName = _nameCtrl.text.trim();
    if (rawName.isEmpty) return;

    final normName = GroupChannel.normaliseName(rawName);
    if (!GroupChannel.isValidName(normName)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Ungültiger Kanalname. '
            'Nur Kleinbuchstaben, Ziffern und Bindestriche erlaubt.'),
      ));
      return;
    }

    final wasPublic = widget.channel.isPublic;
    final nowPublic = _type == _ChannelType.public;
    final nowDiscoverable = _type != _ChannelType.privateHidden;

    // Warn when switching from public → private.
    if (wasPublic && !nowPublic) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Kanal auf Privat umstellen?'),
          content: const Text(
            'Bestehende Mitglieder behalten ihren Zugang.\n'
            'Neue Mitglieder brauchen eine Einladung.',
            style: TextStyle(color: AppColors.onDark),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen',
                  style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.gold,
                  foregroundColor: AppColors.deepBlue),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Umstellen'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    setState(() => _saving = true);
    try {
      final channelMode = widget.channel.channelMode;
      final updated = widget.channel.copyWith(
        name: normName,
        description: _descCtrl.text.trim(),
        isPublic: nowPublic,
        isDiscoverable: nowDiscoverable,
        channelMode: channelMode,
      );
      await GroupChannelService.instance.updateChannel(updated);
      if (mounted) {
        context.read<ChatProvider>().nostrTransport
            ?.publishChannelMetadata(updated.toJson());
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Gespeichert')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── Remove member ─────────────────────────────────────────────────────────

  Future<void> _removeMember(String did) async {
    final name = ContactService.instance.getDisplayName(did);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Mitglied entfernen?'),
        content: Text(
          '$name wird aus dem Kanal ${widget.channel.name} entfernt.',
          style: const TextStyle(color: AppColors.onDark),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen',
                style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Entfernen'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Notify the removed member via DM.
    await context.read<ChatProvider>().sendMessage(
          did,
          'Du wurdest aus dem Kanal ${widget.channel.name} entfernt.',
        );

    // Update member list.
    final newMembers =
        widget.channel.members.where((d) => d != did).toList();
    await GroupChannelService.instance
        .updateMembers(widget.channel.name, newMembers);

    if (mounted) setState(() {});
  }

  // ── Delete channel ────────────────────────────────────────────────────────

  Future<void> _deleteChannel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('${widget.channel.name} löschen?'),
        content: const Text(
          'Der Kanal wird von deinem Gerät entfernt. '
          'Andere Mitglieder sehen keine weiteren Nachrichten.',
          style: TextStyle(color: AppColors.onDark),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen',
                style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await GroupChannelService.instance
        .leaveChannel(widget.channel.name);
    if (mounted) Navigator.of(context).pop();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final members = _otherMembers;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Kanal verwalten'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else
            TextButton(
              onPressed: _save,
              child: const Text('Speichern',
                  style: TextStyle(
                      color: AppColors.gold, fontWeight: FontWeight.bold)),
            ),
        ],
      ),
      body: ListView(
        children: [
          // ── ALLGEMEIN ──────────────────────────────────────────────────
          _SectionHeader(label: 'ALLGEMEIN'),
          _InfoCard(children: [
            // Name
            ListTile(
              dense: true,
              title: const Text('Kanalname',
                  style: TextStyle(
                      color: AppColors.gold,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2)),
              subtitle: TextField(
                controller: _nameCtrl,
                style: const TextStyle(color: AppColors.onDark),
                decoration: InputDecoration(
                  prefixText: '#',
                  prefixStyle:
                      const TextStyle(color: AppColors.gold, fontSize: 15),
                  hintText: 'kanalname',
                  hintStyle: const TextStyle(color: Colors.grey),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            const Divider(height: 1, color: Colors.white10),
            // Description
            ListTile(
              dense: true,
              title: const Text('Beschreibung',
                  style: TextStyle(
                      color: AppColors.gold,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2)),
              subtitle: TextField(
                controller: _descCtrl,
                style: const TextStyle(color: AppColors.onDark),
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: 'Kurze Beschreibung des Kanals',
                  hintStyle: TextStyle(color: Colors.grey),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            const Divider(height: 1, color: Colors.white10),
            // Channel type
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('KANAL-TYP',
                      style: TextStyle(
                          color: AppColors.gold,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2)),
                  const SizedBox(height: 10),
                  SegmentedButton<_ChannelType>(
                    segments: const [
                      ButtonSegment(
                        value: _ChannelType.public,
                        label: Text('Öffentlich'),
                        icon: Icon(Icons.public, size: 16),
                      ),
                      ButtonSegment(
                        value: _ChannelType.privateVisible,
                        label: Text('Privat'),
                        icon: Icon(Icons.lock_outline, size: 16),
                      ),
                      ButtonSegment(
                        value: _ChannelType.privateHidden,
                        label: Text('Unsichtbar'),
                        icon: Icon(Icons.visibility_off_outlined, size: 16),
                      ),
                    ],
                    selected: {_type},
                    onSelectionChanged: (s) =>
                        setState(() => _type = s.first),
                    style: ButtonStyle(
                      backgroundColor:
                          WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.selected)) {
                          return AppColors.gold.withValues(alpha: 0.2);
                        }
                        return Colors.transparent;
                      }),
                      foregroundColor:
                          WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.selected)) {
                          return AppColors.gold;
                        }
                        return Colors.grey;
                      }),
                      side: WidgetStatePropertyAll(
                          BorderSide(color: AppColors.gold.withValues(alpha: 0.3))),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _typeDescription(_type),
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
            ),
          ]),

          const SizedBox(height: 8),

          // ── MITGLIEDER ─────────────────────────────────────────────────
          if (members.isNotEmpty) ...[
            _SectionHeader(
                label: 'MITGLIEDER (${members.length})'),
            _InfoCard(
              children: [
                for (int i = 0; i < members.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, color: Colors.white10),
                  _MemberTile(
                    did: members[i],
                    onRemove: () => _removeMember(members[i]),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
          ],

          // ── AKTIONEN ───────────────────────────────────────────────────
          _SectionHeader(label: 'AKTIONEN'),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.delete_forever,
                    color: Colors.redAccent),
                label: const Text('Kanal löschen',
                    style: TextStyle(color: Colors.redAccent)),
                style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.redAccent)),
                onPressed: _deleteChannel,
              ),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  String _typeDescription(_ChannelType t) {
    switch (t) {
      case _ChannelType.public:
        return 'Jeder kann beitreten und den Kanal finden.';
      case _ChannelType.privateVisible:
        return 'Der Kanal ist sichtbar, aber Beitritt erfordert Einladung oder Anfrage.';
      case _ChannelType.privateHidden:
        return 'Der Kanal erscheint nicht in der Suche. Nur per Einladung.';
    }
  }
}

// ── Member tile ────────────────────────────────────────────────────────────────

class _MemberTile extends StatelessWidget {
  const _MemberTile({required this.did, required this.onRemove});
  final String did;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final name = ContactService.instance.getDisplayName(did);
    return ListTile(
      leading: PeerAvatar(did: did, size: 36),
      title: Text(name, style: const TextStyle(color: AppColors.onDark)),
      subtitle: Text(
        did.length > 20
            ? '${did.substring(0, 10)}…${did.substring(did.length - 8)}'
            : did,
        style: const TextStyle(color: Colors.grey, fontSize: 11),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent),
        tooltip: 'Entfernen',
        onPressed: onRemove,
      ),
    );
  }
}

// ── Shared layout helpers ──────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(
        label,
        style: const TextStyle(
            color: AppColors.gold,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}
