import 'package:flutter/material.dart';

/// A deterministic geometric identicon derived from arbitrary bytes (e.g. a public key).
///
/// Renders a 5×5 symmetric pixel grid where each cell's visibility is determined
/// by hashing the input bytes. The foreground color is derived from the first 3 bytes.
class Identicon extends StatelessWidget {
  final List<int> bytes;
  final double size;
  final Color? backgroundColor;

  const Identicon({
    super.key,
    required this.bytes,
    required this.size,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _IdenticonPainter(bytes: bytes, bgColor: backgroundColor),
      ),
    );
  }
}

class _IdenticonPainter extends CustomPainter {
  final List<int> bytes;
  final Color? bgColor;

  const _IdenticonPainter({required this.bytes, this.bgColor});

  @override
  void paint(Canvas canvas, Size size) {
    if (bytes.isEmpty) return;

    // Derive foreground color from first 3 bytes (HSL for vivid colors)
    final hue = (bytes[0] / 255.0) * 360.0;
    final saturation = 0.45 + (bytes.length > 1 ? (bytes[1] / 255.0) * 0.30 : 0.2);
    final lightness = 0.45 + (bytes.length > 2 ? (bytes[2] / 255.0) * 0.15 : 0.1);
    final fgColor = HSLColor.fromAHSL(1.0, hue, saturation, lightness).toColor();

    final bg = bgColor ?? const Color(0xFF121F38);
    final bgPaint = Paint()..color = bg;
    final fgPaint = Paint()..color = fgColor;

    // Draw background
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bgPaint);

    // 5×5 grid, mirrored left-right (only 3 columns of unique data needed)
    const cols = 5;
    const rows = 5;
    final cellW = size.width / cols;
    final cellH = size.height / rows;

    // Use bytes (with index offset 3 to skip color bytes) to fill the grid
    for (int row = 0; row < rows; row++) {
      for (int col = 0; col < 3; col++) {
        // Which byte drives this cell?
        final byteIndex = (row * 3 + col + 3) % bytes.length;
        // Use the low bit of the byte to decide fill
        final filled = (bytes[byteIndex] >> (col % 8)) & 1 == 1;
        if (!filled) continue;

        // Left half
        canvas.drawRect(
          Rect.fromLTWH(col * cellW + 1, row * cellH + 1, cellW - 2, cellH - 2),
          fgPaint,
        );
        // Mirror to right half (skip center column for col==2)
        if (col < 2) {
          final mirrorCol = cols - 1 - col;
          canvas.drawRect(
            Rect.fromLTWH(
                mirrorCol * cellW + 1, row * cellH + 1, cellW - 2, cellH - 2),
            fgPaint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_IdenticonPainter old) => old.bytes != bytes;
}
