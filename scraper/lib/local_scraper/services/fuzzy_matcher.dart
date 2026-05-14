int levenshtein(String a, String b) {
  if (a.length < b.length) {
    return levenshtein(b, a);
  }
  if (b.isEmpty) {
    return a.length;
  }

  var previous = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 0; i < a.length; i++) {
    final current = <int>[i + 1];
    for (var j = 0; j < b.length; j++) {
      final substitutionCost = a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1;
      current.add(
        _min3(
          previous[j + 1] + 1,
          current[j] + 1,
          previous[j] + substitutionCost,
        ),
      );
    }
    previous = current;
  }
  return previous.last;
}

bool fuzzyMatch(String text, List<String> keywords, {int threshold = 2}) {
  if (keywords.isEmpty) return true;

  final textLower = text.toLowerCase();
  if (keywords.any((kw) => textLower.contains(kw))) {
    return true;
  }

  final words = textLower.split(RegExp(r'\W+'));
  for (final word in words) {
    if (word.length < 4) continue;
    for (final kw in keywords) {
      if ((word.length - kw.length).abs() <= threshold) {
        if (levenshtein(word, kw) <= threshold) {
          return true;
        }
      }
    }
  }
  return false;
}

int _min3(int a, int b, int c) {
  final x = a < b ? a : b;
  return x < c ? x : c;
}
