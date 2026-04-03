import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:nexus_oneapp/core/contacts/contact.dart';
import 'package:nexus_oneapp/core/contacts/contact_service.dart';
import 'package:nexus_oneapp/shared/theme/app_theme.dart';
import 'package:nexus_oneapp/shared/widgets/peer_avatar.dart';

import '../../services/contact_request_service.dart';
import '../invite/invite_screen.dart';
import 'contact_detail_screen.dart';
import 'contact_request.dart';
import 'contact_requests_screen.dart';
import 'manual_key_input_dialog.dart';
import 'widgets/trust_badge.dart';

/// Full-screen contacts management view.
///
/// Accessible from the drawer menu (rootNavigator push, no bottom nav).
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key, this.onContactSelected});

  /// When set, tapping a contact calls this instead of opening ContactDetailScreen.
  final void Function(Contact)? onContactSelected;

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  List<Contact> _contacts = [];
  String _query = '';
  TrustLevel? _filter; // null = show all
  bool _showSearch = false;
  final _searchCtrl = TextEditingController();
  StreamSubscription<List<ContactRequest>>? _requestSub;
  int _pendingRequestCount = 0;

  @override
  void initState() {
    super.initState();
    _reload();
    _pendingRequestCount = ContactRequestService.instance.pendingCount;
    _requestSub = ContactRequestService.instance.stream.listen((_) {
      if (mounted) {
        setState(() {
          _pendingRequestCount = ContactRequestService.instance.pendingCount;
        });
      }
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _requestSub?.cancel();
    super.dispose();
  }

  void _reload() {
    setState(() {
      _contacts = _sorted(ContactService.instance.contacts);
    });
  }

  List<Contact> _sorted(List<Contact> all) {
    final list = [...all];
    list.sort((a, b) {
      final byLevel = b.trustLevel.sortWeight.compareTo(a.trustLevel.sortWeight);
      if (byLevel != 0) return byLevel;
      return a.pseudonym.toLowerCase().compareTo(b.pseudonym.toLowerCase());
    });
    return list;
  }

  List<Contact> get _visible {
    return _contacts.where((c) {
      if (_filter != null && c.trustLevel != _filter) return false;
      if (_query.isNotEmpty) {
        final q = _query.toLowerCase();
        if (c.pseudonym.toLowerCase().contains(q)) return true;
        if (c.did.toLowerCase().contains(q)) return true;
        if (c.notes?.toLowerCase().contains(q) ?? false) return true;
        return false;
      }
      return true;
    }).toList();
  }

  void _openDetail(Contact contact) async {
    if (widget.onContactSelected != null) {
      widget.onContactSelected!(contact);
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ContactDetailScreen(did: contact.did),
      ),
    );
    _reload(); // refresh after any changes
  }

  void _showAddOptions() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Kontakt hinzufügen',
                style: const TextStyle(
                  color: AppColors.gold,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.qr_code_scanner, color: AppColors.gold),
              title: const Text('QR-Code scannen'),
              subtitle: const Text('Identität eines Kontakts scannen'),
              onTap: () {
                Navigator.pop(ctx);
                context.push('/qr-scanner');
              },
            ),
            ListTile(
              leading: const Icon(Icons.vpn_key, color: AppColors.gold),
              title: const Text('Schlüssel eingeben'),
              subtitle: const Text('Netzwerkschlüssel, npub oder DID einfügen'),
              onTap: () {
                Navigator.pop(ctx);
                showManualKeyInputDialog(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.radar, color: AppColors.gold),
              title: const Text('Peers im Netzwerk'),
              subtitle: const Text('Entdecke Peers über BLE, LAN oder Nostr'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).pop(); // go back to chat tab where Radar is
              },
            ),
            ListTile(
              leading: const Icon(Icons.person_add_outlined, color: AppColors.gold),
              title: const Text('Zur App einladen'),
              subtitle: const Text('Freunde mit einem Einladungscode einladen'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const InviteScreen(),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;

    return Scaffold(
      appBar: AppBar(
        title: _showSearch
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                style: const TextStyle(color: AppColors.onDark),
                decoration: InputDecoration(
                  hintText: 'Suche nach Name, DID, Notiz…',
                  hintStyle: const TextStyle(color: Colors.grey),
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _query = v),
              )
            : const Text('Kontakte'),
        actions: [
          // Contact requests badge button
          if (_pendingRequestCount > 0)
            Badge(
              label: Text('$_pendingRequestCount'),
              child: IconButton(
                icon: const Icon(Icons.person_add_alt_1),
                tooltip: 'Kontaktanfragen',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ContactRequestsScreen(),
                  ),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.person_add_alt_1),
              tooltip: 'Kontaktanfragen',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ContactRequestsScreen(),
                ),
              ),
            ),
          IconButton(
            icon: Icon(_showSearch ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _showSearch = !_showSearch;
                if (!_showSearch) {
                  _searchCtrl.clear();
                  _query = '';
                }
              });
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Filter chips ─────────────────────────────────────────────────
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                _FilterChip(
                  label: 'Alle',
                  selected: _filter == null,
                  onTap: () => setState(() => _filter = null),
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: 'Kontakte',
                  selected: _filter == TrustLevel.contact,
                  color: TrustBadge.colorFor(TrustLevel.contact),
                  onTap: () => setState(() => _filter = TrustLevel.contact),
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: 'Vertrauenspersonen',
                  selected: _filter == TrustLevel.trusted,
                  color: TrustBadge.colorFor(TrustLevel.trusted),
                  onTap: () => setState(() => _filter = TrustLevel.trusted),
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: 'Bürgen',
                  selected: _filter == TrustLevel.guardian,
                  color: TrustBadge.colorFor(TrustLevel.guardian),
                  onTap: () => setState(() => _filter = TrustLevel.guardian),
                ),
              ],
            ),
          ),

          const Divider(height: 1, color: AppColors.surfaceVariant),

          // ── Contact list ─────────────────────────────────────────────────
          Expanded(
            child: visible.isEmpty
                ? _EmptyState(
                    hasContacts: _contacts.isNotEmpty,
                    onAdd: _showAddOptions,
                  )
                : ListView.separated(
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => const Divider(
                      height: 1,
                      indent: 72,
                      color: AppColors.surfaceVariant,
                    ),
                    itemBuilder: (ctx, i) => _ContactTile(
                      contact: visible[i],
                      onTap: () => _openDetail(visible[i]),
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddOptions,
        backgroundColor: AppColors.gold,
        foregroundColor: AppColors.deepBlue,
        tooltip: 'Kontakt hinzufügen',
        child: const Icon(Icons.person_add),
      ),
    );
  }
}

