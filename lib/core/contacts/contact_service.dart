import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:nexus_oneapp/core/identity/profile.dart';
import 'package:nexus_oneapp/core/storage/pod_database.dart';
import 'contact.dart';

/// Manages contacts and trust levels, backed by the encrypted [PodDatabase].
class ContactService {
  static final ContactService instance = ContactService._();
  ContactService._();

  final List<Contact> _contacts = [];

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
    } catch (_) {
      // Database not yet open (e.g. during onboarding) – ignore.
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

  /// Mutes a contact – their messages arrive but don't produce notifications.
  Future<void> muteContact(String did) async {
    final contact = _findByDid(did);
    if (contact == null) return;
    contact.muted = true;
    await _persist(contact);
  }

  /// Unmutes a contact.
  Future<void> unmuteContact(String did) async {
    final contact = _findByDid(did);
    if (contact == null) return;
    contact.muted = false;
    await _persist(contact);
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

  /// Returns true if [did] is muted (notifications silenced).
  bool isMuted(String did) =>
      _contacts.any((c) => c.did == did && c.muted);

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
  }

  /// Returns all contacts with the given [level].
  List<Contact> getContactsByTrustLevel(TrustLevel level) =>
      contacts.where((c) => c.trustLevel == level).toList();

  /// Looks up a contact by DID. Returns null if not known.
  Contact? findByDid(String did) => _findByDid(did);

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
