import 'dart:math';

/// Generates deterministic German pseudonyms in the form "AdjektivTier42".
class PseudonymGenerator {
  PseudonymGenerator._();

  static const _adjectives = [
    'Froher', 'Wilder', 'Kluger', 'Tapferer', 'Sanfter', 'Freier', 'Stiller',
    'Flinker', 'Kühner', 'Treuer', 'Heller', 'Starker', 'Edler', 'Leiser',
    'Feiner', 'Bunter', 'Echter', 'Reiner', 'Frecher', 'Milder', 'Rascher',
    'Zarter', 'Weiser', 'Braver', 'Schneller', 'Ruhiger', 'Lachender',
    'Freudiger', 'Munterer', 'Strahlender',
  ];

  static const _animals = [
    'Biber', 'Wolf', 'Bär', 'Adler', 'Fuchs', 'Luchs', 'Hirsch', 'Falke',
    'Otter', 'Rabe', 'Storch', 'Igel', 'Dachs', 'Marder', 'Wiesel', 'Wal',
    'Delfin', 'Tiger', 'Leopard', 'Panda', 'Elch', 'Habicht', 'Kröte',
    'Libelle', 'Schwan', 'Kranich', 'Wisent', 'Auerhuhn', 'Steinbock', 'Auerhahn',
  ];

  /// Returns a random German pseudonym: "AdjektivTier42".
  static String generate() {
    final rng = Random.secure();
    final adj = _adjectives[rng.nextInt(_adjectives.length)];
    final animal = _animals[rng.nextInt(_animals.length)];
    final number = rng.nextInt(100);
    return '$adj$animal$number';
  }

  /// Derives a deterministic pseudonym from a list of bytes (e.g. public key).
  static String fromBytes(List<int> bytes) {
    if (bytes.isEmpty) return generate();
    final adj = _adjectives[bytes[0] % _adjectives.length];
    final animal = _animals[bytes[1] % _animals.length];
    final number = bytes[2] % 100;
    return '$adj$animal$number';
  }
}
