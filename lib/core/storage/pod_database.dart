import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
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
  ///
  /// The database is stored in [getApplicationDocumentsDirectory] so the path
  /// stays stable regardless of the process working directory (important on
  /// Windows desktop where sqflite_ffi defaults to the CWD).
  Future<void> open(Uint8List encKey) async {
    _encKey = encKey;

    // Use path_provider so the path is consistent across restarts on all
    // platforms (sqflite_ffi otherwise falls back to the CWD on Windows).
    final docsDir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(docsDir.path, 'nexus_pod.db');

    final dbFile = File(dbPath);
    final dbFileExists = dbFile.existsSync();
    final dbSize = dbFileExists ? dbFile.lengthSync() : 0;
    debugPrint('[DB] Path: $dbPath  exists: $dbFileExists  size: ${dbSize}B');

    _db = await openDatabase(
      dbPath,
      version: 9,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );

    // Write schema version to metadata
    await _db!.insert(
      'pod_meta',
      {'key': 'schema_version', 'value': '1'},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    final msgCount = (await _db!.rawQuery(
      'SELECT COUNT(*) AS cnt FROM pod_messages',
    )).first['cnt'] as int? ?? 0;
    final contactCount = (await _db!.rawQuery(
      'SELECT COUNT(*) AS cnt FROM pod_contacts',
    )).first['cnt'] as int? ?? 0;
    debugPrint('[DB] Opened – messages: $msgCount  contacts: $contactCount');
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
        id                     INTEGER PRIMARY KEY AUTOINCREMENT,
        peer_did               TEXT NOT NULL UNIQUE,
        enc                    TEXT NOT NULL,
        created_at             INTEGER NOT NULL,
        updated_at             INTEGER NOT NULL,
        encryption_public_key  TEXT
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
        status          TEXT NOT NULL DEFAULT 'pending',
        encrypted       INTEGER NOT NULL DEFAULT 0,
        message_id      TEXT,
        is_favorite     INTEGER NOT NULL DEFAULT 0,
        is_deleted      INTEGER NOT NULL DEFAULT 0,
        edited_body     TEXT
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

    // Group channels: named multi-user channels (e.g. #teneriffa)
    await db.execute('''
      CREATE TABLE group_channels (
        id         TEXT PRIMARY KEY,
        enc        TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    // Unencrypted housekeeping metadata (schema version, etc.)
    await db.execute('''
      CREATE TABLE pod_meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    // System-wide role assignments (superadmin → system_admin).
    await db.execute('''
      CREATE TABLE system_roles (
        did        TEXT PRIMARY KEY,
        role       TEXT NOT NULL,
        granted_by TEXT NOT NULL,
        granted_at INTEGER NOT NULL
      )
    ''');

    // Channel-level role assignments (moderators per channel).
    await db.execute('''
      CREATE TABLE channel_roles (
        channel_id TEXT NOT NULL,
        did        TEXT NOT NULL,
        role       TEXT NOT NULL,
        granted_by TEXT NOT NULL,
        granted_at INTEGER NOT NULL,
        PRIMARY KEY (channel_id, did)
      )
    ''');

    // NIP-25 emoji reactions on messages.
    await db.execute('''
      CREATE TABLE message_reactions (
        message_id   TEXT NOT NULL,
        emoji        TEXT NOT NULL,
        reactor_did  TEXT NOT NULL,
        created_at   INTEGER NOT NULL,
        PRIMARY KEY (message_id, emoji, reactor_did)
      )
    ''');

    // Contact requests (incoming and outgoing).
    await db.execute('''
      CREATE TABLE contact_requests (
        id           TEXT PRIMARY KEY,
        from_did     TEXT NOT NULL,
        is_sent      INTEGER NOT NULL DEFAULT 0,
        status       TEXT NOT NULL DEFAULT 'pending',
        received_at  INTEGER NOT NULL,
        enc          TEXT NOT NULL
      )
    ''');

    // Dorfplatz social feed posts.
    await db.execute('''
      CREATE TABLE feed_posts (
        id             TEXT PRIMARY KEY,
        author_did     TEXT NOT NULL,
        visibility     TEXT NOT NULL DEFAULT 'contacts',
        created_at     INTEGER NOT NULL,
        nostr_event_id TEXT,
        enc            TEXT NOT NULL,
        is_deleted     INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // Dorfplatz comments on feed posts.
    await db.execute('''
      CREATE TABLE feed_comments (
        id                TEXT PRIMARY KEY,
        post_id           TEXT NOT NULL,
        author_did        TEXT NOT NULL,
        created_at        INTEGER NOT NULL,
        enc               TEXT NOT NULL,
        is_deleted        INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // Authors muted by the local user (hidden from feed).
    await db.execute('''
      CREATE TABLE feed_mutes (
        author_did TEXT PRIMARY KEY,
        muted_at   INTEGER NOT NULL
      )
    ''');
  }

  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Add encryption_public_key column to contacts (unencrypted, for quick lookup)
      await db.execute(
        'ALTER TABLE pod_contacts ADD COLUMN encryption_public_key TEXT',
      );
      // Add encrypted flag to messages
      await db.execute(
        'ALTER TABLE pod_messages ADD COLUMN encrypted INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 3) {
      // Add message_id column for deduplication (catches missed messages on restart)
      await db.execute(
        'ALTER TABLE pod_messages ADD COLUMN message_id TEXT',
      );
    }
    if (oldVersion < 4) {
      // Add group_channels table for named multi-user channels.
      await db.execute('''
        CREATE TABLE IF NOT EXISTS group_channels (
          id         TEXT PRIMARY KEY,
          enc        TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
      ''');
    }
    if (oldVersion < 5) {
      // Add local-state columns for message actions (favorite, delete, edit).
      await db.execute(
        'ALTER TABLE pod_messages ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE pod_messages ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE pod_messages ADD COLUMN edited_body TEXT',
      );
    }
    if (oldVersion < 6) {
      // Add system_roles and channel_roles tables for the role hierarchy.
      await db.execute('''
        CREATE TABLE IF NOT EXISTS system_roles (
          did        TEXT PRIMARY KEY,
          role       TEXT NOT NULL,
          granted_by TEXT NOT NULL,
          granted_at INTEGER NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS channel_roles (
          channel_id TEXT NOT NULL,
          did        TEXT NOT NULL,
          role       TEXT NOT NULL,
          granted_by TEXT NOT NULL,
          granted_at INTEGER NOT NULL,
          PRIMARY KEY (channel_id, did)
        )
      ''');
    }
    if (oldVersion < 7) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS message_reactions (
          message_id   TEXT NOT NULL,
          emoji        TEXT NOT NULL,
          reactor_did  TEXT NOT NULL,
          created_at   INTEGER NOT NULL,
          PRIMARY KEY (message_id, emoji, reactor_did)
        )
      ''');
    }
    if (oldVersion < 8) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS contact_requests (
          id           TEXT PRIMARY KEY,
          from_did     TEXT NOT NULL,
          is_sent      INTEGER NOT NULL DEFAULT 0,
          status       TEXT NOT NULL DEFAULT 'pending',
          received_at  INTEGER NOT NULL,
          enc          TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 9) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS feed_posts (
          id             TEXT PRIMARY KEY,
          author_did     TEXT NOT NULL,
          visibility     TEXT NOT NULL DEFAULT 'contacts',
          created_at     INTEGER NOT NULL,
          nostr_event_id TEXT,
          enc            TEXT NOT NULL,
          is_deleted     INTEGER NOT NULL DEFAULT 0
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS feed_comments (
          id                TEXT PRIMARY KEY,
          post_id           TEXT NOT NULL,
          author_did        TEXT NOT NULL,
          created_at        INTEGER NOT NULL,
          enc               TEXT NOT NULL,
          is_deleted        INTEGER NOT NULL DEFAULT 0
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS feed_mutes (
          author_did TEXT PRIMARY KEY,
          muted_at   INTEGER NOT NULL
        )
      ''');
    }
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
    debugPrint('[DB] listContacts: rows=${rows.length}');
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
    // Deduplicate: skip if this message ID already exists in the DB.
    // This prevents duplicate storage when missed Nostr messages are re-delivered
    // on reconnect and a copy was already received via LAN/BLE.
    final msgId = data['id'] as String?;
    if (msgId != null) {
      final rows = await _database.rawQuery(
        'SELECT 1 FROM pod_messages WHERE message_id = ? LIMIT 1',
        [msgId],
      );
      if (rows.isNotEmpty) {
        debugPrint('[DB] insertMessage: duplicate $msgId – skip');
        return;
      }
    }

    final enc = await PodEncryption.encrypt(jsonEncode(data), _key);
    await _database.insert('pod_messages', {
      'conversation_id': conversationId,
      'sender_did': senderDid,
      'enc': enc,
      'ts': data['ts'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      'status': 'pending',
      // ignore: use_null_aware_elements
      if (msgId != null) 'message_id': msgId,
    });
    debugPrint('[DB] insertMessage: saved ${msgId ?? "(no id)"} conv=$conversationId');
  }

  Future<List<Map<String, dynamic>>> listMessages(String conversationId) async {
    final rows = await _database.query(
      'pod_messages',
      where: 'conversation_id = ? AND is_deleted = 0',
      whereArgs: [conversationId],
      orderBy: 'ts ASC',
    );
    debugPrint('[DB] listMessages: conv=$conversationId  rows=${rows.length}');
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final plain = await PodEncryption.decrypt(row['enc'] as String, _key);
      final data = jsonDecode(plain) as Map<String, dynamic>;
      result.add({
        'sender_did': row['sender_did'],
        'ts': row['ts'],
        ...data,
        // Local-state columns – consumed by ChatProvider, not sent over wire.
        '_is_favorite': row['is_favorite'] as int? ?? 0,
        '_edited_body': row['edited_body'] as String?,
      });
    }
    debugPrint('[DB] listMessages: decoded ${result.length} messages for conv=$conversationId');
    return result;
  }

  /// Sets or clears the favorite flag for [messageId].
  Future<void> setMessageFavorite(String messageId, {required bool isFavorite}) async {
    await _database.update(
      'pod_messages',
      {'is_favorite': isFavorite ? 1 : 0},
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }

  /// Soft-deletes a message (hidden from listMessages, data preserved).
  Future<void> softDeleteMessage(String messageId) async {
    await _database.update(
      'pod_messages',
      {'is_deleted': 1},
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }

  /// Stores an edited body for [messageId] without changing the enc blob.
  Future<void> setEditedBody(String messageId, String newBody) async {
    await _database.update(
      'pod_messages',
      {'edited_body': newBody},
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }

  /// Returns all favorite messages in [conversationId], newest first.
  Future<List<Map<String, dynamic>>> listFavoriteMessages(
      String conversationId) async {
    final rows = await _database.query(
      'pod_messages',
      where: 'conversation_id = ? AND is_favorite = 1 AND is_deleted = 0',
      whereArgs: [conversationId],
      orderBy: 'ts DESC',
    );
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      try {
        final plain = await PodEncryption.decrypt(row['enc'] as String, _key);
        final data = jsonDecode(plain) as Map<String, dynamic>;
        result.add({
          'sender_did': row['sender_did'],
          'ts': row['ts'],
          ...data,
          '_is_favorite': 1,
          '_edited_body': row['edited_body'] as String?,
        });
      } catch (_) {}
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
  ///
  /// Pass [excludeSenderDid] to skip messages sent by that user (i.e. own
  /// outgoing messages should never count as unread).
  Future<int> countMessagesAfter(
      String conversationId, int afterTimestampMs,
      {String? excludeSenderDid}) async {
    if (excludeSenderDid != null) {
      final rows = await _database.rawQuery(
        'SELECT COUNT(*) AS cnt FROM pod_messages '
        'WHERE conversation_id = ? AND ts > ? AND sender_did != ?',
        [conversationId, afterTimestampMs, excludeSenderDid],
      );
      return (rows.first['cnt'] as int?) ?? 0;
    }
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

  /// Searches across all stored messages by decrypting each row and
  /// checking if [query] appears in the plaintext body (case-insensitive).
  ///
  /// Image messages are skipped. Returns up to [limit] results starting at
  /// [offset], ordered newest-first.
  Future<List<Map<String, dynamic>>> searchMessages(
    String query, {
    int limit = 50,
    int offset = 0,
  }) async {
    if (query.isEmpty) return [];

    final rows = await _database.query(
      'pod_messages',
      orderBy: 'ts DESC',
    );

    final results = <Map<String, dynamic>>[];
    final lower = query.toLowerCase();
    int skipped = 0;

    for (final row in rows) {
      try {
        final plain = await PodEncryption.decrypt(row['enc'] as String, _key);
        final data = jsonDecode(plain) as Map<String, dynamic>;
        if (data['type'] == 'image') continue;
        final body = (data['body'] as String? ?? '').toLowerCase();
        if (!body.contains(lower)) continue;
        if (skipped < offset) {
          skipped++;
          continue;
        }
        results.add({
          'conversation_id': row['conversation_id'],
          'sender_did': row['sender_did'],
          'ts': row['ts'],
          ...data,
        });
        if (results.length >= limit) break;
      } catch (_) {}
    }

    return results;
  }

  /// Returns the total number of stored messages.
  Future<int> getTotalMessageCount() async {
    final rows = await _database.rawQuery('SELECT COUNT(*) AS cnt FROM pod_messages');
    return (rows.first['cnt'] as int?) ?? 0;
  }

  /// Returns the approximate storage size of messages in bytes
  /// (measures encrypted column length as a proxy for DB space used).
  Future<int> estimateStorageSizeBytes() async {
    final rows = await _database.rawQuery(
      'SELECT COALESCE(SUM(LENGTH(enc)), 0) AS total FROM pod_messages',
    );
    return (rows.first['total'] as int?) ?? 0;
  }

  /// Deletes messages in [conversationId] older than [cutoff].
  Future<void> deleteMessagesOlderThan(
    String conversationId,
    DateTime cutoff,
  ) async {
    await _database.delete(
      'pod_messages',
      where: 'conversation_id = ? AND ts < ?',
      whereArgs: [conversationId, cutoff.millisecondsSinceEpoch],
    );
  }

  /// Deletes all messages from all conversations.
  Future<void> deleteAllMessages() async {
    await _database.delete('pod_messages');
  }

  // ── Group channels namespace ──────────────────────────────────────────────

  Future<void> upsertChannel(String id, Map<String, dynamic> data) async {
    final enc = await PodEncryption.encrypt(jsonEncode(data), _key);
    final now = DateTime.now().millisecondsSinceEpoch;
    await _database.insert(
      'group_channels',
      {
        'id': id,
        'enc': enc,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> listChannels() async {
    final rows =
        await _database.query('group_channels', orderBy: 'updated_at DESC');
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      try {
        final plain =
            await PodEncryption.decrypt(row['enc'] as String, _key);
        result.add(jsonDecode(plain) as Map<String, dynamic>);
      } catch (_) {}
    }
    return result;
  }

  Future<void> deleteChannel(String id) async {
    await _database.delete(
      'group_channels',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ── Contact requests namespace ────────────────────────────────────────────

  /// Inserts or replaces a contact request record.
  ///
  /// [id], [from_did], [is_sent], [status] and [received_at] are stored as
  /// plain columns for fast filtering.  The full [data] map is encrypted and
  /// stored in the [enc] column.
  Future<void> upsertContactRequest(
      String id, Map<String, dynamic> data) async {
    final enc = await PodEncryption.encrypt(jsonEncode(data), _key);
    await _database.insert(
      'contact_requests',
      {
        'id': id,
        'from_did': data['fromDid'] as String? ?? '',
        'is_sent': (data['isSent'] as bool? ?? false) ? 1 : 0,
        'status': data['status'] as String? ?? 'pending',
        'received_at': data['receivedAt'] as int? ??
            DateTime.now().millisecondsSinceEpoch,
        'enc': enc,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Returns all contact request rows, decrypted.
  Future<List<Map<String, dynamic>>> listContactRequests() async {
    final rows = await _database.query(
      'contact_requests',
      orderBy: 'received_at DESC',
    );
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      try {
        final plain =
            await PodEncryption.decrypt(row['enc'] as String, _key);
        final data = jsonDecode(plain) as Map<String, dynamic>;
        // Merge unencrypted index columns so callers always get them.
        result.add({
          'id': row['id'],
          'from_did': row['from_did'],
          'is_sent': row['is_sent'],
          'status': row['status'],
          'received_at': row['received_at'],
          ...data,
        });
      } catch (_) {}
    }
    return result;
  }

  /// Updates the [status] and optional [decidedAt] timestamp for a request.
  Future<void> updateContactRequestStatus(
      String id, String status, DateTime? decidedAt) async {
    await _database.update(
      'contact_requests',
      {
        'status': status,
      },
      where: 'id = ?',
      whereArgs: [id],
    );

    // Also update the enc blob so the full data stays consistent.
    final rows = await _database.query(
      'contact_requests',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    try {
      final plain =
          await PodEncryption.decrypt(rows.first['enc'] as String, _key);
      final data = jsonDecode(plain) as Map<String, dynamic>;
      data['status'] = status;
      if (decidedAt != null) {
        data['decidedAt'] = decidedAt.millisecondsSinceEpoch;
      }
      final enc = await PodEncryption.encrypt(jsonEncode(data), _key);
      await _database.update(
        'contact_requests',
        {'enc': enc, 'status': status},
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (_) {}
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

  // ── System roles namespace ────────────────────────────────────────────────

  Future<void> upsertSystemRole({
    required String did,
    required String roleName,
    required String grantedBy,
    required DateTime grantedAt,
  }) async {
    await _database.insert(
      'system_roles',
      {
        'did': did,
        'role': roleName,
        'granted_by': grantedBy,
        'granted_at': grantedAt.millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteSystemRole(String did) async {
    await _database.delete(
      'system_roles',
      where: 'did = ?',
      whereArgs: [did],
    );
  }

  Future<List<Map<String, dynamic>>> listSystemRoles() async {
    return _database.query('system_roles');
  }

  // ── Channel roles namespace ───────────────────────────────────────────────

  Future<void> upsertChannelRole({
    required String channelId,
    required String did,
    required String roleName,
    required String grantedBy,
    required DateTime grantedAt,
  }) async {
    await _database.insert(
      'channel_roles',
      {
        'channel_id': channelId,
        'did': did,
        'role': roleName,
        'granted_by': grantedBy,
        'granted_at': grantedAt.millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteChannelRole(String channelId, String did) async {
    await _database.delete(
      'channel_roles',
      where: 'channel_id = ? AND did = ?',
      whereArgs: [channelId, did],
    );
  }

  Future<List<Map<String, dynamic>>> listChannelRoles({String? channelId}) async {
    if (channelId != null) {
      return _database.query(
        'channel_roles',
        where: 'channel_id = ?',
        whereArgs: [channelId],
      );
    }
    return _database.query('channel_roles');
  }

  // ── Feed posts namespace ─────────────────────────────────────────────────

  Future<void> insertFeedPost(Map<String, dynamic> data) async {
    final id = data['id'] as String;
    // Deduplicate by id
    final exists = await _database.rawQuery(
      'SELECT 1 FROM feed_posts WHERE id = ? LIMIT 1', [id]);
    if (exists.isNotEmpty) return;

    final enc = await PodEncryption.encrypt(jsonEncode(data), _key);
    await _database.insert('feed_posts', {
      'id': id,
      'author_did': data['authorDid'] as String,
      'visibility': data['visibility'] as String? ?? 'contacts',
      'created_at': data['createdAt'] as int,
      if (data['nostrEventId'] != null) 'nostr_event_id': data['nostrEventId'],
      'enc': enc,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> updateFeedPost(String id, Map<String, dynamic> data) async {
    final enc = await PodEncryption.encrypt(jsonEncode(data), _key);
    await _database.update('feed_posts', {
      'enc': enc,
      if (data['nostrEventId'] != null) 'nostr_event_id': data['nostrEventId'],
    }, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> softDeleteFeedPost(String id) async {
    await _database.update('feed_posts', {'is_deleted': 1},
        where: 'id = ?', whereArgs: [id]);
  }

  /// Returns feed posts ordered by created_at DESC.
  /// Optionally filter by [authorDid] or [visibility].
  Future<List<Map<String, dynamic>>> listFeedPosts({
    int limit = 20,
    int offset = 0,
    String? authorDid,
    List<String>? visibilities,
  }) async {
    final where = <String>['is_deleted = 0'];
    final args = <dynamic>[];
    if (authorDid != null) {
      where.add('author_did = ?');
      args.add(authorDid);
    }
    if (visibilities != null && visibilities.isNotEmpty) {
      final placeholders = List.filled(visibilities.length, '?').join(', ');
      where.add('visibility IN ($placeholders)');
      args.addAll(visibilities);
    }
    final rows = await _database.query(
      'feed_posts',
      where: where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      try {
        final plain = await PodEncryption.decrypt(row['enc'] as String, _key);
        result.add(jsonDecode(plain) as Map<String, dynamic>);
      } catch (_) {}
    }
    return result;
  }

  Future<int> countFeedPosts() async {
    final rows = await _database.rawQuery(
      'SELECT COUNT(*) AS cnt FROM feed_posts WHERE is_deleted = 0');
    return (rows.first['cnt'] as int?) ?? 0;
  }

  // ── Feed comments namespace ───────────────────────────────────────────────

  Future<void> insertFeedComment(Map<String, dynamic> data) async {
    final id = data['id'] as String;
    final exists = await _database.rawQuery(
      'SELECT 1 FROM feed_comments WHERE id = ? LIMIT 1', [id]);
    if (exists.isNotEmpty) return;

    final enc = await PodEncryption.encrypt(jsonEncode(data), _key);
    await _database.insert('feed_comments', {
      'id': id,
      'post_id': data['postId'] as String,
      'author_did': data['authorDid'] as String,
      'created_at': data['createdAt'] as int,
      'enc': enc,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> softDeleteFeedComment(String id) async {
    await _database.update('feed_comments', {'is_deleted': 1},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Map<String, dynamic>>> listFeedComments(String postId) async {
    final rows = await _database.query(
      'feed_comments',
      where: 'post_id = ? AND is_deleted = 0',
      whereArgs: [postId],
      orderBy: 'created_at ASC',
    );
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      try {
        final plain = await PodEncryption.decrypt(row['enc'] as String, _key);
        result.add(jsonDecode(plain) as Map<String, dynamic>);
      } catch (_) {}
    }
    return result;
  }

  // ── Feed mutes namespace ─────────────────────────────────────────────────

  Future<void> muteAuthor(String authorDid) async {
    await _database.insert('feed_mutes', {
      'author_did': authorDid,
      'muted_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> unmuteAuthor(String authorDid) async {
    await _database.delete('feed_mutes',
        where: 'author_did = ?', whereArgs: [authorDid]);
  }

  Future<List<String>> getMutedAuthors() async {
    final rows = await _database.query('feed_mutes');
    return rows.map((r) => r['author_did'] as String).toList();
  }

  // ── Reactions namespace ──────────────────────────────────────────────────

  Future<void> upsertReaction({
    required String messageId,
    required String emoji,
    required String reactorDid,
  }) async {
    await _database.insert(
      'message_reactions',
      {
        'message_id': messageId,
        'emoji': emoji,
        'reactor_did': reactorDid,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteReaction({
    required String messageId,
    required String emoji,
    required String reactorDid,
  }) async {
    await _database.delete(
      'message_reactions',
      where: 'message_id = ? AND emoji = ? AND reactor_did = ?',
      whereArgs: [messageId, emoji, reactorDid],
    );
  }

  /// Returns reactions grouped by emoji: { '👍': ['did:key:...', ...] }
  Future<Map<String, List<String>>> getReactionsForMessage(String messageId) async {
    final rows = await _database.query(
      'message_reactions',
      where: 'message_id = ?',
      whereArgs: [messageId],
      orderBy: 'created_at ASC',
    );
    final result = <String, List<String>>{};
    for (final row in rows) {
      final emoji = row['emoji'] as String;
      final did = row['reactor_did'] as String;
      result.putIfAbsent(emoji, () => []).add(did);
    }
    return result;
  }
}
