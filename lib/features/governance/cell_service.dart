import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/contacts/contact_service.dart';
import '../../core/identity/identity_service.dart';
import '../../core/storage/pod_database.dart';
import '../../services/notification_service.dart';
import 'cell.dart';
import 'cell_join_request.dart';
import 'cell_member.dart';

/// Manages the local user's cell memberships and join requests.
///
/// Follows the same singleton/stream pattern as [GroupChannelService].
/// All mutations persist to [PodDatabase] (encrypted) and emit on [stream].
class CellService {
  CellService._();
  static CellService? _instance;
  static CellService get instance => _instance ??= CellService._();

  // Cells the local user is a member of (persisted).
  final List<Cell> _myCells = [];

  // All discovered cells from Nostr (session-only).
  final List<Cell> _discovered = [];

  // Members keyed by cellId.
  final Map<String, List<CellMember>> _members = {};

  // Join requests keyed by cellId (only for cells where local user is founder/mod).
  final Map<String, List<CellJoinRequest>> _requests = {};

  // Pending outgoing requests (cells the user applied to join).
  final List<CellJoinRequest> _myRequests = [];

  // Cell IDs the user has left or that were dissolved — persisted so they
  // never re-appear in the discovery list after a Nostr re-subscription.
  final Set<String> _dismissedCellIds = {};
  static const _dismissedKey = 'nexus_dismissed_cell_ids';

  // Tombstone list: cell IDs of cells that were DISSOLVED by their founder.
  // This list is NEVER cleared — even across app restarts and on every device.
  // A tombstoned cell can NEVER be re-imported via ANY event type, regardless
  // of event order.  This is the primary defence against zombie cells.
  final Set<String> _deletedCellIds = {};
  static const _deletedCellsKey = 'nexus_deleted_cell_ids';

  // Unix-seconds timestamp of the last data wipe.  Cell announcements whose
  // Nostr created_at predates this are silently ignored so old zombie cells
  // from the relay do not re-appear after a cleanup.
  int? _wipeAt;
  static const _wipeKey = 'nexus_cell_wipe_at';

  final _streamCtrl = StreamController<void>.broadcast();

  /// Fires whenever any cell data changes.
  Stream<void> get stream => _streamCtrl.stream;

  /// Called by ChatProvider whenever the set of joined cells changes so that
  /// NostrTransport can refresh its governance subscriptions immediately.
  /// Set once during ChatProvider initialization.
  VoidCallback? onGovernanceMembershipChanged;

  List<Cell> get myCells => List.unmodifiable(_myCells);
  List<Cell> get discoveredCells => List.unmodifiable(_discovered);

  /// Returns true if [cellId] has been permanently tombstoned (dissolved or
  /// dismissed).  Used by external callers (e.g. ChatProvider) as a fast
  /// pre-filter before calling [addDiscoveredCell] or [handleMembershipConfirmed].
  bool isTombstoned(String cellId) =>
      _deletedCellIds.contains(cellId) || _dismissedCellIds.contains(cellId);

  /// Returns all cells known to the service (joined + discovered), de-duplicated.
  List<Cell> get allKnownCells {
    final joined = {for (final c in _myCells) c.id};
    return [
      ..._myCells,
      ..._discovered.where((c) => !joined.contains(c.id)),
    ];
  }

  /// Members for a specific cell (may be empty if not loaded).
  List<CellMember> membersOf(String cellId) =>
      List.unmodifiable(_members[cellId] ?? []);

  /// Returns the count of confirmed members (FOUNDER + MODERATOR + MEMBER)
  /// by loading directly from DB – reliable even when in-memory cache is stale.
  Future<int> getMemberCount(String cellId) async {
    final rows = await PodDatabase.instance.listCellMembers(cellId);
    final members = rows.map(CellMember.fromJson).toList();
    print('[CELL] getMemberCount($cellId): found ${members.length} raw members');
    for (final m in members) {
      print('[CELL]   - did=${m.did.substring(0, m.did.length.clamp(0, 20))} role=${m.role.name}');
    }
    final f = members.where((m) => m.role == MemberRole.founder).length;
    final mod = members.where((m) => m.role == MemberRole.moderator).length;
    final mem = members.where((m) => m.role == MemberRole.member).length;
    final total = f + mod + mem; // PENDING excluded
    print('[CELL] After filter (no PENDING): $total (founders=$f, mods=$mod, members=$mem)');
    return total;
  }

  /// Pending join requests for a specific cell.
  List<CellJoinRequest> requestsFor(String cellId) =>
      List.unmodifiable(_requests[cellId] ?? []);

  /// Outgoing join requests sent by the local user.
  List<CellJoinRequest> get myOutgoingRequests =>
      List.unmodifiable(_myRequests);

  /// Total count of pending inbound requests across all managed cells.
  int get totalPendingRequests => _requests.values
      .expand((list) => list)
      .where((r) => r.isPending)
      .length;

  /// Returns the local user's membership in [cellId], or null if not a member.
  CellMember? myMembershipIn(String cellId) {
    final myDid = IdentityService.instance.currentIdentity?.did;
    if (myDid == null) return null;
    return _members[cellId]?.where((m) => m.did == myDid).firstOrNull;
  }

  /// Returns true if the local user is a confirmed member of [cellId].
  bool isMember(String cellId) {
    final m = myMembershipIn(cellId);
    return m != null && m.isConfirmed;
  }

  bool hasAppliedTo(String cellId) =>
      _myRequests.any((r) => r.cellId == cellId && r.isPending);

  // ── Initialisation ─────────────────────────────────────────────────────────

