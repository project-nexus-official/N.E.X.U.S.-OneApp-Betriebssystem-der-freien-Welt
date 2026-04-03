import 'package:flutter/material.dart';

class GovernanceScreen extends StatelessWidget {
  const GovernanceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Agora — Politik & Demokratie')),
      body: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.how_to_vote, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('Agora — Liquid Democracy', style: TextStyle(fontSize: 18)),
            SizedBox(height: 8),
            Text(
              'Phase 1b – Kommt bald',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
