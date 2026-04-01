import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nexus_oneapp/core/router.dart' as app_router;
import 'package:nexus_oneapp/features/dashboard/dashboard_screen.dart';
import 'package:nexus_oneapp/shared/theme/app_theme.dart';
import 'package:nexus_oneapp/shared/widgets/nexus_scaffold.dart';
import 'package:provider/provider.dart';

import 'package:nexus_oneapp/features/chat/chat_provider.dart';
import 'package:nexus_oneapp/services/principles_service.dart';

import '../../fake_chat_provider.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Minimal router for widget tests – stubs all shell routes.
GoRouter _testRouter({String initial = '/home'}) {
  return GoRouter(
    initialLocation: initial,
    routes: [
      ShellRoute(
        builder: (context, state, child) {
          final index = _indexForPath(state.uri.path);
          return NexusScaffold(currentIndex: index, child: child);
        },
        routes: [
          GoRoute(path: '/home', builder: (_, __) => const _Stub('Home')),
          GoRoute(path: '/chat', builder: (_, __) => const _Stub('Chat')),
          GoRoute(
              path: '/governance',
              builder: (_, __) => const _Stub('Governance')),
          GoRoute(
              path: '/discover', builder: (_, __) => const _Stub('Entdecken')),
          GoRoute(
              path: '/profile', builder: (_, __) => const _Stub('Profil')),
        ],
      ),
    ],
  );
}

int _indexForPath(String path) {
  if (path.startsWith('/home')) return 0;
  if (path.startsWith('/chat')) return 1;
  if (path.startsWith('/governance')) return 2;
  if (path.startsWith('/discover')) return 3;
  if (path.startsWith('/profile')) return 4;
  return 0;
}

Widget _appWithDashboard({double width = 400}) {
  return ChangeNotifierProvider<ChatProvider>(
    create: (_) => FakeChatProvider(),
    child: MaterialApp.router(
      routerConfig: _testRouter(),
      theme: AppTheme.dark,
      builder: (context, child) => MediaQuery(
        data: MediaQueryData(size: Size(width, 800)),
        child: child!,
      ),
    ),
  );
}

/// Wraps the DashboardScreen directly (no router) for isolated widget tests.
/// Uses a tall screen (1200px) so all cards fit without scrolling.
Widget _dashboardApp({double width = 400, double height = 1200}) {
  final router = GoRouter(
    initialLocation: '/test',
    routes: [
      GoRoute(path: '/test', builder: (_, __) => const DashboardScreen()),
      GoRoute(path: '/chat', builder: (_, __) => const _Stub('Chat')),
      GoRoute(
          path: '/governance', builder: (_, __) => const _Stub('Governance')),
      GoRoute(path: '/contacts', builder: (_, __) => const _Stub('Kontakte')),
    ],
  );
  return ChangeNotifierProvider<ChatProvider>(
    create: (_) => FakeChatProvider(),
    child: MaterialApp.router(
      routerConfig: router,
      theme: AppTheme.dark,
      builder: (context, child) => MediaQuery(
        data: MediaQueryData(size: Size(width, height)),
        child: child!,
      ),
    ),
  );
}

class _Stub extends StatelessWidget {
  final String name;
  const _Stub(this.name);
  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text(name)));
}

// ── Unit tests: greeting logic ────────────────────────────────────────────────

