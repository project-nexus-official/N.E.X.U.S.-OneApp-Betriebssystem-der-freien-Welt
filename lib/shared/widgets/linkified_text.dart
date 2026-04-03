import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

final _urlRegex = RegExp(
  r'https?://[^\s<>"\u0000-\u001F\u007F]+',
  caseSensitive: false,
);

/// Renders [text] with http/https URLs as tappable, underlined links.
/// Falls back to plain [Text] when no URL is found.
///
/// If [query] is non-empty, occurrences of [query] are also highlighted in
/// gold (same behaviour as [HighlightedText]).
class LinkifiedText extends StatelessWidget {
  const LinkifiedText({
    super.key,
    required this.text,
    this.style,
    this.query = '',
    this.maxLines,
    this.overflow,
  });

  final String text;
  final TextStyle? style;
  final String query;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final spans = _buildSpans(context);
    if (spans.length == 1 && spans.first.recognizer == null) {
      // Plain text – no link, no query highlight: cheaper widget.
      return Text(text, style: style, maxLines: maxLines, overflow: overflow);
    }
    return Text.rich(
      TextSpan(children: spans),
      style: style,
      maxLines: maxLines,
      overflow: overflow,
    );
  }

  List<TextSpan> _buildSpans(BuildContext context) {
    final spans = <TextSpan>[];
    int cursor = 0;

    for (final match in _urlRegex.allMatches(text)) {
      if (match.start > cursor) {
        spans.addAll(_maybeHighlight(text.substring(cursor, match.start)));
      }
      final url = match.group(0)!;
      final recognizer = TapGestureRecognizer()
        ..onTap = () async {
          final uri = Uri.tryParse(url);
          if (uri != null && await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        };
      spans.add(TextSpan(
        text: url,
        style: const TextStyle(
          color: Color(0xFF64B5F6), // light-blue, readable on dark backgrounds
          decoration: TextDecoration.underline,
          decorationColor: Color(0xFF64B5F6),
        ),
        recognizer: recognizer,
      ));
      cursor = match.end;
    }

    if (cursor < text.length) {
      spans.addAll(_maybeHighlight(text.substring(cursor)));
    }

    if (spans.isEmpty) {
      spans.add(TextSpan(text: text));
    }

    return spans;
  }

  /// Splits a plain-text segment further by [query] to apply gold highlights.
  List<TextSpan> _maybeHighlight(String segment) {
    if (query.isEmpty) return [TextSpan(text: segment)];

    final result = <TextSpan>[];
    final lower = segment.toLowerCase();
    final qLower = query.toLowerCase();
    int start = 0;

    while (true) {
      final idx = lower.indexOf(qLower, start);
      if (idx == -1) {
        if (start < segment.length) result.add(TextSpan(text: segment.substring(start)));
        break;
      }
      if (idx > start) result.add(TextSpan(text: segment.substring(start, idx)));
      result.add(TextSpan(
        text: segment.substring(idx, idx + query.length),
        style: const TextStyle(
          backgroundColor: Color(0x55D4AF37),
          color: Color(0xFF0A1628),
          fontWeight: FontWeight.bold,
        ),
      ));
      start = idx + query.length;
    }

    return result;
  }
}
