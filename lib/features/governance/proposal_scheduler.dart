import 'dart:async';

import 'package:flutter/widgets.dart';

import 'proposal.dart';
import 'proposal_service.dart';

/// Drives automatic proposal status transitions on a 5-minute timer and on
/// app-resume.
///
/// Transitions handled:
///   VOTING       → VOTING_ENDED  when [Proposal.votingEndsAt] has passed
///   VOTING_ENDED → DECIDED       when grace period ([Proposal.gracePeriodHours]) has passed
///   DECIDED      → ARCHIVED      after 30 days
///
/// Usage:
///   final scheduler = ProposalScheduler(ProposalService.instance);
///   scheduler.start();   // in initServicesAfterIdentity()
///   scheduler.stop();    // on logout / app dispose
class ProposalScheduler with WidgetsBindingObserver {
  final ProposalService proposalService;

  Timer? _timer;
  bool _running = false;

  ProposalScheduler(this.proposalService);

  void start() {
    if (_running) return;
    _running = true;
    print('[PROPOSAL] Scheduler starting');
    WidgetsBinding.instance.addObserver(this);
    // Immediate first check.
    _checkAllProposals();
    // Then every 5 minutes.
    _timer = Timer.periodic(const Duration(minutes: 5), (_) {
      _checkAllProposals();
    });
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
    print('[PROPOSAL] Scheduler stopped');
  }

  /// Manually trigger a check – called after app-resume or a network reconnect.
  Future<void> triggerCheck() async {
    print('[PROPOSAL] Scheduler manual trigger');
    await _checkAllProposals();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      print('[PROPOSAL] App resumed — triggering scheduler check');
      triggerCheck();
    }
  }

  Future<void> _checkAllProposals() async {
    final now = DateTime.now().toUtc();
    final proposals = proposalService.getAllProposalsForScheduler();
    print('[PROPOSAL] Scheduler checking ${proposals.length} proposals');

    for (final p in proposals) {
      try {
        // VOTING → VOTING_ENDED
        if (p.status == ProposalStatus.VOTING &&
            p.votingEndsAt != null &&
            now.isAfter(p.votingEndsAt!)) {
          await proposalService.processGracePeriodStart(p.id);
        }

        // VOTING_ENDED → DECIDED (after grace period)
        if (p.status == ProposalStatus.VOTING_ENDED &&
            p.votingEndsAt != null) {
          final graceEnd = p.votingEndsAt!
              .add(Duration(hours: p.gracePeriodHours));
          if (now.isAfter(graceEnd)) {
            await proposalService.finalizeProposal(p.id);
          }
        }

        // DECIDED → ARCHIVED (after 30 days)
        if (p.status == ProposalStatus.DECIDED && p.decidedAt != null) {
          if (now.difference(p.decidedAt!).inDays >= 30) {
            await proposalService.archiveProposal(p.id);
          }
        }
      } catch (e) {
        print('[PROPOSAL] Scheduler error for ${p.id}: $e');
      }
    }
  }
}
