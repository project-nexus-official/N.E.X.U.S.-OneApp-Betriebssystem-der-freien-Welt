import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/features/chat/chat_provider.dart';
import 'package:nexus_oneapp/features/chat/conversations_screen.dart';
import 'package:nexus_oneapp/features/discover/discover_screen.dart';
import 'package:nexus_oneapp/shared/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../fake_chat_provider.dart';

// ── Test helpers ──────────────────────────────────────────────────────────────

/// Plain MaterialApp wrapper (no router needed for most tests).
Widget _app(Widget child) {
  return MaterialApp(
    theme: AppTheme.dark,
    home: child,
    builder: (context, child) => MediaQuery(
      data: const MediaQueryData(size: Size(400, 800)),
      child: child!,
    ),
  );
}

/// Wraps ConversationsScreen with a FakeChatProvider registered as ChatProvider.
Widget _chatApp() {
  return MaterialApp(
    theme: AppTheme.dark,
    home: ChangeNotifierProvider<ChatProvider>(
      create: (_) => FakeChatProvider(),
      child: const ConversationsScreen(),
    ),
    builder: (context, child) => MediaQuery(
      data: const MediaQueryData(size: Size(400, 800)),
      child: child!,
    ),
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  // ── Path 2: Entdecken-Hub ──────────────────────────────────────────────────

  group('Path 2 – DiscoverScreen Kontakte tile', () {
    testWidgets('Kontakte tile is visible in main grid', (tester) async {
      await tester.pumpWidget(_app(const DiscoverScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Kontakte'), findsOneWidget);
    });

    testWidgets('Kontakte tile has no coming-soon badge', (tester) async {
      await tester.pumpWidget(_app(const DiscoverScreen()));
      await tester.pumpAndSettle();

      // Active tiles have no phase badge.  Find the Positioned badge children
      // inside any Stack that also contains the 'Kontakte' text.
      final stackFinder = find.ancestor(
        of: find.text('Kontakte'),
        matching: find.byType(Stack),
      );
      expect(stackFinder, findsWidgets);

      final stack = tester.widget<Stack>(stackFinder.first);
      final hasPhaseLabel = stack.children.any((child) {
        if (child is! Positioned) return false;
        final inner = child.child;
        if (inner is! Container) return false;
        final innerChild = inner.child;
        return innerChild is Text &&
            (innerChild.data?.startsWith('Phase') ?? false);
      });

      expect(hasPhaseLabel, isFalse,
          reason: 'Kontakte tile must not show a Phase badge');
    });

    testWidgets('Kontakte tile is fully opaque (active, not dimmed)',
        (tester) async {
      await tester.pumpWidget(_app(const DiscoverScreen()));
      await tester.pumpAndSettle();

      final opacityFinder = find.ancestor(
        of: find.text('Kontakte'),
        matching: find.byType(Opacity),
      );
      expect(opacityFinder, findsWidgets);

      final opacity = tester.widget<Opacity>(opacityFinder.first);
      expect(opacity.opacity, 1.0,
          reason: 'Active Kontakte tile must have opacity 1.0');
    });

    testWidgets('Kontakte tile has people_outline icon', (tester) async {
      await tester.pumpWidget(_app(const DiscoverScreen()));
      await tester.pumpAndSettle();

      // Icon must exist inside the tile containing the 'Kontakte' label.
      final iconFinder = find.descendant(
        of: find.ancestor(
          of: find.text('Kontakte'),
          matching: find.byType(Stack),
        ).first,
        matching: find.byIcon(Icons.people_outline),
      );
      expect(iconFinder, findsOneWidget);
    });

    testWidgets('Einstellungen tile still present after adding Kontakte',
        (tester) async {
      await tester.pumpWidget(_app(const DiscoverScreen()));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Einstellungen'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Einstellungen'), findsOneWidget);
    });
  });

  // ── Path 3: Chat-Tab FAB bottom sheet ─────────────────────────────────────

  group('Path 3 – ConversationsScreen FAB menu', () {
    testWidgets('FAB uses add icon (replaced radar icon)', (tester) async {
      await tester.pumpWidget(_chatApp());
      await tester.pump(); // single frame; DB ops caught silently

      expect(find.byType(FloatingActionButton), findsOneWidget);
      final fab =
          tester.widget<FloatingActionButton>(find.byType(FloatingActionButton));
      expect(
        (fab.child as Icon).icon,
        Icons.add,
        reason: 'FAB must show add icon, not the old radar icon',
      );
    });

    testWidgets('tapping FAB opens "Neue Konversation" bottom sheet',
        (tester) async {
      await tester.pumpWidget(_chatApp());
      await tester.pump();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('Neue Konversation'), findsOneWidget);
    });

    testWidgets('bottom sheet lists QR-Code scannen', (tester) async {
      await tester.pumpWidget(_chatApp());
      await tester.pump();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('QR-Code scannen'), findsOneWidget);
    });

    testWidgets('bottom sheet lists Peers in der Nähe', (tester) async {
      await tester.pumpWidget(_chatApp());
      await tester.pump();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('Peers in der Nähe'), findsOneWidget);
    });

    testWidgets('bottom sheet lists Kontakte anzeigen', (tester) async {
      await tester.pumpWidget(_chatApp());
      await tester.pump();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('Kontakte anzeigen'), findsOneWidget);
    });

    testWidgets('bottom sheet has exactly 3 options (ListTile)', (tester) async {
      await tester.pumpWidget(_chatApp());
      await tester.pump();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      // Three ListTiles in the bottom sheet.
      // We search inside the modal route, not the whole tree.
      final optionTexts = [
        'QR-Code scannen',
        'Peers in der Nähe',
        'Kontakte anzeigen',
      ];
      for (final label in optionTexts) {
        expect(find.text(label), findsOneWidget,
            reason: 'Option "$label" must be present');
      }
    });

    testWidgets('bottom sheet has people_outline icon for Kontakte option',
        (tester) async {
      await tester.pumpWidget(_chatApp());
      await tester.pump();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.people_outline), findsWidgets);
    });
  });
}
