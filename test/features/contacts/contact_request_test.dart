import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/core/storage/pod_database.dart';
import 'package:nexus_oneapp/core/transport/nexus_message.dart';
import 'package:nexus_oneapp/features/contacts/contact_request.dart';
import 'package:nexus_oneapp/services/contact_request_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ── DB helpers ─────────────────────────────────────────────────────────────────

Future<Database> _openInMemoryDb() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  return openDatabase(
    inMemoryDatabasePath,
    version: 8,
    onCreate: (db, _) async {
      await db.execute(
          'CREATE TABLE pod_identity (id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, enc TEXT NOT NULL, ts INTEGER NOT NULL)');
      await db.execute(
          'CREATE TABLE pod_contacts (id INTEGER PRIMARY KEY AUTOINCREMENT, peer_did TEXT NOT NULL UNIQUE, enc TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, encryption_public_key TEXT)');
      await db.execute(
          'CREATE TABLE pod_messages (id INTEGER PRIMARY KEY AUTOINCREMENT, conversation_id TEXT NOT NULL, sender_did TEXT NOT NULL, enc TEXT NOT NULL, ts INTEGER NOT NULL, status TEXT NOT NULL DEFAULT "pending", encrypted INTEGER NOT NULL DEFAULT 0, message_id TEXT, is_favorite INTEGER NOT NULL DEFAULT 0, is_deleted INTEGER NOT NULL DEFAULT 0, edited_body TEXT)');
      await db.execute(
          'CREATE TABLE pod_credentials (id INTEGER PRIMARY KEY AUTOINCREMENT, credential_id TEXT NOT NULL UNIQUE, type TEXT NOT NULL, issuer_did TEXT NOT NULL, enc TEXT NOT NULL, issued_at INTEGER NOT NULL)');
      await db.execute(
          'CREATE TABLE recovery_shares (id INTEGER PRIMARY KEY AUTOINCREMENT, share_index INTEGER NOT NULL, threshold INTEGER NOT NULL, total_shares INTEGER NOT NULL, share_data_enc TEXT NOT NULL, guardian_did TEXT, created_at INTEGER NOT NULL)');
      await db.execute(
          'CREATE TABLE group_channels (id TEXT PRIMARY KEY, enc TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)');
      await db.execute(
          'CREATE TABLE pod_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
      await db.execute(
          'CREATE TABLE system_roles (did TEXT PRIMARY KEY, role TEXT NOT NULL, granted_by TEXT NOT NULL, granted_at INTEGER NOT NULL)');
      await db.execute(
          'CREATE TABLE channel_roles (channel_id TEXT NOT NULL, did TEXT NOT NULL, role TEXT NOT NULL, granted_by TEXT NOT NULL, granted_at INTEGER NOT NULL, PRIMARY KEY (channel_id, did))');
      await db.execute(
          'CREATE TABLE message_reactions (message_id TEXT NOT NULL, emoji TEXT NOT NULL, reactor_did TEXT NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY (message_id, emoji, reactor_did))');
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
    },
  );
}

// 32-byte key of all zeros for tests
final _testKey = Uint8List(32);

Future<void> _setupDb() async {
  final db = await _openInMemoryDb();
  PodDatabase.instance.injectDatabase(db, _testKey);
}

