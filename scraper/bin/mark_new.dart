import 'dart:convert';
import 'dart:io';

/// Marks each job in the current scrape as new (`isNew: true`) or
/// previously-seen (`isNew: false`) by diffing against the previous published
/// dataset. Runs in the merge job, where the full new dataset exists and the
/// previously-published jobs.json can be downloaded from the `latest` release.
///
/// Usage:
///   `dart run bin/mark_new.dart <previous.json> <current.json> <output.json>`
///
/// If `previous.json` is missing / empty / unreadable (e.g. the very first run,
/// or no release yet), every job is left as new — matching today's behaviour.
///
/// Job identity is `company|title|applyLink`, normalized. applyLink is the
/// per-posting URL (so distinct reqs never collide); company+title keep it
/// robust when an applyLink is generic. Lookup is an O(1) hash-set check, so
/// diffing tens of thousands of jobs is effectively instant.
void main(List<String> args) {
  if (args.length < 3) {
    stderr.writeln(
      'usage: dart run bin/mark_new.dart <previous.json> <current.json> <output.json>',
    );
    exit(64);
  }
  final prevPath = args[0];
  final currPath = args[1];
  final outPath = args[2];

  final current = _readJobs(currPath);
  if (current == null) {
    stderr.writeln('Cannot read current dataset: $currPath');
    exit(1);
  }

  final previous = _readJobs(prevPath);
  final seen = <String>{};
  if (previous != null) {
    for (final job in previous) {
      seen.add(_key(job));
    }
  }

  var newCount = 0;
  for (final job in current) {
    final isNew = !seen.contains(_key(job));
    job['isNew'] = isNew;
    if (isNew) newCount++;
  }

  File(outPath).writeAsStringSync(jsonEncode(current));
  stdout.writeln(
    'Marked ${current.length} jobs: $newCount new, '
    '${current.length - newCount} seen '
    '(previous dataset: ${previous?.length ?? 0} jobs).',
  );

  final githubEnvPath = Platform.environment['GITHUB_ENV'];
  if (githubEnvPath != null) {
    try {
      File(githubEnvPath).writeAsStringSync(
        'NEW_JOB_COUNT=$newCount\n',
        mode: FileMode.append,
      );
      stdout.writeln('Exported NEW_JOB_COUNT=$newCount to GITHUB_ENV');
    } catch (e) {
      stderr.writeln('Failed to write to GITHUB_ENV: $e');
    }
  }
}

List<Map<String, dynamic>>? _readJobs(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  final raw = file.readAsStringSync().trim();
  if (raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return null;
    return decoded.whereType<Map<String, dynamic>>().toList();
  } catch (_) {
    return null;
  }
}

String _key(Map<String, dynamic> job) {
  String norm(Object? v) => (v ?? '').toString().trim().toLowerCase();
  return '${norm(job['company'])}|${norm(job['title'])}|${norm(job['applyLink'])}';
}
