import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'package:provider/provider.dart';

import '../../core/identity/identity_service.dart';
import '../../core/utils/geohash.dart';
import '../chat/chat_provider.dart';
import '../../services/role_service.dart';
import '../../shared/theme/app_theme.dart';
import 'cell.dart';
import 'cell_edit_screen.dart';
import 'cell_member.dart';
import 'cell_requests_screen.dart';
import 'cell_service.dart';

/// Displays details about a cell and provides management actions.
class CellInfoScreen extends StatefulWidget {
  final Cell cell;
  const CellInfoScreen({super.key, required this.cell});

  @override
  State<CellInfoScreen> createState() => _CellInfoScreenState();
}

class _CellInfoScreenState extends State<CellInfoScreen> {
  StreamSubscription<void>? _sub;
  late Cell _cell;

  @override
  void initState() {
    super.initState();
    _cell = widget.cell;
    _sub = CellService.instance.stream.listen((_) {
      if (mounted) {
        setState(() {
          _cell = CellService.instance.myCells
              .firstWhere((c) => c.id == _cell.id, orElse: () => _cell);
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  String get _myDid =>
      IdentityService.instance.currentIdentity?.did ?? '';

  CellMember? get _myMembership =>
      CellService.instance.membersOf(_cell.id)
          .where((m) => m.did == _myDid)
          .firstOrNull;

  bool get _isFounder => _myMembership?.role == MemberRole.founder;
  bool get _isMod => _myMembership?.role == MemberRole.moderator;
  bool get _canManage => _isFounder || _isMod;

  Future<void> _updateGeohash() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('GPS nicht verfügbar.')),
        );
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Standort-Berechtigung verweigert.')),
        );
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 10),
      );
      final hash = encodeGeohash(pos.latitude, pos.longitude);
      await CellService.instance.updateCellGeohash(_cell.id, hash);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Standort aktualisiert ✓'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// True when the local user is a superadmin or system-admin.
  /// Note: founders cannot delete cells — only admins can.
  bool get _isAdminUser => RoleService.instance.isSystemAdmin(_myDid);

  Future<void> _deleteCell() async {
    // Step 1: warning dialog.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Zelle löschen',
            style: TextStyle(color: Colors.red)),
        content: Text(
          'Zelle "${_cell.name}" wirklich löschen? '
          'Alle Mitglieder werden entfernt. '
          'Das kann nicht rückgängig gemacht werden.',
          style: TextStyle(color: AppColors.onDark.withValues(alpha: 0.85)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Weiter',
                  style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Step 2: type cell name to confirm.
    final nameCtrl = TextEditingController();
    final doubleConfirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Zellenname bestätigen',
            style: TextStyle(color: AppColors.onDark)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tippe den Namen der Zelle ein, um die Löschung zu bestätigen:',
              style: TextStyle(
                  color: AppColors.onDark.withValues(alpha: 0.8)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtrl,
              autofocus: true,
              style: const TextStyle(color: AppColors.onDark),
              decoration: InputDecoration(
                hintText: _cell.name,
                hintStyle: TextStyle(
                    color: AppColors.onDark.withValues(alpha: 0.4)),
                enabledBorder: const UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.red)),
                focusedBorder: const UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.red)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          StatefulBuilder(
            builder: (ctx2, setInner) {
              nameCtrl.addListener(() => setInner(() {}));
              return TextButton(
                onPressed: nameCtrl.text == _cell.name
                    ? () => Navigator.pop(ctx, true)
                    : null,
                child: const Text('Endgültig löschen',
                    style: TextStyle(color: Colors.red)),
              );
            },
          ),
        ],
      ),
    );
    if (doubleConfirmed != true || !mounted) return;

    // Perform deletion.
    final cellName = _cell.name;
    final cellId = _cell.id;
    final cellJson = _cell.toJson();
    await CellService.instance.deleteCell(cellId);
    if (mounted) {
      await context.read<ChatProvider>().deleteCellChannels(cellId);
      // Kind-5 (NIP-09): asks relays to delete the original announcement.
      context.read<ChatProvider>().publishNostrCellDeletion(cellId, cellName);
      // Kind-30000 with deleted:true + tag: notifies all member devices.
      context.read<ChatProvider>().publishNostrCellDissolution(cellJson);
    }

    if (mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Die Zelle "$cellName" wurde aufgelöst.'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _leaveCell() async {
    if (_isFounder) {
      final otherMembers = CellService.instance.membersOf(_cell.id)
          .where((m) => m.isConfirmed && m.did != _myDid)
          .toList();

      if (otherMembers.isEmpty) {
        // Only member — must delete instead of leaving.
        if (!mounted) return;
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.surface,
            title: const Text('Zelle verlassen nicht möglich',
                style: TextStyle(color: AppColors.onDark)),
            content: const Text(
              'Du bist das einzige Mitglied. Lösche die Zelle statt sie zu verlassen.',
              style: TextStyle(color: AppColors.onDark),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('OK')),
            ],
          ),
        );
        return;
      }

      // Must choose a successor.
      final successor = await _pickSuccessor(otherMembers);
      if (successor == null || !mounted) return;

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Gründer-Rolle übertragen',
              style: TextStyle(color: AppColors.onDark)),
          content: Text(
            'Möchtest du …${successor.did.substring(successor.did.length > 12 ? successor.did.length - 12 : 0)} '
            'zum neuen Gründer von "${_cell.name}" ernennen und die Zelle verlassen?',
            style: TextStyle(color: AppColors.onDark.withValues(alpha: 0.85)),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Abbrechen')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Übertragen & Verlassen',
                    style: TextStyle(color: Colors.orange))),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      await CellService.instance.transferFounderRole(_cell.id, successor.did);
      final cellId = _cell.id;
      await CellService.instance.leaveCell(cellId);
      if (mounted) {
        await context.read<ChatProvider>().leaveCellChannels(cellId);
        Navigator.of(context).pop();
      }
      return;
    }

    // Regular member leave.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Zelle verlassen',
            style: TextStyle(color: AppColors.onDark)),
        content: Text(
          'Möchtest du die Zelle "${_cell.name}" wirklich verlassen?',
          style: TextStyle(color: AppColors.onDark.withValues(alpha: 0.8)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Verlassen',
                  style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      final cellId = _cell.id;
      await CellService.instance.leaveCell(cellId);
      if (mounted) {
        await context.read<ChatProvider>().leaveCellChannels(cellId);
        Navigator.of(context).pop();
      }
    }
  }

  /// Shows a dialog to pick a successor from [candidates].
  Future<CellMember?> _pickSuccessor(List<CellMember> candidates) {
    return showDialog<CellMember>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Nachfolger wählen',
            style: TextStyle(color: AppColors.onDark)),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: candidates.length,
            itemBuilder: (_, i) {
              final m = candidates[i];
              final shortDid = '…${m.did.substring(m.did.length > 12 ? m.did.length - 12 : 0)}';
              final roleLabel = m.role == MemberRole.moderator
                  ? 'Moderator'
                  : 'Mitglied';
              return ListTile(
                leading: const Icon(Icons.person, color: AppColors.gold),
                title: Text(shortDid,
                    style: const TextStyle(color: AppColors.onDark)),
                subtitle: Text(roleLabel,
                    style: TextStyle(
                        color: AppColors.onDark.withValues(alpha: 0.6),
                        fontSize: 12)),
                onTap: () => Navigator.pop(ctx, m),
              );
            },
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Abbrechen')),
        ],
      ),
    );
  }

  Future<void> _removeMember(CellMember target) async {
    final shortDid =
        '…${target.did.substring(target.did.length > 12 ? target.did.length - 12 : 0)}';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Mitglied entfernen',
            style: TextStyle(color: Colors.redAccent)),
        content: Text(
          'Möchtest du $shortDid aus der Zelle "${_cell.name}" entfernen? '
          'Die Person verliert sofort den Zugang.',
          style: TextStyle(color: AppColors.onDark.withValues(alpha: 0.85)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Entfernen',
                  style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await CellService.instance.removeMember(_cell.id, target.did);

      // Post system message in discussion channel.
      if (mounted) {
        await context
            .read<ChatProvider>()
            .postCellSystemMessage(_cell.id, '$shortDid wurde aus der Zelle entfernt.');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$shortDid wurde aus der Zelle entfernt.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler: $e')),
        );
      }
    }
  }

  Future<void> _transferFounderRole(CellMember target) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Gründer-Rolle übertragen',
            style: TextStyle(color: AppColors.onDark)),
        content: Text(
          'Möchtest du …${target.did.substring(target.did.length > 12 ? target.did.length - 12 : 0)} '
          'zum neuen Gründer von "${_cell.name}" ernennen? '
          'Du wirst danach zum normalen Mitglied.',
          style: TextStyle(color: AppColors.onDark.withValues(alpha: 0.85)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Ernennen',
                  style: TextStyle(color: AppColors.gold))),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await CellService.instance.transferFounderRole(_cell.id, target.did);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                '…${target.did.substring(target.did.length > 12 ? target.did.length - 12 : 0)} ist jetzt Gründer von ${_cell.name}.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final members = CellService.instance.membersOf(_cell.id);
    final pendingRequests = CellService.instance
        .requestsFor(_cell.id)
        .where((r) => r.isPending)
        .length;

    return Scaffold(
      appBar: AppBar(
        title: Text(_cell.name),
        backgroundColor: AppColors.deepBlue,
      ),
      backgroundColor: AppColors.deepBlue,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Header card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.gold.withValues(alpha: 0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _cell.cellType == CellType.local
                          ? Icons.location_on
                          : Icons.group_work,
                      color: AppColors.gold,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _cell.cellType == CellType.local
                          ? 'Lokale Gemeinschaft'
                          : 'Thematische Gemeinschaft',
                      style: TextStyle(
                        color: AppColors.gold,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  _cell.name,
                  style: const TextStyle(
                    color: AppColors.onDark,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (_cell.description.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    _cell.description,
                    style: TextStyle(
                      color: AppColors.onDark.withValues(alpha: 0.7),
                      height: 1.5,
                    ),
                  ),
                ],
                if (_cell.cellType == CellType.local &&
                    _cell.locationName != null) ...[
                  const SizedBox(height: 8),
                  Row(children: [
                    const Icon(Icons.place, size: 14, color: Colors.blue),
                    const SizedBox(width: 4),
                    Text(_cell.locationName!,
                        style: const TextStyle(
                            color: Colors.blue, fontSize: 13)),
                  ]),
                ],
                if (_cell.cellType == CellType.local &&
                    _cell.geohash == null &&
                    _isFounder) ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _updateGeohash,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.gold,
                      side: const BorderSide(color: AppColors.gold),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                    ),
                    icon: const Icon(Icons.my_location, size: 16),
                    label: const Text('Standort aktualisieren',
                        style: TextStyle(fontSize: 13)),
                  ),
                ],
                if (_cell.cellType == CellType.thematic) ...[
                  if (_cell.category != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _cell.category!,
                      style: TextStyle(
                        color: AppColors.onDark.withValues(alpha: 0.6),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 12),
                Text(
                  '${_cell.memberCount}/${_cell.maxMembers} Mitglieder',
                  style: TextStyle(
                    color: AppColors.onDark.withValues(alpha: 0.6),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Founder management actions
          if (_canManage) ...[
            if (pendingRequests > 0)
              _ActionTile(
                icon: Icons.person_add,
                label: 'Offene Anfragen ($pendingRequests)',
                iconColor: Colors.orange,
                onTap: () => Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        CellRequestsScreen(cellId: _cell.id, cellName: _cell.name),
                  ),
                ),
              ),
            const SizedBox(height: 8),
          ],
          if (_isFounder) ...[
            _ActionTile(
              icon: Icons.edit,
              label: 'Zelle bearbeiten',
              iconColor: AppColors.gold,
              onTap: () async {
                await Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute<void>(
                    builder: (_) => CellEditScreen(cell: _cell),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
          ],

          // Member list
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Mitglieder',
              style: TextStyle(
                color: AppColors.gold,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ),
          ...members.map((m) {
            final canTransferFounder = ((_isFounder || _isAdminUser) &&
                m.did != _myDid &&
                (m.role == MemberRole.member ||
                    m.role == MemberRole.moderator));
            // Founder can remove mods+members; mod can remove only members.
            final canRemove = m.did != _myDid &&
                m.role != MemberRole.founder &&
                (_isFounder ||
                    (_isMod && m.role == MemberRole.member) ||
                    _isAdminUser);
            return _MemberTile(
              member: m,
              isMe: m.did == _myDid,
              canPromote: _isFounder && m.role == MemberRole.member,
              canTransferFounder: canTransferFounder,
              canRemove: canRemove,
              onPromote: _isFounder
                  ? () async {
                      await CellService.instance
                          .promoteModerator(_cell.id, m.did);
                    }
                  : null,
              onTransferFounder: canTransferFounder
                  ? () => _transferFounderRole(m)
                  : null,
              onRemove: canRemove ? () => _removeMember(m) : null,
            );
          }),
          const SizedBox(height: 24),

          // Danger zone
          _ActionTile(
            icon: Icons.exit_to_app,
            label: 'Zelle verlassen',
            iconColor: Colors.red,
            textColor: Colors.red,
            onTap: _leaveCell,
          ),
          if (_isAdminUser) ...[
            const SizedBox(height: 8),
            _ActionTile(
              icon: Icons.delete_forever,
              label: 'Zelle löschen',
              iconColor: Colors.red,
              textColor: Colors.red,
              onTap: _deleteCell,
            ),
          ],
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color iconColor;
  final Color? textColor;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.iconColor,
    required this.onTap,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: iconColor),
      title: Text(
        label,
        style: TextStyle(color: textColor ?? AppColors.onDark),
      ),
      trailing:
          const Icon(Icons.chevron_right, color: AppColors.surfaceVariant),
      onTap: onTap,
      tileColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );
  }
}

class _MemberTile extends StatelessWidget {
  final CellMember member;
  final bool isMe;
  final bool canPromote;
  final bool canTransferFounder;
  final bool canRemove;
  final VoidCallback? onPromote;
  final VoidCallback? onTransferFounder;
  final VoidCallback? onRemove;

  const _MemberTile({
    required this.member,
    required this.isMe,
    required this.canPromote,
    required this.canTransferFounder,
    required this.canRemove,
    this.onPromote,
    this.onTransferFounder,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final roleLabel = switch (member.role) {
      MemberRole.founder => 'Gründer',
      MemberRole.moderator => 'Moderator',
      MemberRole.member => 'Mitglied',
      MemberRole.pending => 'Ausstehend',
    };

    final shortDid = isMe
        ? 'Du'
        : '…${member.did.substring(member.did.length > 12 ? member.did.length - 12 : 0)}';

    Widget tile = Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: AppColors.gold.withValues(alpha: 0.2),
            child: Text(
              member.did.substring(member.did.length - 2),
              style: const TextStyle(
                color: AppColors.gold,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  shortDid,
                  style: TextStyle(
                    color: isMe ? AppColors.gold : AppColors.onDark,
                    fontWeight: isMe ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                Text(
                  roleLabel,
                  style: TextStyle(
                    color: AppColors.onDark.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          if (canPromote)
            TextButton(
              onPressed: onPromote,
              child: const Text('Zum Moderator'),
            ),
          if (canRemove)
            IconButton(
              icon: const Icon(Icons.person_remove_outlined,
                  color: Colors.redAccent, size: 20),
              tooltip: 'Mitglied entfernen',
              onPressed: onRemove,
            ),
        ],
      ),
    );

    if (canTransferFounder || canRemove) {
      tile = GestureDetector(
        onLongPress: () => _showContextMenu(context, shortDid),
        child: tile,
      );
    }

    return tile;
  }

  void _showContextMenu(BuildContext context, String name) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canTransferFounder)
              ListTile(
                leading: const Icon(Icons.stars, color: AppColors.gold),
                title: Text('$name zum Gründer ernennen',
                    style: const TextStyle(color: AppColors.onDark)),
                onTap: () {
                  Navigator.pop(context);
                  onTransferFounder?.call();
                },
              ),
            if (canRemove)
              ListTile(
                leading: const Icon(Icons.person_remove_outlined,
                    color: Colors.redAccent),
                title: Text('$name entfernen',
                    style: const TextStyle(color: Colors.redAccent)),
                onTap: () {
                  Navigator.pop(context);
                  onRemove?.call();
                },
              ),
          ],
        ),
      ),
    );
  }
}
