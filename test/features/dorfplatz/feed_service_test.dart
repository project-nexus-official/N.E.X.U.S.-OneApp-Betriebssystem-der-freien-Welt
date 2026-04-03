import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/features/dorfplatz/feed_post.dart';
import 'package:nexus_oneapp/features/dorfplatz/feed_service.dart';

// ── Stub publisher ─────────────────────────────────────────────────────────────
String? _stubPublisher(int kind, String content, List<List<String>> tags) =>
    'nostr-evt-${kind}-${content.hashCode}';

String? _nullPublisher(int kind, String content, List<List<String>> tags) =>
    null;

// ── Helpers ────────────────────────────────────────────────────────────────────

FeedPost _makePost({
  String? id,
  String authorDid = 'did:test:alice',
  String authorPseudonym = 'Alice',
  String content = 'Hello world',
  FeedVisibility visibility = FeedVisibility.contacts,
  Poll? poll,
  String? repostOf,
  String? repostComment,
  DateTime? createdAt,
}) =>
    FeedPost(
      id: id ?? generateFeedId(),
      authorDid: authorDid,
      authorPseudonym: authorPseudonym,
      content: content,
      visibility: visibility,
      poll: poll,
      repostOf: repostOf,
      repostComment: repostComment,
      createdAt: createdAt ?? DateTime.now(),
    );

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  // ── FeedVisibility ───────────────────────────────────────────────────────────

  group('FeedVisibility', () {
    test('serialises and deserialises via name', () {
      for (final v in FeedVisibility.values) {
        expect(
          FeedVisibility.values.firstWhere((x) => x.name == v.name),
          equals(v),
        );
      }
    });
  });

  // ── generateFeedId ───────────────────────────────────────────────────────────

  group('generateFeedId', () {
    test('returns a valid UUID v4 format', () {
      final id = generateFeedId();
      final parts = id.split('-');
      expect(parts.length, equals(5));
      expect(parts[2][0], equals('4')); // version 4
      expect('89ab'.contains(parts[3][0]), isTrue); // variant bits
    });

    test('generates unique IDs', () {
      final ids = List.generate(100, (_) => generateFeedId()).toSet();
      expect(ids.length, equals(100));
    });
  });

  // ── PollOption ───────────────────────────────────────────────────────────────

  group('PollOption', () {
    test('withVote adds a voter', () {
      final opt = const PollOption(id: '1', text: 'Yes');
      final voted = opt.withVote('did:alice');
      expect(voted.voterDids, contains('did:alice'));
    });

    test('withVote is immutable — original unchanged', () {
      final opt = const PollOption(id: '1', text: 'Yes');
      opt.withVote('did:alice');
      expect(opt.voterDids, isEmpty);
    });

    test('withoutVote removes a voter', () {
      final opt = PollOption(
          id: '1', text: 'Yes', voterDids: ['did:alice', 'did:bob']);
      final removed = opt.withoutVote('did:alice');
      expect(removed.voterDids, isNot(contains('did:alice')));
      expect(removed.voterDids, contains('did:bob'));
    });

    test('toJson / fromJson round-trip', () {
      final opt = PollOption(
          id: 'opt-1', text: 'Option A', voterDids: ['did:alice']);
      final json = opt.toJson();
      final restored = PollOption.fromJson(json);
      expect(restored.id, equals('opt-1'));
      expect(restored.text, equals('Option A'));
      expect(restored.voterDids, equals(['did:alice']));
    });
  });

  // ── Poll ─────────────────────────────────────────────────────────────────────

  group('Poll', () {
    PollOption makeOpt(String id, List<String> voters) =>
        PollOption(id: id, text: id, voterDids: voters);

    test('totalVotes sums all option voters', () {
      final poll = Poll(
        question: 'Q?',
        options: [makeOpt('a', ['d1', 'd2']), makeOpt('b', ['d3'])],
      );
      expect(poll.totalVotes, equals(3));
    });

    test('percentFor calculates correctly', () {
      final optA = makeOpt('a', ['d1', 'd2']);
      final optB = makeOpt('b', ['d3', 'd4']);
      final poll = Poll(question: 'Q?', options: [optA, optB]);
      expect(poll.percentFor(optA), closeTo(0.5, 0.001));
      expect(poll.percentFor(optB), closeTo(0.5, 0.001));
    });

    test('percentFor returns 0 when no votes', () {
      final poll = Poll(
          question: 'Q?', options: [makeOpt('a', []), makeOpt('b', [])]);
      expect(poll.percentFor(poll.options.first), equals(0));
    });

    test('hasVoted returns true if DID voted in any option', () {
      final poll = Poll(
        question: 'Q?',
        options: [makeOpt('a', ['did:alice'])],
      );
      expect(poll.hasVoted('did:alice'), isTrue);
      expect(poll.hasVoted('did:bob'), isFalse);
    });

    test('isExpired returns true past endsAt', () {
      final poll = Poll(
        question: 'Q?',
        options: [],
        endsAt: DateTime.now().subtract(const Duration(seconds: 1)),
      );
      expect(poll.isExpired, isTrue);
    });

    test('isExpired returns false when endsAt is null', () {
      final poll = Poll(question: 'Q?', options: []);
      expect(poll.isExpired, isFalse);
    });

    test('toJson / fromJson round-trip', () {
      final endsAt = DateTime(2030, 1, 1);
      final poll = Poll(
        question: 'Best?',
        options: [makeOpt('x', ['did:alice'])],
        multipleChoice: true,
        endsAt: endsAt,
      );
      final restored = Poll.fromJson(poll.toJson());
      expect(restored.question, equals('Best?'));
      expect(restored.multipleChoice, isTrue);
      expect(restored.options.first.voterDids, equals(['did:alice']));
      expect(restored.endsAt?.millisecondsSinceEpoch,
          equals(endsAt.millisecondsSinceEpoch));
    });
  });

  // ── LinkPreview ───────────────────────────────────────────────────────────────

  group('LinkPreview', () {
    test('displayDomain extracts host from URL', () {
      const lp = LinkPreview(url: 'https://example.com/some/path');
      expect(lp.displayDomain, equals('example.com'));
    });

    test('displayDomain returns empty string when URL has no host', () {
      // Uri.parse on a bare string like 'not-a-url' returns an empty host.
      const lp = LinkPreview(url: 'not-a-url');
      expect(lp.displayDomain, equals(''));
    });

    test('toJson / fromJson round-trip', () {
      const lp = LinkPreview(
        url: 'https://nexus.org',
        title: 'NEXUS',
        description: 'desc',
        imageUrl: 'https://nexus.org/img.png',
      );
      final r = LinkPreview.fromJson(lp.toJson());
      expect(r.url, equals('https://nexus.org'));
      expect(r.title, equals('NEXUS'));
      expect(r.description, equals('desc'));
      expect(r.imageUrl, equals('https://nexus.org/img.png'));
    });
  });

  // ── FeedPost ─────────────────────────────────────────────────────────────────

  group('FeedPost', () {
    test('isEmpty is true with no content, images, voice, poll, repost', () {
      final post = _makePost(content: '');
      expect(post.isEmpty, isTrue);
    });

    test('isEmpty is false when content is set', () {
      expect(_makePost().isEmpty, isFalse);
    });

    test('isRepost returns true when repostOf is set', () {
      final post = _makePost(repostOf: 'orig-id');
      expect(post.isRepost, isTrue);
    });

    test('copyWith preserves fields and overrides poll', () {
      final original = _makePost();
      final newPoll = Poll(
        question: 'Q',
        options: [const PollOption(id: 'a', text: 'A')],
      );
      final copy = original.copyWith(poll: newPoll);
      expect(copy.id, equals(original.id));
      expect(copy.poll, equals(newPoll));
    });

    test('toJson / fromJson round-trip preserves all fields', () {
      final endsAt = DateTime(2030, 6, 15);
      final poll = Poll(
        question: 'Round?',
        options: [const PollOption(id: 'y', text: 'Yes')],
        endsAt: endsAt,
      );
      final post = FeedPost(
        id: 'post-1',
        authorDid: 'did:alice',
        authorPseudonym: 'Alice',
        content: 'Test content',
        images: ['base64abc'],
        visibility: FeedVisibility.public,
        createdAt: DateTime(2025, 1, 15, 12, 0),
        poll: poll,
        nostrEventId: 'nostr-abc',
        repostOf: 'orig-post',
        repostComment: 'Great post!',
      );
      final restored = FeedPost.fromJson(post.toJson());
      expect(restored.id, equals('post-1'));
      expect(restored.authorDid, equals('did:alice'));
      expect(restored.content, equals('Test content'));
      expect(restored.images, equals(['base64abc']));
      expect(restored.visibility, equals(FeedVisibility.public));
      expect(restored.nostrEventId, equals('nostr-abc'));
      expect(restored.repostOf, equals('orig-post'));
      expect(restored.repostComment, equals('Great post!'));
      expect(restored.poll?.question, equals('Round?'));
    });

    test('fromJson handles missing optional fields', () {
      final json = {
        'id': 'p1',
        'authorDid': 'did:alice',
        'authorPseudonym': 'Alice',
        'content': '',
        'visibility': 'contacts',
        'createdAt': DateTime(2025).millisecondsSinceEpoch,
      };
      final post = FeedPost.fromJson(json);
      expect(post.images, isEmpty);
      expect(post.poll, isNull);
      expect(post.nostrEventId, isNull);
    });
  });

  // ── FeedComment ───────────────────────────────────────────────────────────────

  group('FeedComment', () {
    test('isReply is false when parentCommentId is null', () {
      final comment = FeedComment(
        id: 'c1',
        postId: 'p1',
        authorDid: 'did:alice',
        authorPseudonym: 'Alice',
        content: 'Top-level',
        createdAt: DateTime.now(),
      );
      expect(comment.isReply, isFalse);
    });

    test('isReply is true when parentCommentId is set', () {
      final comment = FeedComment(
        id: 'c2',
        postId: 'p1',
        parentCommentId: 'c1',
        authorDid: 'did:bob',
        authorPseudonym: 'Bob',
        content: 'Reply',
        createdAt: DateTime.now(),
      );
      expect(comment.isReply, isTrue);
    });

    test('toJson / fromJson round-trip', () {
      final now = DateTime(2025, 3, 10, 8, 30);
      final comment = FeedComment(
        id: 'c3',
        postId: 'p2',
        parentCommentId: 'c1',
        authorDid: 'did:charlie',
        authorPseudonym: 'Charlie',
        content: 'Nested reply',
        createdAt: now,
        nostrEventId: 'nostr-xyz',
      );
      final r = FeedComment.fromJson(comment.toJson());
      expect(r.id, equals('c3'));
      expect(r.postId, equals('p2'));
      expect(r.parentCommentId, equals('c1'));
      expect(r.authorPseudonym, equals('Charlie'));
      expect(r.nostrEventId, equals('nostr-xyz'));
      expect(r.createdAt.millisecondsSinceEpoch,
          equals(now.millisecondsSinceEpoch));
    });
  });

  // ── FeedService – publisher & stream ──────────────────────────────────────────

  group('FeedService publisher', () {
    test('setNostrPublisher stores the publisher', () {
      FeedService.instance.setNostrPublisher(_stubPublisher);
      // After setting, creating a post should call publisher (indirectly tested
      // via nostrEventId being set). We only test that no exception is thrown.
      FeedService.instance.setNostrPublisher(null);
    });

    test('stream is a broadcast stream (can have multiple listeners)', () {
      // Verify the stream is broadcast and does not throw when multiple
      // listeners subscribe. DB operations are not tested in unit tests.
      int count = 0;
      final sub1 = FeedService.instance.stream.listen((_) => count++);
      final sub2 = FeedService.instance.stream.listen((_) => count++);
      sub1.cancel();
      sub2.cancel();
      // No exception = pass; stream is correctly broadcast.
    });
  });

  // ── FeedService.getPostsForTab – filtering ────────────────────────────────────

  group('FeedService.getPostsForTab filtering', () {
    test('FeedTab.cell always returns empty list (Phase 2)', () {
      final posts = FeedService.instance.getPostsForTab(
        FeedTab.cell,
        myDid: 'did:me',
        contactDids: {'did:alice'},
      );
      expect(posts, isEmpty);
    });
  });

  // ── FeedTab enum ─────────────────────────────────────────────────────────────

  group('FeedTab', () {
    test('has three values', () {
      expect(FeedTab.values.length, equals(3));
    });

    test('contains contacts, cell, entdecken', () {
      expect(FeedTab.values, contains(FeedTab.contacts));
      expect(FeedTab.values, contains(FeedTab.cell));
      expect(FeedTab.values, contains(FeedTab.entdecken));
    });
  });
}
