import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class NexusScaffold extends StatelessWidget {
  final Widget child;
  final int currentIndex;

  const NexusScaffold({
    super.key,
    required this.child,
    required this.currentIndex,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: currentIndex,
        onDestinationSelected: (index) {
          switch (index) {
            case 0:
              context.go('/chat');
            case 1:
              context.go('/wallet');
            case 2:
              context.go('/governance');
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.bluetooth),
            label: 'Chat',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_balance_wallet),
            label: 'Wallet',
          ),
          NavigationDestination(
            icon: Icon(Icons.how_to_vote),
            label: 'Governance',
          ),
        ],
      ),
    );
  }
}
