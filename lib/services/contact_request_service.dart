import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/contacts/contact_service.dart';
import '../core/storage/pod_database.dart';
import '../core/transport/nexus_message.dart';
import '../features/contacts/contact_request.dart';

/// Singleton service managing incoming and outgoing contact requests.
///
/// Requests are persisted in the [PodDatabase] `contact_requests` table and
/// mirrored in the in-memory [_requests] list so the UI can react to changes
/// via [stream] without hitting the DB on every rebuild.
class ContactRequestService {
  static final ContactRequestService instance = ContactRequestService._();
  ContactRequestService._();

  final List<ContactRequest> _requests = [];
  final _controller =
      StreamController<List<ContactRequest>>.broadcast();

  /// Emits the full request list after every state change.
  Stream<List<ContactRequest>> get stream => _controller.stream;

  // ── Derived views ──────────────────────────────────────────────────────────

  /// Incoming requests that have not yet been decided.
  List<ContactRequest> get pendingRequests => _requests
      .where((r) => !r.isSent && r.status == ContactRequestStatus.pending)
      .toList();

  /// Requests we have sent (all statuses).
  List<ContactRequest> get sentRequests =>
      _requests.where((r) => r.isSent).toList();

  /// Number of pending incoming requests.
  int get pendingCount => pendingRequests.length;

  // ── Queries ────────────────────────────────────────────────────────────────

  /// Returns true when we already have a *pending* outgoing request to [did].
  bool hasSentRequestTo(String did) => _requests.any(
        (r) =>
            r.isSent &&
            r.fromDid == did &&
            r.status == ContactRequestStatus.pending,
      );

  /// Returns true when [did] has a pending *incoming* request.
  bool hasPendingRequestFrom(String did) => _requests.any(
        (r) =>
            !r.isSent &&
            r.fromDid == did &&
            r.status == ContactRequestStatus.pending,
      );

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  /// Loads all stored requests from the database.
  Future<void> load() async {
    try {
      final rows = await PodDatabase.instance.listContactRequests();
      _requests
        ..clear()
        ..addAll(rows.map(ContactRequest.fromJson));
      debugPrint(
          '[CR] Loaded ${_requests.length} contact requests from DB');
    } catch (e) {
      debugPrint('[CR] load() failed: $e');
    }
  }

  // ── Sending ────────────────────────────────────────────────────────────────

  /// Sends a contact request to [toDid].
  ///
  /// Returns `null` on success, or a localised error message on failure.
  ///
  /// Rate limits:
  /// - Max 10 requests per calendar day.
  /// - 30-day cooldown after the other party rejected / ignored us.
  Future<String?> sendRequest(
    String toDid,
    String message, {
    required String myDid,
    required String myPseudonym,
    required String myPublicKey,
    required String myNostrPubkey,
    required Future<void> Function(ContactRequest req) sendFn,
  }) async {
    // ── Duplicate check ──────────────────────────────────────────────────────
    if (hasSentRequestTo(toDid)) {
      return 'Du hast bereits eine ausstehende Kontaktanfrage an diese Person.';
    }

    // ── 30-day cooldown (receiver rejected/ignored) ──────────────────────────
    final cooldownError = _checkCooldown(toDid);
    if (cooldownError != null) return cooldownError;

    // ── Daily rate limit ─────────────────────────────────────────────────────
    final rateError = await _checkRateLimit();
    if (rateError != null) return rateError;

    // ── Build and persist ────────────────────────────────────────────────────
    // For sent requests [fromDid] holds the *recipient* DID so that
    // [hasSentRequestTo] and [_checkCooldown] can look up by peer DID.
    final req = ContactRequest(
      id: ContactRequest.generateId(),
      fromDid: toDid,
      fromPseudonym: myPseudonym,
      fromPublicKey: myPublicKey,
      fromNostrPubkey: myNostrPubkey,
      message: message.length > 500 ? message.substring(0, 500) : message,
      receivedAt: DateTime.now(),
      status: ContactRequestStatus.pending,
      isSent: true,
    );

    _requests.add(req);
    await PodDatabase.instance.upsertContactRequest(req.id, req.toJson());
    await _incrementRateLimit();

    try {
      await sendFn(req);
    } catch (e) {
      debugPrint('[CR] sendFn failed: $e');
      // Don't remove – the local record is still useful for tracking.
    }

    _notify();
    return null;
  }

  // ── Receiving ──────────────────────────────────────────────────────────────

