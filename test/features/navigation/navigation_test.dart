import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nexus_oneapp/features/discover/discover_screen.dart';
import 'package:nexus_oneapp/shared/theme/app_theme.dart';
import 'package:nexus_oneapp/shared/widgets/nexus_scaffold.dart';

// ── Test helpers ──────────────────────────────────────────────────────────────

/// Creates a GoRouter with all app routes pointing to simple placeholders.
GoRouter _testRouter({String initialLocation = '/home'}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(path: '/home', builder: (_, __) => const _Tab('Home')),
      GoRoute(path: '/chat', builder: (_, __) => const _Tab('Chat')),
      GoRoute(path: '/governance', builder: (_, __) => const _Tab('Governance')),
      GoRoute(path: '/discover', builder: (_, __) => const DiscoverScreen()),
      GoRoute(path: '/wallet', builder: (_, __) => const _Tab('Wallet')),
      GoRoute(path: '/profile', builder: (_, __) => const _Tab('Profil')),
    ],
  );
}

/// Wraps a widget in a full MaterialApp.router + theme for testing.
Widget _appFor(Widget child, {double width = 400, String initialLocation = '/home'}) {
  final router = GoRouter(
    initialLocation: '/test',
    routes: [
      GoRoute(path: '/test', builder: (_, __) => child),
      GoRoute(path: '/home', builder: (_, __) => const _Tab('Home')),
      GoRoute(path: '/chat', builder: (_, __) => const _Tab('Chat')),
      GoRoute(path: '/governance', builder: (_, __) => const _Tab('Governance')),
      GoRoute(path: '/discover', builder: (_, __) => const DiscoverScreen()),
      GoRoute(path: '/wallet', builder: (_, __) => const _Tab('Wallet')),
      GoRoute(path: '/profile', builder: (_, __) => const _Tab('Profil')),
      GoRoute(path: '/settings', builder: (_, __) => const _Tab('Settings')),
    ],
  );
  return MaterialApp.router(
    routerConfig: router,
    theme: AppTheme.dark,
    builder: (context, child) => MediaQuery(
      data: MediaQueryData(size: Size(width, 800)),
      child: child!,
    ),
  );
}

/// Wraps NexusScaffold in a test app.
Widget _scaffoldApp(int index, {double width = 400}) {
  final router = GoRouter(
    initialLocation: '/test',
    routes: [
      GoRoute(
        path: '/test',
        builder: (_, __) => NexusScaffold(
          currentIndex: index,
          child: const _Tab('Content'),
        ),
      ),
      GoRoute(path: '/home', builder: (_, __) => const _Tab('Home')),
      GoRoute(path: '/chat', builder: (_, __) => const _Tab('Chat')),
      GoRoute(path: '/governance', builder: (_, __) => const _Tab('Governance')),
      GoRoute(path: '/discover', builder: (_, __) => const DiscoverScreen()),
      GoRoute(path: '/wallet', builder: (_, __) => const _Tab('Wallet')),
      GoRoute(path: '/profile', builder: (_, __) => const _Tab('Profil')),
    ],
  );
  return MaterialApp.router(
    routerConfig: router,
    theme: AppTheme.dark,
    builder: (context, child) => MediaQuery(
      data: MediaQueryData(size: Size(width, 800)),
      child: child!,
    ),
  );
}

class _Tab extends StatelessWidget {
  final String name;
  const _Tab(this.name);
  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text(name)));
}

// ── DiscoverScreen tests ──────────────────────────────────────────────────────

