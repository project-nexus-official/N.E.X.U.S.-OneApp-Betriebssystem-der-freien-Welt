import 'package:go_router/go_router.dart';
import 'package:nexus_oneapp/core/identity/identity_service.dart';
import 'package:nexus_oneapp/features/chat/conversations_screen.dart';
import 'package:nexus_oneapp/features/contacts/contact_requests_screen.dart';
import 'package:nexus_oneapp/features/contacts/contacts_screen.dart';
import 'package:nexus_oneapp/features/contacts/qr_scanner_screen.dart';
import 'package:nexus_oneapp/features/contacts/sent_requests_screen.dart';
import 'package:nexus_oneapp/features/dashboard/dashboard_screen.dart';
import 'package:nexus_oneapp/features/discover/discover_screen.dart';
import 'package:nexus_oneapp/features/dorfplatz/dorfplatz_screen.dart';
import 'package:nexus_oneapp/features/governance/governance_screen.dart';
import 'package:nexus_oneapp/features/onboarding/onboarding_screen.dart';
import 'package:nexus_oneapp/features/invite/invite_screen.dart';
import 'package:nexus_oneapp/features/invite/redeem_screen.dart';
import 'package:nexus_oneapp/features/onboarding/principles_commitment_screen.dart';
import 'package:nexus_oneapp/features/onboarding/principles_content_screen.dart';
import 'package:nexus_oneapp/features/onboarding/principles_intro_screen.dart';
import 'package:nexus_oneapp/features/onboarding/restore_screen.dart';
import 'package:nexus_oneapp/features/profile/profile_screen.dart';
import 'package:nexus_oneapp/features/settings/settings_screen.dart';
import 'package:nexus_oneapp/features/wallet/wallet_screen.dart';
import 'package:nexus_oneapp/services/principles_service.dart';
import 'package:nexus_oneapp/shared/widgets/nexus_scaffold.dart';

final router = GoRouter(
  initialLocation: '/home',
  redirect: (context, state) {
    final hasIdentity = IdentityService.instance.hasIdentity;
    final path = state.uri.path;
    final isOnboarding = path.startsWith('/onboarding');
    final isPrinciples = path.startsWith('/principles');

    // No identity → force onboarding.
    if (!hasIdentity && !isOnboarding) return '/onboarding';

    // Identity just created / restored → check if principles flow is needed.
    if (hasIdentity && isOnboarding) {
      return PrinciplesService.instance.hasSeen ? '/home' : '/principles/intro';
    }

    // Already in the app but principles not yet seen → intercept.
    if (hasIdentity && !isOnboarding && !isPrinciples) {
      if (!PrinciplesService.instance.hasSeen) return '/principles/intro';
    }

    return null;
  },
  routes: [
    // Onboarding routes (outside ShellRoute – no bottom nav)
    GoRoute(
      path: '/onboarding',
      builder: (context, state) => const OnboardingScreen(),
      routes: [
        GoRoute(
          path: 'restore',
          builder: (context, state) => const RestoreScreen(),
        ),
      ],
    ),
    // Principles flow (outside ShellRoute – no bottom nav)
    GoRoute(
      path: '/principles/intro',
      builder: (context, state) => const PrinciplesIntroScreen(),
    ),
    GoRoute(
      path: '/principles/content',
      builder: (context, state) => const PrinciplesContentScreen(),
    ),
    GoRoute(
      path: '/principles/commitment',
      builder: (context, state) => const PrinciplesCommitmentScreen(),
    ),
    // Agora (Governance) – outside ShellRoute, no bottom nav.
    // Accessible via Dashboard card and Entdecken → Sphären.
    GoRoute(
      path: '/governance',
      builder: (context, state) => const GovernanceScreen(),
    ),
    // Settings – outside ShellRoute so it appears as a full-screen page
    // without the bottom navigation bar.
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsScreen(),
    ),
    // Contacts – outside ShellRoute (full-screen, no bottom nav)
    GoRoute(
      path: '/contacts',
      builder: (context, state) => const ContactsScreen(),
    ),
    // QR Scanner – outside ShellRoute (full-screen, no bottom nav)
    GoRoute(
      path: '/qr-scanner',
      builder: (context, state) => const QrScannerScreen(),
    ),
    // Contact requests – outside ShellRoute (full-screen, no bottom nav)
    GoRoute(
      path: '/contact-requests',
      builder: (context, state) => const ContactRequestsScreen(),
    ),
    GoRoute(
      path: '/contact-requests/sent',
      builder: (context, state) => const SentRequestsScreen(),
    ),
    // Invite – outside ShellRoute (full-screen, no bottom nav)
    GoRoute(
      path: '/invite',
      builder: (context, state) => const InviteScreen(),
    ),
    GoRoute(
      path: '/invite/redeem',
      builder: (context, state) {
        final code = state.uri.queryParameters['c'];
        return RedeemScreen(initialCode: code);
      },
    ),
    // Main app shell with bottom navigation
    ShellRoute(
      builder: (context, state, child) {
        final index = _indexForLocation(state.uri.path);
        return NexusScaffold(currentIndex: index, child: child);
      },
      routes: [
        GoRoute(
          path: '/home',
          builder: (context, state) => const DashboardScreen(),
        ),
        GoRoute(
          path: '/chat',
          builder: (context, state) {
            final tab = int.tryParse(
                  state.uri.queryParameters['tab'] ?? '',
                ) ??
                0;
            return ConversationsScreen(initialTabIndex: tab);
          },
        ),
        GoRoute(
          path: '/dorfplatz',
          builder: (context, state) => const DorfplatzScreen(),
        ),
        GoRoute(
          path: '/discover',
          builder: (context, state) => const DiscoverScreen(),
        ),
        GoRoute(
          path: '/profile',
          builder: (context, state) => const ProfileScreen(),
        ),
        // Wallet is kept as a shell route for deep-link compatibility but is
        // not in the bottom navigation bar (it is accessible as a coming-soon
        // Dashboard card once Phase 1c is implemented).
        GoRoute(
          path: '/wallet',
          builder: (context, state) => const WalletScreen(),
        ),
      ],
    ),
  ],
);

int _indexForLocation(String path) {
  if (path.startsWith('/home')) return 0;
  if (path.startsWith('/chat')) return 1;
  if (path.startsWith('/dorfplatz')) return 2;
  if (path.startsWith('/discover')) return 3;
  if (path.startsWith('/profile')) return 4;
  return 0; // default to /home (covers /wallet, /governance etc.)
}
