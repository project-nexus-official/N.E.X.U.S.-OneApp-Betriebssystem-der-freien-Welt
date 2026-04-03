import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:nexus_oneapp/core/identity/identity_service.dart';
import 'package:nexus_oneapp/core/identity/profile_service.dart';
import 'package:nexus_oneapp/features/contacts/contacts_screen.dart';
import 'package:nexus_oneapp/features/settings/settings_screen.dart';
import 'package:nexus_oneapp/shared/theme/app_theme.dart';
import 'package:nexus_oneapp/shared/widgets/identicon.dart';

// Responsive breakpoints
const double _kDesktopBreakpoint = 800;
const double _kSidebarWidth = 280;

/// Root scaffold with two-level navigation:
/// - Level 1: Bottom nav (5 tabs) on mobile/tablet; permanent sidebar on desktop
/// - Level 2: Drawer for secondary destinations, actions and settings
///
/// Tab order:  0 Home · 1 Chat · 2 Dorfplatz · 3 Entdecken · 4 Profil
class NexusScaffold extends StatelessWidget {
  final Widget child;
  final int currentIndex;

  const NexusScaffold({
    super.key,
    required this.child,
    required this.currentIndex,
  });

  void _navigate(BuildContext context, int index) {
    switch (index) {
      case 0:
        context.go('/home');
      case 1:
        context.go('/chat');
      case 2:
        context.go('/dorfplatz');
      case 3:
        context.go('/discover');
      case 4:
        context.go('/profile');
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isDesktop = width >= _kDesktopBreakpoint;

    if (isDesktop) {
      return _DesktopLayout(
        currentIndex: currentIndex,
        onNavigate: (i) => _navigate(context, i),
        child: child,
      );
    }
    return _MobileLayout(
      currentIndex: currentIndex,
      onNavigate: (i) => _navigate(context, i),
      child: child,
    );
  }
}

// ── Desktop layout ────────────────────────────────────────────────────────────

class _DesktopLayout extends StatelessWidget {
  final int currentIndex;
  final void Function(int) onNavigate;
  final Widget child;

  const _DesktopLayout({
    required this.currentIndex,
    required this.onNavigate,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: _kSidebarWidth,
            child: _DrawerContent(
              currentIndex: currentIndex,
              onNavigate: onNavigate,
              isPermanent: true,
            ),
          ),
          const VerticalDivider(
            width: 1,
            color: AppColors.surfaceVariant,
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

// ── Mobile layout ─────────────────────────────────────────────────────────────

class _MobileLayout extends StatefulWidget {
  final int currentIndex;
  final void Function(int) onNavigate;
  final Widget child;

  const _MobileLayout({
    required this.currentIndex,
    required this.onNavigate,
    required this.child,
  });

  @override
  State<_MobileLayout> createState() => _MobileLayoutState();
}

class _MobileLayoutState extends State<_MobileLayout> {
  DateTime? _lastBackPress;

  void _handleBackPress() {
    // Not on Home tab → navigate to Home instead of exiting.
    if (widget.currentIndex != 0) {
      widget.onNavigate(0);
      return;
    }
    // Already on Home tab → double-tap-to-exit pattern.
    final now = DateTime.now();
    if (_lastBackPress == null ||
        now.difference(_lastBackPress!) > const Duration(seconds: 2)) {
      _lastBackPress = now;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nochmal drücken um die App zu minimieren'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    // Second press within 2 s → move app to background (not close).
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final scaffold = Scaffold(
      drawer: Drawer(
        backgroundColor: AppColors.deepBlue,
        child: _DrawerContent(
          currentIndex: widget.currentIndex,
          onNavigate: widget.onNavigate,
          isPermanent: false,
        ),
      ),
      body: widget.child,
      bottomNavigationBar: _BottomNav(
        currentIndex: widget.currentIndex,
        onNavigate: widget.onNavigate,
      ),
    );

    // Only intercept the system back button on Android.
    // iOS has no hardware back button; desktop uses window controls.
    if (!Platform.isAndroid) return scaffold;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBackPress();
      },
      child: scaffold,
    );
  }
}

// ── Bottom navigation bar ─────────────────────────────────────────────────────

class _BottomNav extends StatelessWidget {
  final int currentIndex;
  final void Function(int) onNavigate;

  const _BottomNav({required this.currentIndex, required this.onNavigate});

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      selectedIndex: currentIndex,
      onDestinationSelected: onNavigate,
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: 'Home',
        ),
        NavigationDestination(
          icon: Icon(Icons.chat_bubble_outline),
          selectedIcon: Icon(Icons.chat_bubble),
          label: 'Chat',
        ),
        NavigationDestination(
          icon: Icon(Icons.park),
          selectedIcon: Icon(Icons.park),
          label: 'Dorfplatz',
        ),
        NavigationDestination(
          icon: Icon(Icons.explore_outlined),
          selectedIcon: Icon(Icons.explore),
          label: 'Entdecken',
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person),
          label: 'Profil',
        ),
      ],
    );
  }
}

