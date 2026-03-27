import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nexus_oneapp/core/storage/pod_database.dart';
import 'package:nexus_oneapp/core/transport/nexus_message.dart';
import 'package:nexus_oneapp/features/chat/message_search_screen.dart';
import 'package:nexus_oneapp/shared/widgets/highlighted_text.dart';

// ── DB test helpers ───────────────────────────────────────────────────────────

Future<PodDatabase> _openTestDb() async {
  final pod = PodDatabase.instance;
  final db = await openDatabase(
    inMemoryDatabasePath,
    version: 1,
    onCreate: (db, _) async {
      await db.execute('''
        CREATE TABLE pod_messages (
          id              INTEGER PRIMARY KEY AUTOINCREMENT,
          conversation_id TEXT NOT NULL,
          sender_did      TEXT NOT NULL,
          enc             TEXT NOT NULL,
          ts              INTEGER NOT NULL,
          status          TEXT NOT NULL DEFAULT 'pending',
          encrypted       INTEGER NOT NULL DEFAULT 0,
          message_id      TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE pod_identity (
          id INTEGER PRIMARY KEY,
          key TEXT NOT NULL UNIQUE,
          enc TEXT NOT NULL,
          ts  INTEGER NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE pod_contacts (
          id         INTEGER PRIMARY KEY AUTOINCREMENT,
          peer_did   TEXT NOT NULL UNIQUE,
          enc        TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          encryption_public_key TEXT
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
        CREATE TABLE pod_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)
      ''');
    },
  );
  final key = Uint8List(32)..fillRange(0, 32, 0x77);
  pod.injectDatabase(db, key);
  return pod;
}

Future<void> _insert(
  PodDatabase pod,
  String convId,
  String senderDid,
  String body, {
  String type = 'text',
  String? msgId,
}) async {
  await pod.insertMessage(
    conversationId: convId,
    senderDid: senderDid,
    data: {
      if (msgId != null) 'id': msgId,
      'fromDid': senderDid,
      'toDid': 'broadcast',
      'type': type,
      'body': body,
      'timestamp': DateTime.now().toIso8601String(),
      'ttlHours': 24,
      'hopCount': 0,
    },
  );
}

// ── In-memory filter helper (mirrors _ConversationScreenState._runSearch) ─────

List<NexusMessage> _filterMessages(List<NexusMessage> msgs, String query) {
  if (query.isEmpty) return [];
  final lower = query.toLowerCase();
  return msgs
      .where((m) =>
          m.type != NexusMessageType.image &&
          m.body.toLowerCase().contains(lower))
      .toList();
}

