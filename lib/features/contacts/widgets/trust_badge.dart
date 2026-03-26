import 'package:flutter/material.dart';
import 'package:nexus_oneapp/core/contacts/contact.dart';
import 'package:nexus_oneapp/shared/theme/app_theme.dart';

/// Colored badge showing a contact's [TrustLevel].
///
/// Use [TrustBadge.small] for inline list-tile display,
/// [TrustBadge] for the detail-screen header.
class TrustBadge extends StatelessWidget {
  const TrustBadge({super.key, required this.level, this.small = false});

  final TrustLevel level;

  /// Compact mode – smaller font, no padding, fits inside a ListTile.
  final bool small;

  @override
  Widget build(BuildContext context) {
    final (color, icon) = _style(level);

    if (small) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 10, color: color),
            const SizedBox(width: 3),
            Text(
              level.label,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            level.label,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  static (Color, IconData) _style(TrustLevel level) {
    return switch (level) {
      TrustLevel.discovered => (Colors.grey, Icons.person_search_outlined),
      TrustLevel.contact    => (Colors.lightBlueAccent, Icons.person_outline),
      TrustLevel.trusted    => (AppColors.gold, Icons.verified_outlined),
      TrustLevel.guardian   => (AppColors.gold, Icons.shield_outlined),
    };
  }

  /// Returns the badge color for [level] (for external use).
  static Color colorFor(TrustLevel level) => _style(level).$1;
}
