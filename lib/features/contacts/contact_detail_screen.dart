import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nexus_oneapp/core/contacts/contact.dart';
import 'package:nexus_oneapp/core/contacts/contact_service.dart';
import 'package:nexus_oneapp/core/identity/identity_service.dart';
import 'package:nexus_oneapp/shared/theme/app_theme.dart';
import 'package:nexus_oneapp/shared/widgets/peer_avatar.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../features/chat/chat_provider.dart';

import 'screens/key_verification_screen.dart';
import 'widgets/trust_badge.dart';

/// Full-screen detail view for a single contact.
class ContactDetailScreen extends StatefulWidget {
  const ContactDetailScreen({super.key, required this.did});

  final String did;

  @override
  State<ContactDetailScreen> createState() => _ContactDetailScreenState();
}

class _ContactDetailScreenState extends State<ContactDetailScreen> {
  late Contact _contact;
  bool _notFound = false;
  final _notesCtrl = TextEditingController();
  bool _editingNotes = false;
  StreamSubscription<void>? _contactsSub;

  @override
  void initState() {
    super.initState();
    _load();
    // Reload when ContactService updates (e.g. after Kind-0 fetch completes).
    _contactsSub = ContactService.instance.contactsChanged.listen((_) => _load());
    // Actively fetch fresh Kind-0 metadata from Nostr relays.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<ChatProvider>().fetchContactMetadata(widget.did);
      }
    });
  }

  void _load() {
    final c = ContactService.instance.findByDid(widget.did);
    if (c == null) {
      setState(() => _notFound = true);
      return;
    }
    setState(() {
      _contact = c;
      _notesCtrl.text = c.notes ?? '';
      _notFound = false;
    });
  }

  @override
  void dispose() {
    _contactsSub?.cancel();
    _notesCtrl.dispose();
    super.dispose();
  }

  // ── Trust level change ──────────────────────────────────────────────────

  void _showTrustSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
                child: const Text(
                  'Vertrauensstufe ändern',
                  style: TextStyle(
                    color: AppColors.gold,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
              ...TrustLevel.values.map((level) {
                final isCurrent = level == _contact.trustLevel;
                return ListTile(
                  leading: TrustBadge(level: level, small: true),
                  title: Text(level.label),
                  subtitle: Text(
                    level.description,
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  trailing: isCurrent
                      ? const Icon(Icons.check, color: AppColors.gold)
                      : null,
                  onTap: isCurrent
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          _confirmTrustChange(level);
                        },
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmTrustChange(TrustLevel newLevel) async {
    final isUpgrade =
        newLevel.sortWeight > _contact.trustLevel.sortWeight;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          isUpgrade ? 'Stufe erhöhen?' : 'Stufe verringern?',
          style: TextStyle(
            color: isUpgrade ? AppColors.gold : Colors.orange,
          ),
        ),
        content: Text(
          isUpgrade
              ? '${_contact.pseudonym} wird zu "${newLevel.label}" hochgestuft.\n\n'
                  '${newLevel.description}'
              : 'Achtung: ${_contact.pseudonym} wird auf "${newLevel.label}" '
                  'herabgestuft. Freigegebene Profilfelder werden eingeschränkt.',
          style: const TextStyle(color: AppColors.onDark),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: isUpgrade ? AppColors.gold : Colors.orange,
              foregroundColor: AppColors.deepBlue,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isUpgrade ? 'Hochstufen' : 'Herabstufen'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ContactService.instance.setTrustLevel(_contact.did, newLevel);
      _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${_contact.pseudonym} ist jetzt "${newLevel.label}".',
            ),
          ),
        );
      }
    }
  }

  // ── Notes ───────────────────────────────────────────────────────────────

  Future<void> _saveNotes() async {
    await ContactService.instance.updateNotes(
      _contact.did,
      _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
    );
    setState(() => _editingNotes = false);
    _load();
  }

  // ── Actions ─────────────────────────────────────────────────────────────

  Future<void> _removeContact() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Kontakt entfernen?'),
        content: Text(
          '${_contact.pseudonym} wird aus deiner Kontaktliste entfernt. '
          'Nachrichten bleiben erhalten.',
          style: const TextStyle(color: AppColors.onDark),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Entfernen'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ContactService.instance.removeContact(_contact.did);
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _blockContact() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Person blockieren?'),
        content: Text(
          '${_contact.pseudonym} wird stumm geschaltet. '
          'Sie können weiterhin schreiben, aber du siehst ihre Nachrichten nicht mehr. '
          'Sie werden nicht benachrichtigt.',
          style: const TextStyle(color: AppColors.onDark),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Blockieren'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ContactService.instance.blockContact(_contact.did);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_contact.pseudonym} wurde blockiert.'),
          ),
        );
      }
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_notFound) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Kontakt nicht gefunden.')),
      );
    }

    debugPrint('[ContactDetail] contact.about=${_contact.about}  '
        'website=${_contact.website}  nip05=${_contact.nip05}');

    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final shortDid = _contact.did.length > 20
        ? '${_contact.did.substring(0, 10)}…${_contact.did.substring(_contact.did.length - 8)}'
        : _contact.did;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Kontaktdetails'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              if (v == 'block') _blockContact();
              if (v == 'remove') _removeContact();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'block',
                child: Row(
                  children: [
                    Icon(Icons.block, size: 18, color: Colors.orange),
                    SizedBox(width: 8),
                    Text('Blockieren'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'remove',
                child: Row(
                  children: [
                    Icon(Icons.person_remove, size: 18, color: Colors.redAccent),
                    SizedBox(width: 8),
                    Text('Kontakt entfernen',
                        style: TextStyle(color: Colors.redAccent)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(0),
        children: [
          // ── Header ──────────────────────────────────────────────────────
          Container(
            color: AppColors.surface,
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Column(
              children: [
                PeerAvatar(
                  did: _contact.did,
                  profileImage: _contact.profileImage,
                  size: 80,
                ),
                const SizedBox(height: 12),
                Text(
                  _contact.pseudonym,
                  style: const TextStyle(
                    color: AppColors.onDark,
                    fontWeight: FontWeight.bold,
                    fontSize: 22,
                  ),
                ),
                const SizedBox(height: 8),
                TrustBadge(level: _contact.trustLevel),
              ],
            ),
          ),

          const SizedBox(height: 8),

          // ── DID ─────────────────────────────────────────────────────────
          _InfoCard(
            children: [
              ListTile(
                dense: true,
                title: const Text(
                  'DID',
                  style: TextStyle(
                    color: AppColors.gold,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                subtitle: Text(
                  shortDid,
                  style: const TextStyle(
                    color: AppColors.onDark,
                    fontFamily: 'monospace',
                    fontSize: 13,
                  ),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.copy_outlined,
                      size: 18, color: AppColors.gold),
                  tooltip: 'DID kopieren',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _contact.did));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('DID kopiert')),
                    );
                  },
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // ── Trust level ──────────────────────────────────────────────────
          _SectionHeader('VERTRAUENSSTUFE'),
          _InfoCard(
            children: [
              ListTile(
                leading: TrustBadge(level: _contact.trustLevel, small: true),
                title: Text(_contact.trustLevel.label),
                subtitle: Text(
                  _contact.trustLevel.description,
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                trailing: TextButton(
                  onPressed: _showTrustSheet,
                  child: const Text('Ändern'),
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // ── Notes ───────────────────────────────────────────────────────
          _SectionHeader('NOTIZ (nur für dich)'),
          _InfoCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: _editingNotes
                    ? Column(
                        children: [
                          TextField(
                            controller: _notesCtrl,
                            autofocus: true,
                            maxLines: 4,
                            style: const TextStyle(color: AppColors.onDark),
                            decoration: InputDecoration(
                              hintText: 'Persönliche Notiz hinzufügen…',
                              hintStyle: const TextStyle(color: Colors.grey),
                              filled: true,
                              fillColor: AppColors.surfaceVariant,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => setState(() => _editingNotes = false),
                                child: const Text('Abbrechen',
                                    style: TextStyle(color: Colors.grey)),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton(
                                onPressed: _saveNotes,
                                child: const Text('Speichern'),
                              ),
                            ],
                          ),
                        ],
                      )
                    : GestureDetector(
                        onTap: () => setState(() => _editingNotes = true),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _contact.notes?.isNotEmpty == true
                                    ? _contact.notes!
                                    : 'Notiz hinzufügen…',
                                style: TextStyle(
                                  color: _contact.notes?.isNotEmpty == true
                                      ? AppColors.onDark
                                      : Colors.grey,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            const Icon(Icons.edit_outlined,
                                size: 16, color: AppColors.gold),
                          ],
                        ),
                      ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // ── Notification toggle ──────────────────────────────────────────
          _SectionHeader('BENACHRICHTIGUNGEN'),
          _InfoCard(
            children: [
              ListTile(
                leading: Icon(
                  ContactService.instance.isMuted(_contact.did)
                      ? Icons.notifications_off_outlined
                      : Icons.notifications_outlined,
                  color: ContactService.instance.isMuted(_contact.did)
                      ? Colors.grey
                      : AppColors.gold,
                ),
                title: const Text('Benachrichtigungen'),
                subtitle: Text(ContactService.instance.isMuted(_contact.did)
                    ? 'Stumm geschaltet'
                    : 'Aktiviert'),
                trailing: Switch(
                  value: !ContactService.instance.isMuted(_contact.did),
                  activeColor: AppColors.gold,
                  onChanged: (v) async {
                    if (v) {
                      await ContactService.instance
                          .unmuteContact(_contact.did);
                    } else {
                      // Permanent mute via the toggle
                      await ContactService.instance
                          .muteContact(_contact.did, null);
                    }
                    _load();
                  },
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // ── Visible profile fields ───────────────────────────────────────
          _SectionHeader('PROFILINFOS'),
          _ProfileFieldsCard(contact: _contact),

          const SizedBox(height: 8),

          // ── Encryption section ─────────────────────────────────────────
          _SectionHeader('VERSCHLÜSSELUNG'),
          _InfoCard(
            children: [
              if (_contact.encryptionPublicKey != null)
                ListTile(
                  leading: const Icon(Icons.lock, color: AppColors.gold, size: 20),
                  title: const Text('Ende-zu-Ende verschlüsselt'),
                  subtitle: const Text(
                    'Nachrichten mit diesem Kontakt sind verschlüsselt.',
                    style: TextStyle(fontSize: 12),
                  ),
                  trailing: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            KeyVerificationScreen(peerDid: _contact.did),
                      ),
                    ),
                    child: const Text(
                      'Verifizieren',
                      style: TextStyle(color: AppColors.gold, fontSize: 12),
                    ),
                  ),
                )
              else
                const ListTile(
                  leading: Icon(Icons.lock_open, color: Colors.grey, size: 20),
                  title: Text(
                    'Nicht verschlüsselt',
                    style: TextStyle(color: Colors.grey),
                  ),
                  subtitle: Text(
                    'Peer unterstützt (noch) keine Verschlüsselung.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 8),

          // ── Actions ─────────────────────────────────────────────────────
          _SectionHeader('AKTIONEN'),
          _InfoCard(
            children: [
              ListTile(
                leading:
                    const Icon(Icons.chat_bubble_outline, color: AppColors.gold),
                title: const Text('Nachricht senden'),
                onTap: () {
                  // Pop back – caller (ContactsScreen or ConversationsScreen)
                  // handles navigation to chat.
                  Navigator.of(context).pop({'action': 'chat', 'did': _contact.did});
                },
              ),
              const Divider(height: 1, indent: 56, color: AppColors.surfaceVariant),
              ListTile(
                leading: const Icon(Icons.qr_code, color: AppColors.gold),
                title: const Text('QR-Code zeigen'),
                onTap: () => _showQrCode(context),
              ),
              const Divider(height: 1, indent: 56, color: AppColors.surfaceVariant),
              ListTile(
                leading: const Icon(Icons.block, color: Colors.orange),
                title: const Text('Blockieren',
                    style: TextStyle(color: Colors.orange)),
                onTap: _blockContact,
              ),
              const Divider(height: 1, indent: 56, color: AppColors.surfaceVariant),
              ListTile(
                leading: const Icon(Icons.person_remove, color: Colors.redAccent),
                title: const Text('Kontakt entfernen',
                    style: TextStyle(color: Colors.redAccent)),
                onTap: _removeContact,
              ),
            ],
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  void _showQrCode(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('QR-Code anzeigen – Kommt bald')),
    );
  }
}

// ── Helper widgets ────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
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

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      child: Column(children: children),
    );
  }
}

/// German labels for known nexus_profile field keys.
/// Add new entries here when new fields are added to [UserProfile].
const _kNexusFieldLabels = <String, String>{
  'realName':  'KLARNAME',
  'location':  'STANDORT',
  'languages': 'SPRACHEN',
  'skills':    'FÄHIGKEITEN',
};

/// Shows the contact's Kind-0 metadata fields (about, website, nip05,
/// and generic nexus_profile fields like realName, location, languages, skills).
class _ProfileFieldsCard extends StatelessWidget {
  const _ProfileFieldsCard({required this.contact});
  final Contact contact;

  /// Converts a profile field value to a displayable string.
  String _format(dynamic value) {
    if (value is List) return value.join(', ');
    return value.toString();
  }

  @override
  Widget build(BuildContext context) {
    final fields = <Widget>[];

    if (contact.about != null && contact.about!.isNotEmpty) {
      fields.add(_FieldTile(label: 'BIO', value: contact.about!));
    }

    if (contact.website != null && contact.website!.isNotEmpty) {
      fields.add(_FieldTile(
        label: 'WEBSITE',
        value: contact.website!,
        onTap: () async {
          final uri = Uri.tryParse(contact.website!);
          if (uri != null && await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        },
        isLink: true,
      ));
    }

    if (contact.nip05 != null && contact.nip05!.isNotEmpty) {
      fields.add(_FieldTile(label: 'NOSTR-ADRESSE', value: contact.nip05!));
    }

    // Generic nexus_profile fields – automatically includes any future fields.
    for (final entry in contact.nexusProfile.entries) {
      final v = entry.value;
      if (v == null) continue;
      final display = _format(v);
      if (display.isEmpty) continue;
      final label = _kNexusFieldLabels[entry.key]
          ?? entry.key.toUpperCase(); // fallback for unknown future fields
      fields.add(_FieldTile(label: label, value: display));
    }

    if (fields.isEmpty) {
      return Container(
        color: AppColors.surface,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: const Text(
          'Dieser Kontakt hat keine weiteren Profilinfos geteilt.',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
      );
    }

    return Container(
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: fields
            .expand((w) => [w, const Divider(height: 1, indent: 16, color: AppColors.surfaceVariant)])
            .toList()
          ..removeLast(), // remove trailing divider
      ),
    );
  }
}

class _FieldTile extends StatelessWidget {
  const _FieldTile({
    required this.label,
    required this.value,
    this.onTap,
    this.isLink = false,
  });

  final String label;
  final String value;
  final VoidCallback? onTap;
  final bool isLink;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: AppColors.gold,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                color: isLink ? const Color(0xFF64B5F6) : AppColors.onDark,
                fontSize: 14,
                decoration: isLink ? TextDecoration.underline : null,
                decorationColor: isLink ? const Color(0xFF64B5F6) : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
