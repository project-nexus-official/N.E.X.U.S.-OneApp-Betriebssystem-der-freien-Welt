import 'package:go_router/go_router.dart';
import 'package:nexus_oneapp/features/chat/chat_screen.dart';
import 'package:nexus_oneapp/features/governance/governance_screen.dart';
import 'package:nexus_oneapp/features/wallet/wallet_screen.dart';
import 'package:nexus_oneapp/shared/widgets/nexus_scaffold.dart';

final router = GoRouter(
  initialLocation: '/chat',
  routes: [
    ShellRoute(
      builder: (context, state, child) {
        final index = _indexForLocation(state.uri.path);
        return NexusScaffold(currentIndex: index, child: child);
      },
      routes: [
        GoRoute(
          path: '/chat',
          builder: (context, state) => const ChatScreen(),
        ),
        GoRoute(
          path: '/wallet',
          builder: (context, state) => const WalletScreen(),
        ),
        GoRoute(
          path: '/governance',
          builder: (context, state) => const GovernanceScreen(),
        ),
      ],
    ),
  ],
);

int _indexForLocation(String path) {
  if (path.startsWith('/wallet')) return 1;
  if (path.startsWith('/governance')) return 2;
  return 0;
}
