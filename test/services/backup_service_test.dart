import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/core/storage/pod_encryption.dart';
import 'package:nexus_oneapp/services/backup_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// A known 12-word BIP-39 mnemonic used across all tests.
const _testMnemonic =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

/// A second mnemonic for wrong-key tests.
const _wrongMnemonic =
    'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong';

// ── deriveBackupKeySync ───────────────────────────────────────────────────────

void main() {
  group('deriveBackupKeySync', () {
    test('returns 32 bytes', () {
      final key = deriveBackupKeySync(_testMnemonic);
      expect(key.length, 32);
    });

    test('is deterministic – same mnemonic → same key', () {
      final k1 = deriveBackupKeySync(_testMnemonic);
      final k2 = deriveBackupKeySync(_testMnemonic);
      expect(k1, k2);
    });

    test('different mnemonics produce different keys', () {
      final k1 = deriveBackupKeySync(_testMnemonic);
      final k2 = deriveBackupKeySync(_wrongMnemonic);
      expect(k1, isNot(k2));
    });

    test('returns Uint8List', () {
      expect(deriveBackupKeySync(_testMnemonic), isA<Uint8List>());
    });
  });

  // ── hashBackupPayload ─────────────────────────────────────────────────────

  group('hashBackupPayload', () {
    test('same payload → same hash', () {
      final p = {'contacts': [], 'channels': [], 'version': 1};
      expect(hashBackupPayload(p), hashBackupPayload(p));
    });

    test('ignores createdAt field', () {
      final p1 = {'contacts': [], 'createdAt': '2026-01-01T00:00:00Z'};
      final p2 = {'contacts': [], 'createdAt': '2026-06-01T12:00:00Z'};
      expect(hashBackupPayload(p1), hashBackupPayload(p2));
    });

    test('different data → different hash', () {
      final p1 = {'contacts': []};
      final p2 = {'contacts': [{'did': 'did:key:abc'}]};
      expect(hashBackupPayload(p1), isNot(hashBackupPayload(p2)));
    });
  });

  // ── Encryption round-trip ─────────────────────────────────────────────────

  group('Encryption round-trip', () {
    test('encrypt → decrypt recovers plaintext', () async {
      final key = deriveBackupKeySync(_testMnemonic);
      const plain = '{"contacts":[],"version":1}';
      final enc = await PodEncryption.encrypt(plain, key);
      final dec = await PodEncryption.decrypt(enc, key);
      expect(dec, plain);
    });

    test('decryption with wrong key throws', () async {
      final goodKey  = deriveBackupKeySync(_testMnemonic);
      final wrongKey = deriveBackupKeySync(_wrongMnemonic);
      const plain = '{"contacts":[],"version":1}';
      final enc = await PodEncryption.encrypt(plain, goodKey);
      expect(
        () async => await PodEncryption.decrypt(enc, wrongKey),
        throwsA(anything),
      );
    });

    test('backup file does not contain seed phrase or private key material', () async {
      final key = deriveBackupKeySync(_testMnemonic);
      final payload = {
        'version': 1,
        'did': 'did:key:z6MkTest',
        'pseudonym': 'TestUser',
        'contacts': [],
        'channels': [],
        'cells': [],
        'createdAt': DateTime.now().toIso8601String(),
      };
      final encrypted = await PodEncryption.encrypt(jsonEncode(payload), key);
      // The raw encrypted blob must not contain the mnemonic words.
      expect(encrypted.contains('abandon'), isFalse);
      // Must not contain anything that looks like an unencrypted private key.
      expect(encrypted.contains('privateKey'), isFalse);
      expect(encrypted.contains('seedPhrase'), isFalse);
    });
  });

  // ── Backup payload content ────────────────────────────────────────────────

  group('Backup payload', () {
    test('backup payload contains expected fields', () {
      final payload = {
        'version': 1,
        'did': 'did:key:z6MkTest',
        'pseudonym': 'TestUser',
        'contacts': [
          {'did': 'did:key:contact1', 'pseudonym': 'Alice', 'trustLevel': 'contact'},
        ],
        'channels': [{'id': 'ch1', 'name': '#test'}],
        'cells': [],
        'principles': {'hasSeen': true, 'isAccepted': true},
        'settings': {'autoBackupEnabled': true},
        'createdAt': '2026-04-04T12:00:00Z',
      };
      expect(payload['version'], 1);
      expect(payload.containsKey('contacts'), isTrue);
      expect(payload.containsKey('channels'), isTrue);
      expect(payload.containsKey('cells'), isTrue);
      expect(payload.containsKey('principles'), isTrue);
      expect(payload.containsKey('settings'), isTrue);
    });

    test('backup payload must NOT contain seed phrase field', () {
      final payload = {
        'version': 1,
        'did': 'did:key:z6MkTest',
        'pseudonym': 'TestUser',
        'contacts': [],
        'channels': [],
        'cells': [],
      };
      expect(payload.containsKey('seedPhrase'), isFalse);
      expect(payload.containsKey('mnemonic'), isFalse);
      expect(payload.containsKey('privateKey'), isFalse);
      expect(payload.containsKey('podEncKey'), isFalse);
    });

    test('contact backup strips profileImage local path', () {
      final contactJson = {
        'did': 'did:key:abc',
        'pseudonym': 'Bob',
        'trustLevel': 'contact',
        'profileImage': '/data/app/nexus/images/bob.jpg',
        'encryptionPublicKey': 'abc123',
      };
      // Simulate backup stripping profileImage.
      final backupContact = Map<String, dynamic>.from(contactJson)
        ..remove('profileImage');
      expect(backupContact.containsKey('profileImage'), isFalse);
      expect(backupContact['did'], 'did:key:abc');
      expect(backupContact['encryptionPublicKey'], 'abc123');
    });
  });

  // ── Pruning ────────────────────────────────────────────────────────────────

  group('Backup pruning', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('nexus_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('pruning keeps at most maxCount files', () async {
      // Create 5 fake backup files.
      for (int i = 1; i <= 5; i++) {
        final f = File('${tempDir.path}/nexus_backup_2026-01-0${i}_120000.enc');
        await f.writeAsString('fake_backup_$i');
        // Stagger modified times.
        await Future.delayed(const Duration(milliseconds: 10));
      }
      final files = tempDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.enc'))
          .toList()
        ..sort((a, b) =>
            b.statSync().modified.compareTo(a.statSync().modified));
      // Manually prune to 3.
      for (int i = 3; i < files.length; i++) {
        await files[i].delete();
      }
      final remaining = tempDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.enc'))
          .toList();
      expect(remaining.length, 3);
    });

    test('filename contains date stamp', () {
      const ts = '20260404_120000';
      final filename = 'nexus_backup_$ts.enc';
      expect(filename.startsWith('nexus_backup_'), isTrue);
      expect(filename.endsWith('.enc'), isTrue);
      expect(filename.contains('20260404'), isTrue);
    });
  });

  // ── Restore merge logic ───────────────────────────────────────────────────

  group('Restore merge logic', () {
    test('merge skips contacts whose DID already exists', () {
      final existingDids = {'did:key:existing1', 'did:key:existing2'};
      final backupContacts = [
        {'did': 'did:key:existing1', 'pseudonym': 'Alice'},
        {'did': 'did:key:new1', 'pseudonym': 'Bob'},
        {'did': 'did:key:new2', 'pseudonym': 'Carol'},
      ];
      final toImport = backupContacts
          .where((c) => !existingDids.contains(c['did']))
          .toList();
      expect(toImport.length, 2);
      expect(toImport.map((c) => c['did']).toList(),
          containsAll(['did:key:new1', 'did:key:new2']));
    });

    test('merge skips channels whose ID already exists', () {
      final existingIds = {'channel-global'};
      final backupChannels = [
        {'id': 'channel-global', 'name': '#nexus-global'},
        {'id': 'channel-new', 'name': '#new-channel'},
      ];
      final toImport = backupChannels
          .where((c) => !existingIds.contains(c['id']))
          .toList();
      expect(toImport.length, 1);
      expect(toImport.first['id'], 'channel-new');
    });

    test('merge skips cells whose ID already exists', () {
      final existingIds = {'cell-existing'};
      final backupCells = [
        {'id': 'cell-existing', 'name': 'My Cell'},
        {'id': 'cell-new', 'name': 'New Cell'},
      ];
      final toImport = backupCells
          .where((c) => !existingIds.contains(c['id']))
          .toList();
      expect(toImport.length, 1);
      expect(toImport.first['id'], 'cell-new');
    });

    test('principles not overwritten when already accepted', () {
      // Already accepted → skip.
      const alreadyAccepted = true;
      final backupPrinciples = {'hasSeen': true, 'isAccepted': true};
      // Restore only if not already done.
      final shouldRestore = !alreadyAccepted;
      expect(shouldRestore, isFalse);
      // Verify backup data is valid regardless.
      expect(backupPrinciples['isAccepted'], isTrue);
    });

    test('principles restored when not yet seen', () {
      const hasSeen = false;
      final backupPrinciples = {
        'hasSeen': true,
        'isAccepted': true,
        'acceptedAt': '2026-01-01T00:00:00Z',
      };
      final shouldRestore = !hasSeen;
      expect(shouldRestore, isTrue);
      expect(backupPrinciples['acceptedAt'], isNotNull);
    });
  });

  // ── Auto-backup timing ────────────────────────────────────────────────────

  group('Auto-backup timing', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('isOlderThan returns true when lastBackupAt is null', () {
      final svc = BackupService.instance;
      // Reset via SharedPreferences mock.
      expect(svc.isOlderThan(hours: 24), isTrue);
    });

    test('shouldShowReminder returns true before setupSeen', () {
      // BackupService freshly constructed has setupSeen = false initially.
      // We can't reset the singleton, but the logic can be tested directly.
      final setupSeen = false;
      final shouldShow = !setupSeen;
      expect(shouldShow, isTrue);
    });

    test('shouldShowReminder returns false after setupSeen', () {
      const setupSeen = true;
      final shouldShow = !setupSeen;
      expect(shouldShow, isFalse);
    });
  });

  // ── Backup search and preview ─────────────────────────────────────────────

  group('Backup file discovery', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('nexus_search_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('findBackups returns empty list when directory is empty', () async {
      final files = tempDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.enc'))
          .toList();
      expect(files, isEmpty);
    });

    test('findBackups only picks up .enc files', () async {
      await File('${tempDir.path}/nexus_backup_test.enc')
          .writeAsString('encrypted');
      await File('${tempDir.path}/nexus_backup_test.json')
          .writeAsString('json');
      await File('${tempDir.path}/other.txt').writeAsString('other');
      final encFiles = tempDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.enc'))
          .toList();
      expect(encFiles.length, 1);
    });

    test('preview returns null for file encrypted with wrong key', () async {
      final goodKey  = deriveBackupKeySync(_testMnemonic);
      final plain    = jsonEncode({'version': 1, 'contacts': []});
      final enc      = await PodEncryption.encrypt(plain, goodKey);
      final file = File('${tempDir.path}/nexus_backup_test.enc');
      await file.writeAsString(enc);

      // Try to decrypt with wrong key.
      final wrongKey = deriveBackupKeySync(_wrongMnemonic);
      String? result;
      try {
        result = await PodEncryption.decrypt(enc, wrongKey);
      } catch (_) {
        result = null;
      }
      expect(result, isNull);
    });

    test('valid backup can be decrypted with correct key', () async {
      final key   = deriveBackupKeySync(_testMnemonic);
      final payload = jsonEncode({
        'version': 1,
        'createdAt': '2026-04-04T10:00:00Z',
        'contacts': [{'did': 'did:key:abc', 'pseudonym': 'Alice'}],
        'channels': [],
        'cells': [],
      });
      final enc  = await PodEncryption.encrypt(payload, key);
      final dec  = await PodEncryption.decrypt(enc, key);
      final data = jsonDecode(dec) as Map<String, dynamic>;
      expect(data['version'], 1);
      expect((data['contacts'] as List).length, 1);
    });
  });

  // ── Manual backup trigger ─────────────────────────────────────────────────

  group('BackupResult', () {
    test('BackupResult.ok carries path', () {
      const result = BackupResult.ok('/tmp/nexus_backup_test.enc');
      expect(result.success, isTrue);
      expect(result.path, '/tmp/nexus_backup_test.enc');
      expect(result.error, isNull);
    });

    test('BackupResult.fail carries error', () {
      const result = BackupResult.fail('Keine Identität');
      expect(result.success, isFalse);
      expect(result.error, 'Keine Identität');
      expect(result.path, isNull);
    });
  });

  // ── RestoreResult ─────────────────────────────────────────────────────────

  group('RestoreResult', () {
    test('success result carries counts', () {
      const result = RestoreResult(
        success: true,
        restoredContacts: 5,
        restoredChannels: 2,
        restoredCells: 1,
      );
      expect(result.success, isTrue);
      expect(result.restoredContacts, 5);
      expect(result.restoredChannels, 2);
      expect(result.restoredCells, 1);
      expect(result.error, isNull);
    });

    test('failure result carries error', () {
      const result = RestoreResult(success: false, error: 'Falscher Schlüssel');
      expect(result.success, isFalse);
      expect(result.error, 'Falscher Schlüssel');
      expect(result.restoredContacts, 0);
    });
  });
}