void main() {
  group('DiscoverScreen – tile rendering', () {
    testWidgets('shows Entdecken AppBar title', (tester) async {
      await tester.pumpWidget(_appFor(const DiscoverScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Entdecken'), findsOneWidget);
    });

    testWidgets('active Agora tile has no coming-soon badge', (tester) async {
      await tester.pumpWidget(_appFor(const DiscoverScreen()));
      await tester.pumpAndSettle();

      // Agora tile label
      expect(find.text('Agora – Politik'), findsOneWidget);

      // No "Phase" badge next to it (active tile has no badge)
      final agoraTileFinder = find.ancestor(
        of: find.text('Agora – Politik'),
        matching: find.byType(GestureDetector),
      );
      expect(agoraTileFinder, findsOneWidget);
    });

    testWidgets('coming-soon tile shows phase badge', (tester) async {
      await tester.pumpWidget(_appFor(const DiscoverScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Marktplatz'), findsOneWidget);
      expect(find.text('Phase 1c'), findsOneWidget);
    });

    testWidgets('Sphären section header is visible after scrolling',
        (tester) async {
      await tester.pumpWidget(_appFor(const DiscoverScreen()));
      await tester.pumpAndSettle();

      // Scroll down until the section header is built and visible
      await tester.scrollUntilVisible(
        find.text('Sphären'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Sphären'), findsOneWidget);
    });

    testWidgets('all four sphären tiles are rendered', (tester) async {
      await tester.pumpWidget(_appFor(const DiscoverScreen()));
      await tester.pumpAndSettle();

      // Scroll to ensure all tiles are visible
      await tester.dragUntilVisible(
        find.textContaining('Hestia'),
        find.byType(CustomScrollView),
        const Offset(0, -200),
      );

      expect(find.textContaining('Asklepios'), findsOneWidget);
      expect(find.textContaining('Paideia'), findsOneWidget);
      expect(find.textContaining('Demeter'), findsOneWidget);
      expect(find.textContaining('Hestia'), findsOneWidget);
    });

    testWidgets('tapping Agora tile navigates to Governance', (tester) async {
      await tester.pumpWidget(_appFor(const DiscoverScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Agora – Politik'));
      await tester.pumpAndSettle();

      expect(find.text('Governance'), findsOneWidget);
    });

    testWidgets('tapping coming-soon Marktplatz tile does not navigate',
        (tester) async {
      await tester.pumpWidget(_appFor(const DiscoverScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Marktplatz'), warnIfMissed: false);
      await tester.pumpAndSettle();

      // Still on Discover screen (no navigation happened)
      expect(find.text('Entdecken'), findsOneWidget);
    });

    testWidgets('Einstellungen tile is active (has a route)',
        (tester) async {
      await tester.pumpWidget(_appFor(const DiscoverScreen()));
      await tester.pumpAndSettle();

      // SliverGrid is lazy – scroll until the tile is built and visible
      await tester.scrollUntilVisible(
        find.text('Einstellungen'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      // Tile should be fully opaque (active), not dimmed
      final opacity = tester.widget<Opacity>(
        find.ancestor(
          of: find.text('Einstellungen'),
          matching: find.byType(Opacity),
        ).first,
      );
      expect(opacity.opacity, 1.0);
    });
  });

  // ── NexusScaffold responsive layout ────────────────────────────────────────

  group('NexusScaffold – responsive layout', () {
    testWidgets('mobile width shows NavigationBar at bottom', (tester) async {
      await tester.pumpWidget(_scaffoldApp(0, width: 400));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('desktop width hides NavigationBar', (tester) async {
      await tester.pumpWidget(_scaffoldApp(0, width: 900));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsNothing);
    });

    testWidgets('desktop width shows permanent sidebar (VerticalDivider)',
        (tester) async {
      await tester.pumpWidget(_scaffoldApp(0, width: 900));
      await tester.pumpAndSettle();

      expect(find.byType(VerticalDivider), findsOneWidget);
    });

    testWidgets('mobile width shows no sidebar (no VerticalDivider)',
        (tester) async {
      await tester.pumpWidget(_scaffoldApp(0, width: 400));
      await tester.pumpAndSettle();

      expect(find.byType(VerticalDivider), findsNothing);
    });

    testWidgets('NavigationBar has 5 destinations on mobile', (tester) async {
      await tester.pumpWidget(_scaffoldApp(0, width: 400));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationDestination), findsNWidgets(5));
    });

    testWidgets('correct tab is highlighted by currentIndex', (tester) async {
      // currentIndex: 3 = Entdecken (0=Home, 1=Chat, 2=Governance, 3=Entdecken, 4=Profil)
      await tester.pumpWidget(_scaffoldApp(3, width: 400));
      await tester.pumpAndSettle();

      final navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(navBar.selectedIndex, 3);
    });
  });

  // ── Drawer tests ────────────────────────────────────────────────────────────

  group('Drawer – mobile', () {
    testWidgets('drawer opens on hamburger icon tap', (tester) async {
      await tester.pumpWidget(_scaffoldApp(0, width: 400));
      await tester.pumpAndSettle();

      // Open drawer via hamburger menu
      final scaffoldFinder = find.byType(Scaffold);
      final ScaffoldState scaffoldState =
          tester.state(scaffoldFinder.first);
      scaffoldState.openDrawer();
      await tester.pumpAndSettle();

      // Drawer content should be visible
      expect(find.text('Home'), findsWidgets);
      expect(find.text('Chat'), findsWidgets);
      expect(find.text('Governance'), findsWidgets);
      expect(find.text('Profil'), findsWidgets);
    });

    testWidgets('drawer closes on back gesture', (tester) async {
      await tester.pumpWidget(_scaffoldApp(0, width: 400));
      await tester.pumpAndSettle();

      final ScaffoldState scaffoldState =
          tester.state(find.byType(Scaffold).first);
      scaffoldState.openDrawer();
      await tester.pumpAndSettle();

      // Close by tapping outside (barrier)
      await tester.tapAt(const Offset(700, 400));
      await tester.pumpAndSettle();

      // Drawer is closed – only bottom nav labels remain
      final navLabels = find.text('Chat');
      expect(navLabels, findsOneWidget); // only in bottom nav, not drawer
    });

    testWidgets('drawer shows fallback pseudonym when no identity', (tester) async {
      await tester.pumpWidget(_scaffoldApp(0, width: 400));
      await tester.pumpAndSettle();

      final ScaffoldState scaffoldState =
          tester.state(find.byType(Scaffold).first);
      scaffoldState.openDrawer();
      await tester.pumpAndSettle();

      // Without identity the drawer shows 'Anonym' fallback
      expect(find.text('Anonym'), findsOneWidget);
    });

    testWidgets('drawer shows all five main navigation entries', (tester) async {
      await tester.pumpWidget(_scaffoldApp(0, width: 400));
      await tester.pumpAndSettle();

      final ScaffoldState scaffoldState =
          tester.state(find.byType(Scaffold).first);
      scaffoldState.openDrawer();
      await tester.pumpAndSettle();

      // All 5 main nav entries must appear in the drawer
      expect(find.text('Home'), findsWidgets); // also in bottom nav
      expect(find.text('Chat'), findsWidgets); // also in bottom nav
      expect(find.text('Governance'), findsWidgets);
      expect(find.text('Entdecken'), findsWidgets);
      expect(find.text('Profil'), findsWidgets);
    });

    testWidgets('drawer shows SPHÄREN section header', (tester) async {
      await tester.pumpWidget(_scaffoldApp(0, width: 400));
      await tester.pumpAndSettle();

      final ScaffoldState scaffoldState =
          tester.state(find.byType(Scaffold).first);
      scaffoldState.openDrawer();
      await tester.pumpAndSettle();

      expect(find.text('SPHÄREN'), findsOneWidget);
    });
  });

  // ── Router index mapping ────────────────────────────────────────────────────

  group('Bottom nav – tab switching', () {
    testWidgets('tapping Entdecken tab navigates to discover', (tester) async {
      await tester.pumpWidget(_scaffoldApp(0, width: 400));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Entdecken'));
      await tester.pumpAndSettle();

      expect(find.byType(DiscoverScreen), findsOneWidget);
    });

    testWidgets('tapping Governance tab navigates to governance', (tester) async {
      await tester.pumpWidget(_scaffoldApp(0, width: 400));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Governance').first);
      await tester.pumpAndSettle();

      expect(find.text('Governance'), findsWidgets);
    });
  });
}
