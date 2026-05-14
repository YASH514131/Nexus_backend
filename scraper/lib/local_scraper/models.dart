import 'dart:convert';

enum RunStatus { queued, scanning, complete, failed }

enum ResultBucket { hit, miss, error }

class CompanyInput {
  CompanyInput({required this.name, required this.url});

  final String name;
  final String url;

  factory CompanyInput.fromJson(Map<String, dynamic> json) {
    final url = (json['url'] ?? '').toString().trim();
    final rawName = (json['name'] ?? '').toString().trim();
    final name = rawName.isNotEmpty ? rawName : _fallbackNameFromUrl(url);
    return CompanyInput(name: name, url: url);
  }

  Map<String, dynamic> toJson() => {'name': name, 'url': url};
}

class ScanConfig {
  ScanConfig({
    required this.keywords,
    required this.excludeKeywords,
    required this.scanLimit,
    required this.concurrency,
    required this.enableJs,
    required this.hardTimeoutSeconds,
  });

  final List<String> keywords;
  final List<String> excludeKeywords;
  final int scanLimit;
  final int concurrency;
  final bool enableJs;
  final int hardTimeoutSeconds;

  factory ScanConfig.defaults() => ScanConfig(
    keywords: const ['intern', 'internship', 'trainee', 'co-op', 'apprentice'],
    excludeKeywords: const [
      'senior',
      'staff',
      'director',
      'manager',
      'principal',
    ],
    scanLimit: 20,
    concurrency: 4,
    enableJs: true,
    hardTimeoutSeconds: 40,
  );

  factory ScanConfig.fromJson(Map<String, dynamic> json) => ScanConfig(
    keywords: _csvish(json['keywords'], ScanConfig.defaults().keywords),
    excludeKeywords: _csvish(
      json['excludeKeywords'],
      ScanConfig.defaults().excludeKeywords,
    ),
    scanLimit: (json['scanLimit'] as num?)?.toInt() ?? 20,
    concurrency: (json['concurrency'] as num?)?.toInt() ?? 4,
    enableJs: (json['enableJs'] as bool?) ?? ScanConfig.defaults().enableJs,
    hardTimeoutSeconds: (json['hardTimeoutSeconds'] as num?)?.toInt() ?? 40,
  );

  Map<String, dynamic> toJson() => {
    'keywords': keywords,
    'excludeKeywords': excludeKeywords,
    'scanLimit': scanLimit,
    'concurrency': concurrency,
    'enableJs': enableJs,
    'hardTimeoutSeconds': hardTimeoutSeconds,
  };

  static List<String> _csvish(dynamic value, List<String> fallback) {
    if (value is List) {
      return value
          .map((e) => e.toString().trim().toLowerCase())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    if (value is String) {
      return value
          .split(',')
          .map((e) => e.trim().toLowerCase())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return fallback;
  }
}

class ScanResultRow {
  ScanResultRow({
    required this.company,
    required this.title,
    required this.companyUrl,
    required this.applyLink,
    required this.location,
    required this.duration,
    required this.deadline,
    required this.source,
    required this.error,
  });

  final String company;
  final String title;
  final String companyUrl;
  final String applyLink;
  final String location;
  final String duration;
  final String deadline;
  final String source;
  final String error;

  ResultBucket get bucket {
    if (error.trim().isNotEmpty) return ResultBucket.error;
    if (title == 'No internship found') return ResultBucket.miss;
    if (title == '—') return ResultBucket.error;
    return ResultBucket.hit;
  }

  Map<String, dynamic> toJson() => {
    'company': company,
    'title': title,
    'companyUrl': companyUrl,
    'applyLink': applyLink,
    'location': location,
    'duration': duration,
    'deadline': deadline,
    'source': source,
    'error': error,
    'bucket': bucket.name,
  };
}

class MetricsSnapshot {
  MetricsSnapshot({
    required this.scanned,
    required this.hits,
    required this.errors,
    required this.remote,
    required this.total,
  });

  final int scanned;
  final int hits;
  final int errors;
  final int remote;
  final int total;

  Map<String, dynamic> toJson() => {
    'scanned': scanned,
    'hits': hits,
    'errors': errors,
    'remote': remote,
    'total': total,
  };
}

class RunEvent {
  RunEvent({
    required this.index,
    required this.timestamp,
    required this.kind,
    required this.message,
    required this.metrics,
  });

  final int index;
  final DateTime timestamp;
  final String kind;
  final String message;
  final MetricsSnapshot metrics;

  Map<String, dynamic> toJson() => {
    'index': index,
    'timestamp': timestamp.toIso8601String(),
    'kind': kind,
    'message': message,
    'metrics': metrics.toJson(),
  };
}

class ScanRun {
  ScanRun({
    required this.id,
    required this.createdAt,
    required this.status,
    required this.config,
    required this.total,
    required this.results,
    required this.events,
  });

  final String id;
  final DateTime createdAt;
  RunStatus status;
  final ScanConfig config;
  final int total;
  final List<ScanResultRow> results;
  final List<RunEvent> events;

  MetricsSnapshot get metrics {
    final hits = results.where((r) => r.bucket == ResultBucket.hit).length;
    final errors = results.where((r) => r.bucket == ResultBucket.error).length;
    final scanned = results.map((r) => r.company).toSet().length;
    final remote = results
        .where((r) => r.bucket == ResultBucket.hit)
        .where((r) => r.location.toLowerCase().contains('remote'))
        .length;
    return MetricsSnapshot(
      scanned: scanned,
      hits: hits,
      errors: errors,
      remote: remote,
      total: total,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'status': status.name,
    'config': config.toJson(),
    'total': total,
    'metrics': metrics.toJson(),
  };
}

class StartRunRequest {
  StartRunRequest({required this.companies, required this.config});

  final List<CompanyInput> companies;
  final ScanConfig config;

  factory StartRunRequest.fromJson(Map<String, dynamic> json) {
    final config = json['config'] is Map<String, dynamic>
        ? ScanConfig.fromJson(json['config'] as Map<String, dynamic>)
        : ScanConfig.defaults();
    final companies = (json['companies'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(CompanyInput.fromJson)
        .where((c) => c.name.isNotEmpty && c.url.isNotEmpty)
        .toList();
    return StartRunRequest(companies: companies, config: config);
  }
}

String _fallbackNameFromUrl(String rawUrl) {
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) return '';
  final normalized =
      trimmed.startsWith('http://') || trimmed.startsWith('https://')
      ? trimmed
      : 'https://$trimmed';
  final uri = Uri.tryParse(normalized);
  if (uri == null || uri.host.isEmpty) return trimmed;
  final host = uri.host.replaceFirst('www.', '');
  final firstLabel = host.split('.').isNotEmpty ? host.split('.').first : host;
  if (firstLabel.isEmpty) return host;
  return '${firstLabel[0].toUpperCase()}${firstLabel.substring(1)}';
}

Map<String, dynamic> jsonObject(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Expected JSON object');
  }
  return decoded;
}
