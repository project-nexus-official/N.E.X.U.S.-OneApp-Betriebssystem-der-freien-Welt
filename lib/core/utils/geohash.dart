/// Geohash encoding utility.
///
/// Produces a Base32 geohash string with configurable precision.
/// 6 characters ≈ 1.2 km × 0.6 km accuracy.
library;

const _base32 = '0123456789bcdefghjkmnpqrstuvwxyz';

/// Encodes [lat]/[lon] to a geohash with the given [precision] (default 6).
String encodeGeohash(double lat, double lon, {int precision = 6}) {
  var minLat = -90.0, maxLat = 90.0;
  var minLon = -180.0, maxLon = 180.0;

  final result = StringBuffer();
  var bit = 0;
  var charIndex = 0;
  var even = true; // true → longitude bit, false → latitude bit

  while (result.length < precision) {
    if (even) {
      final mid = (minLon + maxLon) / 2;
      if (lon >= mid) {
        charIndex = (charIndex << 1) | 1;
        minLon = mid;
      } else {
        charIndex = charIndex << 1;
        maxLon = mid;
      }
    } else {
      final mid = (minLat + maxLat) / 2;
      if (lat >= mid) {
        charIndex = (charIndex << 1) | 1;
        minLat = mid;
      } else {
        charIndex = charIndex << 1;
        maxLat = mid;
      }
    }
    even = !even;

    if (++bit == 5) {
      result.write(_base32[charIndex]);
      bit = 0;
      charIndex = 0;
    }
  }
  return result.toString();
}

/// Returns the length of the longest common prefix between [a] and [b].
/// Used to measure proximity: longer prefix = closer location.
int geohashCommonPrefixLength(String a, String b) {
  int i = 0;
  while (i < a.length && i < b.length && a[i] == b[i]) {
    i++;
  }
  return i;
}
