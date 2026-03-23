import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/main.dart';

void main() {
  testWidgets('Splash screen shows NEXUS title', (WidgetTester tester) async {
    await tester.pumpWidget(const NexusApp());
    await tester.pump();

    expect(find.text('N.E.X.U.S. OneApp'), findsOneWidget);
    expect(find.text('Für die Menschheitsfamilie'), findsOneWidget);

    // Advance past the splash timer so no pending timers remain
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });
}
