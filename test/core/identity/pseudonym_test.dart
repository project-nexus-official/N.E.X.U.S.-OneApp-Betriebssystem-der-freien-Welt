import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_oneapp/core/identity/pseudonym_generator.dart';

void main() {
  group('PseudonymGenerator', () {
    test('generate returns non-empty string', () {
      final p = PseudonymGenerator.generate();
      expect(p.isNotEmpty, isTrue);
    });

    test('fromBytes is deterministic', () {
      final bytes = [5, 12, 42, 1, 2, 3];
      expect(PseudonymGenerator.fromBytes(bytes),
          PseudonymGenerator.fromBytes(bytes));
    });

    test('fromBytes ends with a number 0-99', () {
      final p = PseudonymGenerator.fromBytes([0, 0, 50]);
      final match = RegExp(r'\d+$').firstMatch(p);
      expect(match, isNotNull);
      expect(int.parse(match!.group(0)!), inInclusiveRange(0, 99));
    });
  });
}
