import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:nexus_oneapp/core/identity/profile.dart';
import 'package:nexus_oneapp/core/storage/pod_database.dart';
import 'package:nexus_oneapp/core/transport/transport_manager.dart';
import 'contact.dart';

/// Manages contacts and trust levels, backed by the encrypted [PodDatabase].
class ContactService {
  static final ContactService instance = ContactService._();
  ContactService._();

  final List<Contact> _contacts = [];

  // Broadcast stream that fires whenever a contact's display name changes.
  // Listeners (e.g. ConversationService) use this to refresh the UI.
  final _contactsChangedController = StreamController<void>.broadcast();
  Stream<void> get contactsChanged => _contactsChangedController.stream;

  /// All non-blocked contacts.
  List<Contact> get contacts =>
      List.unmodifiable(_contacts.where((c) => !c.blocked));

  /// All blocked contacts (for the settings blocked-list screen).
  List<Contact> get blockedContacts =>
      List.unmodifiable(_contacts.where((c) => c.blocked));

  /// Loads all contacts from the POD into memory.
  Future<void> load() async {
    try {
      final rows = await PodDatabase.instance.listContacts();
      _contacts
        ..clear()
        ..addAll(
          rows
              .where((r) => r['_deleted'] != true)
              .map((r) => Contact.fromJson(r)),
        );
      debugPrint('[CONTACTS] Loaded ${_contacts.length} contacts from DB');
      for (final c in _contacts) {
        debugPrint('[CONTACTS]   ${c.did.length > 16 ? c.did.substring(c.did.length - 16) : c.did}'
            '  "${c.pseudonym}"  trust=${c.trustLevel.name}');
      }
    } catch (e) {
      // Database not yet open (e.g. during onboarding) – ignore.
      debugPrint('[CONTACTS] load() failed (DB not open?): $e');
    }
  }

  /// Adds a peer as [TrustLevel.discovered]. Returns existing contact if
  /// the DID is already known.
  Future<Contact> addContact(String did, String pseudonym) async {
    final existing = _findByDid(did);
    if (existing != null) return existing;

    final now = DateTime.now();
    final contact = Contact(
      did: did,
      pseudonym: pseudonym,
      trustLevel: TrustLevel.discovered,
      addedAt: now,
      lastSeen: now,
    );
    await _persist(contact);
    _contacts.add(contact);
    return contact;
  }

  /// Adds (or updates) a contact from a QR code scan.
  ///
  /// Sets trust level to [TrustLevel.contact], stores the X25519 encryption
  /// key and Nostr public key so E2E messaging is possible immediately.
  /// If the DID is already known the trust level is upgraded if needed and
  /// the keys are updated; the pseudonym is refreshed from the QR data.
  Future<Contact> addContactFromQr({
    required String did,
    required String pseudonym,
    String? encryptionPublicKey,
    String? nostrPubkey,
  }) async {
    var contact = _findByDid(did);
    if (contact == null) {
      final now = DateTime.now();
      contact = Contact(
        did: did,
        pseudonym: pseudonym,
        trustLevel: TrustLevel.contact,
        addedAt: now,
        lastSeen: now,
        encryptionPublicKey: encryptionPublicKey,
        nostrPubkey: nostrPubkey,
      );
      await _persist(contact);
      _contacts.add(contact);
    } else {
      // Upgrade trust level if currently lower than "contact".
      if (contact.trustLevel.sortWeight < TrustLevel.contact.sortWeight) {
        contact.trustLevel = TrustLevel.contact;
      }
      contact.pseudonym = pseudonym;
      if (encryptionPublicKey != null && encryptionPublicKey.isNotEmpty) {
        if (contact.encryptionPublicKey != null &&
            contact.encryptionPublicKey != encryptionPublicKey) {
          contact.previousEncryptionPublicKey = contact.encryptionPublicKey;
        }
        contact.encryptionPublicKey = encryptionPublicKey;
      }
      if (nostrPubkey != null && nostrPubkey.isNotEmpty) {
        contact.nostrPubkey = nostrPubkey;
      }
      await _persist(contact);
    }
    return contact;
  }

  /// Sets the Nostr public key for a known contact.
  Future<void> setNostrPubkey(String did, String nostrPubkey) async {
    final contact = _findByDid(did);
    if (contact == null) return;
    contact.nostrPubkey = nostrPubkey;
    await _persist(contact);
  }

  /// Upgrades a contact from [TrustLevel.discovered] to [TrustLevel.contact]
  /// (mutual confirmation).
  Future<void> acceptContact(String did) =>
      setTrustLevel(did, TrustLevel.contact);

  /// Changes the trust level of an existing contact.
  Future<void> setTrustLevel(String did, TrustLevel level) async {
    final contact = _findByDid(did);
    if (contact == null) return;
    contact.trustLevel = level;
    await _persist(contact);
  }

