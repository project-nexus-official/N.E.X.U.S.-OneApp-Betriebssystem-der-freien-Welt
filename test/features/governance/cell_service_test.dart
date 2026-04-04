import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/features/governance/cell.dart';
import 'package:nexus_oneapp/features/governance/cell_join_request.dart';
import 'package:nexus_oneapp/features/governance/cell_member.dart';

// ── Helpers ────────────────────────────────────────────────────────────────────

Cell _makeLocalCell({
  String id = 'cell001',
  String name = 'Hamburg Altona',
  String createdBy = 'did:test:alice',
  String? locationName,
  int maxMembers = 150,
  JoinPolicy joinPolicy = JoinPolicy.approvalRequired,
  MinTrustLevel minTrustLevel = MinTrustLevel.none,
  int proposalWaitDays = 0,
}) =>
    Cell(
      id: id,
      name: name,
      description: 'Test local cell',
      createdBy: createdBy,
      createdAt: DateTime.now().toUtc(),
      cellType: CellType.local,
      locationName: locationName ?? 'Hamburg Altona',
      nostrTag: 'nexus-cell-$id',
      maxMembers: maxMembers,
      joinPolicy: joinPolicy,
      minTrustLevel: minTrustLevel,
      proposalWaitDays: proposalWaitDays,
      memberCount: 1,
    );

Cell _makeThematicCell({
  String id = 'cell002',
  String name = 'Code Circle',
  String createdBy = 'did:test:bob',
  String category = 'Technik',
  String? topic,
  int memberCount = 1,
}) =>
    Cell(
      id: id,
      name: name,
      description: 'Software development cell',
      createdBy: createdBy,
      createdAt: DateTime.now().toUtc(),
      cellType: CellType.thematic,
      category: category,
      topic: topic,
      nostrTag: 'nexus-cell-$id',
      maxMembers: 150,
      memberCount: memberCount,
    );

