import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/contacts/contact_service.dart';
import '../../core/identity/identity_service.dart';
import '../../features/chat/chat_provider.dart';
import '../../features/governance/cell.dart';
import '../../features/governance/cell_service.dart';
import '../../shared/theme/app_theme.dart';

/// Superadmin screen to view all cells in the local DB, identify orphaned
/// cells (founded by an unknown DID), and delete them with a Kind-5 Nostr
/// dissolution event.
class AdminCellManagementScreen extends StatefulWidget {
  const AdminCellManagementScreen({super.key});

  @override
  State<AdminCellManagementScreen> createState() =>
      _AdminCellManagementScreenState();
}

class _AdminCellManagementScreenState
    extends State<AdminCellManagementScreen> {
  List<Cell> _cells = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadCells();
  }

  Future<void> _loadCells() async {
    // Re-load so the list is fresh even if CellService was loaded earlier.
    await CellService.instance.load();
    if (!mounted) return;
    setState(() {
      _cells = List.from(CellService.instance.myCells);
      _loading = false;
    });
  }

  /// A cell is "orphaned" when its founder DID is neither the current user
  /// nor any known contact.
  bool _isOrphaned(Cell cell) {
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    if (cell.createdBy == myDid) return false;
    return !ContactService.instance.contacts
        .any((c) => c.did == cell.createdBy);
  }

  Future<void> _deleteCell(BuildContext context, Cell cell) async {
    final chatProvider = context.read<ChatProvider>();
    final messenger = ScaffoldMessenger.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          'Zelle "${cell.name}" löschen?',
          style: const TextStyle(color: Colors.redAccent),
        ),
        content: Text(
          'ID: ${cell.id}\n\n'
          'Die Zelle wird aus der lokalen Datenbank gelöscht und ein '
          'Kind-5 Nostr-Dissolution-Event wird als Superadmin gesendet.',
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
            child: const Text('Löschen & Kind-5 senden'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await CellService.instance.deleteCell(cell.id);
      await chatProvider.deleteCellChannels(cell.id);

      // Kind-5: asks relays to delete the original announcement.
      chatProvider.publishNostrCellDeletion(cell.id, cell.name);
      // Kind-30000 with deleted:true: notifies all member devices.
      chatProvider.publishNostrCellDissolution(cell.toJson());

      if (!mounted) return;
      setState(() => _cells.removeWhere((c) => c.id == cell.id));
      messenger.showSnackBar(
        SnackBar(
          content: Text('Zelle "${cell.name}" gelöscht · Kind-5 gesendet.'),
          backgroundColor: Colors.redAccent,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Fehler: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final myDid = IdentityService.instance.currentIdentity?.did ?? '';
    final orphanCount = _cells.where(_isOrphaned).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Zellen verwalten'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Neu laden',
            onPressed: () {
              setState(() => _loading = true);
              _loadCells();
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _cells.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.hexagon_outlined,
                          size: 48, color: Colors.grey[700]),
                      const SizedBox(height: 12),
                      const Text(
                        'Keine Zellen in der Datenbank.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    // Summary bar
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      color: AppColors.surfaceVariant,
                      child: Text(
                        '${_cells.length} Zellen gesamt'
                        '${orphanCount > 0 ? ' · $orphanCount verwaist' : ''}',
                        style: TextStyle(
                          fontSize: 13,
                          color: orphanCount > 0
                              ? Colors.orange
                              : AppColors.onDark,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.separated(
                        itemCount: _cells.length,
                        separatorBuilder: (context2, idx) => const Divider(
                          height: 1,
                          indent: 56,
                          color: AppColors.surfaceVariant,
                        ),
                        itemBuilder: (ctx, i) {
                          final cell = _cells[i];
                          final orphaned = _isOrphaned(cell);
                          final isOwn = cell.createdBy == myDid;
                          final founderLabel = isOwn
                              ? 'Ich (eigene Zelle)'
                              : cell.createdBy.length > 28
                                  ? '${cell.createdBy.substring(0, 20)}…'
                                  : cell.createdBy;

                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: orphaned
                                  ? Colors.redAccent.withValues(alpha: 0.15)
                                  : AppColors.gold.withValues(alpha: 0.12),
                              child: Icon(
                                orphaned
                                    ? Icons.warning_amber_rounded
                                    : Icons.hexagon_outlined,
                                color: orphaned
                                    ? Colors.redAccent
                                    : AppColors.gold,
                                size: 20,
                              ),
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    cell.name,
                                    style: TextStyle(
                                      color: orphaned
                                          ? Colors.redAccent
                                          : AppColors.onDark,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (orphaned)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color:
                                          Colors.redAccent.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      'VERWAIST',
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: Colors.redAccent,
                                          letterSpacing: 0.5),
                                    ),
                                  ),
                              ],
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'ID: ${cell.id.substring(0, 12)}…',
                                  style: const TextStyle(
                                      fontSize: 11, color: Colors.grey),
                                ),
                                Text(
                                  'Gegründet von: $founderLabel',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: orphaned
                                          ? Colors.orange
                                          : Colors.grey),
                                ),
                              ],
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  color: Colors.redAccent),
                              tooltip: 'Zelle löschen',
                              onPressed: () => _deleteCell(context, cell),
                            ),
                            isThreeLine: true,
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}
