import 'package:flutter/material.dart';

import '../../services/help_texts.dart';
import '../theme/app_theme.dart';

/// A small ℹ info icon that opens a contextual help bottom-sheet on tap.
///
/// Usage:
///   HelpIcon(contextId: 'agora_general')
///   HelpIcon(contextId: 'cell_bulletin', size: 16)
class HelpIcon extends StatelessWidget {
  final String contextId;
  final double size;

  const HelpIcon({
    super.key,
    required this.contextId,
    this.size = 18,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showHelp(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Icon(
          Icons.info_outline,
          size: size,
          color: AppColors.gold.withValues(alpha: 0.7),
        ),
      ),
    );
  }

  void _showHelp(BuildContext context) {
    final entry = HelpTexts.get(contextId);
    final height = MediaQuery.sizeOf(context).height * 0.55;
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SizedBox(
        height: height,
        child: _HelpSheet(entry: entry),
      ),
    );
  }
}

class _HelpSheet extends StatelessWidget {
  final HelpEntry entry;
  const _HelpSheet({required this.entry});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Handle bar
        Center(
          child: Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.info_outline,
                        color: AppColors.gold, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        entry.title,
                        style: const TextStyle(
                          color: AppColors.gold,
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  entry.body,
                  style: TextStyle(
                    color: AppColors.onDark.withValues(alpha: 0.85),
                    fontSize: 15,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.gold,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text('Verstanden',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      ],
    );
  }
}