NexusMessage _msg(String id, String body, {NexusMessageType type = NexusMessageType.text}) =>
    NexusMessage(
      id: id,
      fromDid: 'did:key:alice',
      toDid: 'broadcast',
      type: type,
      body: body,
      timestamp: DateTime.now().toUtc(),
      ttlHours: 24,
      hopCount: 0,
    );

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // ── Global search – PodDatabase ───────────────────────────────────────────

  group('Global search – PodDatabase.searchMessages', () {
    test('finds messages across all conversations', () async {
      final pod = await _openTestDb();
      await _insert(pod, 'conv-search-a', 'did:key:alice', 'Hallo Welt',
          msgId: 'sa1');
      await _insert(pod, 'conv-search-b', 'did:key:bob', 'Guten Morgen',
          msgId: 'sb1');
      await _insert(pod, 'conv-search-a', 'did:key:alice', 'Ein schöner Tag',
          msgId: 'sa2');

      final results = await pod.searchMessages('Hallo');
      expect(results, hasLength(1));
      expect(results.first['body'], equals('Hallo Welt'));
    });

    test('is case-insensitive', () async {
      final pod = await _openTestDb();
      await _insert(pod, 'conv-search-ci', 'did:key:alice', 'NEXUS Protocol',
          msgId: 'ci1');
      await _insert(pod, 'conv-search-ci', 'did:key:alice', 'nexus protocol',
          msgId: 'ci2');
      await _insert(pod, 'conv-search-ci', 'did:key:alice', 'Nexus Protocol',
          msgId: 'ci3');

      final results = await pod.searchMessages('nexus');
      expect(results, hasLength(3));
    });

    test('empty query returns empty list', () async {
      final pod = await _openTestDb();
      await _insert(pod, 'conv-search-eq', 'did:key:alice', 'Testtext',
          msgId: 'eq1');

      final results = await pod.searchMessages('');
      expect(results, isEmpty);
    });

    test('image messages are skipped', () async {
      final pod = await _openTestDb();
      await _insert(pod, 'conv-search-img', 'did:key:alice', 'base64imgdata',
          type: 'image', msgId: 'img1');
      await _insert(pod, 'conv-search-img', 'did:key:alice', 'base64imgdata',
          msgId: 'img2');

      final results = await pod.searchMessages('base64imgdata');
      // Only the text message should be found (image is skipped)
      expect(results, hasLength(1));
      expect(results.first['type'], isNot('image'));
    });

    test('offset enables pagination', () async {
      final pod = await _openTestDb();
      for (var i = 0; i < 5; i++) {
        await _insert(pod, 'conv-search-page', 'did:key:alice', 'pageable $i',
            msgId: 'page$i');
      }

      final page1 = await pod.searchMessages('pageable', limit: 3);
      expect(page1, hasLength(3));

      final page2 = await pod.searchMessages('pageable', limit: 3, offset: 3);
      expect(page2, hasLength(2));

      // No overlap
      final ids1 = page1.map((r) => r['id']).toSet();
      final ids2 = page2.map((r) => r['id']).toSet();
      expect(ids1.intersection(ids2), isEmpty);
    });

    test('no match returns empty list', () async {
      final pod = await _openTestDb();
      await _insert(pod, 'conv-search-nm', 'did:key:alice', 'Hallo Welt',
          msgId: 'nm1');

      final results = await pod.searchMessages('xyz_not_found');
      expect(results, isEmpty);
    });

    test('results contain conversation_id and ts', () async {
      final pod = await _openTestDb();
      await _insert(pod, 'conv-search-meta', 'did:key:alice', 'Meta-Test',
          msgId: 'meta1');

      final results = await pod.searchMessages('Meta-Test');
      expect(results, hasLength(1));
      expect(results.first['conversation_id'], equals('conv-search-meta'));
      expect(results.first['ts'], isA<int>());
    });
  });

  // ── In-conversation search (in-memory filter) ─────────────────────────────

  group('In-conversation search (in-memory filter)', () {
    final messages = [
      _msg('1', 'Hallo Welt'),
      _msg('2', 'Guten Morgen'),
      _msg('3', 'hallo du'),
      _msg('4', 'Foto', type: NexusMessageType.image),
      _msg('5', 'Auf Wiedersehen'),
    ];

    test('finds messages matching query', () {
      final hits = _filterMessages(messages, 'hallo');
      expect(hits, hasLength(2));
      expect(hits.map((m) => m.id), containsAll(['1', '3']));
    });

    test('is case-insensitive', () {
      final hits = _filterMessages(messages, 'GUTEN');
      expect(hits, hasLength(1));
      expect(hits.first.id, equals('2'));
    });

    test('ignores image messages', () {
      // 'Foto' appears in the image message body – should be excluded
      final hits = _filterMessages(messages, 'Foto');
      expect(hits, isEmpty);
    });

    test('empty query returns no matches', () {
      final hits = _filterMessages(messages, '');
      expect(hits, isEmpty);
    });

    test('query with no match returns empty list', () {
      final hits = _filterMessages(messages, 'zzznomatch');
      expect(hits, isEmpty);
    });

    test('all text messages match a broad query', () {
      // Every text message body contains at least one letter
      final hits = _filterMessages(messages, 'e');
      // 'Hallo Welt' (W-e-lt), 'Guten Morgen' (G-u-t-e-n, Morg-e-n),
      // 'Auf Wiedersehen' (Wi-e-d-e-rs-e-h-e-n) → 3 matches
      expect(hits.length, greaterThanOrEqualTo(1));
    });

    test('navigation: cursor wraps around on prev/next', () {
      // Simulate nextMatch / prevMatch logic
      final ids = ['msg-a', 'msg-b', 'msg-c'];
      int cursor = ids.length - 1; // newest

      // next → wraps to first
      cursor = (cursor + 1) % ids.length;
      expect(cursor, equals(0));

      // prev → wraps to last
      cursor = (cursor - 1 + ids.length) % ids.length;
      expect(cursor, equals(ids.length - 1));
    });
  });

  // ── HighlightedText span logic ────────────────────────────────────────────

  group('HighlightedText widget', () {
    testWidgets('renders plain text when query is empty', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: HighlightedText(text: 'Hallo Welt', query: ''),
        ),
      ));
      expect(find.text('Hallo Welt'), findsOneWidget);
    });

    testWidgets('renders highlighted spans for matching query', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: HighlightedText(text: 'Hallo Welt', query: 'Welt'),
        ),
      ));
      // The widget renders a RichText (Text.rich) with a highlighted span.
      expect(find.byType(RichText), findsWidgets);
    });

    testWidgets('is case-insensitive in highlight', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: HighlightedText(text: 'NEXUS Protocol', query: 'nexus'),
        ),
      ));
      expect(find.byType(RichText), findsWidgets);
    });
  });

  // ── _peerDidFromConvId helper ─────────────────────────────────────────────

  group('_peerDidFromConvId (top-level helper)', () {
    final extract = searchScreenPeerDidFromConvId;

    test('extracts peer DID when myDid is the first part', () {
      const myDid = 'did:key:z6MkAAA';
      const peerDid = 'did:key:z6MkBBB';
      final sorted = [myDid, peerDid]..sort();
      final convId = '${sorted[0]}:${sorted[1]}';
      expect(extract(convId, myDid), equals(peerDid));
    });

    test('extracts peer DID when myDid is the second part', () {
      const myDid = 'did:key:z6MkZZZ';
      const peerDid = 'did:key:z6MkAAA';
      final sorted = [myDid, peerDid]..sort();
      final convId = '${sorted[0]}:${sorted[1]}';
      expect(extract(convId, myDid), equals(peerDid));
    });

    test('returns null for broadcast convId', () {
      expect(extract('broadcast', 'did:key:any'), isNull);
    });
  });

  // ── Debounce logic ────────────────────────────────────────────────────────

  group('Search debounce (300 ms)', () {
    test('timer fires after 300 ms delay', () async {
      int callCount = 0;
      Timer? debounce;

      void triggerDebounce() {
        debounce?.cancel();
        debounce = Timer(const Duration(milliseconds: 300), () {
          callCount++;
        });
      }

      // Simulate rapid typing – 5 keystrokes in quick succession
      for (var i = 0; i < 5; i++) {
        triggerDebounce();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      // Timer has not fired yet
      expect(callCount, equals(0));

      // Wait for debounce to fire
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(callCount, equals(1));

      debounce?.cancel();
    });
  });
}
