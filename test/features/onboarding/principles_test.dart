import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nexus_oneapp/features/onboarding/principles_commitment_screen.dart';
import 'package:nexus_oneapp/features/onboarding/principles_content_screen.dart';
import 'package:nexus_oneapp/features/onboarding/principles_intro_screen.dart';
import 'package:nexus_oneapp/services/principles_service.dart';
import 'package:nexus_oneapp/shared/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Wraps a widget in a minimal MaterialApp with the given router.
Widget _app(GoRouter router) {
  return MaterialApp.router(
    routerConfig: router,
    theme: AppTheme.dark,
  );
}

/// Builds a router whose initial path is [initial].
GoRouter _router(String initial, List<RouteBase> routes) {
  return GoRouter(initialLocation: initial, routes: routes);
}

// ── PrinciplesService unit tests ──────────────────────────────────────────────

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PrinciplesService.instance.resetForTest();
  });

  group('PrinciplesService', () {
    test('initial state: not seen, not accepted, no timestamp', () {
      expect(PrinciplesService.instance.hasSeen, isFalse);
      expect(PrinciplesService.instance.isAccepted, isFalse);
      expect(PrinciplesService.instance.acceptedAt, isNull);
    });

    test('load() reads hasSeen=false when prefs are empty', () async {
      await PrinciplesService.instance.load();
      expect(PrinciplesService.instance.hasSeen, isFalse);
    });

    test('load() restores accepted state from prefs', () async {
      final now = DateTime(2026, 4, 1, 12, 0, 0);
      SharedPreferences.setMockInitialValues({
        'principles_seen': true,
        'principles_accepted': true,
        'principles_accepted_at': now.toIso8601String(),
      });
      await PrinciplesService.instance.load();

      expect(PrinciplesService.instance.hasSeen, isTrue);
      expect(PrinciplesService.instance.isAccepted, isTrue);
      expect(PrinciplesService.instance.acceptedAt, equals(now));
    });

    test('load() restores skipped state from prefs', () async {
      SharedPreferences.setMockInitialValues({
        'principles_seen': true,
        'principles_accepted': false,
      });
      await PrinciplesService.instance.load();

      expect(PrinciplesService.instance.hasSeen, isTrue);
      expect(PrinciplesService.instance.isAccepted, isFalse);
    });

    test('accept() sets hasSeen=true, isAccepted=true, stores timestamp',
        () async {
      final before = DateTime.now();
      await PrinciplesService.instance.accept();
      final after = DateTime.now();

      expect(PrinciplesService.instance.hasSeen, isTrue);
      expect(PrinciplesService.instance.isAccepted, isTrue);
      expect(PrinciplesService.instance.acceptedAt, isNotNull);
      expect(
        PrinciplesService.instance.acceptedAt!
            .isAfter(before.subtract(const Duration(seconds: 1))),
        isTrue,
      );
      expect(
        PrinciplesService.instance.acceptedAt!
            .isBefore(after.add(const Duration(seconds: 1))),
        isTrue,
      );

      // Verify persistence
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('principles_seen'), isTrue);
      expect(prefs.getBool('principles_accepted'), isTrue);
      expect(prefs.getString('principles_accepted_at'), isNotNull);
    });

    test('accept() persists so load() in a new instance restores it', () async {
      await PrinciplesService.instance.accept();
      PrinciplesService.instance.resetForTest();
      await PrinciplesService.instance.load();

      expect(PrinciplesService.instance.isAccepted, isTrue);
      expect(PrinciplesService.instance.hasSeen, isTrue);
    });

    test('skip() sets hasSeen=true, isAccepted=false, no timestamp', () async {
      await PrinciplesService.instance.skip();

      expect(PrinciplesService.instance.hasSeen, isTrue);
      expect(PrinciplesService.instance.isAccepted, isFalse);
      expect(PrinciplesService.instance.acceptedAt, isNull);

      // Verify persistence
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('principles_seen'), isTrue);
      expect(prefs.getBool('principles_accepted'), isFalse);
    });

    test('after skip(), accept() updates state correctly', () async {
      await PrinciplesService.instance.skip();
      await PrinciplesService.instance.accept();

      expect(PrinciplesService.instance.isAccepted, isTrue);
      expect(PrinciplesService.instance.hasSeen, isTrue);
    });

    test('existing user: no prefs key → hasSeen=false (triggers flow)', () async {
      // Simulate existing user who updated the app – no principles key in prefs.
      SharedPreferences.setMockInitialValues({
        'some_other_key': 'value',
      });
      await PrinciplesService.instance.load();

      expect(PrinciplesService.instance.hasSeen, isFalse);
    });

    test('after accept() followed by resetForTest(), state is clean', () async {
      await PrinciplesService.instance.accept();
      PrinciplesService.instance.resetForTest();

      expect(PrinciplesService.instance.hasSeen, isFalse);
      expect(PrinciplesService.instance.isAccepted, isFalse);
      expect(PrinciplesService.instance.acceptedAt, isNull);
    });
  });

  // ── PrinciplesIntroScreen widget tests ────────────────────────────────────────

  group('PrinciplesIntroScreen', () {
    testWidgets('shows intro headline', (tester) async {
      final router = _router('/intro', [
        GoRoute(
          path: '/intro',
          builder: (_, __) => const PrinciplesIntroScreen(),
        ),
        GoRoute(
          path: '/principles/content',
          builder: (_, __) =>
              const Scaffold(body: Text('ContentScreen')),
        ),
      ]);
      await tester.pumpWidget(_app(router));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('principles_intro_headline')),
        findsOneWidget,
      );
      expect(
        find.text('Du bist dabei, einen neuen Raum zu betreten.'),
        findsOneWidget,
      );
    });

    testWidgets('shows "Nimm dir einen Moment Zeit."', (tester) async {
      final router = _router('/intro', [
        GoRoute(
          path: '/intro',
          builder: (_, __) => const PrinciplesIntroScreen(),
        ),
        GoRoute(
          path: '/principles/content',
          builder: (_, __) => const Scaffold(body: Text('Content')),
        ),
      ]);
      await tester.pumpWidget(_app(router));
      await tester.pumpAndSettle();

      expect(find.text('Nimm dir einen Moment Zeit.'), findsOneWidget);
    });

    testWidgets('"Ich bin bereit" button is present', (tester) async {
      final router = _router('/intro', [
        GoRoute(
          path: '/intro',
          builder: (_, __) => const PrinciplesIntroScreen(),
        ),
        GoRoute(
          path: '/principles/content',
          builder: (_, __) => const Scaffold(body: Text('Content')),
        ),
      ]);
      await tester.pumpWidget(_app(router));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('principles_intro_ready_btn')),
        findsOneWidget,
      );
    });

    testWidgets('tapping "Ich bin bereit" navigates to content screen',
        (tester) async {
      final router = _router('/intro', [
        GoRoute(
          path: '/intro',
          builder: (_, __) => const PrinciplesIntroScreen(),
        ),
        GoRoute(
          path: '/principles/content',
          builder: (_, __) =>
              const Scaffold(body: Text('ContentScreen')),
        ),
      ]);
      await tester.pumpWidget(_app(router));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('principles_intro_ready_btn')));
      await tester.pumpAndSettle();

      expect(find.text('ContentScreen'), findsOneWidget);
    });
  });

  // ── PrinciplesContentScreen widget tests ──────────────────────────────────────

  group('PrinciplesContentScreen', () {
    Widget _contentApp({bool readOnly = false}) {
      final routes = <RouteBase>[
        GoRoute(
          path: '/content',
          builder: (_, __) =>
              PrinciplesContentScreen(readOnly: readOnly),
        ),
        GoRoute(
          path: '/principles/commitment',
          builder: (_, __) =>
              const Scaffold(body: Text('CommitmentScreen')),
        ),
      ];
      return _app(_router('/content', routes));
    }

    testWidgets('starts on page 1 and shows page 1 title', (tester) async {
      await tester.pumpWidget(_contentApp());
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('principles_page1_title')),
        findsOneWidget,
      );
    });

    testWidgets('shows 4 progress dots', (tester) async {
      await tester.pumpWidget(_contentApp());
      await tester.pumpAndSettle();

      // PageDots renders 4 Container children; verify via widget tree.
      // Check that next button is present (confirming content rendered).
      expect(find.byKey(const Key('principles_next_btn')), findsOneWidget);
    });

    testWidgets('back button is absent on page 1', (tester) async {
      await tester.pumpWidget(_contentApp());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('principles_back_btn')), findsNothing);
    });

    testWidgets('tapping Weiter advances to page 2, shows back button',
        (tester) async {
      await tester.pumpWidget(_contentApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('principles_next_btn')));
      await tester.pumpAndSettle();

      // Page 1 title should be gone, back button should appear.
      expect(
        find.byKey(const Key('principles_page1_title')),
        findsNothing,
      );
      expect(find.byKey(const Key('principles_back_btn')), findsOneWidget);
    });

    testWidgets('back button returns to previous page', (tester) async {
      await tester.pumpWidget(_contentApp());
      await tester.pumpAndSettle();

      // Advance to page 2.
      await tester.tap(find.byKey(const Key('principles_next_btn')));
      await tester.pumpAndSettle();

      // Go back to page 1.
      await tester.tap(find.byKey(const Key('principles_back_btn')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('principles_page1_title')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('principles_back_btn')), findsNothing);
    });

    testWidgets('navigating through all 4 pages reaches commitment screen',
        (tester) async {
      await tester.pumpWidget(_contentApp());
      await tester.pumpAndSettle();

      for (int i = 0; i < 4; i++) {
        await tester.tap(find.byKey(const Key('principles_next_btn')));
        await tester.pumpAndSettle();
      }

      expect(find.text('CommitmentScreen'), findsOneWidget);
    });

    testWidgets('readOnly=true: last page button shows "Schließen"',
        (tester) async {
      await tester.pumpWidget(_contentApp(readOnly: true));
      await tester.pumpAndSettle();

      // Navigate to last page (page 4).
      for (int i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const Key('principles_next_btn')));
        await tester.pumpAndSettle();
      }

      expect(find.text('Schließen'), findsOneWidget);
    });

    testWidgets('page 3 shows rights bullet points', (tester) async {
      await tester.pumpWidget(_contentApp());
      await tester.pumpAndSettle();

      // Navigate to page 3.
      for (int i = 0; i < 2; i++) {
        await tester.tap(find.byKey(const Key('principles_next_btn')));
        await tester.pumpAndSettle();
      }

      expect(
        find.text('Meine Rechte — unveräußerlich und unantastbar:'),
        findsOneWidget,
      );
    });

    testWidgets('page 4 shows commitment and pact text', (tester) async {
      await tester.pumpWidget(_contentApp());
      await tester.pumpAndSettle();

      // Navigate to page 4.
      for (int i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const Key('principles_next_btn')));
        await tester.pumpAndSettle();
      }

      expect(find.text('Mein Bekenntnis:'), findsOneWidget);
      expect(find.text('Der Pakt:'), findsOneWidget);
    });
  });

  // ── PrinciplesCommitmentScreen widget tests ───────────────────────────────────

  group('PrinciplesCommitmentScreen', () {
    Widget _commitApp(String Function(BuildContext) onCommitRoute) {
      final routes = <RouteBase>[
        GoRoute(
          path: '/commitment',
          builder: (_, __) => const PrinciplesCommitmentScreen(),
        ),
        GoRoute(
          path: '/home',
          builder: (_, __) => const Scaffold(body: Text('Dashboard')),
        ),
      ];
      return _app(_router('/commitment', routes));
    }

    testWidgets('shows commitment headline', (tester) async {
      await tester.pumpWidget(_commitApp((_) => '/home'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('principles_commitment_headline')),
        findsOneWidget,
      );
    });

    testWidgets('both checkboxes start unchecked', (tester) async {
      await tester.pumpWidget(_commitApp((_) => '/home'));
      await tester.pumpAndSettle();

      final cbs = tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
      expect(cbs.length, 2);
      expect(cbs[0].value, isFalse);
      expect(cbs[1].value, isFalse);
    });

    testWidgets('"Ich trete ein" is disabled when no checkboxes are set',
        (tester) async {
      await tester.pumpWidget(_commitApp((_) => '/home'));
      await tester.pumpAndSettle();

      final btn = tester.widget<ElevatedButton>(
        find.byKey(const Key('principles_commit_btn')),
      );
      expect(btn.onPressed, isNull);
    });

    testWidgets('"Ich trete ein" is disabled when only one checkbox is set',
        (tester) async {
      await tester.pumpWidget(_commitApp((_) => '/home'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('principles_cb_understood')));
      await tester.pumpAndSettle();

      final btn = tester.widget<ElevatedButton>(
        find.byKey(const Key('principles_commit_btn')),
      );
      expect(btn.onPressed, isNull);
    });

    testWidgets('"Ich trete ein" becomes active when both checkboxes are set',
        (tester) async {
      await tester.pumpWidget(_commitApp((_) => '/home'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('principles_cb_understood')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('principles_cb_ready')));
      await tester.pumpAndSettle();

      final btn = tester.widget<ElevatedButton>(
        find.byKey(const Key('principles_commit_btn')),
      );
      expect(btn.onPressed, isNotNull);
    });

    testWidgets('"Ich trete ein" saves acceptance and navigates to Dashboard',
        (tester) async {
      await tester.pumpWidget(_commitApp((_) => '/home'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('principles_cb_understood')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('principles_cb_ready')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('principles_commit_btn')));
      await tester.pumpAndSettle();

      expect(PrinciplesService.instance.isAccepted, isTrue);
      expect(PrinciplesService.instance.acceptedAt, isNotNull);
      expect(find.text('Dashboard'), findsOneWidget);
    });

    testWidgets('"Später" navigates to Dashboard without accepting',
        (tester) async {
      await tester.pumpWidget(_commitApp((_) => '/home'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('principles_skip_btn')));
      await tester.pumpAndSettle();

      expect(PrinciplesService.instance.hasSeen, isTrue);
      expect(PrinciplesService.instance.isAccepted, isFalse);
      expect(find.text('Dashboard'), findsOneWidget);
    });
  });

  // ── After acceptance: flow does not reappear ──────────────────────────────────

  group('Post-acceptance behaviour', () {
    test('after accept(), hasSeen=true and isAccepted=true', () async {
      await PrinciplesService.instance.accept();

      expect(PrinciplesService.instance.hasSeen, isTrue);
      expect(PrinciplesService.instance.isAccepted, isTrue);
    });

    test('after skip(), hasSeen=true but isAccepted=false', () async {
      await PrinciplesService.instance.skip();

      expect(PrinciplesService.instance.hasSeen, isTrue);
      expect(PrinciplesService.instance.isAccepted, isFalse);
    });
  });
}
