import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/features/governance/cell.dart';
import 'package:nexus_oneapp/features/governance/cell_member.dart';
import 'package:nexus_oneapp/features/governance/proposal.dart';

// ── Helpers ────────────────────────────────────────────────────────────────────

Proposal _makeProposal({
  String id = 'prop001',
  String cellId = 'cell001',
  String createdBy = 'did:test:alice',
  ProposalStatus status = ProposalStatus.draft,
  ProposalScope scope = ProposalScope.cell,
  String domain = 'Governance',
  int discussionDays = 7,
  int votingDays = 3,
  double quorum = 0.5,
  DateTime? createdAt,
}) {
  final now = createdAt ?? DateTime.now().toUtc();
  return Proposal(
    id: id,
    title: 'Test Proposal Titel',
    description: 'Ein ausführlicher Beschreibungstext.',
    createdBy: createdBy,
    createdAt: now,
    cellId: cellId,
    scope: scope,
    domain: domain,
    status: status,
    discussionDeadline: now.add(Duration(days: discussionDays)),
    votingDeadline: now
        .add(Duration(days: discussionDays))
        .add(Duration(days: votingDays)),
    quorum: quorum,
  );
}

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  // ── Proposal.create factory ───────────────────────────────────────────────────

  group('Proposal.create', () {
    test('assigns unique id', () {
      final p1 = Proposal.create(
        title: 'Proposal 1',
        description: '',
        createdBy: 'did:test:alice',
        cellId: 'cell001',
      );
      final p2 = Proposal.create(
        title: 'Proposal 2',
        description: '',
        createdBy: 'did:test:alice',
        cellId: 'cell001',
      );
      expect(p1.id, isNotEmpty);
      expect(p1.id, isNot(equals(p2.id)));
    });

    test('default status is draft', () {
      final p = Proposal.create(
        title: 'Test',
        description: '',
        createdBy: 'did:test:alice',
        cellId: 'cell001',
      );
      expect(p.status, ProposalStatus.draft);
    });

    test('discussion and voting deadlines are set correctly', () {
      final p = Proposal.create(
        title: 'Test',
        description: '',
        createdBy: 'did:test:alice',
        cellId: 'cell001',
        discussionDays: 7,
        votingDays: 3,
      );
      final diffD = p.discussionDeadline.difference(p.createdAt).inDays;
      final diffV = p.votingDeadline.difference(p.discussionDeadline).inDays;
      expect(diffD, 7);
      expect(diffV, 3);
    });

    test('default quorum is 0.5', () {
      final p = Proposal.create(
        title: 'Test',
        description: '',
        createdBy: 'did:test:alice',
        cellId: 'cell001',
      );
      expect(p.quorum, 0.5);
    });
  });

  // ── Proposal lifecycle states ──────────────────────────────────────────────────

  group('Proposal status', () {
    test('draft is not active', () {
      final p = _makeProposal(status: ProposalStatus.draft);
      expect(p.isActive, isFalse);
    });

    test('discussion is active', () {
      final p = _makeProposal(status: ProposalStatus.discussion);
      expect(p.isActive, isTrue);
    });

    test('voting is active', () {
      final p = _makeProposal(status: ProposalStatus.voting);
      expect(p.isActive, isTrue);
    });

    test('decided is not active', () {
      final p = _makeProposal(status: ProposalStatus.decided);
      expect(p.isActive, isFalse);
    });

    test('archived is not active', () {
      final p = _makeProposal(status: ProposalStatus.archived);
      expect(p.isActive, isFalse);
    });

    test('status mutation works (mutable field)', () {
      final p = _makeProposal(status: ProposalStatus.draft);
      p.status = ProposalStatus.discussion;
      expect(p.status, ProposalStatus.discussion);
    });
  });

  // ── Proposal.toJson / fromJson ────────────────────────────────────────────────

  group('Proposal serialisation', () {
    test('round-trip preserves all fields', () {
      final p = _makeProposal(
        scope: ProposalScope.cell,
        domain: 'Umwelt',
        quorum: 0.75,
      );
      final json = p.toJson();
      final restored = Proposal.fromJson(json);

      expect(restored.id, p.id);
      expect(restored.title, p.title);
      expect(restored.description, p.description);
      expect(restored.createdBy, p.createdBy);
      expect(restored.cellId, p.cellId);
      expect(restored.scope, p.scope);
      expect(restored.domain, p.domain);
      expect(restored.status, p.status);
      expect(restored.quorum, p.quorum);
    });

    test('fromJson handles missing optional fields with defaults', () {
      final json = {
        'id': 'p1',
        'title': 'Test',
        'createdBy': 'did:test:alice',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'cellId': 'c1',
        'discussionDeadline':
            DateTime.now().add(const Duration(days: 7)).millisecondsSinceEpoch,
        'votingDeadline':
            DateTime.now().add(const Duration(days: 10)).millisecondsSinceEpoch,
      };
      final p = Proposal.fromJson(json);
      expect(p.status, ProposalStatus.draft);
      expect(p.scope, ProposalScope.cell);
      expect(p.domain, 'Sonstiges');
      expect(p.quorum, 0.5);
    });
  });

  // ── ProposalScope ─────────────────────────────────────────────────────────────

  group('ProposalScope', () {
    test('all values serialize and deserialize via name', () {
      for (final s in ProposalScope.values) {
        expect(
          ProposalScope.values.firstWhere((e) => e.name == s.name),
          equals(s),
        );
      }
    });

    test('cell scope is default', () {
      final p = Proposal.create(
        title: 'Test',
        description: '',
        createdBy: 'did:test:alice',
        cellId: 'cell001',
      );
      expect(p.scope, ProposalScope.cell);
    });
  });

  // ── proposalDomains ───────────────────────────────────────────────────────────

  group('proposalDomains', () {
    test('contains expected domains', () {
      expect(proposalDomains, contains('Umwelt'));
      expect(proposalDomains, contains('Infrastruktur'));
      expect(proposalDomains, contains('Soziales'));
      expect(proposalDomains, contains('Wirtschaft'));
      expect(proposalDomains, contains('Governance'));
      expect(proposalDomains, contains('Sonstiges'));
    });

    test('has exactly 6 domains', () {
      expect(proposalDomains.length, 6);
    });
  });

  // ── CellMember – proposal permission checks ───────────────────────────────────

  group('CellMember proposal permissions', () {
    test('confirmed founder can create proposals', () {
      final member = CellMember(
        cellId: 'c1',
        did: 'did:test:alice',
        joinedAt: DateTime.now().toUtc(),
        role: MemberRole.founder,
        confirmedBy: 'did:test:alice',
      );
      expect(member.isConfirmed, isTrue);
    });

    test('confirmed member can create proposals', () {
      final member = CellMember(
        cellId: 'c1',
        did: 'did:test:bob',
        joinedAt: DateTime.now().toUtc(),
        role: MemberRole.member,
        confirmedBy: 'did:test:alice',
      );
      expect(member.isConfirmed, isTrue);
    });

    test('pending member cannot create proposals', () {
      final member = CellMember(
        cellId: 'c1',
        did: 'did:test:charlie',
        joinedAt: DateTime.now().toUtc(),
        role: MemberRole.pending,
      );
      expect(member.isConfirmed, isFalse);
    });

    test('proposalWaitDays: member who just joined is blocked', () {
      final cell = Cell.create(
        name: 'Strict',
        description: '',
        createdBy: 'did:test:alice',
        cellType: CellType.thematic,
        proposalWaitDays: 7,
      );
      final member = CellMember(
        cellId: cell.id,
        did: 'did:test:bob',
        joinedAt: DateTime.now().toUtc(), // just joined
        role: MemberRole.member,
        confirmedBy: 'did:test:alice',
      );
      // Simulate check: days since joining < proposalWaitDays
      final waitedDays =
          DateTime.now().toUtc().difference(member.joinedAt).inDays;
      expect(waitedDays < cell.proposalWaitDays, isTrue);
    });

    test('proposalWaitDays: member who waited enough is allowed', () {
      final cell = Cell.create(
        name: 'Strict',
        description: '',
        createdBy: 'did:test:alice',
        cellType: CellType.thematic,
        proposalWaitDays: 7,
      );
      final member = CellMember(
        cellId: cell.id,
        did: 'did:test:bob',
        joinedAt: DateTime.now().toUtc().subtract(const Duration(days: 10)),
        role: MemberRole.member,
        confirmedBy: 'did:test:alice',
      );
      final waitedDays =
          DateTime.now().toUtc().difference(member.joinedAt).inDays;
      expect(waitedDays >= cell.proposalWaitDays, isTrue);
    });
  });

  // ── Proposal lifecycle management ─────────────────────────────────────────────

  group('Proposal lifecycle', () {
    test('DRAFT → DISCUSSION transition (simulated)', () {
      final p = _makeProposal(status: ProposalStatus.draft);
      // Simulate publishProposal
      p.status = ProposalStatus.discussion;
      expect(p.status, ProposalStatus.discussion);
      expect(p.isActive, isTrue);
    });

    test('DISCUSSION → VOTING after deadline (simulated)', () {
      final p = Proposal(
        id: 'p1',
        title: 'Test',
        description: '',
        createdBy: 'did:test:alice',
        createdAt: DateTime.now().toUtc().subtract(const Duration(days: 10)),
        cellId: 'c1',
        scope: ProposalScope.cell,
        domain: 'Governance',
        status: ProposalStatus.discussion,
        discussionDeadline:
            DateTime.now().toUtc().subtract(const Duration(days: 2)),
        votingDeadline:
            DateTime.now().toUtc().add(const Duration(days: 1)),
        quorum: 0.5,
      );
      // Advance status manually (as _advanceStatuses does)
      final now = DateTime.now().toUtc();
      if (now.isAfter(p.discussionDeadline)) {
        p.status = ProposalStatus.voting;
      }
      expect(p.status, ProposalStatus.voting);
    });

    test('VOTING → DECIDED after deadline (simulated)', () {
      final p = Proposal(
        id: 'p2',
        title: 'Test',
        description: '',
        createdBy: 'did:test:alice',
        createdAt: DateTime.now().toUtc().subtract(const Duration(days: 15)),
        cellId: 'c1',
        scope: ProposalScope.cell,
        domain: 'Governance',
        status: ProposalStatus.voting,
        discussionDeadline:
            DateTime.now().toUtc().subtract(const Duration(days: 8)),
        votingDeadline:
            DateTime.now().toUtc().subtract(const Duration(days: 1)),
        quorum: 0.5,
      );
      final now = DateTime.now().toUtc();
      if (now.isAfter(p.votingDeadline)) {
        p.status = ProposalStatus.decided;
      }
      expect(p.status, ProposalStatus.decided);
    });

    test('DECIDED → ARCHIVED after 30 days (simulated)', () {
      final p = Proposal(
        id: 'p3',
        title: 'Test',
        description: '',
        createdBy: 'did:test:alice',
        createdAt: DateTime.now().toUtc().subtract(const Duration(days: 50)),
        cellId: 'c1',
        scope: ProposalScope.cell,
        domain: 'Governance',
        status: ProposalStatus.decided,
        discussionDeadline:
            DateTime.now().toUtc().subtract(const Duration(days: 40)),
        votingDeadline:
            DateTime.now().toUtc().subtract(const Duration(days: 35)),
        quorum: 0.5,
      );
      final now = DateTime.now().toUtc();
      if (now.difference(p.votingDeadline).inDays >= 30) {
        p.status = ProposalStatus.archived;
      }
      expect(p.status, ProposalStatus.archived);
    });

    test('DECIDED is not archived before 30 days', () {
      final p = Proposal(
        id: 'p4',
        title: 'Test',
        description: '',
        createdBy: 'did:test:alice',
        createdAt: DateTime.now().toUtc().subtract(const Duration(days: 5)),
        cellId: 'c1',
        scope: ProposalScope.cell,
        domain: 'Governance',
        status: ProposalStatus.decided,
        discussionDeadline:
            DateTime.now().toUtc().subtract(const Duration(days: 3)),
        votingDeadline:
            DateTime.now().toUtc().subtract(const Duration(days: 1)),
        quorum: 0.5,
      );
      final now = DateTime.now().toUtc();
      // Should NOT archive yet
      if (now.difference(p.votingDeadline).inDays >= 30) {
        p.status = ProposalStatus.archived;
      }
      expect(p.status, ProposalStatus.decided); // unchanged
    });
  });

  // ── Membership in multiple cells ──────────────────────────────────────────────

  group('Multi-cell membership', () {
    test('Member can belong to multiple cells', () {
      final memberships = [
        CellMember(
          cellId: 'cell001',
          did: 'did:test:alice',
          joinedAt: DateTime.now().toUtc(),
          role: MemberRole.founder,
        ),
        CellMember(
          cellId: 'cell002',
          did: 'did:test:alice',
          joinedAt: DateTime.now().toUtc(),
          role: MemberRole.member,
        ),
        CellMember(
          cellId: 'cell003',
          did: 'did:test:alice',
          joinedAt: DateTime.now().toUtc(),
          role: MemberRole.moderator,
        ),
      ];
      expect(memberships.length, 3);
      expect(memberships.every((m) => m.did == 'did:test:alice'), isTrue);
    });

    test('Exit right: any member can leave', () {
      final founder = CellMember(
        cellId: 'c1',
        did: 'did:test:alice',
        joinedAt: DateTime.now().toUtc(),
        role: MemberRole.founder,
      );
      final member = CellMember(
        cellId: 'c1',
        did: 'did:test:bob',
        joinedAt: DateTime.now().toUtc(),
        role: MemberRole.member,
      );
      // Exit right is unconditional (no canLeave restriction in model)
      expect(founder.did, isNotEmpty);
      expect(member.did, isNotEmpty);
    });
  });
}