  /// Removes a contact (soft-delete in the POD).
  Future<void> removeContact(String did) async {
    _contacts.removeWhere((c) => c.did == did);
    await PodDatabase.instance
        .upsertContact(did, {'did': did, '_deleted': true});
  }

  /// Blocks a contact – their messages will be silently dropped.
  /// The contact remains in [_contacts] but is excluded from [contacts].
  Future<void> blockContact(String did) async {
    var contact = _findByDid(did);
    if (contact == null) {
      // Create a minimal blocked entry so the DID stays blocked.
      final now = DateTime.now();
      contact = Contact(
        did: did,
        pseudonym: did.length > 12 ? did.substring(did.length - 12) : did,
        trustLevel: TrustLevel.discovered,
        addedAt: now,
        lastSeen: now,
        blocked: true,
      );
      _contacts.add(contact);
    } else {
      contact.blocked = true;
    }
    await _persist(contact);
  }

  /// Unblocks a previously blocked contact.
  Future<void> unblockContact(String did) async {
    final contact = _findByDid(did);
    if (contact == null) return;
    contact.blocked = false;
    await _persist(contact);
  }

  /// Returns true if [did] is blocked.
  bool isBlocked(String did) =>
      _contacts.any((c) => c.did == did && c.blocked);

  /// Mutes a contact for [duration] (null = permanent).
  /// Their messages arrive but don't produce notifications.
  Future<void> muteContact(String did, Duration? duration) async {
    final contact = _findByDid(did);
    if (contact == null) return;
    contact.mutedUntil =
        duration != null ? DateTime.now().add(duration) : DateTime(9999);
    await _persist(contact);
    _contactsChangedController.add(null); // refresh conversation list icons
  }

  /// Unmutes a contact immediately.
  Future<void> unmuteContact(String did) async {
    final contact = _findByDid(did);
    if (contact == null) return;
    contact.mutedUntil = null;
    await _persist(contact);
    _contactsChangedController.add(null); // refresh conversation list icons
  }

  /// Clears expired mutes (mutedUntil in the past). Call periodically.
  Future<void> clearExpiredMutes() async {
    final now = DateTime.now();
    final expired = _contacts
        .where((c) => c.mutedUntil != null && c.mutedUntil!.isBefore(now))
        .toList();
    if (expired.isEmpty) return;
    for (final c in expired) {
      c.mutedUntil = null;
      await _persist(c);
    }
    _contactsChangedController.add(null);
  }

  /// Sets (or updates) the X25519 encryption public key for a peer.
  /// If the key changes, saves the previous key for key-change warning display.
  Future<void> setEncryptionKey(String did, String encKeyHex) async {
    final contact = findByDid(did);
    if (contact == null) return;
    if (contact.encryptionPublicKey == encKeyHex) return; // no change
    if (contact.encryptionPublicKey != null &&
        contact.encryptionPublicKey != encKeyHex) {
      contact.previousEncryptionPublicKey = contact.encryptionPublicKey;
    }
    contact.encryptionPublicKey = encKeyHex;
    await _persist(contact);
  }

  /// Clears the key-change warning for [did] after user acknowledges it.
  Future<void> acknowledgeKeyChange(String did) async {
    final contact = findByDid(did);
    if (contact == null) return;
    contact.previousEncryptionPublicKey = null;
    await _persist(contact);
  }

  /// Returns true if [did] is currently muted (mutedUntil is set and in the future).
  bool isMuted(String did) {
    final contact = _findByDid(did);
    if (contact == null) return false;
    return contact.mutedUntil != null &&
        contact.mutedUntil!.isAfter(DateTime.now());
  }

  /// Returns the mutedUntil DateTime for [did], or null if not muted.
  DateTime? mutedUntil(String did) {
    final contact = _findByDid(did);
    if (contact == null) return null;
    final mu = contact.mutedUntil;
    if (mu == null || mu.isBefore(DateTime.now())) return null;
    return mu;
  }

  /// Updates the private local note for a contact.
  Future<void> updateNotes(String did, String? notes) async {
    final contact = _findByDid(did);
    if (contact == null) return;
    contact.notes = notes;
    await _persist(contact);
  }

  /// Updates the display name for a contact.
  Future<void> updatePseudonym(String did, String pseudonym) async {
    final contact = _findByDid(did);
    if (contact == null) return;
    contact.pseudonym = pseudonym;
    await _persist(contact);
    _contactsChangedController.add(null);
  }

  /// Returns all contacts with the given [level].
  List<Contact> getContactsByTrustLevel(TrustLevel level) =>
      contacts.where((c) => c.trustLevel == level).toList();

  /// Looks up a contact by DID. Returns null if not known.
  Contact? findByDid(String did) => _findByDid(did);

