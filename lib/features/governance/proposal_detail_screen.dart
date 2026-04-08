import 'dart:async';

import 'package:flutter/material.dart';

import '../../shared/theme/app_theme.dart';
import 'proposal.dart';
import 'proposal_service.dart';

/// Full detail view of a proposal.
///
/// Shows title, description, status timeline, and voting placeholder (G2).
class ProposalDetailScreen extends StatefulWidget {
  final Proposal proposal;
  const ProposalDetailScreen({super.key, required this.proposal});

  @override
  State<ProposalDetailScreen> createState() => _ProposalDetailScreenState();
}

class _ProposalDetailScreenState extends State<ProposalDetailScreen> {
  StreamSubscription<void>? _sub;
  late Proposal _proposal;

  @override
  void initState() {
    super.initState();
    _proposal = widget.proposal;
    _sub = ProposalService.instance.stream.listen((_) {
      if (mounted) {
        setState(() {
          _proposal = ProposalService.instance.allProposals
              .firstWhere((p) => p.id == _proposal.id,
                  orElse: () => _proposal);
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Antrag'),
        backgroundColor: AppColors.deepBlue,
        actions: [
          _PublishButton(proposal: _proposal),
        ],
      ),
      backgroundColor: AppColors.deepBlue,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Status badges
          Row(
            children: [
              _StatusBadge(status: _proposal.status),
              const SizedBox(width: 8),
              _ScopeBadge(scope: _proposal.scope),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _proposal.domain,
                  style: TextStyle(
                    color: AppColors.onDark.withValues(alpha: 0.7),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Title
          Text(
            _proposal.title,
            style: const TextStyle(
              color: AppColors.onDark,
              fontSize: 20,
              fontWeight: FontWeight.bold,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 8),

          // Description
          if (_proposal.description.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _proposal.description,
                style: TextStyle(
                  color: AppColors.onDark.withValues(alpha: 0.85),
                  height: 1.6,
                ),
              ),
            ),
          const SizedBox(height: 20),

          // Timeline
          _Timeline(proposal: _proposal),
          const SizedBox(height: 20),

          // Voting placeholder (G2)
          if (_proposal.status == ProposalStatus.VOTING)
            _VotingPlaceholder()
          else if (_proposal.status == ProposalStatus.DISCUSSION)
            _DiscussionBanner(proposal: _proposal),

          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

// ── Publish button (for drafts) ───────────────────────────────────────────────

class _PublishButton extends StatelessWidget {
  final Proposal proposal;
  const _PublishButton({required this.proposal});

  @override
  Widget build(BuildContext context) {
    if (proposal.status != ProposalStatus.DRAFT) return const SizedBox.shrink();
    return TextButton(
      onPressed: () async {
        await ProposalService.instance.publishProposal(proposal.id);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Antrag veröffentlicht!'),
              backgroundColor: Colors.green,
            ),
          );
        }
      },
      child: const Text(
        'Veröffentlichen',
        style: TextStyle(color: AppColors.gold, fontWeight: FontWeight.bold),
      ),
    );
  }
}

// ── Timeline ──────────────────────────────────────────────────────────────────

class _Timeline extends StatelessWidget {
  final Proposal proposal;
  const _Timeline({required this.proposal});

  @override
  Widget build(BuildContext context) {
    final p = proposal;
    final status = p.status;
    final events = <_TimelineEvent>[];

    // ── Erstellt (always) ─────────────────────────────────────────────────────
    events.add(_TimelineEvent(label: 'Erstellt', date: p.createdAt, done: true));

    if (status == ProposalStatus.WITHDRAWN) {
      // WITHDRAWN: show withdrawnAt if available
      if (p.withdrawnAt != null) {
        events.add(_TimelineEvent(
            label: 'Zurückgezogen', date: p.withdrawnAt!, done: true));
      }
    } else if (status == ProposalStatus.DRAFT) {
      // DRAFT: nothing further
    } else if (status == ProposalStatus.DISCUSSION) {
      events.add(_TimelineEvent(
          label: 'Diskussion läuft',
          date: p.discussionStartedAt ?? p.createdAt,
          done: false));
    } else if (status == ProposalStatus.VOTING) {
      if (p.votingStartedAt != null) {
        events.add(_TimelineEvent(
            label: 'Abstimmung gestartet',
            date: p.votingStartedAt!,
            done: true));
      }
      if (p.votingEndsAt != null) {
        events.add(_TimelineEvent(
            label: 'Abstimmung endet', date: p.votingEndsAt!, done: false));
      }
    } else if (status == ProposalStatus.VOTING_ENDED) {
      if (p.votingEndsAt != null) {
        events.add(_TimelineEvent(
            label: 'Abstimmung beendet', date: p.votingEndsAt!, done: true));
      }
      events.add(_TimelineEvent(
          label: 'Grace Period läuft',
          date: p.votingEndsAt ?? p.createdAt,
          done: false));
    } else if (status == ProposalStatus.DECIDED) {
      if (p.votingEndsAt != null) {
        events.add(_TimelineEvent(
            label: 'Abstimmung beendet', date: p.votingEndsAt!, done: true));
      }
      if (p.decidedAt != null) {
        events.add(_TimelineEvent(
            label: 'Entschieden', date: p.decidedAt!, done: true));
      }
    } else if (status == ProposalStatus.ARCHIVED) {
      if (p.decidedAt != null) {
        events.add(_TimelineEvent(
            label: 'Entschieden', date: p.decidedAt!, done: true));
      }
      if (p.archivedAt != null) {
        events.add(
            _TimelineEvent(label: 'Archiviert', date: p.archivedAt!, done: true));
      }
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Zeitplan',
            style: TextStyle(
              color: AppColors.onDark.withValues(alpha: 0.7),
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 12),
          ...events.map((e) => _TimelineRow(event: e)),
        ],
      ),
    );
  }
}

class _TimelineEvent {
  final String label;
  final DateTime date;
  final bool done;
  const _TimelineEvent(
      {required this.label, required this.date, required this.done});
}

class _TimelineRow extends StatelessWidget {
  final _TimelineEvent event;
  const _TimelineRow({required this.event});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(
            event.done ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 16,
            color: event.done ? Colors.green : AppColors.surfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              event.label,
              style: TextStyle(
                color: event.done ? AppColors.onDark : AppColors.onDark.withValues(alpha: 0.6),
                fontSize: 13,
              ),
            ),
          ),
          Text(
            _formatDate(event.date),
            style: TextStyle(
              color: AppColors.onDark.withValues(alpha: 0.5),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
  }
}

// ── Voting placeholder ────────────────────────────────────────────────────────

class _VotingPlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Text(
            'Abstimmung (G2)',
            style: const TextStyle(
              color: AppColors.gold,
              fontWeight: FontWeight.bold,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Liquid Democracy Abstimmung kommt in Version G2.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.onDark.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: null,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.green),
                    foregroundColor: Colors.green,
                  ),
                  child: const Text('Ja'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: null,
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: AppColors.surfaceVariant),
                    foregroundColor: AppColors.surfaceVariant,
                  ),
                  child: const Text('Enthaltung'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: null,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.red),
                    foregroundColor: Colors.red,
                  ),
                  child: const Text('Nein'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Discussion banner ─────────────────────────────────────────────────────────

class _DiscussionBanner extends StatelessWidget {
  final Proposal proposal;
  const _DiscussionBanner({required this.proposal});

  @override
  Widget build(BuildContext context) {
    final deadlineDate = proposal.discussionStartedAt?.add(const Duration(days: 7)) ??
        DateTime.now().toUtc().add(const Duration(days: 7));
    final remaining = deadlineDate.difference(DateTime.now().toUtc());
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.forum_outlined, color: Colors.blue),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              remaining.isNegative
                  ? 'Diskussionsphase abgelaufen'
                  : 'Noch ${remaining.inDays}d ${remaining.inHours % 24}h für Diskussion',
              style: const TextStyle(color: Colors.blue),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Reused badge widgets ──────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final ProposalStatus status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      ProposalStatus.DRAFT => ('Entwurf', AppColors.onDark),
      ProposalStatus.DISCUSSION => ('Diskussion', Colors.blue),
      ProposalStatus.VOTING => ('Abstimmung', Colors.orange),
      ProposalStatus.VOTING_ENDED => ('Abgestimmt', Colors.deepOrange),
      ProposalStatus.DECIDED => ('Entschieden', Colors.green),
      ProposalStatus.ARCHIVED => ('Archiviert', AppColors.surfaceVariant),
      ProposalStatus.WITHDRAWN => ('Zurückgezogen', AppColors.surfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _ScopeBadge extends StatelessWidget {
  final ProposalScope scope;
  const _ScopeBadge({required this.scope});

  @override
  Widget build(BuildContext context) {
    if (scope == ProposalScope.cell) return const SizedBox.shrink();
    final label =
        scope == ProposalScope.federation ? 'Föderation' : 'Global';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.gold.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: AppColors.gold,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