  Future<void> load() async {
    try {
      // Load dismissed cell IDs and wipe timestamp first so discovery filter
      // works immediately before any Nostr events arrive.
      final prefs = await SharedPreferences.getInstance();

      // ── RENAME-DIAG: raw SharedPrefs state at startup ────────────────────
      final tombstones = prefs.getStringList('nexus_cell_tombstones') ?? [];
      final dismissed = prefs.getStringList('nexus_dismissed_cell_ids') ?? [];
      print('[RENAME-DIAG] Tombstones: $tombstones');
      print('[RENAME-DIAG] Dismissed: $dismissed');
      // ─────────────────────────────────────────────────────────────────────

      // ── Load tombstone + dismissed lists BEFORE any Nostr events arrive ────
      final rawDeleted = prefs.getString(_deletedCellsKey);
      final rawDismissed = prefs.getString(_dismissedKey);
      final rawWipeAt = prefs.getInt(_wipeKey);

      if (rawDeleted != null) {
        final list = (jsonDecode(rawDeleted) as List<dynamic>).cast<String>();
        _deletedCellIds.addAll(list);
      }
      if (rawDismissed != null) {
        final list = (jsonDecode(rawDismissed) as List<dynamic>).cast<String>();
        _dismissedCellIds.addAll(list);
      }
      _wipeAt = rawWipeAt;

      // ── ZOMBIE-V2: startup diagnosis ──────────────────────────────────────
      print('[ZOMBIE-V2] === APP START CELL DIAGNOSIS ===');
      print('[ZOMBIE-V2] Loaded ${_deletedCellIds.length} tombstones: $_deletedCellIds');
      print('[ZOMBIE-V2] Loaded ${_dismissedCellIds.length} dismissed: $_dismissedCellIds');
      print('[ZOMBIE-V2] Wipe timestamp: ${rawWipeAt ?? "NOT SET"}');
      // ─────────────────────────────────────────────────────────────────────

      // ── ZOMBIE-V3: tombstone state at load time ───────────────────────────
      print('[ZOMBIE-V3] Tombstones at load: ${_deletedCellIds.length} -> ${_deletedCellIds.toList()}');
      print('[ZOMBIE-V3] Dismissed at load: ${_dismissedCellIds.length} -> ${_dismissedCellIds.toList()}');
      print('[ZOMBIE-V3] WipeAt at load: ${rawWipeAt ?? "NOT SET"}');
      // ─────────────────────────────────────────────────────────────────────

      final rows = await PodDatabase.instance.listCells();
      _myCells.clear();

      // ── ZOMBIE-V2: DB contents at startup ────────────────────────────────
      print('[ZOMBIE-V2] DB cells count: ${rows.length}');
      for (final row in rows) {
        final cId = row['id'] as String? ?? '?';
        final cName = row['name'] as String? ?? '?';
        print('[ZOMBIE-V2] DB cell: "$cName" | id: $cId'
            '  tombstoned=${_deletedCellIds.contains(cId)}'
            '  dismissed=${_dismissedCellIds.contains(cId)}');
      }
      // ─────────────────────────────────────────────────────────────────────

      // Filter out cells that are tombstoned (dissolved) or dismissed (left).
      // Handles the case where a cell was dissolved/left but still in DB due
      // to a prior race condition (fixed by persistent tombstone list).
      for (final row in rows) {
        final cell = Cell.fromJson(row);
        if (_deletedCellIds.contains(cell.id)) {
          print('[ZOMBIE-V2] Removing tombstoned DB cell: "${cell.name}" ${cell.id}');
          await PodDatabase.instance.deleteCell(cell.id);
          continue;
        }
        if (_dismissedCellIds.contains(cell.id)) {
          print('[ZOMBIE-V2] Removing dismissed DB cell: "${cell.name}" ${cell.id}');
          await PodDatabase.instance.deleteCell(cell.id);
          continue;
        }
        print('[ZOMBIE-V3] WRITE PATH: db_import, cellId=${cell.id}, name="${cell.name}"');
        print('[ZOMBIE-V3] Is in tombstones? ${_deletedCellIds.contains(cell.id)}');
        print('[ZOMBIE-V3] Is in dismissed? ${_dismissedCellIds.contains(cell.id)}');
        print('[ZOMBIE-V3] Decision: ALLOWED (loaded from DB)');
        print('[CELL-IMPORT] DB load: cellId=${cell.id}, name="${cell.name}", role=see_members_table');
        print('[CELL-UPDATE] DB load: cellId=${cell.id}, name="${cell.name}", version=n/a');
        _myCells.add(cell);
      }

      // Load members and requests for each joined cell.
      for (final cell in _myCells) {
        final memberRows = await PodDatabase.instance.listCellMembers(cell.id);
        _members[cell.id] =
            memberRows.map(CellMember.fromJson).toList();
        final myMembership = _members[cell.id]
            ?.where((m) => m.did == IdentityService.instance.currentIdentity?.did)
            .firstOrNull;
        print('[CELL-IMPORT] DB load member: cellId=${cell.id}, name="${cell.name}",'
            ' role=${myMembership?.role.name ?? "NOT_FOUND"}'
            ' (${_members[cell.id]?.length ?? 0} total members)');

        final reqRows =
            await PodDatabase.instance.listCellJoinRequests(cell.id);
        _requests[cell.id] =
            reqRows.map(CellJoinRequest.fromJson).toList();
      }

      // Load outgoing requests.
      final outRows =
          await PodDatabase.instance.listMyCellJoinRequests();
      _myRequests
        ..clear()
        ..addAll(outRows.map(CellJoinRequest.fromJson));

      // Re-register nostrPubkey mappings from loaded inbound requests so
      // that founder can "Nachfragen" even after an app restart.
      for (final cellRequests in _requests.values) {
        for (final req in cellRequests) {
          final pubkey = req.requesterNostrPubkey;
          if (pubkey != null && pubkey.isNotEmpty && onRegisterNostrMapping != null) {
            onRegisterNostrMapping!(req.requesterDid, pubkey);
          }
        }
      }

      debugPrint('[CELLS] Loaded ${_myCells.length} cells');
      _notify();
    } catch (e) {
      debugPrint('[CELLS] load error: $e');
    }
  }

  // ── Cell CRUD ──────────────────────────────────────────────────────────────

  /// Creates a new cell and sets the local user as FOUNDER.
  Future<Cell> createCell(Cell cell) async {
    final myDid = IdentityService.instance.currentIdentity!.did;

    // Persist cell.
    await PodDatabase.instance.upsertCell(cell.id, cell.toJson());

    // Add founder membership.
    final founder = CellMember(
      cellId: cell.id,
      did: myDid,
      joinedAt: DateTime.now().toUtc(),
      role: MemberRole.founder,
      confirmedBy: myDid,
    );
    await PodDatabase.instance.upsertCellMember(cell.id, myDid, founder.toJson());

    _myCells.add(cell);
    _members[cell.id] = [founder];
    _requests[cell.id] = [];

    _notify();
    debugPrint('[CELLS] Created cell ${cell.name} (${cell.id})');
    return cell;
  }

  /// Updates the geohash of a local cell (founder action).
  Future<void> updateCellGeohash(String cellId, String geohash) async {
    final idx = _myCells.indexWhere((c) => c.id == cellId);
    if (idx < 0) return;
    final updated = _myCells[idx].copyWith(geohash: geohash);
    _myCells[idx] = updated;
    await PodDatabase.instance.upsertCell(updated.id, updated.toJson());
    _notify();
  }

