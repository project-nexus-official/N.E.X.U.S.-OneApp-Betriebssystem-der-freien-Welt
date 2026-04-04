import 'dart:async';

import 'package:flutter/foundation.dart';

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

  final _streamCtrl = StreamController<void>.broadcast();

  /// Fires whenever any cell data changes.
  Stream<void> get stream => _streamCtrl.stream;

  List<Cell> get myCells => List.unmodifiable(_myCells);
  List<Cell> get discoveredCells => List.unmodifiable(_discovered);

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
      final rows = await PodDatabase.instance.listCells();
      _myCells
        ..clear()
        ..addAll(rows.map(Cell.fromJson));

      // Load members and requests for each joined cell.
      for (final cell in _myCells) {
        final memberRows = await PodDatabase.instance.listCellMembers(cell.id);
        _members[cell.id] =
            memberRows.map(CellMember.fromJson).toList();

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
    _myCells[idx] = updated;
    await PodDatabase.instance.upsertCell(updated.id, updated.toJson());
    _notify();
  }

  /// Restores a cell membership from a backup JSON map (merge – only adds if
  /// not already a member).  Called by [BackupService].
  Future<void> restoreFromBackup(Map<String, dynamic> json) async {
    try {
      final cell = Cell.fromJson(json);
      if (_myCells.any((c) => c.id == cell.id)) return;
      _myCells.add(cell);
      await PodDatabase.instance.upsertCell(cell.id, json);
      _notify();
    } catch (e) {
      debugPrint('[CELLS] restoreFromBackup error: $e');
    }
  }

  /// Adds a discovered cell from Nostr (does not persist).
  void addDiscoveredCell(Cell cell) {
    if (_myCells.any((c) => c.id == cell.id)) return;
    _discovered.removeWhere((c) => c.id == cell.id);
    _discovered.add(cell);
    _notify();
  }

  // ── Membership management ──────────────────────────────────────────────────

  /// Sends a join request for [cell] (APPROVAL_REQUIRED policy).
  Future<void> sendJoinRequest(Cell cell, {String? message}) async {
    final identity = IdentityService.instance.currentIdentity!;
    final req = CellJoinRequest.create(
      cellId: cell.id,
      requesterDid: identity.did,
      requesterPseudonym: identity.pseudonym,
      message: message,
    );
    await PodDatabase.instance.upsertCellJoinRequest(
        req.id, req.cellId, req.toJson(), isSent: true);
    _myRequests.add(req);
    _notify();
    debugPrint('[CELLS] Sent join request to ${cell.name}');
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

  /// The local user leaves a cell (exit right always available).
  Future<void> leaveCell(String cellId) async {
    final myDid = IdentityService.instance.currentIdentity!.did;
    await PodDatabase.instance.deleteCellMember(cellId, myDid);
    await PodDatabase.instance.deleteCell(cellId);
    _myCells.removeWhere((c) => c.id == cellId);
    _members.remove(cellId);
    _requests.remove(cellId);
    _notify();
    debugPrint('[CELLS] Left cell $cellId');
  }

  /// Dissolves a cell entirely (superadmin / system-admin only).
  ///
  /// Removes all members and the cell itself from the local DB.
  /// The caller is responsible for publishing the Kind-5 Nostr deletion event.
  Future<void> deleteCell(String cellId) async {
    final members = List<CellMember>.from(_members[cellId] ?? []);
    for (final m in members) {
      await PodDatabase.instance.deleteCellMember(cellId, m.did);
    }
    await PodDatabase.instance.deleteCell(cellId);
    _myCells.removeWhere((c) => c.id == cellId);
    _discovered.removeWhere((c) => c.id == cellId);
    _members.remove(cellId);
    _requests.remove(cellId);
    _notify();
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
  Future<void> handleMembershipConfirmed(Cell cell, CellMember member) async {
    // Check if we already know this cell.
    if (!_myCells.any((c) => c.id == cell.id)) {
      await PodDatabase.instance.upsertCell(cell.id, cell.toJson());
      _myCells.add(cell);
      _members[cell.id] = [];
      _requests[cell.id] = [];
    }
    (_members[cell.id] ??= [])
        .removeWhere((m) => m.did == member.did);
    (_members[cell.id] ??= []).add(member);
    await PodDatabase.instance.upsertCellMember(
        cell.id, member.did, member.toJson());
    _notify();

    await NotificationService.instance.showGenericNotification(
      title: 'Beitritt bestätigt!',
      body: 'Du bist jetzt Mitglied von ${cell.name}.',
      payload: 'cell_info:${cell.id}',
    );
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

  void _notify() => _streamCtrl.add(null);
}
