import 'package:flutter/material.dart';

import '../../core/contacts/contact_service.dart';
import '../../core/identity/identity_service.dart';
import '../../services/role_service.dart';
import '../../shared/theme/app_theme.dart';

/// Screen for the superadmin to manage system admins.
class AdminManagementScreen extends StatefulWidget {
  const AdminManagementScreen({super.key});

  @override
  State<AdminManagementScreen> createState() => _AdminManagementScreenState();
}

class _AdminManagementScreenState extends State<AdminManagementScreen> {
  List<String> _admins = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _admins = List.from(RoleService.instance.systemAdmins);
    });
  }

  Future<void> _revoke(String targetDid) async {
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final name = ContactService.instance.getDisplayName(targetDid);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Admin entfernen?',
            style: TextStyle(color: Colors.redAccent)),
        content: Text(
          '$name als System-Admin entfernen?',
          style: const TextStyle(color: AppColors.onDark),
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
            child: const Text('Entfernen'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await RoleService.instance.revokeSystemAdmin(myDid, targetDid);
      _reload();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$name als Admin entfernt.')),
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

  Future<void> _addAdmin() async {
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final contacts = ContactService.instance.contacts
        .where((c) => !_admins.contains(c.did))
        .toList();

    if (contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Keine weiteren Kontakte verfügbar.')),
      );
      return;
    }

    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Admin ernennen',
            style: TextStyle(color: AppColors.gold)),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: contacts.length,
            itemBuilder: (_, i) {
              final c = contacts[i];
              return ListTile(
                title: Text(c.pseudonym,
                    style: const TextStyle(color: AppColors.onDark)),
                onTap: () => Navigator.pop(ctx, c.did),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen',
                style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );

    if (selected == null || !mounted) return;

    final name = ContactService.instance.getDisplayName(selected);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Admin ernennen?',
            style: TextStyle(color: AppColors.gold)),
        content: Text(
          '$name zum System-Admin ernennen?',
          style: const TextStyle(color: AppColors.onDark),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:
                const Text('Abbrechen', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.gold,
              foregroundColor: AppColors.deepBlue,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ernennen'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await RoleService.instance.grantSystemAdmin(myDid, selected);
      _reload();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$name wurde zum System-Admin ernannt.'),
            backgroundColor: AppColors.gold,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('System-Admins verwalten')),
      body: _admins.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.manage_accounts,
                      size: 48, color: Colors.grey[700]),
                  const SizedBox(height: 12),
                  const Text(
                    'Keine System-Admins ernannt.',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Tippe auf + um einen Admin zu ernennen.',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
            )
          : ListView.separated(
              itemCount: _admins.length,
              separatorBuilder: (_, __) => const Divider(
                height: 1,
                indent: 56,
                color: AppColors.surfaceVariant,
              ),
              itemBuilder: (ctx, i) {
                final did = _admins[i];
                final name = ContactService.instance.getDisplayName(did);
                return ListTile(
                  leading:
                      const Icon(Icons.shield_outlined, color: AppColors.gold),
                  title: Text(name),
                  subtitle: Text(
                    did.length > 20
                        ? '${did.substring(0, 10)}…${did.substring(did.length - 8)}'
                        : did,
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: TextButton(
                    onPressed: () => _revoke(did),
                    child: const Text(
                      'Entfernen',
                      style: TextStyle(color: Colors.redAccent),
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.gold,
        foregroundColor: AppColors.deepBlue,
        icon: const Icon(Icons.person_add),
        label: const Text('Admin hinzufügen'),
        onPressed: _addAdmin,
      ),
    );
  }
}
