import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/features/chat/group_channel.dart';

void main() {
  group('GroupChannel.normaliseName', () {
    test('adds # prefix when missing', () {
      expect(GroupChannel.normaliseName('teneriffa'), '#teneriffa');
    });

    test('lowercases input', () {
      expect(GroupChannel.normaliseName('Teneriffa'), '#teneriffa');
    });

    test('keeps existing # prefix', () {
      expect(GroupChannel.normaliseName('#teneriffa'), '#teneriffa');
    });

    test('replaces spaces with hyphens', () {
      expect(GroupChannel.normaliseName('gran canaria'), '#gran-canaria');
    });

    test('collapses multiple hyphens', () {
      expect(GroupChannel.normaliseName('a--b'), '#a-b');
    });

    test('replaces special characters with hyphens and collapses', () {
      expect(GroupChannel.normaliseName('nexus!@#global'), '#nexus-global');
    });
  });

  group('GroupChannel.isValidName', () {
    test('valid name without #', () {
      expect(GroupChannel.isValidName('teneriffa'), isTrue);
    });

    test('valid name with #', () {
      expect(GroupChannel.isValidName('#teneriffa'), isTrue);
    });

    test('valid name with hyphens', () {
      expect(GroupChannel.isValidName('gran-canaria'), isTrue);
    });

    test('valid name with digits', () {
      expect(GroupChannel.isValidName('channel42'), isTrue);
    });

    test('rejects single char', () {
      expect(GroupChannel.isValidName('a'), isFalse);
    });

    test('rejects uppercase', () {
      expect(GroupChannel.isValidName('Teneriffa'), isFalse);
    });

    test('rejects leading hyphen', () {
      expect(GroupChannel.isValidName('-teneriffa'), isFalse);
    });

    test('rejects spaces', () {
      expect(GroupChannel.isValidName('gran canaria'), isFalse);
    });
  });

  group('GroupChannel.nameToNostrTag', () {
    test('converts #teneriffa to nexus-channel-teneriffa', () {
      expect(
        GroupChannel.nameToNostrTag('#teneriffa'),
        'nexus-channel-teneriffa',
      );
    });

    test('works without # prefix', () {
      expect(
        GroupChannel.nameToNostrTag('teneriffa'),
        'nexus-channel-teneriffa',
      );
    });
  });

  group('GroupChannel.nostrTagToName', () {
    test('converts nexus-channel-teneriffa to #teneriffa', () {
      expect(
        GroupChannel.nostrTagToName('nexus-channel-teneriffa'),
        '#teneriffa',
      );
    });

    test('returns null for non-channel tags', () {
      expect(GroupChannel.nostrTagToName('nexus-mesh'), isNull);
    });
  });

  group('GroupChannel.create', () {
    test('sets name with # prefix', () {
      final ch = GroupChannel.create(
        name: 'teneriffa',
        description: 'Test channel',
        createdBy: 'did:key:abc',
      );
      expect(ch.name, '#teneriffa');
    });

    test('sets nostrTag correctly', () {
      final ch = GroupChannel.create(
        name: 'my-channel',
        description: '',
        createdBy: 'did:key:abc',
      );
      expect(ch.nostrTag, 'nexus-channel-my-channel');
    });

    test('sets conversationId with # prefix', () {
      final ch = GroupChannel.create(
        name: 'test',
        description: '',
        createdBy: 'did:key:abc',
      );
      expect(ch.conversationId, '#test');
    });

    test('joinedAt is set on creation', () {
      final ch = GroupChannel.create(
        name: 'test',
        description: '',
        createdBy: 'did:key:abc',
      );
      expect(ch.joinedAt, isNotNull);
    });

    test('has unique UUID id', () {
      final ch1 = GroupChannel.create(
        name: 'channel1',
        description: '',
        createdBy: 'did:key:abc',
      );
      final ch2 = GroupChannel.create(
        name: 'channel2',
        description: '',
        createdBy: 'did:key:abc',
      );
      expect(ch1.id, isNot(equals(ch2.id)));
    });
  });

  group('GroupChannel JSON round-trip', () {
    test('serializes and deserializes correctly', () {
      final original = GroupChannel.create(
        name: 'teneriffa',
        description: 'Sun, sea and NEXUS',
        createdBy: 'did:key:z6MkABC',
      );
      final json = original.toJson();
      final restored = GroupChannel.fromJson(json);

      expect(restored.name, original.name);
      expect(restored.description, original.description);
      expect(restored.createdBy, original.createdBy);
      expect(restored.nostrTag, original.nostrTag);
      expect(restored.isPublic, original.isPublic);
      expect(restored.id, original.id);
    });

    test('round-trip without joinedAt', () {
      final ch = GroupChannel(
        id: 'test-id',
        name: '#test',
        description: '',
        createdBy: 'did:key:abc',
        createdAt: DateTime.utc(2024, 1, 1),
        nostrTag: 'nexus-channel-test',
      );
      final restored = GroupChannel.fromJson(ch.toJson());
      expect(restored.joinedAt, isNull);
    });
  });
}
