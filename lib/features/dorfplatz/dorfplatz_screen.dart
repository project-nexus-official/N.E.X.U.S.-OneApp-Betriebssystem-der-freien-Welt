import 'package:flutter/material.dart';
import 'package:nexus_oneapp/shared/theme/app_theme.dart';

/// Placeholder screen for the Dorfplatz (community feed) feature.
/// The real social feed will be built in a subsequent step.
class DorfplatzScreen extends StatelessWidget {
  const DorfplatzScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dorfplatz')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.park,
                size: 80,
                color: AppColors.gold.withValues(alpha: 0.55),
              ),
              const SizedBox(height: 24),
              const Text(
                'Der Dorfplatz kommt gleich',
                style: TextStyle(
                  color: AppColors.gold,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                'Hier teilst du Beiträge mit deiner Gemeinschaft. '
                'Ohne Algorithmus, ohne Werbung, ohne Konzern.',
                style: TextStyle(
                  color: AppColors.onDark.withValues(alpha: 0.7),
                  fontSize: 15,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
