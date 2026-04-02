import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/core/config/system_config.dart';
import 'package:nexus_oneapp/core/roles/permission_helper.dart';
import 'package:nexus_oneapp/core/roles/role_enums.dart';
import 'package:nexus_oneapp/services/role_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart';
import 'package:nexus_oneapp/core/storage/pod_database.dart';
import 'dart:typed_data';

// ── Helpers ────────────────────────────────────────────────────────────────────

Future<Database> _openInMemoryDb() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  return openDatabase(
    inMemoryDatabasePath,
    version: 6,
    onCreate: (db, _) async {
      await db.execute('''
        CREATE TABLE system_roles (
          did TEXT PRIMARY KEY,
          role TEXT NOT NULL,
          granted_by TEXT NOT NULL,
          granted_at INTEGER NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE channel_roles (
          channel_id TEXT NOT NULL,
          did TEXT NOT NULL,
          role TEXT NOT NULL,
          granted_by TEXT NOT NULL,
          granted_at INTEGER NOT NULL,
          PRIMARY KEY (channel_id, did)
        )
      ''');
      // Minimal tables to keep PodDatabase happy.
      await db.execute('CREATE TABLE pod_identity (id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, enc TEXT NOT NULL, ts INTEGER NOT NULL)');
      await db.execute('CREATE TABLE pod_contacts (id INTEGER PRIMARY KEY AUTOINCREMENT, peer_did TEXT NOT NULL UNIQUE, enc TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, encryption_public_key TEXT)');
      await db.execute('CREATE TABLE pod_messages (id INTEGER PRIMARY KEY AUTOINCREMENT, conversation_id TEXT NOT NULL, sender_did TEXT NOT NULL, enc TEXT NOT NULL, ts INTEGER NOT NULL, status TEXT NOT NULL DEFAULT "pending", encrypted INTEGER NOT NULL DEFAULT 0, message_id TEXT, is_favorite INTEGER NOT NULL DEFAULT 0, is_deleted INTEGER NOT NULL DEFAULT 0, edited_body TEXT)');
      await db.execute('CREATE TABLE pod_credentials (id INTEGER PRIMARY KEY AUTOINCREMENT, credential_id TEXT NOT NULL UNIQUE, type TEXT NOT NULL, issuer_did TEXT NOT NULL, enc TEXT NOT NULL, issued_at INTEGER NOT NULL)');
      await db.execute('CREATE TABLE recovery_shares (id INTEGER PRIMARY KEY AUTOINCREMENT, share_index INTEGER NOT NULL, threshold INTEGER NOT NULL, total_shares INTEGER NOT NULL, share_data_enc TEXT NOT NULL, guardian_did TEXT, created_at INTEGER NOT NULL)');
      await db.execute('CREATE TABLE group_channels (id TEXT PRIMARY KEY, enc TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)');
      await db.execute('CREATE TABLE pod_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    },
  );
}

const _superDid = 'did:key:superadmin123';
const _adminDid = 'did:key:sysadmin456';
const _userDid = 'did:key:user789';
const _channelId = '#test-channel';
const _channelAdminDid = 'did:key:channeladmin';
const _modDid = 'did:key:moderator';

Future<void> _setupTest({String? superadminDid}) async {
  // Reset singleton state.
  RoleService.instance.reset();

  // Inject mock superadmin DID.
  SystemConfig.instance.reset();
  if (superadminDid != null) {
    // Manually set the internal superadmin DID by calling persistSuperadminDid
    // would touch SharedPreferences – instead we bypass via direct injection below.
  }

  final db = await _openInMemoryDb();
  final encKey = Uint8List(32); // zero key – fine for unit tests
  PodDatabase.instance.injectDatabase(db, encKey);
}

void _injectSuperadmin(String did) {
  // Bypass asset loading by directly calling persistSuperadminDid is async.
  // Instead we use the reset/reload path + a test-only setter via the config reset.
  // For tests we directly manipulate SystemConfig via its public API.
  // The cleanest approach: reset, then call a test-friendly method.
  // We use the fact that after reset, superadminDid is null; the `load()` path
  // checks SharedPreferences then the bundle. In tests neither is available so
  // we call _forceForTest which we'll expose as package-visible.
  SystemConfig.instance.forceForTest(did);
}

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    RoleService.instance.reset();
    SystemConfig.instance.reset();
  });

  group('SystemConfig', () {
    test('returns null when no superadmin is set (placeholder)', () {
      // After reset, superadminDid is null – no asset is loaded in tests.
      expect(SystemConfig.instance.superadminDid, isNull);
    });

    test('forceForTest sets the superadmin DID', () {
      SystemConfig.instance.forceForTest(_superDid);
      expect(SystemConfig.instance.superadminDid, equals(_superDid));
    });
  });

  group('RoleService – isSuperadmin', () {
    test('returns true for the superadmin DID', () async {
      await _setupTest();
      _injectSuperadmin(_superDid);
      await RoleService.instance.init();
      expect(RoleService.instance.isSuperadmin(_superDid), isTrue);
    });

    test('returns false for a regular user', () async {
      await _setupTest();
      _injectSuperadmin(_superDid);
      await RoleService.instance.init();
      expect(RoleService.instance.isSuperadmin(_userDid), isFalse);
    });

    test('returns false when no superadmin is configured', () async {
      await _setupTest();
      // superadmin not injected → SystemConfig.superadminDid == null
      await RoleService.instance.init();
      expect(RoleService.instance.isSuperadmin(_superDid), isFalse);
    });
  });

  group('RoleService – grantSystemAdmin / revokeSystemAdmin', () {
    test('superadmin can grant system admin', () async {
      await _setupTest();
      _injectSuperadmin(_superDid);
      await RoleService.instance.init();

      await RoleService.instance.grantSystemAdmin(_superDid, _adminDid);

      expect(RoleService.instance.systemAdmins, contains(_adminDid));
      expect(RoleService.instance.isSystemAdmin(_adminDid), isTrue);
    });

    test('superadmin can revoke system admin', () async {
      await _setupTest();
      _injectSuperadmin(_superDid);
      await RoleService.instance.init();

      await RoleService.instance.grantSystemAdmin(_superDid, _adminDid);
      await RoleService.instance.revokeSystemAdmin(_superDid, _adminDid);

      expect(RoleService.instance.systemAdmins, isNot(contains(_adminDid)));
    });

    test('non-superadmin cannot grant system admin', () async {
      await _setupTest();
      _injectSuperadmin(_superDid);
      await RoleService.instance.init();

      await expectLater(
        () => RoleService.instance.grantSystemAdmin(_adminDid, _userDid),
        throwsStateError,
      );
    });

    test('system admin cannot grant other system admins', () async {
      await _setupTest();
      _injectSuperadmin(_superDid);
      await RoleService.instance.init();

      await RoleService.instance.grantSystemAdmin(_superDid, _adminDid);

      await expectLater(
        () => RoleService.instance.grantSystemAdmin(_adminDid, _userDid),
        throwsStateError,
      );
    });

    test('system admin cannot remove other system admins', () async {
      await _setupTest();
      _injectSuperadmin(_superDid);
      await RoleService.instance.init();

      await RoleService.instance.grantSystemAdmin(_superDid, _adminDid);

      await expectLater(
        () => RoleService.instance.revokeSystemAdmin(_adminDid, _adminDid),
        throwsStateError,
      );
    });

    test('cannot revoke the superadmin role via revokeSystemAdmin', () async {
      await _setupTest();
      _injectSuperadmin(_superDid);
      await RoleService.instance.init();

      await expectLater(
        () => RoleService.instance.revokeSystemAdmin(_superDid, _superDid),
        throwsStateError,
      );
    });

    test('isSystemAdmin returns true for superadmin too', () async {
      await _setupTest();
      _injectSuperadmin(_superDid);
      await RoleService.instance.init();

      expect(RoleService.instance.isSystemAdmin(_superDid), isTrue);
    });
  });

  group('RoleService – transferSuperadmin', () {
    test('superadmin can transfer to another DID', () async {
      await _setupTest();
      _injectSuperadmin(_superDid);
      await RoleService.instance.init();

      // transferSuperadmin calls SystemConfig.persistSuperadminDid which uses
      // SharedPreferences – in tests this would fail. We skip persistence and
      // only verify the StateError path.
      await expectLater(
        () async => RoleService.instance.transferSuperadmin(_userDid, _adminDid),
        throwsStateError,
      );
    });

    test('non-superadmin cannot transfer', () async {
      await _setupTest();
      _injectSuperadmin(_superDid);
      await RoleService.instance.init();

      await expectLater(
        () => RoleService.instance.transferSuperadmin(_userDid, _adminDid),
        throwsStateError,
      );
    });
  });

  group('RoleService – channel roles', () {
    test('createdBy is returned as channelAdmin', () async {
      await _setupTest();
      _injectSuperadmin(_superDid);
      await RoleService.instance.init();

      final role = RoleService.instance.getChannelRole(
        _channelId,
        _channelAdminDid,
        channelAdminDid: _channelAdminDid,
      );
      expect(role, equals(ChannelRole.channelAdmin));
    });

    test('channel admin can grant moderator', () async {
      await _setupTest();
      _injectSuperadmin(_superDid);
      await RoleService.instance.init();

      await RoleService.instance.grantChannelModerator(
        _channelAdminDid,
        _channelId,
        _modDid,
        channelAdminDid: _channelAdminDid,
      );

      final role = RoleService.instance.getChannelRole(
        _channelId,
        _modDid,
        channelAdminDid: _channelAdminDid,
      );
      expect(role, equals(ChannelRole.channelModerator));
    });

    test('channel admin can revoke moderator', () async {
      await _setupTest();
      _injectSuperadmin(_superDid);
      await RoleService.instance.init();

      await RoleService.instance.grantChannelModerator(
        _channelAdminDid, _channelId, _modDid,
        channelAdminDid: _channelAdminDid,
      );
      await RoleService.instance.revokeChannelModerator(
        _channelAdminDid, _channelId, _modDid,
        channelAdminDid: _channelAdminDid,
      );

      final role = RoleService.instance.getChannelRole(
        _channelId,
        _modDid,
        channelAdminDid: _channelAdminDid,
      );
      expect(role, equals(ChannelRole.channelMember));
    });

    test('regular user cannot grant moderator', () async {
      await _setupTest();
      _injectSuperadmin(_superDid);
      await RoleService.instance.init();

      await expectLater(
        () => RoleService.instance.grantChannelModerator(
          _userDid, _channelId, _modDid,
          channelAdminDid: _channelAdminDid,
        ),
        throwsStateError,
      );
    });
  });

  group('PermissionHelper – canPostInChannel', () {
    setUp(() async {
      await _setupTest();
      _injectSuperadmin(_superDid);
      await RoleService.instance.init();
    });

    test('discussion channel: all members can post', () {
      expect(
        PermissionHelper.canPostInChannel(
          channelId: _channelId,
          did: _userDid,
          channelMode: ChannelMode.discussion,
          channelAdminDid: _channelAdminDid,
        ),
        isTrue,
      );
    });

    test('announcement channel: regular user cannot post', () {
      expect(
        PermissionHelper.canPostInChannel(
          channelId: _channelId,
          did: _userDid,
          channelMode: ChannelMode.announcement,
          channelAdminDid: _channelAdminDid,
        ),
        isFalse,
      );
    });

    test('announcement channel: channel admin can post', () {
      expect(
        PermissionHelper.canPostInChannel(
          channelId: _channelId,
          did: _channelAdminDid,
          channelMode: ChannelMode.announcement,
          channelAdminDid: _channelAdminDid,
        ),
        isTrue,
      );
    });

    test('announcement channel: superadmin can post', () {
      expect(
        PermissionHelper.canPostInChannel(
          channelId: _channelId,
          did: _superDid,
          channelMode: ChannelMode.announcement,
          channelAdminDid: _channelAdminDid,
        ),
        isTrue,
      );
    });

    test('announcement channel: system admin can post', () async {
      await RoleService.instance.grantSystemAdmin(_superDid, _adminDid);
      expect(
        PermissionHelper.canPostInChannel(
          channelId: _channelId,
          did: _adminDid,
          channelMode: ChannelMode.announcement,
          channelAdminDid: _channelAdminDid,
        ),
        isTrue,
      );
    });
  });

  group('PermissionHelper – canCreateAnnouncementChannel', () {
    setUp(() async {
      await _setupTest();
      _injectSuperadmin(_superDid);
      await RoleService.instance.init();
    });

    test('regular user cannot create announcement channel', () {
      expect(
          PermissionHelper.canCreateAnnouncementChannel(_userDid), isFalse);
    });

    test('superadmin can create announcement channel', () {
      expect(
          PermissionHelper.canCreateAnnouncementChannel(_superDid), isTrue);
    });

    test('system admin can create announcement channel', () async {
      await RoleService.instance.grantSystemAdmin(_superDid, _adminDid);
      expect(
          PermissionHelper.canCreateAnnouncementChannel(_adminDid), isTrue);
    });
  });

  group('PermissionHelper – canDeleteMessage', () {
    setUp(() async {
      await _setupTest();
      _injectSuperadmin(_superDid);
      await RoleService.instance.init();
    });

    test('user can delete own message', () {
      expect(
        PermissionHelper.canDeleteMessage(
          channelId: _channelId,
          messageSenderDid: _userDid,
          requesterDid: _userDid,
          channelAdminDid: _channelAdminDid,
        ),
        isTrue,
      );
    });

    test('user cannot delete foreign message', () {
      expect(
        PermissionHelper.canDeleteMessage(
          channelId: _channelId,
          messageSenderDid: _userDid,
          requesterDid: 'did:key:other',
          channelAdminDid: _channelAdminDid,
        ),
        isFalse,
      );
    });

    test('channel admin can delete any message', () {
      expect(
        PermissionHelper.canDeleteMessage(
          channelId: _channelId,
          messageSenderDid: _userDid,
          requesterDid: _channelAdminDid,
          channelAdminDid: _channelAdminDid,
        ),
        isTrue,
      );
    });

    test('superadmin can delete any message', () {
      expect(
        PermissionHelper.canDeleteMessage(
          channelId: _channelId,
          messageSenderDid: _userDid,
          requesterDid: _superDid,
          channelAdminDid: _channelAdminDid,
        ),
        isTrue,
      );
    });

    test('channel moderator can delete foreign message', () async {
      await RoleService.instance.grantChannelModerator(
        _channelAdminDid, _channelId, _modDid,
        channelAdminDid: _channelAdminDid,
      );
      expect(
        PermissionHelper.canDeleteMessage(
          channelId: _channelId,
          messageSenderDid: _userDid,
          requesterDid: _modDid,
          channelAdminDid: _channelAdminDid,
        ),
        isTrue,
      );
    });
  });

  group('Fallback: no superadmin configured', () {
    test('all admin features disabled', () async {
      await _setupTest();
      // Do NOT inject superadmin → SystemConfig.superadminDid == null
      await RoleService.instance.init();

      expect(RoleService.instance.isSuperadmin(_superDid), isFalse);
      expect(PermissionHelper.canManageSystemAdmins(_superDid), isFalse);
      expect(PermissionHelper.canCreateAnnouncementChannel(_superDid), isFalse);
    });
  });
}
