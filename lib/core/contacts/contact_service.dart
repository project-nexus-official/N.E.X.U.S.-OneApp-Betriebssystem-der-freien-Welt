import 'package:nexus_oneapp/core/identity/profile.dart';
import 'package:nexus_oneapp/core/storage/pod_database.dart';
import 'contact.dart';

/// Manages contacts and trust levels, backed by the encrypted [PodDatabase].
class ContactService {
  static final ContactService instance = ContactService._();
  ContactService._();

  final List<Contact> _contacts = [];
  List<Contact> get contacts => List.unmodifiable(_contacts);

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

  /// Returns all contacts with the given [level].
  List<Contact> getContactsByTrustLevel(TrustLevel level) =>
      _contacts.where((c) => c.trustLevel == level).toList();

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
