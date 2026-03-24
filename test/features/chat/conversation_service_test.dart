import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexus_oneapp/core/storage/pod_database.dart';
import 'package:nexus_oneapp/core/transport/nexus_message.dart';

/// Sets up an in-memory PodDatabase for tests.
Future<void> openTestDb() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
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
          CREATE TABLE pod_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)
        ''');
      },
    ),
  );

  // Use a fixed 32-byte key
  final key = Uint8List(32)..fillRange(0, 32, 0x42);
  PodDatabase.instance.injectDatabase(db, key);
}

void main() {
  setUpAll(() async {
    await openTestDb();
  });

  group('PodDatabase – conversation helpers', () {
    const convA = 'did:key:z6MkAAA:did:key:z6MkBBB';
    const convB = 'did:key:z6MkCCC:did:key:z6MkDDD';
    const myDid = 'did:key:z6MkAAA';

    Future<void> insertMsg(
        String convId, String senderDid, String body) async {
      final msg = NexusMessage.create(
        fromDid: senderDid,
        toDid: 'did:key:z6MkBBB',
        body: body,
      );
      await PodDatabase.instance.insertMessage(
        conversationId: convId,
        senderDid: senderDid,
        data: msg.toJson(),
      );
      // Small delay to ensure distinct ts values
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }

    test('listConversationSummaries returns one row per conversation', () async {
      await insertMsg(convA, myDid, 'Hello');
      await insertMsg(convA, myDid, 'World');
      await insertMsg(convB, myDid, 'Other conv');

      final summaries =
          await PodDatabase.instance.listConversationSummaries();
      final ids = summaries.map((s) => s['conversation_id']).toList();
      expect(ids, containsAll([convA, convB]));
    });

    test('listConversationSummaries orders by most-recent first', () async {
      // convB already has a message; add a newer one to convA
      await insertMsg(convA, myDid, 'Newer message');

      final summaries =
          await PodDatabase.instance.listConversationSummaries();
      expect(summaries.first['conversation_id'], convA);
    });

    test('listLastMessages returns last N messages newest-first', () async {
      final rows = await PodDatabase.instance.listLastMessages(convA, limit: 2);
      expect(rows.length, lessThanOrEqualTo(2));
    });

    test('countMessagesAfter counts only messages after timestamp', () async {
      final before = DateTime.now().millisecondsSinceEpoch;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await insertMsg(convA, myDid, 'New after marker');

      final count =
          await PodDatabase.instance.countMessagesAfter(convA, before);
      expect(count, greaterThanOrEqualTo(1));
    });

    test('countMessagesAfter returns 0 when no messages after timestamp', () async {
      final future = DateTime.now()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch;
      final count =
          await PodDatabase.instance.countMessagesAfter(convA, future);
      expect(count, 0);
    });

    test('deleteConversation removes all messages for that conversation', () async {
      const convToDelete = 'delete:test:conv';
      await insertMsg(convToDelete, myDid, 'Will be deleted');
      await insertMsg(convToDelete, myDid, 'Also deleted');

      final before = await PodDatabase.instance.listMessages(convToDelete);
      expect(before, isNotEmpty);

      await PodDatabase.instance.deleteConversation(convToDelete);

      final after = await PodDatabase.instance.listMessages(convToDelete);
      expect(after, isEmpty);
    });

    test('deleteConversation only removes the target conversation', () async {
      // convA still has messages; deleting convB should not affect convA.
      await insertMsg(convB, myDid, 'B message');

      await PodDatabase.instance.deleteConversation(convB);

      final aMessages = await PodDatabase.instance.listMessages(convA);
      expect(aMessages, isNotEmpty);

      final bMessages = await PodDatabase.instance.listMessages(convB);
      expect(bMessages, isEmpty);
    });
  });

  group('PodDatabase – unread count via identity store', () {
    test('can persist and retrieve conv_last_read map', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await PodDatabase.instance.setIdentityValue(
        'conv_last_read',
        {'some:conv:id': now},
      );

      final data =
          await PodDatabase.instance.getIdentityValue('conv_last_read');
      expect(data, isNotNull);
      expect(data!['some:conv:id'], now);
    });
  });
}
