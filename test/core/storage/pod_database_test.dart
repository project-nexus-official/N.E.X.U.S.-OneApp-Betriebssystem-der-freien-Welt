import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexus_oneapp/core/storage/pod_database.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<PodDatabase> openTestDb() async {
    // Create a fresh singleton clone for each test to avoid state leakage
    final pod = PodDatabase.instance;
    final db = await openDatabase(
      inMemoryDatabasePath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE pod_identity (
            id   INTEGER PRIMARY KEY,
            key  TEXT NOT NULL UNIQUE,
            enc  TEXT NOT NULL,
            ts   INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE pod_contacts (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            peer_did   TEXT NOT NULL UNIQUE,
            enc        TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
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
        await db.execute('''
          CREATE TABLE pod_meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
      },
    );
    final key = Uint8List(32)..fillRange(0, 32, 0x42); // test key
    pod.injectDatabase(db, key);
    return pod;
  }

  group('PodDatabase namespaces', () {
    test('all 6 tables exist', () async {
      final pod = await openTestDb();
      final db = pod.testDb; // expose via getter in implementation
      final tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name");
      final names = tables.map((r) => r['name'] as String).toSet();
      expect(names, containsAll([
        'pod_identity', 'pod_contacts', 'pod_messages',
        'pod_credentials', 'recovery_shares', 'pod_meta',
      ]));
    });

    test('identity namespace: set and get', () async {
      final pod = await openTestDb();
      await pod.setIdentityValue('profile', {'did': 'did:key:zTest', 'name': 'Alice'});
      final data = await pod.getIdentityValue('profile');
      expect(data, isNotNull);
      expect(data!['did'], 'did:key:zTest');
      expect(data['name'], 'Alice');
    });

    test('identity namespace: missing key returns null', () async {
      final pod = await openTestDb();
      expect(await pod.getIdentityValue('nonexistent'), isNull);
    });

    test('contacts namespace: upsert and list', () async {
      final pod = await openTestDb();
      await pod.upsertContact('did:key:zAlice', {'name': 'Alice', 'alias': 'Friend'});
      await pod.upsertContact('did:key:zBob', {'name': 'Bob'});
      final contacts = await pod.listContacts();
      expect(contacts.length, 2);
      expect(contacts.any((c) => c['peer_did'] == 'did:key:zAlice'), isTrue);
    });

    test('messages namespace: insert and list', () async {
      final pod = await openTestDb();
      await pod.insertMessage(
        conversationId: 'conv-1',
        senderDid: 'did:key:zAlice',
        data: {'text': 'Hallo Welt'},
      );
      final msgs = await pod.listMessages('conv-1');
      expect(msgs.length, 1);
      expect(msgs.first['text'], 'Hallo Welt');
    });

    test('recovery_shares table exists and is empty initially', () async {
      final pod = await openTestDb();
      final rows = await pod.testDb.query('recovery_shares');
      expect(rows, isEmpty);
    });

    test('export and import round-trip', () async {
      final pod = await openTestDb();
      await pod.setIdentityValue('did', {'value': 'did:key:zTest123'});
      await pod.upsertContact('did:key:zPeer', {'name': 'Peer'});

      final blob = await pod.exportEncrypted();
      expect(blob.isNotEmpty, isTrue);

      // Clear and reimport
      await pod.testDb.delete('pod_identity');
      await pod.testDb.delete('pod_contacts');
      await pod.importEncrypted(blob);

      final identity = await pod.getIdentityValue('did');
      expect(identity!['value'], 'did:key:zTest123');
      final contacts = await pod.listContacts();
      expect(contacts.any((c) => c['peer_did'] == 'did:key:zPeer'), isTrue);
    });
  });
}
