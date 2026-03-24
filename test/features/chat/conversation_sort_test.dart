import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/features/chat/conversation.dart';

void main() {
  group('Conversation sorting', () {
    Conversation makeConv({
      required String id,
      required String peerPseudonym,
      required DateTime lastMessageTime,
      int unreadCount = 0,
      bool isPinned = false,
    }) {
      return Conversation(
        id: id,
        peerDid: 'did:key:$id',
        peerPseudonym: peerPseudonym,
        lastMessage: 'Test',
        lastMessageTime: lastMessageTime,
        unreadCount: unreadCount,
        isPinned: isPinned,
      );
    }

    final base = DateTime(2026, 1, 1, 12, 0, 0, 0, 0);

    test('sorts by lastMessageTime descending', () {
      final a = makeConv(
          id: 'a', peerPseudonym: 'A', lastMessageTime: base);
      final b = makeConv(
          id: 'b',
          peerPseudonym: 'B',
          lastMessageTime: base.add(const Duration(hours: 1)));
      final c = makeConv(
          id: 'c',
          peerPseudonym: 'C',
          lastMessageTime: base.subtract(const Duration(hours: 1)));

      final list = [a, b, c];
      list.sort((x, y) {
        if (x.isPinned && !y.isPinned) return -1;
        if (!x.isPinned && y.isPinned) return 1;
        return y.lastMessageTime.compareTo(x.lastMessageTime);
      });

      expect(list[0].id, 'b'); // newest
      expect(list[1].id, 'a');
      expect(list[2].id, 'c'); // oldest
    });

    test('pinned conversations always appear first', () {
      final mesh = makeConv(
          id: 'broadcast',
          peerPseudonym: '#mesh',
          lastMessageTime: base.subtract(const Duration(days: 30)),
          isPinned: true);
      final recent = makeConv(
          id: 'alice',
          peerPseudonym: 'Alice',
          lastMessageTime: base.add(const Duration(hours: 2)));

      final list = [recent, mesh];
      list.sort((x, y) {
        if (x.isPinned && !y.isPinned) return -1;
        if (!x.isPinned && y.isPinned) return 1;
        return y.lastMessageTime.compareTo(x.lastMessageTime);
      });

      expect(list[0].id, 'broadcast');
      expect(list[1].id, 'alice');
    });

    test('unreadCount defaults to zero', () {
      final conv = makeConv(
          id: 'x', peerPseudonym: 'X', lastMessageTime: base);
      expect(conv.unreadCount, 0);
    });

    test('copyWith updates fields without cloning others', () {
      final original = makeConv(
          id: 'orig',
          peerPseudonym: 'Orig',
          lastMessageTime: base,
          unreadCount: 3);
      final updated = original.copyWith(unreadCount: 0);

      expect(updated.unreadCount, 0);
      expect(updated.id, 'orig');
      expect(updated.peerPseudonym, 'Orig');
    });

    test('isBroadcast returns true only for broadcast peerDid', () {
      final broadcast = Conversation(
        id: 'broadcast',
        peerDid: 'broadcast',
        peerPseudonym: '#mesh',
        lastMessage: '',
        lastMessageTime: base,
      );
      final direct = makeConv(
          id: 'direct', peerPseudonym: 'Bob', lastMessageTime: base);

      expect(broadcast.isBroadcast, isTrue);
      expect(direct.isBroadcast, isFalse);
    });

    test('directId is deterministic and symmetric', () {
      const didA = 'did:key:z6MkAAA';
      const didB = 'did:key:z6MkBBB';

      expect(
        Conversation.directId(didA, didB),
        Conversation.directId(didB, didA),
      );
    });

    test('peerDidFrom extracts the correct peer DID', () {
      const myDid = 'did:key:z6MkAAA';
      const peerDid = 'did:key:z6MkBBB';
      final convId = Conversation.directId(myDid, peerDid);

      final extracted = Conversation.peerDidFrom(convId, myDid);
      expect(extracted, peerDid);
    });

    test('peerDidFrom returns broadcast for broadcast convId', () {
      expect(
        Conversation.peerDidFrom('broadcast', 'did:key:z6MkAAA'),
        'broadcast',
      );
    });
  });
}
