import 'dart:convert';
import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'pod_encryption.dart';

/// The NEXUS local data vault (proto-POD).
///
/// Namespaces:
///   - pod_identity    : profile, key metadata, DID
///   - pod_contacts    : known peers (prepared for Phase 1a chat)
///   - pod_messages    : chat messages (prepared for Phase 1a)
///   - pod_credentials : Verifiable Credentials (prepared for Phase 2)
///   - recovery_shares : Shamir's Secret Sharing fragments (Phase 1a+)
///   - pod_meta        : unencrypted schema version and housekeeping data
///
/// All value columns store AES-256-GCM encrypted JSON blobs.
class PodDatabase {
  PodDatabase._();

  static PodDatabase? _instance;
  static PodDatabase get instance => _instance ??= PodDatabase._();

  Database? _db;
  Uint8List? _encKey;

  /// Opens (or creates) the database and sets the encryption key.
  /// [encKey] must be 32 bytes (256-bit AES key).
  Future<void> open(Uint8List encKey) async {
    _encKey = encKey;
    final path = p.join(await getDatabasesPath(), 'nexus_pod.db');
    _db = await openDatabase(path, version: 1, onCreate: _onCreate);
    // Write schema version to metadata
    await _db!.insert(
      'pod_meta',
      {'key': 'schema_version', 'value': '1'},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Allows injecting a pre-opened database (for tests).
  void injectDatabase(Database db, Uint8List encKey) {
    _db = db;
    _encKey = encKey;
  }

  Database get _database {
    if (_db == null) throw StateError('PodDatabase not opened. Call open() first.');
    return _db!;
  }

  /// Exposes the underlying database for testing purposes.
  Database get testDb => _database;

  Uint8List get _key {
    if (_encKey == null) throw StateError('Encryption key not set.');
    return _encKey!;
  }

  // ── Schema ────────────────────────────────────────────────────────────────

  static Future<void> _onCreate(Database db, int version) async {
    // Identity namespace: key/value store for profile and key metadata
    await db.execute('''
      CREATE TABLE pod_identity (
        id   INTEGER PRIMARY KEY,
        key  TEXT NOT NULL UNIQUE,
        enc  TEXT NOT NULL,
        ts   INTEGER NOT NULL
      )
    ''');

    // Contacts: known peers identified by DID
    await db.execute('''
      CREATE TABLE pod_contacts (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        peer_did   TEXT NOT NULL UNIQUE,
        enc        TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    // Messages: chat history (prepared for BLE mesh chat)
    await db.execute('''
      CREATE TABLE pod_messages (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id TEXT NOT NULL,
        sender_did      TEXT NOT NULL,
        enc             TEXT NOT NULL,
        ts              INTEGER NOT NULL,
        status          TEXT NOT NULL DEFAULT 'pending'
      )
    ''');

    // Verifiable Credentials (prepared for Phase 2)
    await db.execute('''
      CREATE TABLE pod_credentials (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        credential_id TEXT NOT NULL UNIQUE,
        type          TEXT NOT NULL,
        issuer_did    TEXT NOT NULL,
        enc           TEXT NOT NULL,
        issued_at     INTEGER NOT NULL
      )
    ''');

    // Shamir's Secret Sharing recovery fragments (Social Recovery)
    // threshold-of-total scheme: e.g. 3-of-5 guardian shares
    await db.execute('''
      CREATE TABLE recovery_shares (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        share_index    INTEGER NOT NULL,
        threshold      INTEGER NOT NULL,
        total_shares   INTEGER NOT NULL,
        share_data_enc TEXT NOT NULL,
        guardian_did   TEXT,
        created_at     INTEGER NOT NULL
      )
    ''');

    // Unencrypted housekeeping metadata (schema version, etc.)
    await db.execute('''
      CREATE TABLE pod_meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  // ── Identity namespace ────────────────────────────────────────────────────

  Future<void> setIdentityValue(String key, Map<String, dynamic> data) async {
    final enc = await PodEncryption.encrypt(jsonEncode(data), _key);
    await _database.insert(
      'pod_identity',
      {'key': key, 'enc': enc, 'ts': DateTime.now().millisecondsSinceEpoch},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> getIdentityValue(String key) async {
    final rows = await _database.query(
      'pod_identity',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final plain = await PodEncryption.decrypt(rows.first['enc'] as String, _key);
    return jsonDecode(plain) as Map<String, dynamic>;
  }

  // ── Contacts namespace ────────────────────────────────────────────────────

  Future<void> upsertContact(String peerDid, Map<String, dynamic> data) async {
    final enc = await PodEncryption.encrypt(jsonEncode(data), _key);
    final now = DateTime.now().millisecondsSinceEpoch;
    await _database.insert(
      'pod_contacts',
      {
        'peer_did': peerDid,
        'enc': enc,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> listContacts() async {
    final rows = await _database.query('pod_contacts', orderBy: 'updated_at DESC');
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final plain = await PodEncryption.decrypt(row['enc'] as String, _key);
      final data = jsonDecode(plain) as Map<String, dynamic>;
      result.add({'peer_did': row['peer_did'], ...data});
    }
    return result;
  }

  // ── Messages namespace ────────────────────────────────────────────────────

  Future<void> insertMessage({
    required String conversationId,
    required String senderDid,
    required Map<String, dynamic> data,
  }) async {
    final enc = await PodEncryption.encrypt(jsonEncode(data), _key);
    await _database.insert('pod_messages', {
      'conversation_id': conversationId,
      'sender_did': senderDid,
      'enc': enc,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'status': 'pending',
    });
  }

  Future<List<Map<String, dynamic>>> listMessages(String conversationId) async {
    final rows = await _database.query(
      'pod_messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'ts ASC',
    );
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final plain = await PodEncryption.decrypt(row['enc'] as String, _key);
      final data = jsonDecode(plain) as Map<String, dynamic>;
      result.add({'sender_did': row['sender_did'], 'ts': row['ts'], ...data});
    }
    return result;
  }

  // ── Conversation helpers ──────────────────────────────────────────────────

  /// Returns one row per conversation: { conversation_id, last_ts }.
  /// Ordered by most-recent message first.
  Future<List<Map<String, dynamic>>> listConversationSummaries() async {
    final rows = await _database.rawQuery('''
      SELECT conversation_id, MAX(ts) AS last_ts
      FROM pod_messages
      GROUP BY conversation_id
      ORDER BY last_ts DESC
    ''');
    return List<Map<String, dynamic>>.from(rows);
  }

  /// Returns the last [limit] messages for [conversationId] (newest first).
  /// Each row is decrypted and includes sender_did and ts.
  Future<List<Map<String, dynamic>>> listLastMessages(
    String conversationId, {
    int limit = 1,
  }) async {
    final rows = await _database.query(
      'pod_messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'ts DESC',
      limit: limit,
    );
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      try {
        final plain =
            await PodEncryption.decrypt(row['enc'] as String, _key);
        final data = jsonDecode(plain) as Map<String, dynamic>;
        result.add({'sender_did': row['sender_did'], 'ts': row['ts'], ...data});
      } catch (_) {
        // Skip unreadable rows
      }
    }
    return result;
  }

  /// Counts messages in [conversationId] received after [afterTimestampMs].
  Future<int> countMessagesAfter(
      String conversationId, int afterTimestampMs) async {
    final rows = await _database.rawQuery(
      'SELECT COUNT(*) AS cnt FROM pod_messages '
      'WHERE conversation_id = ? AND ts > ?',
      [conversationId, afterTimestampMs],
    );
    return (rows.first['cnt'] as int?) ?? 0;
  }

  /// Deletes all messages belonging to [conversationId].
  Future<void> deleteConversation(String conversationId) async {
    await _database.delete(
      'pod_messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
    );
  }

  // ── Export / Import ───────────────────────────────────────────────────────

  /// Exports all pod data as a single AES-256-GCM encrypted JSON blob.
  ///
  /// Structure (before encryption):
  /// {
  ///   "version": 1,
  ///   "exported_at": "ISO-8601 timestamp",
  ///   "identity": [ { "key": ..., "enc": ... } ],
  ///   "contacts": [...],
  ///   "messages": [...],
  ///   "credentials": [...],
  ///   "recovery_shares": [...]
  /// }
  ///
  /// Returns base64url-encoded encrypted blob suitable for Solid POD migration.
  Future<String> exportEncrypted() async {
    final db = _database;
    final payload = <String, dynamic>{
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'identity': await db.query('pod_identity'),
      'contacts': await db.query('pod_contacts'),
      'messages': await db.query('pod_messages'),
      'credentials': await db.query('pod_credentials'),
      'recovery_shares': await db.query('recovery_shares'),
    };
    return PodEncryption.encrypt(jsonEncode(payload), _key);
  }

  /// Imports from an encrypted blob created by [exportEncrypted].
  ///
  /// WARNING: This replaces all existing data in the pod.
  Future<void> importEncrypted(String blob) async {
    final plain = await PodEncryption.decrypt(blob, _key);
    final payload = jsonDecode(plain) as Map<String, dynamic>;

    final db = _database;
    final batch = db.batch();

    batch.delete('pod_identity');
    batch.delete('pod_contacts');
    batch.delete('pod_messages');
    batch.delete('pod_credentials');
    batch.delete('recovery_shares');

    for (final row in (payload['identity'] as List)) {
      batch.insert('pod_identity', Map<String, dynamic>.from(row as Map));
    }
    for (final row in (payload['contacts'] as List)) {
      batch.insert('pod_contacts', Map<String, dynamic>.from(row as Map));
    }
    for (final row in (payload['messages'] as List)) {
      batch.insert('pod_messages', Map<String, dynamic>.from(row as Map));
    }
    for (final row in (payload['credentials'] as List)) {
      batch.insert('pod_credentials', Map<String, dynamic>.from(row as Map));
    }
    for (final row in (payload['recovery_shares'] as List)) {
      batch.insert('recovery_shares', Map<String, dynamic>.from(row as Map));
    }
    await batch.commit(noResult: true);
  }

  // ── Metadata ──────────────────────────────────────────────────────────────

  Future<String?> getMeta(String key) async {
    final rows = await _database.query(
      'pod_meta', where: 'key = ?', whereArgs: [key], limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setMeta(String key, String value) async {
    await _database.insert(
      'pod_meta',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
