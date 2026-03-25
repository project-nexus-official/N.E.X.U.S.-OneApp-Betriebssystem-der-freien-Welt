import 'package:go_router/go_router.dart';
import 'package:nexus_oneapp/core/identity/identity_service.dart';
import 'package:nexus_oneapp/features/chat/conversations_screen.dart';
import 'package:nexus_oneapp/features/discover/discover_screen.dart';
import 'package:nexus_oneapp/features/governance/governance_screen.dart';
import 'package:nexus_oneapp/features/onboarding/onboarding_screen.dart';
import 'package:nexus_oneapp/features/onboarding/restore_screen.dart';
import 'package:nexus_oneapp/features/profile/profile_screen.dart';
import 'package:nexus_oneapp/features/settings/settings_screen.dart';
import 'package:nexus_oneapp/features/wallet/wallet_screen.dart';
import 'package:nexus_oneapp/shared/widgets/nexus_scaffold.dart';

final router = GoRouter(
  initialLocation: '/chat',
  redirect: (context, state) {
    final hasIdentity = IdentityService.instance.hasIdentity;
    final isOnboarding = state.uri.path.startsWith('/onboarding');

    if (!hasIdentity && !isOnboarding) {
      return '/onboarding';
    }
    if (hasIdentity && isOnboarding) {
      return '/chat';
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
    // Main app shell with bottom navigation
    ShellRoute(
      builder: (context, state, child) {
        final index = _indexForLocation(state.uri.path);
        return NexusScaffold(currentIndex: index, child: child);
      },
      routes: [
        GoRoute(
          path: '/chat',
          builder: (context, state) => const ConversationsScreen(),
        ),
        GoRoute(
          path: '/governance',
          builder: (context, state) => const GovernanceScreen(),
        ),
        GoRoute(
          path: '/discover',
          builder: (context, state) => const DiscoverScreen(),
        ),
        GoRoute(
          path: '/wallet',
          builder: (context, state) => const WalletScreen(),
        ),
        GoRoute(
          path: '/profile',
          builder: (context, state) => const ProfileScreen(),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => const SettingsScreen(),
        ),
      ],
    ),
  ],
);

int _indexForLocation(String path) {
  if (path.startsWith('/governance')) return 1;
  if (path.startsWith('/discover')) return 2;
  if (path.startsWith('/wallet')) return 3;
  if (path.startsWith('/profile')) return 4;
  return 0; // /chat
}