  /// Processes an incoming `contact_request` message.
  ///
  /// Ignored silently when:
  /// - The sender is blocked.
  /// - A 30-day cooldown is active (we previously rejected/ignored them).
  Future<void> handleIncomingRequest(NexusMessage msg) async {
    final fromDid = msg.fromDid;

    // Blocked sender – silent drop.
    if (ContactService.instance.isBlocked(fromDid)) {
      debugPrint('[CR] Ignored incoming request from blocked DID: $fromDid');
      return;
    }

    // 30-day cooldown after we rejected/ignored this DID.
    if (_checkCooldown(fromDid) != null) {
      debugPrint('[CR] Cooldown active for $fromDid – ignoring request');
      return;
    }

    final crData =
        msg.metadata?['contact_request_data'] as Map<String, dynamic>?;
    final fromPublicKey = crData?['fromPublicKey'] as String? ?? '';
    final fromNostrPubkey = crData?['fromNostrPubkey'] as String? ?? '';
    final introMessage = crData?['message'] as String?
        ?? (msg.metadata?['message'] as String? ?? '');

    final fromPseudonym =
        ContactService.instance.getDisplayName(fromDid);

    // De-duplicate: if there is already a pending request from this DID,
    // update it instead of creating a second one.
    final existingIdx = _requests.indexWhere(
      (r) =>
          !r.isSent &&
          r.fromDid == fromDid &&
          r.status == ContactRequestStatus.pending,
    );

    if (existingIdx >= 0) {
      final updated = _requests[existingIdx].copyWith();
      _requests[existingIdx] = updated;
      await PodDatabase.instance
          .upsertContactRequest(updated.id, updated.toJson());
    } else {
      final req = ContactRequest(
        id: ContactRequest.generateId(),
        fromDid: fromDid,
        fromPseudonym: fromPseudonym,
        fromPublicKey: fromPublicKey,
        fromNostrPubkey: fromNostrPubkey,
        message: introMessage,
        receivedAt: DateTime.now(),
        status: ContactRequestStatus.pending,
        isSent: false,
      );
      _requests.add(req);
      await PodDatabase.instance.upsertContactRequest(req.id, req.toJson());
    }

    _notify();
  }

  /// Processes an incoming `contact_request_accepted` message.
  ///
  /// Finds the matching sent request and marks it accepted; then calls
  /// [addContactFn] to add the accepting peer as a contact.
  Future<void> handleAcceptance(
    NexusMessage msg, {
    required Future<void> Function(
      String did,
      String pseudonym,
      String encKey,
      String nostrPubkey,
    ) addContactFn,
  }) async {
    final fromDid = msg.fromDid;
    final idx = _requests.indexWhere(
      (r) =>
          r.isSent &&
          r.fromDid == fromDid &&
          r.status == ContactRequestStatus.pending,
    );
    if (idx < 0) {
      debugPrint('[CR] handleAcceptance: no matching sent request for $fromDid');
      return;
    }

    final now = DateTime.now();
    final updated = _requests[idx].copyWith(
      status: ContactRequestStatus.accepted,
      decidedAt: now,
    );
    _requests[idx] = updated;

    await PodDatabase.instance.updateContactRequestStatus(
      updated.id,
      'accepted',
      now,
    );

    final crData =
        msg.metadata?['contact_request_data'] as Map<String, dynamic>?;
    final encKey = crData?['fromPublicKey'] as String? ??
        (msg.metadata?['enc_key'] as String? ?? '');
    final nostrPubkey = crData?['fromNostrPubkey'] as String? ?? '';
    final pseudonym = msg.body.isNotEmpty
        ? msg.body
        : ContactService.instance.getDisplayName(fromDid);

    try {
      await addContactFn(fromDid, pseudonym, encKey, nostrPubkey);
    } catch (e) {
      debugPrint('[CR] handleAcceptance addContactFn error: $e');
    }

    _notify();
  }

  // ── Decision ───────────────────────────────────────────────────────────────

  /// Accepts an incoming request: adds the sender as a contact and sends a
  /// confirmation message back.
  Future<void> acceptRequest(
    String requestId, {
    required Future<void> Function(ContactRequest req) sendConfirmFn,
    required Future<void> Function(
      String did,
      String pseudonym,
      String encKey,
      String nostrPubkey,
    ) addContactFn,
  }) async {
    final idx = _requests.indexWhere((r) => r.id == requestId);
    if (idx < 0) {
      debugPrint('[CR] acceptRequest: request $requestId not found');
      return;
    }

    final req = _requests[idx];
    final now = DateTime.now();
    final updated = req.copyWith(
      status: ContactRequestStatus.accepted,
      decidedAt: now,
    );
    _requests[idx] = updated;
    await PodDatabase.instance.updateContactRequestStatus(
      requestId,
      'accepted',
      now,
    );

    try {
      await addContactFn(
        req.fromDid,
        req.fromPseudonym,
        req.fromPublicKey,
        req.fromNostrPubkey,
      );
    } catch (e) {
      debugPrint('[CR] acceptRequest addContactFn error: $e');
    }

    try {
      await sendConfirmFn(req);
    } catch (e) {
      debugPrint('[CR] acceptRequest sendConfirmFn error: $e');
    }

    _notify();
  }

