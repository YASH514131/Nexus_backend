import 'dart:math';

final _durationPatterns = <RegExp>[
  RegExp(r'(\d+)\s*[-–]\s*(\d+)\s*(month|week|mo\b)', caseSensitive: false),
  RegExp(r'(\d+)\s*(month|week|mo\b)', caseSensitive: false),
  RegExp(
    r'(summer|spring|fall|winter|q[1-4])\s*(intern)?',
    caseSensitive: false,
  ),
];

(String, double) parseDuration(String text) {
  for (final pattern in _durationPatterns) {
    final match = pattern.firstMatch(text);
    if (match == null) continue;
    final raw = match.group(0) ?? '';
    final lower = raw.toLowerCase();
    if (lower.contains('summer') ||
        lower.contains('spring') ||
        lower.contains('fall') ||
        lower.contains('winter')) {
      return (toTitleCase(raw), 3.0);
    }

    final first = int.tryParse(match.group(1) ?? '0') ?? 0;
    final unit = (match.group(match.groupCount) ?? '').toLowerCase();
    final months = unit.contains('month') ? first.toDouble() : (first / 4.3);
    return ('$first $unit', months);
  }
  return ('Not specified', 0);
}

String parseLocation(String text) {
  final lowered = text.toLowerCase();
  if (RegExp(r'\bremote\b').hasMatch(lowered)) return 'Remote';
  if (RegExp(r'\bhybrid\b').hasMatch(lowered)) return 'Hybrid';
  if (RegExp(r'\bon[-\s]?site\b').hasMatch(lowered)) return 'On-site';

  final match = RegExp(
    r'\b([A-Z][a-z]+(?: [A-Z][a-z]+)*,\s*[A-Z][a-z]+(?: [A-Z][a-z]+)*)\b',
  ).firstMatch(text);
  if (match != null) {
    return match.group(1) ?? 'Not specified';
  }

  final stateMatch = RegExp(
    r'\b([A-Z][a-z]+(?: [A-Z][a-z]+)?,\s*[A-Z]{2})\b',
  ).firstMatch(text);
  return stateMatch?.group(1) ?? 'Not specified';
}

String toTitleCase(String input) {
  return input
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .map((w) => '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
      .join(' ');
}

List<T> takeRandom<T>(List<T> items, int maxCount) {
  if (items.length <= maxCount) return List<T>.from(items);
  final rand = Random();
  final copy = List<T>.from(items)..shuffle(rand);
  return copy.take(maxCount).toList();
}
