import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

const careerPathHints = <String>[
  '/careers',
  '/jobs',
  '/join-us',
  '/work-with-us',
  '/opportunities',
  '/hiring',
  '/open-positions',
  '/positions',
  '/team/join',
  '/about/careers',
  '/company/careers',
  '/recruit',
  '/vacancies',
  '/en/careers',
  '/apply',
  '/work-here',
  '/come-work-with-us',
  '/life',
  '/people',
];

Future<Uri> discoverCareerUrl(http.Client client, Uri baseUri) async {
  final pathLower = baseUri.path.toLowerCase();
  final hasExplicitPath = pathLower.isNotEmpty && pathLower != '/';
  final looksLikeCareerPath = [
    'career',
    'job',
    'hiring',
    'position',
    'vacanc',
    'join',
    'work',
  ].any(pathLower.contains);

  if (hasExplicitPath && looksLikeCareerPath) {
    return baseUri;
  }

  final root = Uri(
    scheme: baseUri.scheme,
    host: baseUri.host,
    port: baseUri.hasPort ? baseUri.port : null,
    path: '/',
  );

  final probes = careerPathHints.map((hint) async {
    final candidate = root.resolve(hint);
    try {
      var response = await client
          .head(candidate)
          .timeout(const Duration(seconds: 3));
      if (response.statusCode == 403 ||
          response.statusCode == 405 ||
          response.statusCode == 501) {
        response = await client
            .get(candidate)
            .timeout(const Duration(seconds: 3));
      }
      if (response.statusCode < 400) {
        return candidate;
      }
    } catch (_) {}
    return null;
  }).toList();

  for (final probe in probes) {
    final hit = await probe;
    if (hit != null) {
      return hit;
    }
  }

  try {
    final resp = await client.get(baseUri).timeout(const Duration(seconds: 8));
    if (resp.statusCode >= 400) return baseUri;
    final doc = html_parser.parse(resp.body);

    for (final anchor in doc.querySelectorAll('a[href]')) {
      final href = anchor.attributes['href'] ?? '';
      final text = anchor.text.toLowerCase();
      final lowerHref = href.toLowerCase();
      final likely = [
        'career',
        'job',
        'hiring',
        'join us',
        'work with',
      ].any((k) => lowerHref.contains(k) || text.contains(k));
      if (!likely) continue;

      final resolved = root.resolve(href);
      if (resolved.host == baseUri.host) {
        return resolved;
      }
    }
  } catch (_) {}

  return baseUri;
}