CellMember _makeMember({
  String cellId = 'cell001',
  String did = 'did:test:alice',
  MemberRole role = MemberRole.founder,
  DateTime? joinedAt,
}) =>
    CellMember(
      cellId: cellId,
      did: did,
      joinedAt: joinedAt ?? DateTime.now().toUtc(),
      role: role,
      confirmedBy: 'did:test:alice',
    );

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  // ── Cell model ───────────────────────────────────────────────────────────────

  group('Cell', () {
    test('Cell.create generates a unique id and nostrTag', () {
      final cell1 = Cell.create(
        name: 'Test Zelle',
        description: '',
        createdBy: 'did:test:alice',
        cellType: CellType.thematic,
      );
      final cell2 = Cell.create(
        name: 'Test Zelle 2',
        description: '',
        createdBy: 'did:test:alice',
        cellType: CellType.thematic,
      );
      expect(cell1.id, isNotEmpty);
      expect(cell2.id, isNotEmpty);
      expect(cell1.id, isNot(equals(cell2.id)));
      expect(cell1.nostrTag, startsWith('nexus-cell-'));
      expect(cell1.nostrTag, contains(cell1.id));
    });

    test('Local cell stores locationName and no category', () {
      final cell = Cell.create(
        name: 'Hamburg',
        description: '',
        createdBy: 'did:test:alice',
        cellType: CellType.local,
        locationName: 'Hamburg Nord',
      );
      expect(cell.cellType, CellType.local);
      expect(cell.locationName, 'Hamburg Nord');
      expect(cell.category, isNull);
    });

    test('Thematic cell stores topic and category', () {
      final cell = Cell.create(
        name: 'Dev Circle',
        description: '',
        createdBy: 'did:test:alice',
        cellType: CellType.thematic,
        topic: 'Flutter',
        category: 'Technik',
      );
      expect(cell.cellType, CellType.thematic);
      expect(cell.topic, 'Flutter');
      expect(cell.category, 'Technik');
      expect(cell.locationName, isNull);
    });

    test('Default settings are correct', () {
      final cell = Cell.create(
        name: 'Test',
        description: '',
        createdBy: 'did:test:alice',
        cellType: CellType.thematic,
      );
      expect(cell.maxMembers, 150);
      expect(cell.joinPolicy, JoinPolicy.approvalRequired);
      expect(cell.minTrustLevel, MinTrustLevel.none);
      expect(cell.proposalWaitDays, 0);
    });

    test('All configurable settings are stored', () {
      final cell = Cell.create(
        name: 'Strict Cell',
        description: '',
        createdBy: 'did:test:alice',
        cellType: CellType.local,
        maxMembers: 50,
        joinPolicy: JoinPolicy.inviteOnly,
        minTrustLevel: MinTrustLevel.trusted,
        proposalWaitDays: 30,
      );
      expect(cell.maxMembers, 50);
      expect(cell.joinPolicy, JoinPolicy.inviteOnly);
      expect(cell.minTrustLevel, MinTrustLevel.trusted);
      expect(cell.proposalWaitDays, 30);
    });

    test('toJson / fromJson round-trip', () {
      final cell = _makeLocalCell(locationName: 'Teneriffa Nord');
      final json = cell.toJson();
      final restored = Cell.fromJson(json);
      expect(restored.id, cell.id);
      expect(restored.name, cell.name);
      expect(restored.cellType, cell.cellType);
      expect(restored.locationName, cell.locationName);
      expect(restored.maxMembers, cell.maxMembers);
      expect(restored.joinPolicy, cell.joinPolicy);
      expect(restored.proposalWaitDays, cell.proposalWaitDays);
    });

    test('toJson / fromJson round-trip for thematic cell', () {
      final cell = _makeThematicCell(topic: 'Software', category: 'Technik');
      final json = cell.toJson();
      final restored = Cell.fromJson(json);
      expect(restored.cellType, CellType.thematic);
      expect(restored.topic, 'Software');
      expect(restored.category, 'Technik');
    });

    test('isNew returns true for recently created cells', () {
      final cell = _makeLocalCell();
      expect(cell.isNew, isTrue);
    });

    test('isNew returns false for old cells', () {
      final cell = Cell(
        id: 'old',
        name: 'Old Cell',
        description: '',
        createdBy: 'did:test:alice',
        createdAt: DateTime.now().toUtc().subtract(const Duration(days: 30)),
        cellType: CellType.thematic,
        nostrTag: 'nexus-cell-old',
      );
      expect(cell.isNew, isFalse);
    });

    test('isFull returns true when memberCount equals maxMembers', () {
      final cell = _makeThematicCell(memberCount: 150);
      expect(cell.isFull, isTrue);
    });

    test('isFull returns false when below maxMembers', () {
      final cell = _makeThematicCell(memberCount: 10);
      expect(cell.isFull, isFalse);
    });

    test('copyWith updates only specified fields', () {
      final cell = _makeLocalCell();
      final updated = cell.copyWith(name: 'New Name', maxMembers: 50);
      expect(updated.name, 'New Name');
      expect(updated.maxMembers, 50);
      expect(updated.id, cell.id); // unchanged
      expect(updated.joinPolicy, cell.joinPolicy); // unchanged
    });
  });

  // ── CellMember ───────────────────────────────────────────────────────────────

  group('CellMember', () {
    test('Founder role is confirmed', () {
      final m = _makeMember(role: MemberRole.founder);
      expect(m.isConfirmed, isTrue);
    });

    test('Pending role is not confirmed', () {
      final m = _makeMember(role: MemberRole.pending);
      expect(m.isConfirmed, isFalse);
    });

    test('Founder can manage requests', () {
      final m = _makeMember(role: MemberRole.founder);
      expect(m.canManageRequests, isTrue);
    });

    test('Moderator can manage requests', () {
      final m = _makeMember(role: MemberRole.moderator);
      expect(m.canManageRequests, isTrue);
    });

    test('Member cannot manage requests', () {
      final m = _makeMember(role: MemberRole.member);
      expect(m.canManageRequests, isFalse);
    });

    test('Pending cannot manage requests', () {
      final m = _makeMember(role: MemberRole.pending);
      expect(m.canManageRequests, isFalse);
    });

    test('toJson / fromJson round-trip', () {
      final m = _makeMember(role: MemberRole.moderator);
      final json = m.toJson();
      final restored = CellMember.fromJson(json);
      expect(restored.did, m.did);
      expect(restored.cellId, m.cellId);
      expect(restored.role, m.role);
    });

    test('copyWith updates role correctly', () {
      final m = _makeMember(role: MemberRole.member);
      final promoted = m.copyWith(role: MemberRole.moderator);
      expect(promoted.role, MemberRole.moderator);
      expect(promoted.did, m.did);
    });
  });

  // ── CellJoinRequest ───────────────────────────────────────────────────────────

  group('CellJoinRequest', () {
    test('create generates unique id', () {
      final r1 = CellJoinRequest.create(
        cellId: 'c1',
        requesterDid: 'did:test:alice',
        requesterPseudonym: 'Alice',
      );
      final r2 = CellJoinRequest.create(
        cellId: 'c1',
        requesterDid: 'did:test:bob',
        requesterPseudonym: 'Bob',
      );
      expect(r1.id, isNotEmpty);
      expect(r1.id, isNot(equals(r2.id)));
    });

    test('Default status is pending', () {
      final r = CellJoinRequest.create(
        cellId: 'c1',
        requesterDid: 'did:test:alice',
        requesterPseudonym: 'Alice',
      );
      expect(r.status, JoinRequestStatus.pending);
      expect(r.isPending, isTrue);
    });

    test('Approved request is not pending', () {
      final r = CellJoinRequest.create(
        cellId: 'c1',
        requesterDid: 'did:test:alice',
        requesterPseudonym: 'Alice',
      );
      final approved = r.copyWith(status: JoinRequestStatus.approved);
      expect(approved.isPending, isFalse);
    });

    test('Request stores message', () {
      final r = CellJoinRequest.create(
        cellId: 'c1',
        requesterDid: 'did:test:alice',
        requesterPseudonym: 'Alice',
        message: 'Ich möchte gerne beitreten.',
      );
      expect(r.message, 'Ich möchte gerne beitreten.');
    });

    test('toJson / fromJson round-trip', () {
      final r = CellJoinRequest.create(
        cellId: 'cell001',
        requesterDid: 'did:test:alice',
        requesterPseudonym: 'Alice',
        message: 'Hello',
      );
      final json = r.toJson();
      final restored = CellJoinRequest.fromJson(json);
      expect(restored.id, r.id);
      expect(restored.cellId, r.cellId);
      expect(restored.requesterDid, r.requesterDid);
      expect(restored.message, r.message);
      expect(restored.status, r.status);
    });

    test('copyWith updates status and decidedBy', () {
      final r = CellJoinRequest.create(
        cellId: 'c1',
        requesterDid: 'did:test:alice',
        requesterPseudonym: 'Alice',
      );
      final decided = r.copyWith(
        status: JoinRequestStatus.approved,
        decidedBy: 'did:test:founder',
        decidedAt: DateTime.now().toUtc(),
      );
      expect(decided.status, JoinRequestStatus.approved);
      expect(decided.decidedBy, 'did:test:founder');
      expect(decided.decidedAt, isNotNull);
    });
  });

  // ── CellType enum ─────────────────────────────────────────────────────────────

  group('CellType', () {
    test('all values serialize and deserialize via name', () {
      for (final t in CellType.values) {
        expect(
          CellType.values.firstWhere((e) => e.name == t.name),
          equals(t),
        );
      }
    });
  });

  // ── JoinPolicy enum ───────────────────────────────────────────────────────────

  group('JoinPolicy', () {
    test('all values serialize and deserialize via name', () {
      for (final p in JoinPolicy.values) {
        expect(
          JoinPolicy.values.firstWhere((e) => e.name == p.name),
          equals(p),
        );
      }
    });
  });

  // ── MinTrustLevel enum ────────────────────────────────────────────────────────

  group('MinTrustLevel', () {
    test('all values serialize and deserialize via name', () {
      for (final tl in MinTrustLevel.values) {
        expect(
          MinTrustLevel.values.firstWhere((e) => e.name == tl.name),
          equals(tl),
        );
      }
    });
  });

  // ── Dunbar's limit ────────────────────────────────────────────────────────────

  group('Dunbar limit', () {
    test('Default maxMembers is 150', () {
      final cell = Cell.create(
        name: 'Test',
        description: '',
        createdBy: 'did:test:alice',
        cellType: CellType.thematic,
      );
      expect(cell.maxMembers, 150);
    });

    test('isFull triggers at maxMembers', () {
      final cell = Cell(
        id: 'x',
        name: 'Full',
        description: '',
        createdBy: 'did:test:alice',
        createdAt: DateTime.now().toUtc(),
        cellType: CellType.thematic,
        nostrTag: 'nexus-cell-x',
        maxMembers: 5,
        memberCount: 5,
      );
      expect(cell.isFull, isTrue);
    });

    test('isFull false when one below limit', () {
      final cell = Cell(
        id: 'x',
        name: 'Almost Full',
        description: '',
        createdBy: 'did:test:alice',
        createdAt: DateTime.now().toUtc(),
        cellType: CellType.thematic,
        nostrTag: 'nexus-cell-x',
        maxMembers: 5,
        memberCount: 4,
      );
      expect(cell.isFull, isFalse);
    });
  });

  // ── cellCategories list ───────────────────────────────────────────────────────

  group('cellCategories', () {
    test('contains expected categories', () {
      expect(cellCategories, contains('Technik'));
      expect(cellCategories, contains('Umwelt'));
      expect(cellCategories, contains('Bildung'));
      expect(cellCategories, contains('Tiergerechtigkeit'));
      expect(cellCategories, contains('Ernährung'));
      expect(cellCategories, contains('Gesundheit'));
      expect(cellCategories, contains('Wohnen'));
      expect(cellCategories, contains('Kultur'));
      expect(cellCategories, contains('Wirtschaft'));
      expect(cellCategories, contains('Sonstiges'));
    });

    test('has exactly 10 categories', () {
      expect(cellCategories.length, 10);
    });
  });
}