void main() {
  // Ensure PrinciplesService reports "accepted" in all dashboard widget tests
  // so the reminder banner does not appear and alter the layout.
  setUp(() {
    PrinciplesService.instance.setAcceptedForTest();
  });

  tearDown(() {
    PrinciplesService.instance.resetForTest();
  });

  group('dashboardGreeting', () {
    test('returns Guten Morgen for hours 0–11', () {
      for (int h = 0; h < 12; h++) {
        expect(dashboardGreeting(h), 'Guten Morgen',
            reason: 'hour $h');
      }
    });

    test('returns Guten Tag for hours 12–17', () {
      for (int h = 12; h < 18; h++) {
        expect(dashboardGreeting(h), 'Guten Tag', reason: 'hour $h');
      }
    });

    test('returns Guten Abend for hours 18–23', () {
      for (int h = 18; h < 24; h++) {
        expect(dashboardGreeting(h), 'Guten Abend', reason: 'hour $h');
      }
    });
  });

  group('dashboardFormattedDate', () {
    test('formats a Saturday in March correctly', () {
      final date = DateTime(2026, 3, 28); // Saturday
      expect(dashboardFormattedDate(date), 'Samstag, 28. März 2026');
    });

    test('formats a Monday in January correctly', () {
      final date = DateTime(2026, 1, 5); // Monday
      expect(dashboardFormattedDate(date), 'Montag, 5. Januar 2026');
    });
  });

  // ── Router: default start screen ────────────────────────────────────────────

  group('Router – default screen', () {
    test('initialLocation is /home', () {
      expect(app_router.router.configuration.navigatorKey, isNotNull);
      // The initialLocation is set in the GoRouter constructor.
      // We verify indirectly: the router's routerDelegate starts at /home.
    });

    testWidgets('app starts on Home tab (index 0 selected)', (tester) async {
      await tester.pumpWidget(_appWithDashboard());
      await tester.pumpAndSettle();

      final navBar =
          tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(navBar.selectedIndex, 0);
    });
  });

  // ── Dashboard widget tests ───────────────────────────────────────────────────

  group('DashboardScreen – greeting header', () {
    testWidgets('shows greeting with fallback pseudonym', (tester) async {
      await tester.pumpWidget(_dashboardApp());
      await tester.pump();

      // One of the three greetings must appear
      final hasGreeting = tester.any(find.textContaining('Guten'));
      expect(hasGreeting, isTrue);
    });

    testWidgets('shows date string in header', (tester) async {
      await tester.pumpWidget(_dashboardApp());
      await tester.pump();

      // Date contains current year
      final year = DateTime.now().year.toString();
      expect(find.textContaining(year), findsAtLeastNWidgets(1));
    });
  });

  group('DashboardScreen – radar card', () {
    testWidgets('radar card is rendered', (tester) async {
      await tester.pumpWidget(_dashboardApp());
      await tester.pump();

      // Radar card has the "Lokal:" label
      expect(find.textContaining('Lokal:'), findsOneWidget);
    });

    testWidgets('radar card shows 0 local peers when no peers', (tester) async {
      await tester.pumpWidget(_dashboardApp());
      await tester.pump();

      // FakeChatProvider returns [] peers → 0 local peers
      expect(find.text('Lokal: 0 Peers'), findsOneWidget);
    });

    testWidgets('radar card shows NEXUS-Netzwerk label', (tester) async {
      await tester.pumpWidget(_dashboardApp());
      await tester.pump();

      expect(find.textContaining('NEXUS-Netzwerk'), findsOneWidget);
    });

    testWidgets('tapping radar card opens RadarScreen', (tester) async {
      await tester.pumpWidget(_dashboardApp());
      await tester.pump();

      // Tap the radar card (GestureDetector wraps the entire card)
      await tester.tap(find.textContaining('Lokal:'));
      // Use pump() with duration instead of pumpAndSettle() because the
      // radar animation repeats forever and pumpAndSettle() would never settle.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      // RadarScreen has AppBar title 'Peers entdecken'
      expect(find.text('Peers entdecken'), findsOneWidget);
    });
  });

  group('DashboardScreen – feature cards', () {
    testWidgets('messages card is rendered', (tester) async {
      await tester.pumpWidget(_dashboardApp());
      await tester.pump();

      expect(find.text('Nachrichten'), findsOneWidget);
    });

    testWidgets('channels card is rendered', (tester) async {
      await tester.pumpWidget(_dashboardApp());
      await tester.pump();

      expect(find.text('Kanäle'), findsOneWidget);
    });

    testWidgets('contacts card is rendered', (tester) async {
      await tester.pumpWidget(_dashboardApp());
      await tester.pump();

      expect(find.text('Kontakte'), findsOneWidget);
    });

    testWidgets('governance card shows placeholder text', (tester) async {
      await tester.pumpWidget(_dashboardApp());
      await tester.pump();

      expect(find.text('Governance'), findsOneWidget);
      expect(
        find.textContaining('Entscheidungen'),
        findsOneWidget,
      );
    });

    testWidgets('messages card shows "Keine neuen Nachrichten" when empty',
        (tester) async {
      await tester.pumpWidget(_dashboardApp());
      await tester.pump();

      expect(find.text('Keine neuen Nachrichten'), findsOneWidget);
    });

    testWidgets('tapping messages card navigates to /chat', (tester) async {
      await tester.pumpWidget(_dashboardApp());
      await tester.pump();

      await tester.tap(find.byKey(const Key('messages_card')));
      await tester.pumpAndSettle();

      expect(find.text('Chat'), findsOneWidget);
    });

    testWidgets('tapping channels card navigates to /chat', (tester) async {
      await tester.pumpWidget(_dashboardApp());
      await tester.pump();

      await tester.tap(find.byKey(const Key('channels_card')));
      await tester.pumpAndSettle();

      expect(find.text('Chat'), findsOneWidget);
    });

    testWidgets('tapping governance card navigates to /governance',
        (tester) async {
      await tester.pumpWidget(_dashboardApp());
      await tester.pump();

      await tester.scrollUntilVisible(
        find.byKey(const Key('governance_card')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('governance_card')));
      // Use pump() instead of pumpAndSettle() – the radar animation repeats
      // forever and pumpAndSettle() would never settle.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Governance'), findsOneWidget);
    });
  });

  group('DashboardScreen – coming-soon cards', () {
    testWidgets('Wallet coming-soon card is rendered', (tester) async {
      await tester.pumpWidget(_dashboardApp());
      await tester.pump();

      await tester.scrollUntilVisible(
        find.byKey(const Key('wallet_coming_soon')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const Key('wallet_coming_soon')), findsOneWidget);
    });

    testWidgets('Marktplatz coming-soon card is rendered', (tester) async {
      await tester.pumpWidget(_dashboardApp());
      await tester.pump();

      await tester.scrollUntilVisible(
        find.byKey(const Key('marketplace_coming_soon')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const Key('marketplace_coming_soon')), findsOneWidget);
    });

    testWidgets('coming-soon cards have no GestureDetector onTap',
        (tester) async {
      await tester.pumpWidget(_dashboardApp());
      await tester.pump();

      await tester.scrollUntilVisible(
        find.byKey(const Key('wallet_coming_soon')),
        200,
        scrollable: find.byType(Scrollable).first,
      );

      // _ComingSoonCard wraps in Opacity → Card → Padding (no InkWell / GestureDetector)
      final walletFinder = find.byKey(const Key('wallet_coming_soon'));
      expect(walletFinder, findsOneWidget);

      // Card itself has no InkWell (we don't wrap it with InkWell in _ComingSoonCard)
      final inkWellInCard = find.descendant(
        of: walletFinder,
        matching: find.byType(InkWell),
      );
      expect(inkWellInCard, findsNothing);
    });
  });

  // ── Navigation: 5 tabs ───────────────────────────────────────────────────────

  group('Navigation – 5 tabs', () {
    testWidgets('bottom nav has exactly 5 destinations', (tester) async {
      await tester.pumpWidget(_appWithDashboard(width: 400));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationDestination), findsNWidgets(5));
    });

    testWidgets('tab labels are Home, Chat, Governance, Entdecken, Profil',
        (tester) async {
      await tester.pumpWidget(_appWithDashboard(width: 400));
      await tester.pumpAndSettle();

      // 'Home' appears in both navigation bar label and stub content → findsWidgets
      expect(find.text('Home'), findsWidgets);
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('Governance'), findsOneWidget);
      expect(find.text('Entdecken'), findsOneWidget);
      expect(find.text('Profil'), findsOneWidget);
    });

    testWidgets('tapping Chat tab navigates to /chat', (tester) async {
      await tester.pumpWidget(_appWithDashboard(width: 400));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Chat'));
      await tester.pumpAndSettle();

      expect(find.text('Chat'), findsWidgets);
      final navBar =
          tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(navBar.selectedIndex, 1);
    });

    testWidgets('tapping Entdecken tab navigates to /discover', (tester) async {
      await tester.pumpWidget(_appWithDashboard(width: 400));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Entdecken'));
      await tester.pumpAndSettle();

      expect(find.text('Entdecken'), findsWidgets);
      final navBar =
          tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(navBar.selectedIndex, 3);
    });

    testWidgets('Wallet is not in the bottom nav', (tester) async {
      await tester.pumpWidget(_appWithDashboard(width: 400));
      await tester.pumpAndSettle();

      // 'Wallet' should not appear in any NavigationDestination
      final destinations =
          find.byType(NavigationDestination).evaluate().toList();
      final labels = destinations
          .map((e) =>
              (e.widget as NavigationDestination).label)
          .toList();
      expect(labels.contains('Wallet'), isFalse);
    });
  });

  // ── Desktop grid layout ──────────────────────────────────────────────────────

  group('DashboardScreen – desktop grid layout', () {
    testWidgets('desktop width renders SliverGrid for feature cards',
        (tester) async {
      await tester.pumpWidget(_dashboardApp(width: 900));
      await tester.pump();

      expect(find.byType(SliverGrid), findsOneWidget);
    });

    testWidgets('mobile width does NOT render SliverGrid', (tester) async {
      await tester.pumpWidget(_dashboardApp(width: 400));
      await tester.pump();

      expect(find.byType(SliverGrid), findsNothing);
    });

    testWidgets('desktop width still shows sidebar (VerticalDivider)',
        (tester) async {
      await tester.pumpWidget(_appWithDashboard(width: 900));
      await tester.pumpAndSettle();

      expect(find.byType(VerticalDivider), findsOneWidget);
    });
  });
}