  /// Cancels an outgoing request: removes it locally and optionally notifies
  /// the recipient so they can hide the pending request on their side.
  ///
  /// Only works on requests where [isSent] is true.
  Future<void> cancelRequest(
    String requestId, {
    Future<void> Function(String toDid)? sendCancellationFn,
  }) async {
    final idx = _requests.indexWhere((r) => r.id == requestId && r.isSent);
    if (idx < 0) return;

    final req = _requests[idx];

    // Notify the recipient (best-effort) so their pending list updates too.
    if (sendCancellationFn != null) {
      sendCancellationFn(req.fromDid).catchError((e) {
        debugPrint('[CR] cancelRequest sendCancellationFn failed: $e');
      });
    }

    _requests.removeAt(idx);
    await PodDatabase.instance.deleteContactRequest(requestId);
    _notify();
  }

  /// Removes a pending *incoming* request when the sender cancelled it.
  Future<void> handleCancellation(String fromDid) async {
    final idx = _requests.indexWhere(
      (r) =>
          !r.isSent &&
          r.fromDid == fromDid &&
          r.status == ContactRequestStatus.pending,
    );
    if (idx < 0) return;
    final id = _requests[idx].id;
    _requests.removeAt(idx);
    await PodDatabase.instance.deleteContactRequest(id);
    _notify();
  }

  /// Silently rejects a request (the sender is never notified).
  Future<void> rejectRequest(String requestId) async {
    await _updateStatus(requestId, ContactRequestStatus.rejected);
  }

  /// Ignores a request (treated the same as rejected for cooldown purposes).
  Future<void> ignoreRequest(String requestId) async {
    await _updateStatus(requestId, ContactRequestStatus.ignored);
  }

  // ── Internal helpers ───────────────────────────────────────────────────────

  Future<void> _updateStatus(
      String requestId, ContactRequestStatus newStatus) async {
    final idx = _requests.indexWhere((r) => r.id == requestId);
    if (idx < 0) return;

    final now = DateTime.now();
    _requests[idx] = _requests[idx].copyWith(
      status: newStatus,
      decidedAt: now,
    );
    await PodDatabase.instance.updateContactRequestStatus(
      requestId,
      newStatus.name,
      now,
    );
    _notify();
  }

  /// Returns an error message if a 30-day cooldown is active for [did].
  String? _checkCooldown(String did) {
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    final hasCooldown = _requests.any(
      (r) =>
          r.fromDid == did &&
          (r.status == ContactRequestStatus.rejected ||
              r.status == ContactRequestStatus.ignored) &&
          (r.decidedAt?.isAfter(cutoff) ?? false),
    );
    if (hasCooldown) {
      return 'Bitte warte 30 Tage bevor du erneut anfragst.';
    }
    return null;
  }

  /// Returns an error message when the daily rate limit (10/day) is exceeded.
  Future<String?> _checkRateLimit() async {
    final prefs = await SharedPreferences.getInstance();
    final today = _todayString();
    final storedDate = prefs.getString('nexus_cr_today_date') ?? '';
    final count = storedDate == today
        ? (prefs.getInt('nexus_cr_today_count') ?? 0)
        : 0;
    if (count >= 10) {
      return 'Du hast heute bereits 10 Kontaktanfragen gesendet. '
          'Bitte versuche es morgen erneut.';
    }
    return null;
  }

  Future<void> _incrementRateLimit() async {
    final prefs = await SharedPreferences.getInstance();
    final today = _todayString();
    final storedDate = prefs.getString('nexus_cr_today_date') ?? '';
    final count =
        storedDate == today ? (prefs.getInt('nexus_cr_today_count') ?? 0) : 0;
    await prefs.setString('nexus_cr_today_date', today);
    await prefs.setInt('nexus_cr_today_count', count + 1);
  }

  String _todayString() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  void _notify() {
    _controller.add(List.unmodifiable(_requests));
  }

  /// Resets in-memory state. For use in unit tests only.
  void resetForTest() {
    _requests.clear();
    _notify();
  }
}
