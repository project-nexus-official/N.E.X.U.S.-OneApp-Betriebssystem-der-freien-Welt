import 'package:flutter/material.dart';
import 'package:nexus_oneapp/shared/theme/app_theme.dart';

class WalletScreen extends StatelessWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AETHER Wallet')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _WalletCard(
              symbol: 'Ꝟ',
              name: 'VITA',
              subtitle: 'Fließend · Demurrage 0,5%/Monat',
              balance: '0,00',
              color: Colors.green.shade700,
            ),
            const SizedBox(height: 12),
            _WalletCard(
              symbol: '₮',
              name: 'TERRA',
              subtitle: 'Fest · Infrastruktur · Kein Demurrage',
              balance: '0,00',
              color: AppColors.deepBlue,
            ),
            const SizedBox(height: 12),
            _WalletCard(
              symbol: '₳',
              name: 'AURA',
              subtitle: 'Reputation · Nicht transferierbar',
              balance: '0',
              color: AppColors.gold,
            ),
            const SizedBox(height: 24),
            const Center(
              child: Text(
                'Phase 1c – Coming soon',
                style: TextStyle(color: Colors.grey),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WalletCard extends StatelessWidget {
  final String symbol;
  final String name;
  final String subtitle;
  final String balance;
  final Color color;

  const _WalletCard({
    required this.symbol,
    required this.name,
    required this.subtitle,
    required this.balance,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color,
          child: Text(symbol, style: const TextStyle(color: Colors.white, fontSize: 18)),
        ),
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
        trailing: Text(
          balance,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