// ── Drawer content (shared between mobile drawer and desktop sidebar) ──────────

class _DrawerContent extends StatelessWidget {
  final int currentIndex;
  final void Function(int) onNavigate;
  final bool isPermanent;

  const _DrawerContent({
    required this.currentIndex,
    required this.onNavigate,
    required this.isPermanent,
  });

  void _go(BuildContext context, int index) {
    if (!isPermanent) Navigator.of(context).pop(); // close drawer
    onNavigate(index);
  }

  void _goRoute(BuildContext context, String route) {
    if (!isPermanent) Navigator.of(context).pop();
    context.go(route);
  }

  void _snack(BuildContext context, String msg) {
    if (!isPermanent) Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _openSettings(BuildContext context) {
    if (!isPermanent) Navigator.of(context).pop(); // close drawer on mobile
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
    );
  }

  void _openContacts(BuildContext context) {
    if (!isPermanent) Navigator.of(context).pop();
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => const ContactsScreen()),
    );
  }

  Future<void> _showAbout(BuildContext context) async {
    if (!isPermanent) Navigator.of(context).pop();
    final info = await PackageInfo.fromPlatform();
    if (!context.mounted) return;
    showAboutDialog(
      context: context,
      applicationName: 'N.E.X.U.S. OneApp',
      applicationVersion: 'v${info.version}',
      applicationLegalese: '© 2026 Die Menschheitsfamilie',
      children: [
        const SizedBox(height: 12),
        const Text(
          'Ein dezentrales, zensurresistentes Protokoll für die Menschheitsfamilie.',
          style: TextStyle(color: AppColors.onDark),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final identity = IdentityService.instance.currentIdentity;
    final profile = ProfileService.instance.currentProfile;
    final pseudonym = profile?.pseudonym.value ?? 'Anonym';
    final did = identity?.did ?? '';
    final shortDid = did.length > 24
        ? '${did.substring(0, 12)}…${did.substring(did.length - 8)}'
        : did;

    return Container(
      color: AppColors.deepBlue,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          // ── Profile header ──────────────────────────────────────────────────
          DrawerHeader(
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border(
                bottom: BorderSide(color: AppColors.gold.withValues(alpha: 0.3)),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Identicon(
                  bytes: utf8.encode(did.isNotEmpty ? did : pseudonym),
                  size: 48,
                ),
                const SizedBox(height: 10),
                Text(
                  pseudonym,
                  style: const TextStyle(
                    color: AppColors.gold,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                if (shortDid.isNotEmpty)
                  Text(
                    shortDid,
                    style: const TextStyle(
                      color: AppColors.onDark,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),

          // ── Main tabs ───────────────────────────────────────────────────────
          _DrawerNavItem(
            icon: Icons.home_outlined,
            label: 'Home',
            selected: currentIndex == 0,
            onTap: () => _go(context, 0),
          ),
          _DrawerNavItem(
            icon: Icons.chat_bubble_outline,
            label: 'Chat',
            selected: currentIndex == 1,
            onTap: () => _go(context, 1),
          ),
          _DrawerNavItem(
            icon: Icons.park,
            label: 'Dorfplatz',
            selected: currentIndex == 2,
            onTap: () => _go(context, 2),
          ),
          _DrawerNavItem(
            icon: Icons.explore_outlined,
            label: 'Entdecken',
            selected: currentIndex == 3,
            onTap: () => _go(context, 3),
          ),
          _DrawerNavItem(
            icon: Icons.person_outline,
            label: 'Profil',
            selected: currentIndex == 4,
            onTap: () => _go(context, 4),
          ),
          _DrawerNavItem(
            icon: Icons.people_outline,
            label: 'Kontakte',
            selected: false,
            onTap: () => _openContacts(context),
          ),

          const Divider(color: AppColors.surfaceVariant, height: 24),

          // ── Sphären (coming soon) ───────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'SPHÄREN',
              style: TextStyle(
                color: AppColors.gold.withValues(alpha: 0.7),
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.4,
              ),
            ),
          ),
          _DrawerComingSoonItem(icon: Icons.shopping_cart_outlined, label: 'Marktplatz'),
          _DrawerComingSoonItem(icon: Icons.medical_services_outlined, label: 'Asklepios – Gesundheit & Fürsorge'),
          _DrawerComingSoonItem(icon: Icons.school_outlined, label: 'Paideia – Bildung'),
          _DrawerComingSoonItem(icon: Icons.eco_outlined, label: 'Demeter – Ernährung'),
          _DrawerComingSoonItem(icon: Icons.home_outlined, label: 'Hestia – Wohnen'),

          const Divider(color: AppColors.surfaceVariant, height: 24),

          // ── Utility actions ─────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.settings_outlined, color: AppColors.onDark),
            title: const Text('Einstellungen', style: TextStyle(color: AppColors.onDark)),
            dense: true,
            onTap: () => _openSettings(context),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline, color: AppColors.onDark),
            title: const Text('Über N.E.X.U.S.', style: TextStyle(color: AppColors.onDark)),
            dense: true,
            onTap: () => _showAbout(context),
          ),
          ListTile(
            leading: const Icon(Icons.key_outlined, color: AppColors.onDark),
            title: const Text('Seed Phrase sichern', style: TextStyle(color: AppColors.onDark)),
            dense: true,
            onTap: () => _goRoute(context, '/profile'),
          ),
          ListTile(
            leading: const Icon(Icons.upload_outlined, color: AppColors.onDark),
            title: const Text('Daten exportieren', style: TextStyle(color: AppColors.onDark)),
            dense: true,
            onTap: () => _snack(context, 'Export – Kommt bald'),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _DrawerNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _DrawerNavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: selected
            ? AppColors.gold.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: selected
            ? Border.all(color: AppColors.gold.withValues(alpha: 0.4))
            : null,
      ),
      child: ListTile(
        leading: Icon(
          icon,
          color: selected ? AppColors.gold : AppColors.onDark,
        ),
        title: Text(
          label,
          style: TextStyle(
            color: selected ? AppColors.gold : AppColors.onDark,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        dense: true,
        onTap: onTap,
      ),
    );
  }
}

class _DrawerComingSoonItem extends StatelessWidget {
  final IconData icon;
  final String label;

  const _DrawerComingSoonItem({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.45,
      child: ListTile(
        leading: Icon(icon, color: AppColors.onDark),
        title: Text(label, style: const TextStyle(color: AppColors.onDark)),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.surfaceVariant,
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Text(
            'Bald',
            style: TextStyle(color: AppColors.onDark, fontSize: 9),
          ),
        ),
        dense: true,
      ),
    );
  }
}