  /// Updates a cell's settings (founder-only action checked by caller).
  Future<void> updateCell(Cell updated) async {
    final idx = _myCells.indexWhere((c) => c.id == updated.id);
    if (idx < 0) return;
    print('[CELL-RENAME] Publishing name change: cellId=${updated.id}, newName=${updated.name}');
    _myCells[idx] = updated;
    await PodDatabase.instance.upsertCell(updated.id, updated.toJson());
    _notify();
    print('[CELL-RENAME] Kind-30000 published: accepted=pending_via_chat_provider');
  }

  /// Restores a cell membership from a backup JSON map (merge – only adds if
  /// not already a member and not tombstoned).  Called by [BackupService].
  Future<void> restoreFromBackup(Map<String, dynamic> json) async {
    try {
      final cell = Cell.fromJson(json);
      print('[ZOMBIE-V3] WRITE PATH: restoreFromBackup, cellId=${cell.id}, name="${cell.name}", source=backup');
      print('[ZOMBIE-V3] Is in tombstones? ${_deletedCellIds.contains(cell.id)}');
      print('[ZOMBIE-V3] Is in dismissed? ${_dismissedCellIds.contains(cell.id)}');
      if (_deletedCellIds.contains(cell.id)) {
        print('[ZOMBIE-V3] Decision: BLOCKED (tombstoned)');
        return; // dissolved — never restore
      }
      if (_dismissedCellIds.contains(cell.id)) {
        print('[ZOMBIE-V3] Decision: BLOCKED (dismissed)');
        return; // left — never restore
      }
      if (_myCells.any((c) => c.id == cell.id)) {
        print('[ZOMBIE-V3] Decision: BLOCKED (already in myCells)');
        return;
      }
      print('[ZOMBIE-V3] Decision: ALLOWED (restored from backup)');
      _myCells.add(cell);
      await PodDatabase.instance.upsertCell(cell.id, json);
      _notify();
    } catch (e) {
      debugPrint('[CELLS] restoreFromBackup error: $e');
    }
  }

  /// Adds a discovered cell from Nostr (does not persist).
  ///
  /// Cells the user has left or that were dissolved are silently ignored —
  /// they stay in the dismissed list and will never re-appear in discovery.
  /// [nostrCreatedAt] is the Nostr event's `created_at` Unix-seconds value.
  /// Announcements older than the last wipe are silently ignored so zombie
  /// cells from relays do not re-appear after a debug reset or cleanup.
  void addDiscoveredCell(Cell cell, {int? nostrCreatedAt, bool ownDevice = false}) {
    print('[CELL-IMPORT] Incoming Kind-30000: cellId=${cell.id}, name="${cell.name}"');
    print('[CELL-IMPORT] Membership check: isMember=${_myCells.any((c) => c.id == cell.id)},'
        ' wasLeave=${_dismissedCellIds.contains(cell.id)}');
    print('[ZOMBIE-V3] WRITE PATH: addDiscoveredCell, cellId=${cell.id}, name="${cell.name}", source=Kind30000');
    print('[ZOMBIE-V3] Is in tombstones? ${_deletedCellIds.contains(cell.id)}');
    print('[ZOMBIE-V3] Is in dismissed? ${_dismissedCellIds.contains(cell.id)}');
    print('[ZOMBIE-V3] WipeAt=$_wipeAt, nostrCreatedAt=$nostrCreatedAt, blocked_by_wipe=${_wipeAt != null && nostrCreatedAt != null && nostrCreatedAt < _wipeAt!}');
    print('[ZOMBIE-V2] Event received: kind=30000, cellId=${cell.id},'
        ' action=announcement, timestamp=$nostrCreatedAt');
    print('[ZOMBIE-V2] Current state:'
        ' inMyCells=${_myCells.any((c) => c.id == cell.id)}'
        ' inDiscovered=${_discovered.any((c) => c.id == cell.id)}'
        ' inTombstones=${_deletedCellIds.contains(cell.id)}'
        ' inDismissed=${_dismissedCellIds.contains(cell.id)}');

    // Check tombstone first — dissolved cells NEVER come back.
    final existingOwned = _myCells.where((c) => c.id == cell.id).firstOrNull;
    final existingDiscovered =
        _discovered.where((c) => c.id == cell.id).firstOrNull;
    print('[CELL-UPDATE] Incoming Kind-30000: cellId=${cell.id}, name="${cell.name}", version=n/a, self=false');
    if (existingOwned != null) {
      print('[CELL-UPDATE] Existing cell found: currentName="${existingOwned.name}", currentVersion=n/a');
    } else if (existingDiscovered != null) {
      print('[CELL-UPDATE] Existing cell found: currentName="${existingDiscovered.name}", currentVersion=n/a');
    }
    print('[CELL-UPDATE] WARNING: No version check found');
    if (_deletedCellIds.contains(cell.id)) {
      print('[ZOMBIE-V2] Import blocked by tombstone: ${cell.id}');
      print('[ZOMBIE-V2] Decision: REJECTED (reason: cell tombstoned/dissolved)');
      print('[CELL-IMPORT] Decision: BLOCKED reason=tombstoned');
      print('[CELL-UPDATE] Decision: SKIPPED reason=tombstoned');
      return;
    }
    final ownedIdx = _myCells.indexWhere((c) => c.id == cell.id);
    if (ownedIdx >= 0) {
      final existing = _myCells[ownedIdx];
      if (ownDevice && existing.name != cell.name) {
        // Multi-device rename: update only the name in-place so we don't
        // overwrite local-only fields with the Nostr-echoed version.
        print('[CELL-UPDATE] Decision: UPDATED reason=own_device_rename'
            ' (${existing.name} → ${cell.name})');
        _myCells[ownedIdx] = existing.copyWith(name: cell.name);
        PodDatabase.instance.upsertCell(
            cell.id, _myCells[ownedIdx].toJson());
        _notify();
      } else {
        print('[ZOMBIE-V2] Decision: REJECTED (reason: already in myCells)');
        print('[CELL-IMPORT] Decision: BLOCKED reason=already_in_myCells');
        print('[CELL-UPDATE] Decision: SKIPPED reason='
            '${ownDevice ? "own_device_echo_same_name" : "already_in_myCells"}');
      }
      return;
    }
    if (_dismissedCellIds.contains(cell.id)) {
      print('[CELL-DEL] Import blocked for cell ${cell.id} (on block list)');
      print('[ZOMBIE-V2] Decision: REJECTED (reason: dismissed/left)');
      print('[CELL-IMPORT] Decision: BLOCKED reason=dismissed_left');
      print('[CELL-UPDATE] Decision: SKIPPED reason=dismissed_left');
      return;
    }
    if (nostrCreatedAt != null &&
        _wipeAt != null &&
        nostrCreatedAt < _wipeAt!) {
      print('[CELL-DEL] Import blocked for cell ${cell.id} '
          '(event $nostrCreatedAt < wipe $_wipeAt)');
      print('[ZOMBIE-V2] Decision: REJECTED (reason: older than wipe timestamp)');
      print('[CELL-IMPORT] Decision: BLOCKED reason=older_than_wipe');
      print('[CELL-UPDATE] Decision: SKIPPED reason=older_than_wipe');
      return;
    }
    _discovered.removeWhere((c) => c.id == cell.id);
    _discovered.add(cell);
    _notify();
    print('[ZOMBIE-V3] Decision: ALLOWED (added to discovered)');
    print('[ZOMBIE-V2] Decision: ADDED to discovered');
    print('[CELL-IMPORT] Decision: ALLOWED reason=new_discovery');
    print('[CELL-UPDATE] Decision: UPDATED reason=added_to_discovered');
  }