  /// Returns the best available display name for [did].
  ///
  /// Priority:
  ///   1. Contact's pseudonym (if set and not just a raw DID fragment).
  ///   2. Live transport peer name (correct but ephemeral – requires peer online).
  ///   3. Last 12 characters of the DID as final fallback.
  String getDisplayName(String did) {
    final contact = _findByDid(did);
    if (contact != null) {
      final p = contact.pseudonym.trim();
      if (p.isNotEmpty && !_isDidFragment(p, did)) return p;
    }
    // Fall back to live peer name from any active transport
    final livePeer = TransportManager.instance.peers
        .where((p) => p.did == did)
        .firstOrNull;
    if (livePeer != null && livePeer.pseudonym.isNotEmpty) {
      return livePeer.pseudonym;
    }
    return did.length > 12 ? did.substring(did.length - 12) : did;
  }

  /// Updates a contact's stored pseudonym only when [pseudonym] is a proper
  /// name (i.e. not a raw DID fragment) and differs from what is stored.
  ///
  /// Called when a presence event or Kind-0 metadata event arrives with the
  /// peer's self-reported name.
  Future<void> updatePseudonymIfBetter(String did, String pseudonym) async {
    final trimmed = pseudonym.trim();
    if (trimmed.isEmpty) return;
    final contact = _findByDid(did);
    if (contact == null) return;
    if (_isDidFragment(trimmed, did)) return; // not an improvement
    if (contact.pseudonym == trimmed) return; // no change
    final old = contact.pseudonym;
    contact.pseudonym = trimmed;
    await _persist(contact);
    debugPrint('[CONTACTS] Nickname updated: "$old" → "$trimmed" (did: ...${did.length > 8 ? did.substring(did.length - 8) : did})');
    _contactsChangedController.add(null);
  }

  /// Returns true when [value] is just the tail fragment of [did] (i.e. was
  /// generated as a fallback, not supplied by the peer themselves).
  bool _isDidFragment(String value, String did) {
    if (did.length > 12) return value == did.substring(did.length - 12);
    return value == did;
  }

  /// Returns the profile fields of [myProfile] that a contact with [did]
  /// is allowed to see, based on their trust level.
  ///
  /// Falls back to [TrustLevel.discovered] if the DID is unknown.
  Map<String, dynamic> getVisibleProfile(
    String did,
    UserProfile myProfile,
  ) {
    final contact = _findByDid(did);
    final level = contact?.trustLevel ?? TrustLevel.discovered;
    return myProfile.visibleTo(level.allowedVisibility);
  }

  /// Exports all non-deleted contacts as a JSON list.
  String exportJson() {
    final exportable = _contacts
        .where((c) => !c.blocked)
        .map((c) => c.toJson())
        .toList();
    return jsonEncode(exportable);
  }

  /// Imports contacts from a JSON list string.
  ///
  /// - Skips DIDs that are already known.
  /// - If the imported entry has a higher trust level, it wins.
  /// - Returns [ImportResult] with counts.
  Future<ImportResult> importJson(String jsonStr) async {
    int added = 0, updated = 0, skipped = 0;

    final List<dynamic> list;
    try {
      list = jsonDecode(jsonStr) as List<dynamic>;
    } catch (_) {
      return ImportResult(added: 0, updated: 0, skipped: 0, error: 'Ungültiges JSON-Format.');
    }

    for (final raw in list) {
      try {
        final map = raw as Map<String, dynamic>;
        final did = map['did'] as String? ?? '';
        if (did.isEmpty) { skipped++; continue; }

        final existing = _findByDid(did);
        if (existing == null) {
          final contact = Contact.fromJson(map);
          contact.blocked = false; // never import blocked state
          await _persist(contact);
          _contacts.add(contact);
          added++;
        } else {
          // Higher trust level wins.
          final importedLevel = TrustLevel.values.firstWhere(
            (e) => e.name == map['trustLevel'],
            orElse: () => TrustLevel.discovered,
          );
          if (importedLevel.sortWeight > existing.trustLevel.sortWeight) {
            existing.trustLevel = importedLevel;
            await _persist(existing);
            updated++;
          } else {
            skipped++;
          }
        }
      } catch (e) {
        debugPrint('[CONTACTS] Import error: $e');
        skipped++;
      }
    }
    return ImportResult(added: added, updated: updated, skipped: skipped);
  }

  Contact? _findByDid(String did) {
    try {
      return _contacts.firstWhere((c) => c.did == did);
    } catch (_) {
      return null;
    }
  }

  Future<void> _persist(Contact contact) async {
    contact.lastSeen = DateTime.now();
    await PodDatabase.instance.upsertContact(contact.did, contact.toJson());
  }
}

class ImportResult {
  final int added;
  final int updated;
  final int skipped;
  final String? error;

  const ImportResult({
    required this.added,
    required this.updated,
    required this.skipped,
    this.error,
  });
}
