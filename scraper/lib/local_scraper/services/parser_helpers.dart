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

String parseExperience(String text) {
  if (text.isEmpty) return '—';

  // Clean HTML tags first to get clean text
  final cleanText = text.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ');

  final regex = RegExp(
    r'\b(\d+)\s*(?:\+|plus|to|-|\s)*\s*(\d+)?\s*(?:years?|yrs?)\b',
    caseSensitive: false,
  );

  final matches = regex.allMatches(cleanText);
  for (final match in matches) {
    final firstNum = match.group(1);
    final secondNum = match.group(2);
    final fullMatchStr = match.group(0)!.toLowerCase();

    // Check context for age restrictions (e.g. 18 years or older)
    final idx = cleanText.indexOf(match.group(0)!);
    final start = idx > 25 ? idx - 25 : 0;
    final end = idx + fullMatchStr.length + 25 < cleanText.length ? idx + fullMatchStr.length + 25 : cleanText.length;
    final context = cleanText.substring(start, end).toLowerCase();

    if (context.contains('or older') ||
        context.contains('of age') ||
        context.contains('age of') ||
        context.contains('at least 18') ||
        context.contains('at least 21') ||
        context.contains('age limit')) {
      continue; // Skip age qualifications
    }

    final suffix = (firstNum == '1' && secondNum == null) ? 'year' : 'years';
    if (secondNum != null) {
      return '$firstNum-$secondNum $suffix';
    } else if (fullMatchStr.contains('+') || fullMatchStr.contains('plus')) {
      return '$firstNum+ $suffix';
    } else {
      return '$firstNum $suffix';
    }
  }

  return '—';
}