Future<void> _resetService() async {
  ContactRequestService.instance.resetForTest();
}

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await _setupDb();
    await _resetService();
  });

  // ── ContactRequest model ─────────────────────────────────────────────────────

  group('ContactRequest serialization', () {
    test('toJson / fromJson round-trip preserves all fields', () {
      final req = ContactRequest(
        id: 'abc-123',
        fromDid: 'did:key:z6Alice',
        fromPseudonym: 'Alice',
        fromPublicKey: 'deadbeef',
        fromNostrPubkey: 'cafebabe',
        message: 'Hi there',
        receivedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        status: ContactRequestStatus.pending,
        isSent: false,
      );

      final json = req.toJson();
      final restored = ContactRequest.fromJson(json);

      expect(restored.id, req.id);
      expect(restored.fromDid, req.fromDid);
      expect(restored.fromPseudonym, req.fromPseudonym);
      expect(restored.fromPublicKey, req.fromPublicKey);
      expect(restored.fromNostrPubkey, req.fromNostrPubkey);
      expect(restored.message, req.message);
      expect(restored.receivedAt.millisecondsSinceEpoch,
          req.receivedAt.millisecondsSinceEpoch);
      expect(restored.status, req.status);
      expect(restored.isSent, req.isSent);
      expect(restored.decidedAt, isNull);
    });

    test('toJson / fromJson preserves decidedAt when set', () {
      final decided = DateTime.fromMillisecondsSinceEpoch(1800000000000);
      final req = ContactRequest(
        id: 'id-2',
        fromDid: 'did:key:z6Bob',
        fromPseudonym: 'Bob',
        fromPublicKey: '',
        fromNostrPubkey: '',
        message: '',
        receivedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        status: ContactRequestStatus.accepted,
        decidedAt: decided,
        isSent: true,
      );

      final json = req.toJson();
      final restored = ContactRequest.fromJson(json);
      expect(restored.decidedAt?.millisecondsSinceEpoch,
          decided.millisecondsSinceEpoch);
      expect(restored.status, ContactRequestStatus.accepted);
    });

    test('copyWith changes only specified fields', () {
      final req = ContactRequest(
        id: 'id-3',
        fromDid: 'did:key:z6',
        fromPseudonym: 'Peer',
        fromPublicKey: 'key',
        fromNostrPubkey: 'nostr',
        message: 'hello',
        receivedAt: DateTime.now(),
        status: ContactRequestStatus.pending,
        isSent: false,
      );
      final updated = req.copyWith(
        status: ContactRequestStatus.rejected,
        decidedAt: DateTime.fromMillisecondsSinceEpoch(1900000000000),
      );
      expect(updated.id, req.id);
      expect(updated.fromDid, req.fromDid);
      expect(updated.status, ContactRequestStatus.rejected);
      expect(updated.decidedAt, isNotNull);
    });

    test('generateId produces a valid UUID v4 format', () {
      final id = ContactRequest.generateId();
      final parts = id.split('-');
      expect(parts.length, 5);
      expect(parts[0].length, 8);
      expect(parts[1].length, 4);
      expect(parts[2].length, 4);
      expect(parts[3].length, 4);
      expect(parts[4].length, 12);
      // Version nibble must be '4'
      expect(parts[2][0], '4');
    });

    test('generateId produces unique IDs', () {
      final ids = List.generate(100, (_) => ContactRequest.generateId());
      expect(ids.toSet().length, 100);
    });

    test('fromJson handles missing optional fields gracefully', () {
      final minimal = {
        'id': 'min-1',
        'fromDid': 'did:key:z',
        'receivedAt': 1700000000000,
        'isSent': false,
      };
      final req = ContactRequest.fromJson(minimal);
      expect(req.fromPseudonym, '');
      expect(req.message, '');
      expect(req.status, ContactRequestStatus.pending);
    });
  });

  // ── ContactRequestService.load() ────────────────────────────────────────────

  group('ContactRequestService.load()', () {
    test('loads previously persisted requests from DB', () async {
      final req = ContactRequest(
        id: ContactRequest.generateId(),
        fromDid: 'did:key:z6Peer',
        fromPseudonym: 'Peer',
        fromPublicKey: 'pk',
        fromNostrPubkey: 'npk',
        message: 'Hi',
        receivedAt: DateTime.now(),
        status: ContactRequestStatus.pending,
        isSent: false,
      );

      await PodDatabase.instance.upsertContactRequest(req.id, req.toJson());
      await ContactRequestService.instance.load();

      expect(ContactRequestService.instance.pendingCount, 1);
      expect(
          ContactRequestService.instance.pendingRequests.first.id, req.id);
    });
  });

  // ── sendRequest() ────────────────────────────────────────────────────────────

  group('ContactRequestService.sendRequest()', () {
    test('returns null and creates a sent request on success', () async {
      bool sendCalled = false;
      final err = await ContactRequestService.instance.sendRequest(
        'did:key:z6Recipient',
        'Hello!',
        myDid: 'did:key:z6Me',
        myPseudonym: 'Me',
        myPublicKey: 'pk',
        myNostrPubkey: 'npk',
        sendFn: (req) async {
          sendCalled = true;
        },
      );

      expect(err, isNull);
      expect(sendCalled, isTrue);
      expect(
          ContactRequestService.instance
              .hasSentRequestTo('did:key:z6Recipient'),
          isTrue);
    });

    test('rejects duplicate pending request to same DID', () async {
      // Send first request successfully.
      await ContactRequestService.instance.sendRequest(
        'did:key:z6Dup',
        'first',
        myDid: 'did:key:z6Me',
        myPseudonym: 'Me',
        myPublicKey: '',
        myNostrPubkey: '',
        sendFn: (_) async {},
      );

      // Attempt second request to same DID.
      final err = await ContactRequestService.instance.sendRequest(
        'did:key:z6Dup',
        'second',
        myDid: 'did:key:z6Me',
        myPseudonym: 'Me',
        myPublicKey: '',
        myNostrPubkey: '',
        sendFn: (_) async {},
      );

      expect(err, isNotNull);
      expect(err, contains('ausstehende'));
    });

    test('enforces 30-day cooldown after rejection', () async {
      // Simulate a previously rejected incoming request from the target DID.
      final oldReq = ContactRequest(
        id: ContactRequest.generateId(),
        fromDid: 'did:key:z6Target',
        fromPseudonym: 'Target',
        fromPublicKey: '',
        fromNostrPubkey: '',
        message: '',
        receivedAt: DateTime.now().subtract(const Duration(days: 5)),
        status: ContactRequestStatus.rejected,
        decidedAt: DateTime.now().subtract(const Duration(days: 1)),
        isSent: false,
      );
      await PodDatabase.instance
          .upsertContactRequest(oldReq.id, oldReq.toJson());
      await ContactRequestService.instance.load();

      final err = await ContactRequestService.instance.sendRequest(
        'did:key:z6Target',
        'hi',
        myDid: 'did:key:z6Me',
        myPseudonym: 'Me',
        myPublicKey: '',
        myNostrPubkey: '',
        sendFn: (_) async {},
      );

      expect(err, isNotNull);
      expect(err, contains('30 Tage'));
    });

    test('enforces 30-day cooldown after ignore', () async {
      final oldReq = ContactRequest(
        id: ContactRequest.generateId(),
        fromDid: 'did:key:z6IgnoreTarget',
        fromPseudonym: 'Target',
        fromPublicKey: '',
        fromNostrPubkey: '',
        message: '',
        receivedAt: DateTime.now().subtract(const Duration(days: 10)),
        status: ContactRequestStatus.ignored,
        decidedAt: DateTime.now().subtract(const Duration(days: 2)),
        isSent: false,
      );
      await PodDatabase.instance
          .upsertContactRequest(oldReq.id, oldReq.toJson());
      await ContactRequestService.instance.load();

      final err = await ContactRequestService.instance.sendRequest(
        'did:key:z6IgnoreTarget',
        'hi',
        myDid: 'did:key:z6Me',
        myPseudonym: 'Me',
        myPublicKey: '',
        myNostrPubkey: '',
        sendFn: (_) async {},
      );

      expect(err, isNotNull);
      expect(err, contains('30 Tage'));
    });

    test('cooldown does not apply after 30 days', () async {
      final oldReq = ContactRequest(
        id: ContactRequest.generateId(),
        fromDid: 'did:key:z6Old',
        fromPseudonym: 'Old',
        fromPublicKey: '',
        fromNostrPubkey: '',
        message: '',
        receivedAt: DateTime.now().subtract(const Duration(days: 40)),
        status: ContactRequestStatus.rejected,
        decidedAt: DateTime.now().subtract(const Duration(days: 35)),
        isSent: false,
      );
      await PodDatabase.instance
          .upsertContactRequest(oldReq.id, oldReq.toJson());
      await ContactRequestService.instance.load();

      final err = await ContactRequestService.instance.sendRequest(
        'did:key:z6Old',
        'hello again',
        myDid: 'did:key:z6Me',
        myPseudonym: 'Me',
        myPublicKey: '',
        myNostrPubkey: '',
        sendFn: (_) async {},
      );

      expect(err, isNull);
    });

    test('enforces daily rate limit of 10 requests', () async {
      // Set count to 10 already.
      final today = _todayString();
      SharedPreferences.setMockInitialValues({
        'nexus_cr_today_count': 10,
        'nexus_cr_today_date': today,
      });

      final err = await ContactRequestService.instance.sendRequest(
        'did:key:z6RateLimit',
        'hi',
        myDid: 'did:key:z6Me',
        myPseudonym: 'Me',
        myPublicKey: '',
        myNostrPubkey: '',
        sendFn: (_) async {},
      );

      expect(err, isNotNull);
      expect(err, contains('10'));
    });

    test('rate limit resets on a new day', () async {
      SharedPreferences.setMockInitialValues({
        'nexus_cr_today_count': 10,
        'nexus_cr_today_date': '1970-01-01', // old date
      });

      final err = await ContactRequestService.instance.sendRequest(
        'did:key:z6NewDay',
        'hi',
        myDid: 'did:key:z6Me',
        myPseudonym: 'Me',
        myPublicKey: '',
        myNostrPubkey: '',
        sendFn: (_) async {},
      );

      expect(err, isNull);
    });
  });

  // ── handleIncomingRequest() ───────────────────────────────────────────────────

  group('ContactRequestService.handleIncomingRequest()', () {
    test('saves incoming request as pending', () async {
      final msg = _makeContactRequestMsg(
        fromDid: 'did:key:z6Sender',
        message: 'Let me in!',
      );

      await ContactRequestService.instance.handleIncomingRequest(msg);

      expect(ContactRequestService.instance.pendingCount, 1);
      expect(
          ContactRequestService.instance.pendingRequests.first.message,
          'Let me in!');
    });

    test('de-duplicates pending request from same DID', () async {
      final msg = _makeContactRequestMsg(fromDid: 'did:key:z6DupSender');

      await ContactRequestService.instance.handleIncomingRequest(msg);
      await ContactRequestService.instance.handleIncomingRequest(msg);

      expect(ContactRequestService.instance.pendingCount, 1);
    });

    test('stream emits after incoming request', () async {
      final events = <int>[];
      ContactRequestService.instance.stream.listen((list) {
        events.add(list.length);
      });

      final msg = _makeContactRequestMsg(fromDid: 'did:key:z6StreamSender');
      await ContactRequestService.instance.handleIncomingRequest(msg);

      await Future<void>.delayed(Duration.zero);
      expect(events, isNotEmpty);
    });
  });

  // ── acceptRequest() ───────────────────────────────────────────────────────────

  group('ContactRequestService.acceptRequest()', () {
    test('calls addContactFn and sendConfirmFn and marks accepted', () async {
      final msg = _makeContactRequestMsg(fromDid: 'did:key:z6ToAccept');
      await ContactRequestService.instance.handleIncomingRequest(msg);

      final reqId = ContactRequestService.instance.pendingRequests.first.id;
      bool addCalled = false;
      bool confirmCalled = false;

      await ContactRequestService.instance.acceptRequest(
        reqId,
        addContactFn: (did, pseudo, key, nostr) async {
          addCalled = true;
        },
        sendConfirmFn: (req) async {
          confirmCalled = true;
        },
      );

      expect(addCalled, isTrue);
      expect(confirmCalled, isTrue);
      expect(ContactRequestService.instance.pendingCount, 0);

      // The request was incoming (isSent=false), so it won't appear in sentRequests.
      // Confirm the pending list is empty (status = accepted).
      expect(ContactRequestService.instance.pendingRequests, isEmpty);
    });

    test('updates status to accepted in memory', () async {
      final msg = _makeContactRequestMsg(fromDid: 'did:key:z6Accepted2');
      await ContactRequestService.instance.handleIncomingRequest(msg);
      final reqId = ContactRequestService.instance.pendingRequests.first.id;

      await ContactRequestService.instance.acceptRequest(
        reqId,
        addContactFn: (did, pseudo, key, nostr) async {},
        sendConfirmFn: (_) async {},
      );

      expect(ContactRequestService.instance.pendingRequests, isEmpty);
    });
  });

  // ── rejectRequest() ───────────────────────────────────────────────────────────

  group('ContactRequestService.rejectRequest()', () {
    test('removes request from pending list', () async {
      final msg = _makeContactRequestMsg(fromDid: 'did:key:z6ToReject');
      await ContactRequestService.instance.handleIncomingRequest(msg);
      final reqId = ContactRequestService.instance.pendingRequests.first.id;

      await ContactRequestService.instance.rejectRequest(reqId);

      expect(ContactRequestService.instance.pendingCount, 0);
    });

    test('stream emits after rejection', () async {
      final msg = _makeContactRequestMsg(fromDid: 'did:key:z6RejectStream');
      await ContactRequestService.instance.handleIncomingRequest(msg);
      final reqId = ContactRequestService.instance.pendingRequests.first.id;

      final events = <int>[];
      ContactRequestService.instance.stream.listen((l) => events.add(l.length));

      await ContactRequestService.instance.rejectRequest(reqId);
      await Future<void>.delayed(Duration.zero);

      expect(events, isNotEmpty);
    });
  });

  // ── ignoreRequest() ───────────────────────────────────────────────────────────

  group('ContactRequestService.ignoreRequest()', () {
    test('removes request from pending list', () async {
      final msg = _makeContactRequestMsg(fromDid: 'did:key:z6ToIgnore');
      await ContactRequestService.instance.handleIncomingRequest(msg);
      final reqId = ContactRequestService.instance.pendingRequests.first.id;

      await ContactRequestService.instance.ignoreRequest(reqId);

      expect(ContactRequestService.instance.pendingCount, 0);
    });
  });

  // ── hasSentRequestTo / hasPendingRequestFrom ─────────────────────────────────

  group('Query helpers', () {
    test('hasSentRequestTo returns true for pending sent request', () async {
      await ContactRequestService.instance.sendRequest(
        'did:key:z6Query',
        '',
        myDid: 'did:key:z6Me',
        myPseudonym: 'Me',
        myPublicKey: '',
        myNostrPubkey: '',
        sendFn: (_) async {},
      );

      expect(
          ContactRequestService.instance.hasSentRequestTo('did:key:z6Query'),
          isTrue);
      expect(
          ContactRequestService.instance.hasSentRequestTo('did:key:z6Other'),
          isFalse);
    });

    test('hasPendingRequestFrom works correctly', () async {
      final msg = _makeContactRequestMsg(fromDid: 'did:key:z6PendFrom');
      await ContactRequestService.instance.handleIncomingRequest(msg);

      expect(
          ContactRequestService.instance
              .hasPendingRequestFrom('did:key:z6PendFrom'),
          isTrue);
      expect(
          ContactRequestService.instance
              .hasPendingRequestFrom('did:key:z6Other'),
          isFalse);
    });

    test('pendingCount reflects only incoming pending requests', () async {
      // Sent request should NOT count.
      await ContactRequestService.instance.sendRequest(
        'did:key:z6Sent',
        '',
        myDid: 'did:key:z6Me',
        myPseudonym: 'Me',
        myPublicKey: '',
        myNostrPubkey: '',
        sendFn: (_) async {},
      );
      expect(ContactRequestService.instance.pendingCount, 0);

      // Incoming request SHOULD count.
      final msg = _makeContactRequestMsg(fromDid: 'did:key:z6Incoming');
      await ContactRequestService.instance.handleIncomingRequest(msg);
      expect(ContactRequestService.instance.pendingCount, 1);
    });
  });

  // ── handleAcceptance ────────────────────────────────────────────────────────

  group('ContactRequestService.handleAcceptance()', () {
    test('marks sent request as accepted and calls addContactFn', () async {
      // First, send a request.
      await ContactRequestService.instance.sendRequest(
        'did:key:z6Acceptor',
        'hi',
        myDid: 'did:key:z6Me',
        myPseudonym: 'Me',
        myPublicKey: 'mypk',
        myNostrPubkey: 'mynpk',
        sendFn: (_) async {},
      );

      bool addCalled = false;
      final acceptMsg = NexusMessage.create(
        fromDid: 'did:key:z6Acceptor',
        toDid: 'did:key:z6Me',
        body: 'Acceptor',
        metadata: {
          'type': 'contact_request_accepted',
          'contact_request_data': {
            'fromPublicKey': 'acceptorpk',
            'fromNostrPubkey': 'acceptornpk',
          },
        },
      );

      await ContactRequestService.instance.handleAcceptance(
        acceptMsg,
        addContactFn: (did, pseudo, key, nostr) async {
          addCalled = true;
          expect(did, 'did:key:z6Acceptor');
        },
      );

      expect(addCalled, isTrue);
      // Request should no longer be pending.
      expect(
          ContactRequestService.instance
              .hasSentRequestTo('did:key:z6Acceptor'),
          isFalse);
    });
  });

  // ── QR-scanned contacts don't need a request ──────────────────────────────────

  group('Trust level check in gate', () {
    test('ContactRequest.fromJson handles unknown status gracefully', () {
      final json = {
        'id': 'id-unk',
        'fromDid': 'did:key:z6',
        'receivedAt': 1700000000000,
        'status': 'unknown_future_value',
        'isSent': false,
      };
      final req = ContactRequest.fromJson(json);
      // Should default to pending rather than throw.
      expect(req.status, ContactRequestStatus.pending);
    });
  });

  // ── DB round-trip ─────────────────────────────────────────────────────────────

  group('DB round-trip', () {
    test('upsert + list + update round-trip', () async {
      final req = ContactRequest(
        id: 'roundtrip-1',
        fromDid: 'did:key:z6RT',
        fromPseudonym: 'RT',
        fromPublicKey: 'pk',
        fromNostrPubkey: 'npk',
        message: 'Round trip',
        receivedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        status: ContactRequestStatus.pending,
        isSent: false,
      );

      await PodDatabase.instance.upsertContactRequest(req.id, req.toJson());

      // Update status.
      final decided = DateTime.fromMillisecondsSinceEpoch(1800000000000);
      await PodDatabase.instance.updateContactRequestStatus(
          req.id, 'accepted', decided);

      // Reload and verify.
      await ContactRequestService.instance.load();
      // Verify via full list (won't be in sentRequests since isSent=false).
      final rows =
          await PodDatabase.instance.listContactRequests();
      expect(rows.isNotEmpty, isTrue);
      final row = rows.firstWhere((r) => r['id'] == 'roundtrip-1');
      expect(row['status'], 'accepted');
    });
  });
}

// ── Helpers ────────────────────────────────────────────────────────────────────

/// Creates a real [NexusMessage] for contact_request type messages.
NexusMessage _makeContactRequestMsg({
  required String fromDid,
  String message = 'Test intro',
}) {
  return NexusMessage.create(
    fromDid: fromDid,
    toDid: 'did:key:z6Me',
    body: message,
    metadata: {
      'type': 'contact_request',
      'contact_request_data': {
        'fromPublicKey': 'pk-$fromDid',
        'fromNostrPubkey': 'npk-$fromDid',
        'message': message,
      },
    },
  );
}

/// Returns today's date as YYYY-MM-DD string (same as service).
String _todayString() {
  final now = DateTime.now();
  return '${now.year}-${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}