// ── Filter chip ───────────────────────────────────────────────────────────────

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.gold;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? c.withValues(alpha: 0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? c : Colors.grey.withValues(alpha: 0.4),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? c : Colors.grey,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

// ── Contact tile ──────────────────────────────────────────────────────────────

class _ContactTile extends StatelessWidget {
  const _ContactTile({required this.contact, required this.onTap});

  final Contact contact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final lastSeen = _formatLastSeen(contact.lastSeen);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: PeerAvatar(did: contact.did, profileImage: contact.profileImage),
      title: Row(
        children: [
          Expanded(
            child: Text(
              contact.pseudonym,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.onDark,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          TrustBadge(level: contact.trustLevel, small: true),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            lastSeen,
            style: const TextStyle(color: Colors.grey, fontSize: 11),
          ),
          if (contact.notes != null && contact.notes!.isNotEmpty)
            Text(
              contact.notes!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
        ],
      ),
      onTap: onTap,
    );
  }

  String _formatLastSeen(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 2) return 'Gerade online';
    if (diff.inHours < 1) return 'Vor ${diff.inMinutes} Min.';
    if (diff.inDays < 1) return 'Vor ${diff.inHours} Std.';
    if (diff.inDays == 1) return 'Gestern';
    if (diff.inDays < 7) return 'Vor ${diff.inDays} Tagen';
    final d = dt.toLocal();
    return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasContacts, required this.onAdd});

  final bool hasContacts;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.people_outline, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              hasContacts
                  ? 'Kein Kontakt entspricht dem Filter.'
                  : 'Noch keine Kontakte.\nEntdecke Peers im Netzwerk oder scanne einen QR-Code!',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, fontSize: 16),
            ),
            if (!hasContacts) ...[
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.person_add),
                label: const Text('Kontakt hinzufügen'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
