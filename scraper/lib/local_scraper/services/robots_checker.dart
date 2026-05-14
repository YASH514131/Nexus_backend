import 'dart:convert';

import 'package:http/http.dart' as http;

Future<bool> robotsOk(http.Client client, Uri target) async {
  try {
    final robotsUri = Uri(
      scheme: target.scheme,
      host: target.host,
      port: target.hasPort ? target.port : null,
      path: '/robots.txt',
    );

    final response = await client
        .get(robotsUri)
        .timeout(const Duration(seconds: 6));

    if (response.statusCode != 200) {
      return true;
    }

    final contentType = response.headers['content-type'] ?? '';
    if (!contentType.contains('text') && !contentType.contains('plain')) {
      return true;
    }

    final body = utf8.decode(response.bodyBytes).trim();
    final lower = body.toLowerCase();
    if (lower.startsWith('<!doctype') || lower.startsWith('<html')) {
      return true;
    }

    return _canFetchWildcard(body, target.path.isEmpty ? '/' : target.path);
  } catch (_) {
    return true;
  }
}

bool _canFetchWildcard(String robots, String path) {
  final lines = robots
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('#'));

  var inWildcard = false;
  final disallow = <String>[];
  final allow = <String>[];

  for (final line in lines) {
    final idx = line.indexOf(':');
    if (idx <= 0) continue;
    final key = line.substring(0, idx).trim().toLowerCase();
    final value = line.substring(idx + 1).trim();

    if (key == 'user-agent') {
      inWildcard = value == '*';
      continue;
    }
    if (!inWildcard) continue;

    if (key == 'disallow' && value.isNotEmpty) {
      disallow.add(value);
    }
    if (key == 'allow' && value.isNotEmpty) {
      allow.add(value);
    }
  }

  final denied = disallow.where((d) => path.startsWith(d)).toList();
  if (denied.isEmpty) return true;

  final allowed = allow.where((a) => path.startsWith(a)).toList();
  final deniedLongest = denied.fold<int>(
    0,
    (m, e) => e.length > m ? e.length : m,
  );
  final allowedLongest = allowed.fold<int>(
    0,
    (m, e) => e.length > m ? e.length : m,
  );

  return allowedLongest >= deniedLongest;
}