  /// Records the current timestamp as the last wipe point.
  /// Cell announcements older than this are ignored after a cleanup.
  Future<void> recordWipe() async {
    _wipeAt = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_wipeKey, _wipeAt!);
    print('[CELL-DEL] Wipe timestamp recorded: $_wipeAt');
  }

  // ── Membership management ──────────────────────────────────────────────────

  /// Called on member devices when a cell dissolution event is received from
  /// Nostr (Kind-30000 with deleted:true).  Removes all local state for the
  /// cell: membership, join requests, discovered entry.
  ///
  /// Order of operations (MUST NOT be reordered):
  ///   1. Save tombstone persistently (synchronous in-memory write first)
  ///   2. Clean up DB + memory (always — no wasInMyList short-circuit)
  ///   3. Notify UI
  ///
  /// The DB/memory cleanup is intentionally always executed (not skipped when
  /// the cell is "unknown locally").  A racing Kind-31004 membership
  /// confirmation may be mid-await when this runs and will add the cell to
  /// myCells after the cleanup — the tombstone check re-catches that case.
  Future<void> handleCellDeleted(String cellId, String cellName) async {
    print('[ZOMBIE-V2] Event received: kind=30000, cellId=$cellId,'
        ' action=dissolution');
    print('[LIVE-DEL] Incoming cell deletion: $cellId ($cellName)');
    print('[ZOMBIE-V2] Current state:'
        ' inMyCells=${_myCells.any((c) => c.id == cellId)}'
        ' inDiscovered=${_discovered.any((c) => c.id == cellId)}'
        ' inTombstones=${_deletedCellIds.contains(cellId)}');

    // ── Step 1: Synchronous in-memory tombstone (no await — visible to
    //    any coroutine that checks after this point in the event loop). ───────
    _deletedCellIds.add(cellId);
    _dismissedCellIds.add(cellId);
    print('[LIVE-DEL] Tombstone stored (in-memory, synchronous)');

    // ── Step 2: Snapshot member list BEFORE clearing memory. ────────────────
    final membersToDelete =
        List<CellMember>.from(_members[cellId] ?? []);

    // ── Step 3: Remove from ALL in-memory structures — no await before here.
    //    This keeps the live-update path entirely synchronous so the UI
    //    reflects the deletion in the same microtask batch as the event. ──────
    _myCells.removeWhere((c) => c.id == cellId);
    _discovered.removeWhere((c) => c.id == cellId);
    _members.remove(cellId);
    _requests.remove(cellId);
    _myRequests.removeWhere((r) => r.cellId == cellId);
    print('[LIVE-DEL] Removed from _myCells and _discovered');

    // ── Step 4: Notify UI IMMEDIATELY — no awaits have occurred above. ───────
    _notify();
    print('[LIVE-DEL] Stream notified — UI should update now');
    // Refresh governance subscriptions so the dissolved cell is removed
    // from the Nostr filter immediately.
    onGovernanceMembershipChanged?.call();

    // ── Step 5: Async persistence — UI is already updated. ──────────────────
    await _saveTombstone(cellId); // idempotent; also saves dismissed list
    print('[LIVE-DEL] Tombstone persisted to SharedPrefs');

    // ── Step 6: DB cleanup — idempotent, safe to call even if cell absent. ──
    await PodDatabase.instance.deleteCell(cellId);
    print('[LIVE-DEL] Deleted from DB');
    await PodDatabase.instance.deleteCellJoinRequestsByCell(cellId);
    for (final m in membersToDelete) {
      await PodDatabase.instance.deleteCellMember(cellId, m.did);
    }

    final dbCount = (await PodDatabase.instance.listCells()).length;
    print('[ZOMBIE-V2] Decision: DELETED (reason: dissolution event)');
    print('[ZOMBIE-V2] DB state after: $dbCount cells in DB');
    print('[LIVE-DEL] Subscriptions stopped (via deleteCellChannels in ChatProvider)');
    print('[LIVE-DEL] UI should now update — Meine Zellen no longer shows: $cellName');
  }

  /// Withdraws a pending join request for [cellId].
  ///
  /// Deletes the local record and publishes a Kind-31003 withdraw event so
  /// the founder's device removes the pending request too.
  Future<void> withdrawJoinRequest(String cellId) async {
    final req = _myRequests.where((r) => r.cellId == cellId && r.isPending).firstOrNull;
    if (req == null) return;

    _myRequests.removeWhere((r) => r.id == req.id);
    await PodDatabase.instance.deleteCellJoinRequest(req.id);
    _notify();

    if (onPublishJoinRequest != null) {
      onPublishJoinRequest!({...req.toJson(), 'action': 'withdraw'});
      print('[JOIN] Request withdrawn by applicant: ${req.requesterPseudonym} for cell: $cellId');
      print('[JOIN] Withdraw event sent to founder');
    }
  }

  /// Called on the founder's device when an applicant withdraws their request.
  Future<void> handleJoinRequestWithdrawn(String requestId, String cellId) async {
    final reqList = _requests[cellId];
    if (reqList == null) return;
    reqList.removeWhere((r) => r.id == requestId);
    await PodDatabase.instance.deleteCellJoinRequest(requestId);
    _notify();
    print('[JOIN] Withdraw received, removing pending request: $requestId');
  }

  /// Sends a join request for [cell] (APPROVAL_REQUIRED policy).
  ///
  /// The request is stored locally and published via Kind-31003 to Nostr
  /// relays so that the founder receives it even without a contact
  /// relationship.
  Future<void> sendJoinRequest(Cell cell,
      {String? message, String? localNostrPubkeyHex}) async {
    final identity = IdentityService.instance.currentIdentity!;
    final req = CellJoinRequest.create(
      cellId: cell.id,
      requesterDid: identity.did,
      requesterPseudonym: identity.pseudonym,
      requesterNostrPubkey: localNostrPubkeyHex,
      message: message,
    );
    await PodDatabase.instance.upsertCellJoinRequest(
        req.id, req.cellId, req.toJson(), isSent: true);
    _myRequests.add(req);
    _notify();

    // Publish to Nostr so the founder's device receives it.
    if (onPublishJoinRequest != null) {
      onPublishJoinRequest!(req.toJson());
      print('[JOIN] Request sent to cell: ${cell.name} (founder receives via Kind-31003)');
    } else {
      debugPrint('[JOIN-DIAG] onPublishJoinRequest is NULL — request NOT sent over network!');
    }
  }

  /// Handles an incoming join request from Nostr (called by ChatProvider).
  Future<void> handleIncomingJoinRequest(CellJoinRequest req) async {
    // Only process if we manage this cell.
    if (!_myCells.any((c) => c.id == req.cellId)) return;
    // Deduplicate.
    final existing = _requests[req.cellId];
    if (existing?.any((r) => r.id == req.id) ?? false) return;

    await PodDatabase.instance.upsertCellJoinRequest(
        req.id, req.cellId, req.toJson(), isSent: false);
    (_requests[req.cellId] ??= []).add(req);
    _notify();

    // Notify founder/moderators.
    await NotificationService.instance.showGenericNotification(
      title: 'Neue Beitrittsanfrage',
      body: '${req.requesterPseudonym} möchte deiner Zelle beitreten.',
      payload: 'cell_request:${req.cellId}',
    );
  }

  /// Approves a join request – makes the requester a confirmed MEMBER.
  Future<void> approveRequest(CellJoinRequest req) async {
    final myDid = IdentityService.instance.currentIdentity!.did;

    // Verify caller has permission.
    final myMembership = myMembershipIn(req.cellId);
    if (myMembership == null || !myMembership.canManageRequests) {
      throw StateError('Insufficient permissions to approve requests.');
    }

    final now = DateTime.now().toUtc();
    final updated = req.copyWith(
      status: JoinRequestStatus.approved,
      decidedBy: myDid,
      decidedAt: now,
    );
    await PodDatabase.instance.updateCellJoinRequestStatus(
        req.id, 'approved', myDid, now);

    // Create member record.
    final newMember = CellMember(
      cellId: req.cellId,
      did: req.requesterDid,
      joinedAt: now,
      role: MemberRole.member,
      confirmedBy: myDid,
    );
    await PodDatabase.instance.upsertCellMember(
        req.cellId, req.requesterDid, newMember.toJson());

    // Update in-memory state.
    final reqList = _requests[req.cellId];
    final idx = reqList?.indexWhere((r) => r.id == req.id) ?? -1;
    if (idx >= 0) reqList![idx] = updated;
    (_members[req.cellId] ??= [])
        .removeWhere((m) => m.did == req.requesterDid);
    (_members[req.cellId] ??= []).add(newMember);

    // Update member count on cell.
    final cellIdx = _myCells.indexWhere((c) => c.id == req.cellId);
    if (cellIdx >= 0) {
      final memberCount = (_members[req.cellId]?.length ?? 1);
      _myCells[cellIdx] = _myCells[cellIdx].copyWith(memberCount: memberCount);
      await PodDatabase.instance.upsertCell(
          _myCells[cellIdx].id, _myCells[cellIdx].toJson());
    }

    _notify();
    debugPrint('[CELLS] Approved request ${req.id} for ${req.requesterPseudonym}');
    print('[JOIN] Request approved by founder for: ${req.requesterPseudonym}');
    print('[JOIN] Member added + cell channels subscribed');

    // Send membership confirmation via Kind-31004 so the applicant's device
    // learns about the approval without a contact relationship.
    final requesterPubkey = req.requesterNostrPubkey ?? '';
    if (onPublishMembershipConfirmed != null && requesterPubkey.isNotEmpty) {
      final cell = _myCells.firstWhere((c) => c.id == req.cellId);
      onPublishMembershipConfirmed!(cell.toJson(), newMember.toJson(), requesterPubkey);
      print('[JOIN] Confirmation sent to applicant: ${requesterPubkey.substring(0, 8)}…');
    } else if (requesterPubkey.isEmpty) {
      debugPrint('[JOIN-DIAG] requesterNostrPubkey unknown — cannot send Kind-31004 confirmation');
    }

    // Post welcome message in discussion channel (fire-and-forget).
    if (onMemberApproved != null) {
      onMemberApproved!(req.cellId, req.requesterPseudonym);
      print('[JOIN] Welcome message posted');
    }
  }

  /// Rejects a join request silently (no feedback sent to requester).
  Future<void> rejectRequest(CellJoinRequest req) async {
    final myDid = IdentityService.instance.currentIdentity!.did;
    final myMembership = myMembershipIn(req.cellId);
    if (myMembership == null || !myMembership.canManageRequests) {
      throw StateError('Insufficient permissions to reject requests.');
    }

    final now = DateTime.now().toUtc();
    final updated = req.copyWith(
      status: JoinRequestStatus.rejected,
      decidedBy: myDid,
      decidedAt: now,
    );
    await PodDatabase.instance.updateCellJoinRequestStatus(
        req.id, 'rejected', myDid, now);

    final reqList = _requests[req.cellId];
    final idx = reqList?.indexWhere((r) => r.id == req.id) ?? -1;
    if (idx >= 0) reqList![idx] = updated;

    _notify();
  }

  /// Saves [cellId] to the permanent tombstone list AND the dismissed list.
  ///
  /// Called when a cell dissolution event is received.  Writing the tombstone
  /// BEFORE any await means the ID is immediately visible to concurrent async
  /// operations (e.g. a racing Kind-31004 that has already passed its guard
  /// but not yet written to memory/DB).
  Future<void> _saveTombstone(String cellId) async {
    final isNew = _deletedCellIds.add(cellId); // in-memory first, synchronous
    _dismissedCellIds.add(cellId);             // also add to dismissed
    _discovered.removeWhere((c) => c.id == cellId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _deletedCellsKey, jsonEncode(_deletedCellIds.toList()));
    await prefs.setString(
        _dismissedKey, jsonEncode(_dismissedCellIds.toList()));
    if (isNew) {
      print('[ZOMBIE-V2] Storing tombstone for cellId: $cellId');
      print('[ZOMBIE-V2] Tombstone list size: ${_deletedCellIds.length}');
    }
  }

  /// Persists [cellId] to the dismissed list so it never re-appears in
  /// discovery after a Nostr re-subscription.  Used for voluntary leave/remove.
  ///
  /// NOTE: Always writes SharedPreferences even if [cellId] is already in the
  /// in-memory set.  [leaveCell] adds to [_dismissedCellIds] synchronously
  /// BEFORE calling this — the early-return guard was the original bug that
  /// prevented the dismissed list from ever being persisted on voluntary leave.
  Future<void> _dismissCell(String cellId) async {
    _dismissedCellIds.add(cellId); // idempotent Set.add
    _discovered.removeWhere((c) => c.id == cellId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _dismissedKey, jsonEncode(_dismissedCellIds.toList()));
    // Verify the write actually landed.
    final verify = prefs.getString(_dismissedKey);
    if (verify == null) {
      print('[CELL-LEAVE] WARNING: No persistent leave marker found! SharedPrefs write may have failed.');
    } else {
      print('[CELL-LEAVE] Verified: dismissed list saved'
          ' (${_dismissedCellIds.length} entries, contains=$cellId:'
          ' ${_dismissedCellIds.contains(cellId)})');
    }
    print('[CELL-DEL] Adding $cellId to block list');
  }

  /// The local user leaves a cell (exit right always available).
  ///
  /// Publishes a Kind-31005 leave event so the founder's device can update its
  /// member list.  Caller is responsible for leaving the cell-internal channels.
  Future<void> leaveCell(String cellId) async {
    final myDid = IdentityService.instance.currentIdentity!.did;

    // Publish leave event BEFORE local cleanup (founder needs to see it).
    print('[CELL-LEAVE] Publishing Kind-31005 for cellId=$cellId');
    if (onPublishMemberUpdate != null) {
      onPublishMemberUpdate!(cellId: cellId, targetDid: myDid, action: 'left');
      print('[CELL] Published leave event for cell: $cellId');
    } else {
      print('[CELL-LEAVE] WARNING: onPublishMemberUpdate is null — Kind-31005 NOT sent!');
    }

    // Dismiss in-memory immediately (synchronous).
    _dismissedCellIds.add(cellId);
    _discovered.removeWhere((c) => c.id == cellId);

    // Remove from memory + notify UI immediately (no await before here).
    _myCells.removeWhere((c) => c.id == cellId);
    _myRequests.removeWhere((r) => r.cellId == cellId);
    _members.remove(cellId);
    _requests.remove(cellId);
    print('[CELL-LEAVE] In-memory removal: cellId=$cellId');
    _notify();

    // Async persistence + DB cleanup after UI is updated.
    await _dismissCell(cellId); // persists dismissed list (idempotent)
    print('[CELL-LEAVE] Persistent leave marker set: cellId=$cellId'
        ' (dismissedCount=${_dismissedCellIds.length})');
    await PodDatabase.instance.deleteCellMember(cellId, myDid);
    print('[CELL-LEAVE] Local DB membership removed: cellId=$cellId, memberId=$myDid');
    await PodDatabase.instance.deleteCell(cellId);
    await PodDatabase.instance.deleteCellJoinRequestsByCell(cellId);
    debugPrint('[CELLS] Left cell $cellId');
  }

  /// Removes [memberDid] from [cellId] (founder / moderator action).
  ///
  /// Publishes a Kind-31005 removal event so the removed member's device can
  /// clean up its local state.  The optional [reason] is included in the event
  /// but never shown to the removed member (no UI feedback by design).
  Future<void> removeMember(String cellId, String memberDid,
      {String? reason}) async {
    final myDid = IdentityService.instance.currentIdentity!.did;
    final myMembership = myMembershipIn(cellId);
    if (myMembership == null || !myMembership.canManageRequests) {
      throw StateError('Insufficient permissions to remove members.');
    }
    // Cannot remove the founder or yourself.
    final target = _members[cellId]?.where((m) => m.did == memberDid).firstOrNull;
    if (target == null) return;
    if (target.role == MemberRole.founder) {
      throw StateError('Cannot remove the cell founder.');
    }
    if (memberDid == myDid) {
      throw StateError('Use leaveCell() to leave a cell.');
    }
    // Moderators can only remove regular members, not other moderators.
    if (myMembership.role == MemberRole.moderator &&
        target.role == MemberRole.moderator) {
      throw StateError('Moderators cannot remove other moderators.');
    }

    // Remove locally first.
    await PodDatabase.instance.deleteCellMember(cellId, memberDid);
    _members[cellId]?.removeWhere((m) => m.did == memberDid);

    // Update member count on cell.
    final cellIdx = _myCells.indexWhere((c) => c.id == cellId);
    if (cellIdx >= 0) {
      final memberCount = _members[cellId]?.length ?? 0;
      _myCells[cellIdx] = _myCells[cellIdx].copyWith(memberCount: memberCount);
      await PodDatabase.instance.upsertCell(
          _myCells[cellIdx].id, _myCells[cellIdx].toJson());
    }

    _notify();
    print('[CELL] Removed member $memberDid from cell $cellId');

    // Notify the removed member via Nostr.
    if (onPublishMemberUpdate != null) {
      onPublishMemberUpdate!(
          cellId: cellId,
          targetDid: memberDid,
          action: 'removed',
          reason: reason);
      print('[CELL] Published removal event for $memberDid in cell $cellId');
    }
  }

  /// Called on ANY device when a Kind-31005 member-update event is received.
  ///
  /// - If [action] == `'left'`: the member voluntarily left → update member
  ///   list on the founder's / other members' devices.
  /// - If [action] == `'removed'` and [targetDid] == my DID: I was kicked →
  ///   clean up my local state.
  Future<void> handleMemberLeft(
      String cellId, String targetDid, String action) async {
    final myDid = IdentityService.instance.currentIdentity?.did;

    if (action == 'removed' && targetDid == myDid) {
      // I was removed — dismiss in-memory immediately (synchronous).
      _dismissedCellIds.add(cellId);
      _discovered.removeWhere((c) => c.id == cellId);

      // Remove from memory + notify UI immediately (no await before here).
      _myCells.removeWhere((c) => c.id == cellId);
      _myRequests.removeWhere((r) => r.cellId == cellId);
      _members.remove(cellId);
      _requests.remove(cellId);
      _notify();
      onGovernanceMembershipChanged?.call();

      // Async persistence + DB cleanup after UI is updated.
      await _dismissCell(cellId); // idempotent persist
      await PodDatabase.instance.deleteCellMember(cellId, myDid!);
      await PodDatabase.instance.deleteCell(cellId);
      await PodDatabase.instance.deleteCellJoinRequestsByCell(cellId);
      print('[CELL] I was removed from cell: $cellId — cleaned up local state');
      return;
    }

    // Someone else left or was removed — update member list if we manage this cell.
    if (!_myCells.any((c) => c.id == cellId)) return;
    _members[cellId]?.removeWhere((m) => m.did == targetDid);
    await PodDatabase.instance.deleteCellMember(cellId, targetDid);

    // Update member count.
    final cellIdx = _myCells.indexWhere((c) => c.id == cellId);
    if (cellIdx >= 0) {
      final memberCount = _members[cellId]?.length ?? 0;
      _myCells[cellIdx] = _myCells[cellIdx].copyWith(memberCount: memberCount);
      await PodDatabase.instance.upsertCell(
          _myCells[cellIdx].id, _myCells[cellIdx].toJson());
    }

    _notify();
    print('[CELL] Member $targetDid $action cell $cellId — member list updated');
  }

  /// Dissolves a cell entirely (superadmin / system-admin only).
  ///
  /// Removes all members and the cell itself from the local DB.
  /// The caller is responsible for publishing the Kind-5 Nostr deletion event.
  Future<void> deleteCell(String cellId) async {
    // Snapshot member list before clearing memory.
    final membersToDelete = List<CellMember>.from(_members[cellId] ?? []);

    // Tombstone in-memory first so replayed announcements/confirmations
    // are blocked even before the DB cleanup finishes.
    _deletedCellIds.add(cellId);
    _dismissedCellIds.add(cellId);

    // Remove from memory + notify UI immediately (no await before here).
    _myCells.removeWhere((c) => c.id == cellId);
    _discovered.removeWhere((c) => c.id == cellId);
    _members.remove(cellId);
    _requests.remove(cellId);
    _myRequests.removeWhere((r) => r.cellId == cellId);
    _notify();

    // Persist tombstone + DB cleanup asynchronously after UI is updated.
    await _saveTombstone(cellId);
    for (final m in membersToDelete) {
      await PodDatabase.instance.deleteCellMember(cellId, m.did);
    }
    await PodDatabase.instance.deleteCell(cellId);
    await PodDatabase.instance.deleteCellJoinRequestsByCell(cellId);
    print('[JOIN] Cleaning up zombie requests for deleted cell: $cellId');
    debugPrint('[CELLS] Deleted cell $cellId (admin action)');
  }

  /// Transfers the FOUNDER role to [targetDid] and demotes the current founder
  /// to MEMBER.  Only the current founder or a superadmin may call this.
  Future<void> transferFounderRole(String cellId, String targetDid) async {
    final members = _members[cellId];
    if (members == null) return;

    final founderIdx = members.indexWhere((m) => m.role == MemberRole.founder);
    final targetIdx = members.indexWhere((m) => m.did == targetDid);
    if (founderIdx < 0 || targetIdx < 0) return;

    // Demote old founder to member.
    final oldFounder = members[founderIdx].copyWith(role: MemberRole.member);
    members[founderIdx] = oldFounder;
    await PodDatabase.instance.upsertCellMember(
        cellId, oldFounder.did, oldFounder.toJson());

    // Promote target to founder.
    final newFounder = members[targetIdx].copyWith(role: MemberRole.founder);
    members[targetIdx] = newFounder;
    await PodDatabase.instance.upsertCellMember(
        cellId, newFounder.did, newFounder.toJson());

    _notify();
    debugPrint('[CELLS] Founder role transferred to $targetDid in $cellId');
  }

  /// Promotes a member to moderator.
  Future<void> promoteModerator(String cellId, String targetDid) async {
    final myMembership = myMembershipIn(cellId);
    if (myMembership?.role != MemberRole.founder) {
      throw StateError('Only the founder can promote moderators.');
    }
    final members = _members[cellId];
    final idx = members?.indexWhere((m) => m.did == targetDid) ?? -1;
    if (idx < 0) return;
    final updated = members![idx].copyWith(role: MemberRole.moderator);
    members[idx] = updated;
    await PodDatabase.instance.upsertCellMember(
        cellId, targetDid, updated.toJson());
    _notify();
  }

  /// Handles a confirmed membership notification from Nostr.
  ///
  /// Race-condition-safe: checks the tombstone/dismissed lists both BEFORE
  /// and AFTER every await so a concurrent dissolution event cannot sneak in
  /// between the guard check and the actual DB/memory write.
  Future<void> handleMembershipConfirmed(Cell cell, CellMember member) async {
    print('[CELL-IMPORT] Incoming Kind-31004: cellId=${cell.id}, name="${cell.name}"');
    print('[CELL-IMPORT] Membership check: isMember=${_myCells.any((c) => c.id == cell.id)},'
        ' wasLeave=${_dismissedCellIds.contains(cell.id)}');
    print('[ZOMBIE-V3] WRITE PATH: handleMembershipConfirmed, cellId=${cell.id}, name="${cell.name}", source=Kind31004');
    print('[ZOMBIE-V3] Is in tombstones? ${_deletedCellIds.contains(cell.id)}');
    print('[ZOMBIE-V3] Is in dismissed? ${_dismissedCellIds.contains(cell.id)}');
    print('[ZOMBIE-V2] Event received: kind=31004, cellId=${cell.id},'
        ' action=membership_confirmed');
    print('[ZOMBIE-V2] Current state:'
        ' inMyCells=${_myCells.any((c) => c.id == cell.id)}'
        ' inTombstones=${_deletedCellIds.contains(cell.id)}'
        ' inDismissed=${_dismissedCellIds.contains(cell.id)}');

    // Guard 1 (pre-await): check tombstone + dismissed.
    if (_deletedCellIds.contains(cell.id)) {
      print('[ZOMBIE-V2] Import blocked by tombstone: ${cell.id}');
      print('[ZOMBIE-V2] Decision: REJECTED (reason: cell tombstoned/dissolved)');
      print('[CELL-IMPORT] Decision: BLOCKED reason=tombstoned');
      return;
    }
    if (_dismissedCellIds.contains(cell.id)) {
      print('[JOIN] Ignoring membership confirmation for dismissed cell: ${cell.id}');
      print('[ZOMBIE-V2] Decision: REJECTED (reason: dismissed/left)');
      print('[CELL-IMPORT] Decision: BLOCKED reason=dismissed_left');
      return;
    }

    if (!_myCells.any((c) => c.id == cell.id)) {
      await PodDatabase.instance.upsertCell(cell.id, cell.toJson());

      // Guard 2 (post-await): a dissolution event may have arrived and saved
      // its tombstone while we were waiting for the DB write above.
      if (_deletedCellIds.contains(cell.id) ||
          _dismissedCellIds.contains(cell.id)) {
        // Undo the DB insert — tombstone wins.
        await PodDatabase.instance.deleteCell(cell.id);
        print('[ZOMBIE-V2] Post-await guard triggered for ${cell.id} —'
            ' tombstone arrived during DB write, rolling back');
        print('[ZOMBIE-V2] Decision: REJECTED (reason: tombstone arrived during await)');
        print('[CELL-IMPORT] Decision: BLOCKED reason=post_await_tombstone');
        return;
      }

      print('[ZOMBIE-V3] Decision: ALLOWED (added to myCells, source: Kind31004)');
      print('[ZOMBIE-V2] Decision: ADDED to myCells (source: membership_confirmed)');
      print('[CELL-IMPORT] Decision: ALLOWED reason=membership_confirmed_Kind31004');
      _myCells.add(cell);
      _members[cell.id] = [];
      _requests[cell.id] = [];
    }

    (_members[cell.id] ??= []).removeWhere((m) => m.did == member.did);
    (_members[cell.id] ??= []).add(member);
    await PodDatabase.instance.upsertCellMember(
        cell.id, member.did, member.toJson());

    // Bug A fix: on the joining device the founder is not yet in the DB.
    // Add a synthetic FOUNDER entry derived from cell.createdBy so that
    // getMemberCount() returns the correct total on all devices.
    final founderDid = cell.createdBy;
    if (founderDid != member.did) {
      final alreadyHasFounder =
          (_members[cell.id] ?? []).any((m) => m.did == founderDid);
      if (!alreadyHasFounder) {
        final founderMember = CellMember(
          cellId: cell.id,
          did: founderDid,
          joinedAt: cell.createdAt,
          role: MemberRole.founder,
          confirmedBy: founderDid,
        );
        (_members[cell.id] ??= []).add(founderMember);
        await PodDatabase.instance.upsertCellMember(
            cell.id, founderDid, founderMember.toJson());
        print('[JOIN] Auto-added founder $founderDid to member list on joining device');
      }
    }

    _notify();

    // Explicitly refresh governance subscriptions so the joining device
    // immediately starts listening for proposals/votes in this cell.
    // Belt-and-suspenders: the stream listener in ChatProvider also handles
    // this via _notify(), but the direct callback guarantees it even if
    // the stream dispatch is delayed.
    final allMyCellIds = _myCells.map((c) => c.id).toList();
    print('[CELL] Refreshing governance subscriptions for ${allMyCellIds.length} cells');
    onGovernanceMembershipChanged?.call();

    await NotificationService.instance.showGenericNotification(
      title: 'Beitritt bestätigt!',
      body: 'Du bist jetzt Mitglied von ${cell.name}.',
      payload: 'cell_info:${cell.id}',
    );

    // Notify ChatProvider to create/subscribe to cell-internal channels.
    final myDid = IdentityService.instance.currentIdentity?.did;
    if (myDid != null && onMembershipConfirmed != null) {
      await onMembershipConfirmed!(cell, myDid);
    }
  }

  // ── Trust-level check ──────────────────────────────────────────────────────

  /// Returns true if [requesterDid] meets the [minTrustLevel] requirement
  /// for [cell] (i.e. at least one confirmed member is a contact or trusted
  /// person of the requester).
  bool meetsMinTrustLevel(Cell cell, String requesterDid) {
    if (cell.minTrustLevel == MinTrustLevel.none) return true;

    final members = _members[cell.id] ?? [];
    final contacts = ContactService.instance.contacts;

    for (final _ in members.where((m) => m.isConfirmed)) {
      final contact = contacts.where((c) => c.did == requesterDid).firstOrNull;
      if (contact == null) continue;
      if (cell.minTrustLevel == MinTrustLevel.contact) return true;
      // TRUSTED: need at least Vertrauensperson trust level
      if (cell.minTrustLevel == MinTrustLevel.trusted &&
          contact.trustLevel.index >= 2) {
        return true;
      }
    }
    return false;
  }

  /// Optional callback invoked when the local user's membership in a cell is
  /// confirmed (join request accepted or direct invite accepted).
  ///
  /// Set by [ChatProvider] to auto-create cell-internal channels.
  Future<void> Function(Cell cell, String myDid)? onMembershipConfirmed;

  /// Optional callback invoked when a new member is approved into a cell
  /// (called on the founder/moderator's device).
  ///
  /// Parameters: cellId, newMemberPseudonym.
  /// Set by [ChatProvider] to post a welcome message in the discussion channel.
  Future<void> Function(String cellId, String pseudonym)? onMemberApproved;

  /// Publishes a Kind-31003 cell join request to Nostr relays.
  /// Set by [ChatProvider] after the transport is ready.
  void Function(Map<String, dynamic> reqJson)? onPublishJoinRequest;

  /// Registers a DID → Nostr pubkey mapping in the transport layer.
  /// Set by [ChatProvider] so CellService can restore mappings on load.
  void Function(String did, String nostrPubkeyHex)? onRegisterNostrMapping;

  /// Publishes a Kind-31004 membership confirmation to Nostr relays.
  /// [requesterNostrPubkeyHex] is the applicant's Nostr pubkey so the relay
  /// can route the event even without a direct DM channel.
  /// Set by [ChatProvider] after the transport is ready.
  void Function(
    Map<String, dynamic> cellJson,
    Map<String, dynamic> memberJson,
    String requesterNostrPubkeyHex,
  )? onPublishMembershipConfirmed;

  /// Publishes a Kind-31005 cell member update event (leave / remove).
  ///
  /// Set by [ChatProvider] after the transport is ready.
  void Function({
    required String cellId,
    required String targetDid,
    required String action,
    String? reason,
  })? onPublishMemberUpdate;

  /// Adds [cellIds] to the persistent block list so they never re-appear in
  /// discovery after a Nostr re-subscription.  Call this BEFORE wiping the DB
  /// so the IDs are remembered even after the rest of the state is cleared.
  Future<void> dismissCells(List<String> cellIds) async {
    var changed = false;
    for (final id in cellIds) {
      if (id.isEmpty) continue;
      if (!_dismissedCellIds.contains(id)) {
        _dismissedCellIds.add(id);
        changed = true;
      }
    }
    _discovered.removeWhere((c) => cellIds.contains(c.id));
    if (changed) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_dismissedKey, jsonEncode(_dismissedCellIds.toList()));
      print('[CELL-DEL] Adding ${cellIds.length} cellIds to block list');
    }
  }

  /// Clears all in-memory cell state. DEBUG use only — call after wiping the DB.
  ///
  /// NOTE: The dismissed-cell block list is intentionally kept so that
  /// zombie cells from Nostr relays do NOT re-appear after a debug reset.
  Future<void> resetForDebug() async {
    _myCells.clear();
    _discovered.clear();
    _members.clear();
    _requests.clear();
    _myRequests.clear();
    // _dismissedCellIds intentionally NOT cleared — persistent block list.
    _notify();
  }

  void _notify() => _streamCtrl.add(null);
}
