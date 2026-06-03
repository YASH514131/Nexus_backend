import 'dart:convert';
import 'dart:io';

import 'package:scraper/local_scraper/models.dart';
import 'package:scraper/local_scraper/services/scraper_service.dart';
import 'package:scraper/default_companies.dart';

/// NEXUS backend scraper.
///
/// Designed to run as one shard of a fan-out/fan-in pipeline: a GitHub Actions
/// matrix launches N copies of this binary in parallel, each scraping a disjoint
/// slice of the company list, then a merge job concatenates the per-shard JSON.
///
/// Behaviour is driven by environment variables so the same binary works for a
/// single local run (defaults) and a sharded CI run:
///   SHARD_INDEX      this shard's id, 0-based            (default 0)
///   SHARD_COUNT      total number of shards              (default 1)
///   CONCURRENCY      max companies scraped at once        (default 50)
///   CALLS_PER_SECOND per-host request rate                (default 2.0)
///   OUTPUT           output file path                     (default jobs.json)
int _envInt(String key, int fallback) {
  final raw = Platform.environment[key]?.trim();
  if (raw == null || raw.isEmpty) return fallback;
  return int.tryParse(raw) ?? fallback;
}

double _envDouble(String key, double fallback) {
  final raw = Platform.environment[key]?.trim();
  if (raw == null || raw.isEmpty) return fallback;
  return double.tryParse(raw) ?? fallback;
}

String _envStr(String key, String fallback) {
  final raw = Platform.environment[key]?.trim();
  return (raw == null || raw.isEmpty) ? fallback : raw;
}

Future<void> main() async {
  final shardIndex = _envInt('SHARD_INDEX', 0);
  final shardCount = _envInt('SHARD_COUNT', 1);
  final concurrency = _envInt('CONCURRENCY', 50);
  final callsPerSecond = _envDouble('CALLS_PER_SECOND', 2.0);
  final outputPath = _envStr('OUTPUT', 'jobs.json');

  if (shardCount < 1 || shardIndex < 0 || shardIndex >= shardCount) {
    stderr.writeln(
      'Invalid shard config: SHARD_INDEX=$shardIndex SHARD_COUNT=$shardCount',
    );
    exit(64);
  }

  // Stable, ordered company list (Dart Map preserves insertion order).
  final allCompanies = defaultCompanyUrls.entries
      .map((e) => CompanyInput(name: e.key, url: e.value))
      .toList();

  // Round-robin assignment: spreads same-ATS clusters (which tend to sit next
  // to each other in the source list) evenly across shards, so no single shard
  // is stuck behind a run of slow hosts.
  final companies = <CompanyInput>[
    for (var i = 0; i < allCompanies.length; i++)
      if (i % shardCount == shardIndex) allCompanies[i],
  ];

  final config = ScanConfig(
    keywords: const [], // Empty list allows all jobs (fuzzyMatch is permissive).
    excludeKeywords: const [],
    scanLimit: 500,
    concurrency: 10,
    enableJs: false,
    hardTimeoutSeconds: 40,
  );

  print(
    'NEXUS scraper · shard $shardIndex/$shardCount · '
    '${companies.length}/${allCompanies.length} companies · '
    'concurrency=$concurrency · ${callsPerSecond}req/s/host',
  );

  if (companies.isEmpty) {
    await File(outputPath).writeAsString('[]');
    print('No companies in this shard — wrote empty $outputPath');
    exit(0);
  }

  final service = ScraperService(callsPerSecond: callsPerSecond);
  final allJobs = <Map<String, dynamic>>[];

  final sw = Stopwatch()..start();
  var cursor = 0;
  var done = 0;
  var failed = 0;

  // Worker-pool / sliding-window: a fixed set of workers each pull the next
  // company off a shared cursor as soon as they finish one. Unlike the old
  // batch-of-10 + Future.wait, there is no barrier — a single slow company
  // never blocks the others, so workers stay saturated until the queue drains.
  // (Dart's event loop is single-threaded, so the cursor read+increment between
  // await points is atomic; no lock is needed.)
  Future<void> worker() async {
    while (cursor < companies.length) {
      final company = companies[cursor++];
      try {
        final rows = await service
            .scrapeCompany(company, config)
            // Enforce the per-company hard timeout that the old pipeline never
            // actually applied — frees a stuck worker instead of letting one
            // company stall the whole shard.
            .timeout(Duration(seconds: config.hardTimeoutSeconds));
        for (final row in rows) {
          if (row.title == '—' || row.title == 'No internship found') continue;
          allJobs.add({
            'title': row.title,
            'company': row.company,
            'companyUrl': row.companyUrl,
            'applyLink': row.applyLink,
            'location': row.location,
            'duration': row.duration,
            'deadline': row.deadline,
            'source': row.source,
            'tags': <String>[],
            'isNew': true,
          });
        }
      } catch (e) {
        failed++;
        stderr.writeln('✗ ${company.name}: $e');
      } finally {
        done++;
        if (done % 10 == 0 || done == companies.length) {
          print(
            '  [$done/${companies.length}] '
            '${allJobs.length} jobs · ${sw.elapsed.inSeconds}s',
          );
        }
      }
    }
  }

  final workerCount = concurrency < companies.length
      ? concurrency
      : companies.length;
  await Future.wait(List.generate(workerCount, (_) => worker()));

  sw.stop();
  print(
    'Done · ${companies.length} companies · ${allJobs.length} jobs · '
    '$failed failed · ${sw.elapsed.inSeconds}s',
  );

  await File(outputPath).writeAsString(jsonEncode(allJobs));
  print('Wrote $outputPath');
  exit(0);
}
