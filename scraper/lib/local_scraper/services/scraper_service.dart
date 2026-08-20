import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import '../models.dart';
import 'career_discovery.dart';
import 'extractor.dart';
import 'fuzzy_matcher.dart';
import 'parser_helpers.dart';
import 'rate_limiter.dart';
import 'robots_checker.dart';

class ScraperService {
  ScraperService({http.Client? client, double callsPerSecond = 0.8})
    : _client = client ?? _createDefaultClient(),
      _limiter = RateLimiter(callsPerSecond: callsPerSecond);

  static http.Client _createDefaultClient() {
    final inner = HttpClient()..maxConnectionsPerHost = 100;
    return IOClient(inner);
  }

  final http.Client _client;
  final RateLimiter _limiter;
  final JobExtractor _extractor = JobExtractor();

  static const userAgents = <String>[
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4_1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    'Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:124.0) Gecko/20100101 Firefox/124.0',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:125.0) Gecko/20100101 Firefox/125.0',
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Mobile/15E148 Safari/604.1',
  ];

  static const _jobBoardHostHints = <String>[
    'careers.kula.ai',
    'kula.ai',
    'greenhouse.io',
    'lever.co',
    'workdayjobs.com',
    'myworkdayjobs.com',
    'ashbyhq.com',
    'smartrecruiters.com',
    'jobvite.com',
    'icims.com',
    'teamtailor.com',
    'recruitee.com',
    'reczee.com',
    'bamboohr.com',
  ];

  static ({String tenant, String site})? extractWorkdayTenantAndSite(
    Uri careerUri,
  ) {
    final host = careerUri.host.toLowerCase();
    if (!host.contains('myworkdaysite.com') &&
        !host.contains('myworkdayjobs.com')) {
      return null;
    }

    final segments = careerUri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return null;

    final recruitingIndex = segments.indexWhere(
      (s) => s.toLowerCase() == 'recruiting',
    );
    if (recruitingIndex >= 0 && recruitingIndex + 2 < segments.length) {
      return (
        tenant: segments[recruitingIndex + 1],
        site: segments[recruitingIndex + 2],
      );
    }

    // Workday hosted pages often use /<locale>/<site>, e.g. /en-GB/DBS_Careers.
    final first = segments.first;
    final localePrefix = RegExp(
      r'^[a-z]{2}(?:-[a-z]{2})?$',
      caseSensitive: false,
    );
    if (localePrefix.hasMatch(first) && segments.length >= 2) {
      final hostLabels = careerUri.host
          .split('.')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (hostLabels.isEmpty) return null;
      return (tenant: hostLabels.first, site: segments[1]);
    }

    final hostLabels = careerUri.host
        .split('.')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (hostLabels.isEmpty) return null;
    return (tenant: hostLabels.first, site: segments.first);
  }

  Future<List<ScanResultRow>> scrapeCompany(
    CompanyInput company,
    ScanConfig config,
  ) async {
    final base = _normalize(company.url);
    final uri = Uri.parse(base);
    final loweredHost = uri.host.toLowerCase();

    if (!_isPrioritizedKnownApi(loweredHost)) {
      final robotAllowed = await robotsOk(_client, uri);
      if (!robotAllowed) {
        return [
          ScanResultRow(
            company: company.name,
            title: '—',
            companyUrl: base,
            applyLink: base,
            location: '—',
            duration: '—',
            deadline: '—',
            source: '—',
            error: 'robots.txt disallowed',
          ),
        ];
      }
    }

    final careerUri = await discoverCareerUrl(_client, uri);
    final knownApiSeedUri = _selectKnownApiSeedUri(
      originalUri: uri,
      discoveredUri: careerUri,
    );

    final careerHost = careerUri.host.toLowerCase();
    if (careerHost.contains('a16zcrypto.com') ||
        careerHost.contains('remitly.com') ||
        careerHost.contains('myworkdayjobs.com') ||
        careerHost.contains('myworkdaysite.com') ||
        careerHost.contains('pwc.in') ||
        careerHost.contains('polygon.technology') ||
        careerHost.contains('greenhouse.io') ||
        careerHost.contains('jobs.ashbyhq.com') ||
        careerHost.contains('phonepe.com') ||
        careerHost.contains('phantom.com') ||
        careerHost.contains('pfizer.com') ||
        careerHost.contains('pepsicojobs.com') ||
        careerHost.contains('jobs.lever.co') ||
        careerHost.contains('paxos.com') ||
        careerHost.contains('paradigm.xyz') ||
        careerHost.contains('panteracapital.com') ||
        careerHost.contains('pgcareers.com') ||
        careerHost.contains('orange.jobs') ||
        careerHost.contains('limitbreak.com') ||
        careerHost.contains('careers.loreal.com') ||
        careerHost.contains('loreal.com') ||
        careerHost.contains('m2pfintech.com') ||
        careerHost.contains('maersk.com') ||
        careerHost.contains('mars.com') ||
        careerHost.contains('mastercard.com') ||
        careerHost.contains('navan.com') ||
        careerHost.contains('nestle.com') ||
        careerHost.contains('novartis.com') ||
        careerHost.contains('nvidia.com') ||
        careerHost.contains('niramai.com') ||
        careerHost.contains('gem.com') ||
        careerHost.contains('salesforce.com') ||
        careerHost.contains('shopify.com') ||
        careerHost.contains('signzy.com') ||
        careerHost.contains('slack.com') ||
        careerHost.contains('pyjamahr.com') ||
        careerHost.contains('smartowner.com') ||
        careerHost.contains('snowflake.com') ||
        careerHost.contains('sonyjobs.com') ||
        careerHost.contains('sorare.com') ||
        careerHost.contains('spotdraft.com') ||
        careerHost.contains('jobs.standardchartered.com') ||
        careerHost.contains('eightfold.ai') ||
        careerHost.contains('stripe.com') ||
        careerHost.contains('near.foundation')) {
      final apiRows = await _fetchKnownJsonApiRows(
        companyName: company.name,
        careerUri: knownApiSeedUri,
        keywords: config.keywords,
      );
      if (apiRows.isNotEmpty) {
        return apiRows;
      }
    }

    final html = await _fetch(careerUri);
    String? renderedHtml;
    if (html == null || html.trim().isEmpty) {
      final apiRows = await _fetchKnownJsonApiRows(
        companyName: company.name,
        careerUri: knownApiSeedUri,
        keywords: config.keywords,
      );
      if (apiRows.isNotEmpty) {
        return apiRows;
      }

      if (config.enableJs) {
        renderedHtml = await _fetchRendered(careerUri);
      }
      if (renderedHtml != null && renderedHtml.trim().isNotEmpty) {
        final renderedRows = _extractor.extract(
          html: renderedHtml,
          sourceUrl: careerUri,
          company: company.name,
          terms: config.keywords,
        );
        if (renderedRows.isNotEmpty) {
          return renderedRows;
        }
      }
      return [
        ScanResultRow(
          company: company.name,
          title: '—',
          companyUrl: base,
          applyLink: careerUri.toString(),
          location: '—',
          duration: '—',
          deadline: '—',
          source: '—',
          error: 'Fetch failed',
        ),
      ];
    }

    final shouldPrioritizeKnownApi = _isPrioritizedKnownApi(careerHost);
    if (shouldPrioritizeKnownApi) {
      final apiRows = await _fetchKnownJsonApiRows(
        companyName: company.name,
        careerUri: knownApiSeedUri,
        keywords: config.keywords,
      );
      if (apiRows.isNotEmpty) {
        return apiRows;
      }
    }

    final rows = _extractor.extract(
      html: html,
      sourceUrl: careerUri,
      company: company.name,
      terms: config.keywords,
    );

    if (rows.isEmpty) {
      final apiRows = await _fetchKnownJsonApiRows(
        companyName: company.name,
        careerUri: knownApiSeedUri,
        keywords: config.keywords,
      );
      if (apiRows.isNotEmpty) {
        return apiRows;
      }
    }

    if (rows.isEmpty && config.enableJs) {
      renderedHtml ??= await _fetchRendered(careerUri);
      if (renderedHtml != null && renderedHtml.trim().isNotEmpty) {
        final renderedRows = _extractor.extract(
          html: renderedHtml,
          sourceUrl: careerUri,
          company: company.name,
          terms: config.keywords,
        );
        if (renderedRows.isNotEmpty) {
          return renderedRows;
        }
      }
    }

    if (rows.isEmpty) {
      final linkSources = <String>[];
      if (html.trim().isNotEmpty) {
        linkSources.add(html);
      }
      if (renderedHtml != null && renderedHtml.trim().isNotEmpty) {
        linkSources.add(renderedHtml);
      }

      final candidates = _discoverLikelyJobBoardLinks(
        baseUrl: careerUri,
        sourceHtml: linkSources,
      );

      for (final candidate in candidates.take(3)) {
        final candidateHtml = await _fetch(candidate);
        if (candidateHtml != null && candidateHtml.trim().isNotEmpty) {
          final candidateRows = _extractor.extract(
            html: candidateHtml,
            sourceUrl: candidate,
            company: company.name,
            terms: config.keywords,
          );
          if (candidateRows.isNotEmpty) {
            return candidateRows;
          }
        }

        if (config.enableJs) {
          final candidateRendered = await _fetchRendered(candidate);
          if (candidateRendered != null &&
              candidateRendered.trim().isNotEmpty) {
            final candidateRows = _extractor.extract(
              html: candidateRendered,
              sourceUrl: candidate,
              company: company.name,
              terms: config.keywords,
            );
            if (candidateRows.isNotEmpty) {
              return candidateRows;
            }
          }
        }
      }
    }

    if (rows.isEmpty) {
      return [
        ScanResultRow(
          company: company.name,
          title: 'No internship found',
          companyUrl: base,
          applyLink: careerUri.toString(),
          location: '—',
          duration: '—',
          deadline: '—',
          source: '—',
          error: '',
        ),
      ];
    }
    return rows;
  }

  bool _isPrioritizedKnownApi(String loweredHost) {
    return loweredHost.contains('a16zcrypto.com') ||
        loweredHost.contains('remitly.com') ||
        loweredHost.contains('pwc.in') ||
        loweredHost.contains('polygon.technology') ||
        loweredHost.contains('phonepe.com') ||
        loweredHost.contains('phantom.com') ||
        loweredHost.contains('pfizer.com') ||
        loweredHost.contains('pepsicojobs.com') ||
        loweredHost.contains('paxos.com') ||
        loweredHost.contains('paradigm.xyz') ||
        loweredHost.contains('panteracapital.com') ||
        loweredHost.contains('pgcareers.com') ||
        loweredHost.contains('orange.jobs') ||
        loweredHost.contains('gem.com') ||
        loweredHost.contains('niramai.com') ||
        loweredHost.contains('nvidia.com') ||
        loweredHost.contains('novartis.com') ||
        loweredHost.contains('awign.com') ||
        loweredHost.contains('gauntlet.xyz') ||
        loweredHost.contains('search-careers.gm.com') ||
        loweredHost.contains('bain.com') ||
        loweredHost.contains('mondelezinternational.com') ||
        loweredHost.contains('morpho.org') ||
        loweredHost.contains('gomotive.com') ||
        loweredHost.contains('darwinbox.in') ||
        loweredHost.contains('capitalonecareers.com') ||
        loweredHost.contains('capgemini.com') ||
        loweredHost.contains('myworkdaysite.com') ||
        loweredHost.contains('myworkdayjobs.com') ||
        loweredHost.contains('careers.breadfinancial.com') ||
        loweredHost.contains('bitso.com') ||
        loweredHost.contains('careers.blackline.com') ||
        loweredHost.contains('jobs.blockchaincapital.com') ||
        loweredHost.contains('block.xyz') ||
        loweredHost.contains('blockchain.com') ||
        loweredHost.contains('avature.net') ||
        loweredHost.contains('jobs.ea.com') ||
        loweredHost.contains('binance.com') ||
        loweredHost.contains('bitcoinsuisse.com') ||
        loweredHost.contains('greenhouse.io') ||
        loweredHost.contains('careers.bcg.com') ||
        loweredHost.contains('careers.bankofamerica.com') ||
        loweredHost.contains('layerzero.network') ||
        loweredHost.contains('oraclecloud.com') ||
        loweredHost.contains('careers.oracle.com') ||
        loweredHost.contains('oracle.com') ||
        loweredHost.contains('eightfold.ai') ||
        loweredHost.contains('kraftheinz.com') ||
        loweredHost.contains('kellanova.com') ||
        loweredHost.contains('successfactors.com') ||
        loweredHost.contains('recsolu.com') ||
        loweredHost.contains('khatabook.com') ||
        loweredHost.contains('workforcenow.adp.com') ||
        loweredHost.contains('acko.com') ||
        loweredHost.contains('cashfree.com') ||
        loweredHost.contains('chaoslabs.xyz') ||
        loweredHost.contains('artivatic.ai') ||
        loweredHost.contains('att.jobs') ||
        loweredHost.contains('careers.astrazeneca.com') ||
        loweredHost.contains('careers.blackrock.com') ||
        loweredHost.contains('careers.coupa.com') ||
        loweredHost.contains('careers.cred.club') ||
        loweredHost.contains('copper.co') ||
        loweredHost.contains('cybrilla.com') ||
        loweredHost.contains('dapperlabs.com') ||
        loweredHost.contains('notion.site') ||
        loweredHost.contains('instahyre.com') ||
        loweredHost.contains('careers.kula.ai') ||
        loweredHost.contains('jobs.apple.com') ||
        loweredHost.contains('jobs.lever.co') ||
        loweredHost.contains('jobs.ashbyhq.com') ||
        loweredHost.contains('chainlinklabs.com') ||
        loweredHost.contains('careers.ford.com') ||
        loweredHost.contains('jobs.fidelity.com') ||
        loweredHost.contains('finbox.in') ||
        loweredHost.contains('careers.hcltech.com') ||
        loweredHost.contains('hashgraph.com') ||
        loweredHost.contains('hyperverge.co') ||
        loweredHost.contains('apply.hp.com') ||
        loweredHost.contains('careers.hp.com') ||
        loweredHost.contains('jobs.reczee.com') ||
        loweredHost.contains('finhaat.com') ||
        loweredHost.contains('metacareers.com') ||
        loweredHost.contains('etoro.com') ||
        loweredHost.contains('www.exodus.com') ||
        loweredHost.contains('careers.fabric.vc') ||
        loweredHost.contains('eyglobal.yello.co') ||
        loweredHost.contains('yello.co') ||
        loweredHost.contains('careers.etsy.com') ||
        loweredHost.contains('jobs.aon.com') ||
        loweredHost.contains('jobs.thecignagroup.com') ||
        loweredHost.contains('jobs.electriccapital.com') ||
        loweredHost.contains('consensys.io') ||
        loweredHost.contains('careers.circle.com') ||
        loweredHost.contains('careers.cisco.com') ||
        loweredHost.contains('careers.cognizant.com') ||
        loweredHost.contains('jobs.gsk.com') ||
        loweredHost.contains('careers.lilly.com') ||
        loweredHost.contains('southasiacareers.deloitte.com') ||
        loweredHost.contains('jobs.disneycareers.com') ||
        loweredHost.contains('jobs.ebayinc.com') ||
        loweredHost.contains('eigenlabs.org') ||
        loweredHost.contains('zohorecruit.in') ||
        loweredHost.contains('careers.dxc.com') ||
        loweredHost.contains('jobs.comcast.com') ||
        loweredHost.contains('jobs.citi.com') ||
        loweredHost.contains('careers.coca-colacompany.com') ||
        loweredHost.contains('dydx.exchange') ||
        loweredHost.contains('coinbase.com') ||
        loweredHost.contains('cwan.com') ||
        loweredHost.contains('0x.org') ||
        loweredHost.contains('www.google.com') ||
        loweredHost.contains('amazon.jobs') ||
        loweredHost.contains('accenture.com') ||
        loweredHost.contains('careers.amd.com') ||
        loweredHost.contains('search.jobs.barclays') ||
        loweredHost.contains('globalcareers.lge.com') ||
        loweredHost.contains('limitbreak.com') ||
        loweredHost.contains('freshteam.com') ||
        loweredHost.contains('careers.loreal.com') ||
        loweredHost.contains('m2pfintech.com') ||
        loweredHost.contains('maersk.com') ||
        loweredHost.contains('mars.com') ||
        loweredHost.contains('mastercard.com') ||
        loweredHost.contains('navan.com') ||
        loweredHost.contains('nestle.com') ||
        loweredHost.contains('near.foundation') ||
        loweredHost.contains('explore.jobs.netflix.net') ||
        loweredHost.contains('netflix.com') ||
        loweredHost.contains('careers.amgen.com');
  }

  Future<String?> _fetch(Uri uri) async {
    final domain = uri.host;

    // Retry on 429 instead of returning null. Callers treat a null page as
    // "no more pages" and stop paginating, so a single rate-limited request
    // used to silently drop the rest of a company's jobs — which gutted hit
    // counts when scraping big multi-page sites from datacenter IPs.
    // penalize() grows the per-host backoff, so each retry waits longer via
    // _limiter.wait(); the whole loop is still bounded by the per-company
    // hard timeout upstream.
    for (var attempt = 0; attempt < 3; attempt++) {
      await _limiter.wait(domain);
      try {
        final response = await _client
            .get(
              uri,
              headers: {
                'User-Agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
                'Accept-Language': 'en-US,en;q=0.9',
                'Accept':
                    'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                'DNT': '1',
              },
            )
            .timeout(const Duration(seconds: 10));

        if (response.statusCode == 429) {
          _limiter.penalize(domain);
          continue; // wait out the now-larger backoff and try again
        }
        if (response.statusCode >= 400) {
          return null;
        }
        _limiter.reset(domain);
        return response.body;
      } catch (_) {
        return null;
      }
    }
    return null; // exhausted 429 retries
  }

  Future<String?> _fetchRendered(Uri uri) async {
    // Mobile local scanning does not ship a Chromium runtime.
    return null;
  }

  List<Uri> _discoverLikelyJobBoardLinks({
    required Uri baseUrl,
    required List<String> sourceHtml,
  }) {
    final out = <Uri>[];
    final seen = <String>{};

    bool isLikely(Uri uri) {
      final host = uri.host.toLowerCase();
      final path = uri.path.toLowerCase();
      final hintHost = _jobBoardHostHints.any(host.contains);
      final hintPath = [
        '/jobs',
        '/careers',
        '/positions',
        '/open-positions',
        '/job/',
      ].any(path.contains);
      return hintHost || hintPath;
    }

    void maybeAdd(String? raw) {
      if (raw == null || raw.trim().isEmpty) return;
      final resolved = baseUrl.resolve(raw.trim());
      if (!['http', 'https'].contains(resolved.scheme)) return;
      if (!isLikely(resolved)) return;
      final key = resolved.toString();
      if (seen.contains(key)) return;
      if (resolved.toString() == baseUrl.toString()) return;
      seen.add(key);
      out.add(resolved);
    }

    for (final html in sourceHtml) {
      final doc = html_parser.parse(html);
      for (final a in doc.querySelectorAll('a[href]')) {
        maybeAdd(a.attributes['href']);
      }
      for (final frame in doc.querySelectorAll('iframe[src]')) {
        maybeAdd(frame.attributes['src']);
      }
      for (final script in doc.querySelectorAll('script[src]')) {
        maybeAdd(script.attributes['src']);
      }
    }

    return out;
  }

  Uri _selectKnownApiSeedUri({
    required Uri originalUri,
    required Uri discoveredUri,
  }) {
    final discoveredHost = discoveredUri.host.toLowerCase();
    final originalHost = originalUri.host.toLowerCase();

    if (originalHost.contains('orange.jobs') ||
        discoveredHost.contains('orange.jobs')) {
      return Uri.parse('https://orange.jobs/gb/en/search-results');
    }

    if (originalHost.contains('pepsicojobs.com') ||
        discoveredHost.contains('pepsicojobs.com')) {
      return Uri.parse('https://www.pepsicojobs.com/api/jobs');
    }

    if (originalHost.contains('phonepe.com') ||
        discoveredHost.contains('phonepe.com')) {
      return Uri.parse('https://boards.greenhouse.io/phonepe');
    }

    if (originalHost.contains('pwc.in') || discoveredHost.contains('pwc.in')) {
      return Uri.parse('https://www.pwc.in/careers/experienced-jobs.html');
    }

    if (originalHost.contains('remitly.com') ||
        discoveredHost.contains('remitly.com')) {
      return Uri.parse('https://careers.remitly.com/job-search-results/');
    }

    if (originalHost.contains('a16zcrypto.com') ||
        discoveredHost.contains('a16zcrypto.com')) {
      return Uri.parse('https://a16zcrypto.com/jobs/');
    }

    if (originalHost.contains('polygon.technology') ||
        discoveredHost.contains('polygon.technology')) {
      return Uri.parse('https://jobs.ashbyhq.com/polygon-labs');
    }

    if (originalHost.contains('phantom.com') ||
        discoveredHost.contains('phantom.com')) {
      return Uri.parse('https://jobs.ashbyhq.com/phantom');
    }

    if (originalHost.contains('pfizer.com') ||
        discoveredHost.contains('pfizer.com')) {
      return Uri.parse('https://pfizer.wd1.myworkdayjobs.com/PfizerCareers');
    }

    if (originalHost.contains('paradigm.xyz') ||
        discoveredHost.contains('paradigm.xyz')) {
      return Uri.parse('https://www.paradigm.xyz/careers');
    }

    if (originalHost.contains('salesforce.com') ||
        discoveredHost.contains('salesforce.com')) {
      return Uri.parse(
        'https://salesforce.wd12.myworkdayjobs.com/External_Career_Site',
      );
    }

    if (originalHost.contains('securitize.io') ||
        discoveredHost.contains('securitize.io')) {
      return Uri.parse('https://boards.greenhouse.io/securitize');
    }

    if (originalHost.contains('shopify.com') ||
        discoveredHost.contains('shopify.com')) {
      return Uri.parse('https://www.shopify.com/careers/search');
    }

    if (originalHost.contains('signzy.com') ||
        discoveredHost.contains('signzy.com')) {
      return Uri.parse(
        'https://signzy.keka.com/careers/api/embedjobs/default/active/54e30b3d-e138-4862-8055-8b2ce8c31009',
      );
    }

    if (originalHost.contains('slack.com') ||
        discoveredHost.contains('slack.com')) {
      return Uri.parse('https://salesforce.wd12.myworkdayjobs.com/Slack');
    }

    if (originalHost.contains('pyjamahr.com') ||
        discoveredHost.contains('pyjamahr.com')) {
      final queryParams = discoveredUri.queryParameters.isNotEmpty
          ? discoveredUri.queryParameters
          : originalUri.queryParameters;
      final companyUuid = queryParams['company_uuid'] ?? '2615584222';
      return Uri.parse(
        'https://api.pyjamahr.com/api/career/jobs/?company_uuid=$companyUuid',
      );
    }

    if (originalHost.contains('snowflake.com') ||
        discoveredHost.contains('snowflake.com')) {
      return Uri.parse('https://jobs.ashbyhq.com/snowflake');
    }

    if (originalHost.contains('sonyjobs.com') ||
        discoveredHost.contains('sonyjobs.com')) {
      return Uri.parse(
        'https://sonyglobal.wd1.myworkdayjobs.com/SonyGlobalCareers',
      );
    }

    if (originalHost.contains('sorare.com') ||
        discoveredHost.contains('sorare.com')) {
      return Uri.parse('https://jobs.ashbyhq.com/sorare');
    }

    if (originalHost.contains('spotdraft.com') ||
        discoveredHost.contains('spotdraft.com')) {
      return Uri.parse('https://jobs.ashbyhq.com/spotdraft');
    }

    if (originalHost.contains('jobs.standardchartered.com') ||
        discoveredHost.contains('jobs.standardchartered.com')) {
      final feedId =
          discoveredUri.queryParameters['feedid'] ??
          discoveredUri.queryParameters['feedId'] ??
          originalUri.queryParameters['feedid'] ??
          originalUri.queryParameters['feedId'] ??
          '363857';
      return Uri.parse(
        'https://jobs.standardchartered.com/services/rss/job/?feedid=$feedId',
      );
    }

    if (originalHost.contains('eightfold.ai') ||
        discoveredHost.contains('eightfold.ai')) {
      String tenant = originalHost.split('.').first;
      if (tenant == 'app' || tenant == 'careers') tenant = 'starbucks';
      final domain = originalUri.queryParameters['domain'] ?? '$tenant.com';
      return Uri.parse(
        'https://$originalHost/api/pcsx/search?domain=$domain&sort_by=timestamp',
      );
    }

    if (originalHost.contains('stripe.com') ||
        discoveredHost.contains('stripe.com')) {
      return Uri.parse(
        'https://boards-api.greenhouse.io/v1/boards/stripe/jobs?content=true',
      );
    }

    if (originalHost.contains('paxos.com') ||
        discoveredHost.contains('paxos.com')) {
      return Uri.parse('https://jobs.ashbyhq.com/paxos');
    }

    if (originalHost.contains('panteracapital.com') ||
        discoveredHost.contains('panteracapital.com')) {
      return Uri.parse(
        'https://jobs.panteracapital.com/api-boards/search-jobs',
      );
    }

    if (originalHost.contains('pgcareers.com') ||
        discoveredHost.contains('pgcareers.com')) {
      return Uri.parse('https://www.pgcareers.com/in/en/search-results');
    }

    if (originalHost.contains('morpho.org')) {
      return Uri.parse('https://jobs.ashbyhq.com/morpho');
    }

    if (originalHost.contains('navan.com')) {
      return Uri.parse('https://boards.greenhouse.io/tripactions');
    }

    if (originalHost.contains('near.foundation')) {
      return Uri.parse('https://boards.greenhouse.io/nearfoundation');
    }

    if (originalHost.contains('nestle.com')) {
      return Uri.parse('https://jobdetails.nestle.com/sitemap.xml');
    }

    if (originalHost.contains('explore.jobs.netflix.net') ||
        originalHost.contains('netflix.com') ||
        originalHost.contains('jobs.netflix.net')) {
      return Uri.parse(
        'https://explore.jobs.netflix.net/api/apply/v2/jobs?domain=netflix.com&start=0&num=10',
      );
    }

    if (originalHost.contains('gomotive.com')) {
      return Uri.parse('https://boards.greenhouse.io/gomotive');
    }

    if (originalHost.contains('maersk.com')) {
      return Uri.parse('https://maersk.wd3.myworkdayjobs.com/Maersk_Careers');
    }

    if (originalHost.contains('mondelezinternational.com')) {
      return Uri.parse('https://mdlz.wd3.myworkdayjobs.com/External');
    }

    if (originalHost.contains('mars.com')) {
      return Uri.parse('https://careers.mars.com/widgets');
    }

    if (originalHost.contains('mastercard.com')) {
      return Uri.parse('https://careers.mastercard.com/widgets');
    }

    if (originalHost.contains('gauntlet.xyz')) {
      return Uri.https('jobs.lever.co', '/gauntlet');
    }

    if (discoveredHost.contains('workforcenow.adp.com') &&
        originalHost.contains('workforcenow.adp.com')) {
      final discoveredPath = discoveredUri.path.toLowerCase();
      final originalPath = originalUri.path.toLowerCase();
      final hasCid = (originalUri.queryParameters['cid'] ?? '')
          .trim()
          .isNotEmpty;
      final isRecruitmentUrl = originalPath.contains('/mdf/recruitment/');
      if (discoveredPath == '/careers' && hasCid && isRecruitmentUrl) {
        return originalUri;
      }
    }

    if (discoveredHost.contains('jobs.apple.com') &&
        originalHost.contains('jobs.apple.com')) {
      final discoveredPath = discoveredUri.path.toLowerCase();
      final originalPath = originalUri.path.toLowerCase();
      if (discoveredPath.contains('/careers') &&
          originalPath.contains('/search')) {
        return originalUri;
      }
    }

    if (discoveredHost.contains('jobs.ebayinc.com') &&
        originalHost.contains('jobs.ebayinc.com')) {
      final discoveredPath = discoveredUri.path.toLowerCase();
      final originalPath = originalUri.path.toLowerCase();
      if (discoveredPath.contains('/careers') &&
          originalPath.contains('/search-results')) {
        return originalUri;
      }
    }

    if (discoveredHost.contains('jobs.ea.com') &&
        originalHost.contains('jobs.ea.com')) {
      final discoveredPath = discoveredUri.path.toLowerCase();
      final originalPath = originalUri.path.toLowerCase();
      if ((discoveredPath == '/careers' || discoveredPath == '/') &&
          originalPath.contains('/careers/home')) {
        return originalUri;
      }
    }

    if (discoveredHost.contains('metacareers.com') &&
        originalHost.contains('metacareers.com')) {
      final discoveredPath = discoveredUri.path.toLowerCase();
      final originalPath = originalUri.path.toLowerCase();
      if ((discoveredPath == '/' || discoveredPath == '/home') &&
          originalPath.contains('/jobsearch')) {
        return originalUri;
      }
    }

    if (discoveredHost.contains('careers.lilly.com') &&
        originalHost.contains('careers.lilly.com')) {
      final discoveredPath = discoveredUri.path.toLowerCase();
      final originalPath = originalUri.path.toLowerCase();
      if (discoveredPath.contains('/careers') &&
          originalPath.contains('/search-results')) {
        return originalUri;
      }
    }

    if (discoveredHost.contains('jobs.ashbyhq.com') &&
        originalHost.contains('jobs.ashbyhq.com')) {
      final discoveredPath = discoveredUri.path.toLowerCase();
      final originalSegments = originalUri.pathSegments
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if ((discoveredPath == '/careers' ||
              discoveredPath == '/' ||
              discoveredPath.isEmpty) &&
          originalSegments.isNotEmpty &&
          originalSegments.first.toLowerCase() != 'careers') {
        return originalUri;
      }
    }

    if (discoveredHost.contains('gem.com') &&
        originalHost.contains('gem.com')) {
      final discoveredPath = discoveredUri.path.toLowerCase();
      final originalSegments = originalUri.pathSegments
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if ((discoveredPath == '/careers' ||
              discoveredPath == '/jobs' ||
              discoveredPath == '/' ||
              discoveredPath.isEmpty) &&
          originalSegments.isNotEmpty &&
          originalSegments.first.toLowerCase() != 'careers' &&
          originalSegments.first.toLowerCase() != 'jobs') {
        return originalUri;
      }
    }

    if (discoveredHost.contains('greenhouse.io') &&
        originalHost.contains('greenhouse.io')) {
      final discoveredSegments = discoveredUri.pathSegments
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      final originalSegments = originalUri.pathSegments
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (discoveredSegments.length == 1 &&
          discoveredSegments.first.toLowerCase() == 'opportunities' &&
          originalSegments.isNotEmpty &&
          originalSegments.first.toLowerCase() != 'opportunities') {
        return originalUri;
      }
    }

    if (originalHost.contains('cwan.com') &&
        (discoveredHost.contains('myworkdayjobs.com') ||
            discoveredHost.contains('myworkdaysite.com'))) {
      return originalUri;
    }

    return discoveredUri;
  }

  Future<List<ScanResultRow>> _fetchKnownJsonApiRows({
    required String companyName,
    required Uri careerUri,
    required List<String> keywords,
  }) async {
    final host = careerUri.host.toLowerCase();

    if (host.contains('pepsicojobs.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        var page = 1;
        const limit = 100;
        var totalHits = limit;

        while (rows.length < totalHits) {
          final uri = Uri.parse(
            'https://www.pepsicojobs.com/api/jobs?page=$page&limit=$limit',
          );
          final resp = await _client
              .get(
                uri,
                headers: {
                  'User-Agent':
                      userAgents[DateTime.now().millisecond %
                          userAgents.length],
                  'Accept': 'application/json',
                },
              )
              .timeout(const Duration(seconds: 15));

          if (resp.statusCode != 200 || resp.body.trim().isEmpty) {
            break;
          }

          final data = jsonDecode(resp.body);
          if (data is! Map) break;

          final rawTotal = data['totalCount'];
          if (rawTotal is num) {
            totalHits = rawTotal.toInt();
          }

          final jobsList = data['jobs'] as List? ?? [];
          if (jobsList.isEmpty) break;

          for (final job in jobsList.whereType<Map>()) {
            final jobData = job['data'];
            if (jobData is! Map) continue;

            final map = jobData.map((k, v) => MapEntry(k.toString(), v));
            final title = (map['title'] ?? '').toString().trim();
            if (title.isEmpty) continue;

            final slug = (map['slug'] ?? '').toString().trim();
            final applyLink =
                (map['apply_url'] ?? '').toString().trim().isNotEmpty
                ? map['apply_url'].toString().trim()
                : 'https://www.pepsicojobs.com/main/jobs/$slug';

            final shortLoc = (map['short_location'] ?? '').toString().trim();
            final fullLoc = (map['full_location'] ?? '').toString().trim();
            final location = shortLoc.isNotEmpty
                ? shortLoc
                : (fullLoc.isNotEmpty ? fullLoc : 'Not specified');

            if (matchTerms.isNotEmpty) {
              final titleLower = title.toLowerCase();
              final exactWordMatch = matchTerms.any((kw) {
                final pattern = RegExp(
                  '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                );
                return pattern.hasMatch(titleLower) ||
                    pattern.hasMatch(location.toLowerCase());
              });
              if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
                continue;
              }
            }

            final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
            if (seen.add(key)) {
              final empType = (map['employment_type'] ?? '').toString().trim();
              final duration = empType.isNotEmpty
                  ? empType
                  : parseDuration(title).$1;
              final quals = (map['qualifications'] ?? '').toString().trim();
              final desc = (map['description'] ?? '').toString().trim();
              final exp = parseExperience(quals.isNotEmpty ? quals : desc);
              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location,
                  duration: duration,
                  deadline: '—',
                  source: 'PepsiCo Careers',
                  error: '',
                  experience: exp,
                ),
              );
            }
          }

          page++;
          if (jobsList.length < limit) break;
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('pwc.in')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final resp = await _client
            .get(
              careerUri,
              headers: {
                'User-Agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
              },
            )
            .timeout(const Duration(seconds: 15));

        if (resp.statusCode != 200 || resp.body.trim().isEmpty) {
          return const [];
        }

        final html = resp.body;
        const marker = 'var jsondata =';
        final startIndex = html.indexOf(marker);
        if (startIndex >= 0) {
          final jsonStart = html.indexOf('[', startIndex);
          var depth = 0;
          var jsonEnd = jsonStart;
          for (var i = jsonStart; i < html.length; i++) {
            if (html[i] == '[') depth++;
            if (html[i] == ']') {
              depth--;
              if (depth == 0) {
                jsonEnd = i + 1;
                break;
              }
            }
          }
          final jsonStr = html.substring(jsonStart, jsonEnd);
          final data = jsonDecode(jsonStr);
          if (data is List) {
            for (final job in data.whereType<Map>()) {
              final map = job.map((k, v) => MapEntry(k.toString(), v));
              final title = (map['title'] ?? '').toString().trim();
              if (title.isEmpty) continue;

              final applyLink = (map['apply'] ?? '').toString().trim();
              final location = (map['location'] ?? '').toString().trim();

              if (matchTerms.isNotEmpty) {
                final titleLower = title.toLowerCase();
                final exactWordMatch = matchTerms.any((kw) {
                  final pattern = RegExp(
                    '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                  );
                  return pattern.hasMatch(titleLower) ||
                      pattern.hasMatch(location.toLowerCase());
                });
                if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
                  continue;
                }
              }

              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.add(key)) {
                final exp = parseExperience(title);
                rows.add(
                  ScanResultRow(
                    company: companyName,
                    title: title,
                    companyUrl: careerUri.toString(),
                    applyLink: applyLink,
                    location: location.isEmpty ? 'Not specified' : location,
                    duration: parseDuration(title).$1,
                    deadline: '—',
                    source: 'PwC India Careers',
                    error: '',
                    experience: exp,
                  ),
                );
              }
            }
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('remitly.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        const org = 'companies/c9a5233b-7164-44d2-98df-974dcaa42789';
        const pageSize = 100;
        var offset = 0;
        int? total;

        while (true) {
          final getUri =
              Uri.parse(
                'https://jobsapi-google.m-cloud.io/api/job/search',
              ).replace(
                queryParameters: {
                  'CompanyName': org,
                  'pageSize': '$pageSize',
                  'offset': '$offset',
                },
              );

          final response = await _client
              .get(
                getUri,
                headers: {
                  'User-Agent':
                      userAgents[DateTime.now().millisecond %
                          userAgents.length],
                  'Accept': 'application/json',
                },
              )
              .timeout(const Duration(seconds: 15));

          if (response.statusCode != 200 || response.body.trim().isEmpty) {
            break;
          }

          final decoded = jsonDecode(response.body);
          if (decoded is! Map) {
            break;
          }

          total ??= int.tryParse('${decoded['totalHits'] ?? ''}');
          final searchResults = decoded['searchResults'] as List? ?? [];
          if (searchResults.isEmpty) {
            break;
          }

          for (final item in searchResults.whereType<Map>()) {
            final job = item['job'] as Map? ?? {};
            final map = job.map((k, v) => MapEntry(k.toString(), v));
            final title = (map['title'] ?? '').toString().trim();
            if (title.isEmpty) continue;

            final description = (map['description'] ?? '').toString().trim();
            final city = (map['primary_city'] ?? '').toString().trim();
            final state = (map['primary_state'] ?? '').toString().trim();
            final country = (map['primary_country'] ?? '').toString().trim();

            if (matchTerms.isNotEmpty) {
              final titleLower = title.toLowerCase();
              final searchable = [
                title,
                description,
                city,
                state,
                country,
              ].where((v) => v.trim().isNotEmpty).join(' | ').toLowerCase();

              final exactWordMatch = matchTerms.any((kw) {
                final pattern = RegExp(
                  '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                );
                return pattern.hasMatch(searchable);
              });
              if (!exactWordMatch &&
                  !fuzzyMatch(titleLower, matchTerms) &&
                  !fuzzyMatch(searchable, matchTerms)) {
                continue;
              }
            }

            final seoUrl = (map['seo_url'] ?? '').toString().trim();
            final urlVal = (map['url'] ?? '').toString().trim();
            final applyLink = urlVal.isNotEmpty
                ? urlVal
                : (seoUrl.isNotEmpty ? seoUrl : careerUri.toString());

            final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
            if (seen.add(key)) {
              final locationParts = [
                city,
                state,
                country,
              ].where((v) => v.isNotEmpty).toList();
              final location = locationParts.isEmpty
                  ? 'Not specified'
                  : locationParts.join(', ');

              final exp = parseExperience(description);
              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location,
                  duration: parseDuration(description).$1,
                  deadline: '—',
                  source: 'Google Cloud Jobs API',
                  error: '',
                  experience: exp,
                ),
              );
            }
          }

          offset += searchResults.length;
          if (total != null && offset >= total) {
            break;
          }
          if (searchResults.length < pageSize) {
            break;
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('a16zcrypto.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final resp = await _client
            .get(
              careerUri,
              headers: {
                'User-Agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
              },
            )
            .timeout(const Duration(seconds: 15));

        if (resp.statusCode != 200 || resp.body.trim().isEmpty) {
          return const [];
        }

        final html = resp.body;
        const marker = 'const portfolioJobs =';
        final startIndex = html.indexOf(marker);
        if (startIndex >= 0) {
          final jsonStart = html.indexOf('[', startIndex);
          var depth = 0;
          var jsonEnd = jsonStart;
          for (var i = jsonStart; i < html.length; i++) {
            if (html[i] == '[') depth++;
            if (html[i] == ']') {
              depth--;
              if (depth == 0) {
                jsonEnd = i + 1;
                break;
              }
            }
          }
          final jsonStr = html.substring(jsonStart, jsonEnd);
          final data = jsonDecode(jsonStr);
          if (data is List) {
            for (final comp in data.whereType<Map>()) {
              final compName = (comp['company'] ?? '').toString().trim();
              final jobs = comp['jobs'] as List? ?? [];
              for (final job in jobs.whereType<Map>()) {
                final map = job.map((k, v) => MapEntry(k.toString(), v));
                final title = (map['title'] ?? '').toString().trim();
                if (title.isEmpty) continue;

                final applyLink = (map['url'] ?? '').toString().trim();
                final locs = map['locations'] as List? ?? [];
                final isRemote = map['remote'] == true;

                final locParts = locs
                    .map((e) => e.toString().trim())
                    .where((s) => s.isNotEmpty)
                    .toList();
                var location = locParts.isEmpty
                    ? 'Not specified'
                    : locParts.join(', ');
                if (isRemote) {
                  if (location == 'Not specified') {
                    location = 'Remote';
                  } else if (!location.toLowerCase().contains('remote')) {
                    location = '$location (Remote)';
                  }
                }

                if (matchTerms.isNotEmpty) {
                  final titleLower = title.toLowerCase();
                  final searchable = [
                    title,
                    compName,
                    location,
                  ].where((v) => v.trim().isNotEmpty).join(' | ').toLowerCase();

                  final exactWordMatch = matchTerms.any((kw) {
                    final pattern = RegExp(
                      '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                    );
                    return pattern.hasMatch(searchable);
                  });
                  if (!exactWordMatch &&
                      !fuzzyMatch(titleLower, matchTerms) &&
                      !fuzzyMatch(searchable, matchTerms)) {
                    continue;
                  }
                }

                final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
                if (seen.add(key)) {
                  final yearsExp = map['yearsExperience'] as Map?;
                  var exp = '—';
                  if (yearsExp != null) {
                    final min = yearsExp['min'];
                    final max = yearsExp['max'];
                    if (min != null && max != null) {
                      exp = '$min-$max years';
                    } else if (min != null) {
                      exp = '$min+ years';
                    } else if (max != null) {
                      exp = 'Up to $max years';
                    }
                  }
                  if (exp == '—') {
                    exp = parseExperience(title);
                  }

                  rows.add(
                    ScanResultRow(
                      company: compName.isEmpty ? companyName : compName,
                      title: title,
                      companyUrl: careerUri.toString(),
                      applyLink: applyLink.isEmpty
                          ? careerUri.toString()
                          : applyLink,
                      location: location,
                      duration: parseDuration(title).$1,
                      deadline: '—',
                      source: 'a16z Crypto Jobs',
                      error: '',
                      experience: exp,
                    ),
                  );
                }
              }
            }
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('paradigm.xyz')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final html = await _fetch(careerUri);
        if (html == null || html.isEmpty) return const [];

        final marker = '<script id="__NEXT_DATA__" type="application/json">';
        final startIndex = html.indexOf(marker);
        if (startIndex < 0) return const [];

        final jsonStart = html.indexOf('{', startIndex + marker.length);
        if (jsonStart < 0) return const [];

        int depth = 0;
        int jsonEnd = jsonStart;
        for (int i = jsonStart; i < html.length; i++) {
          if (html[i] == '{') depth++;
          if (html[i] == '}') {
            depth--;
            if (depth == 0) {
              jsonEnd = i + 1;
              break;
            }
          }
        }

        final jsonStr = html.substring(jsonStart, jsonEnd);
        final data = jsonDecode(jsonStr);
        if (data is Map) {
          final props = data['props'] as Map? ?? {};
          final pageProps = props['pageProps'] as Map? ?? {};
          final jobsList = pageProps['jobs'] as List? ?? [];
          for (final job in jobsList.whereType<Map>()) {
            final map = job.map((k, v) => MapEntry(k.toString(), v));
            final title = (map['title'] ?? '').toString().trim();
            if (title.isEmpty) continue;

            final comp = (map['companyName'] ?? companyName).toString().trim();
            final applyLink = (map['url'] ?? '').toString().trim();
            if (applyLink.isEmpty) continue;

            final locs = map['locations'] as List? ?? [];
            final location = locs.isEmpty ? 'Not specified' : locs.join(', ');

            if (matchTerms.isNotEmpty) {
              final titleLower = title.toLowerCase();
              final compLower = comp.toLowerCase();
              final locLower = location.toLowerCase();
              final exactWordMatch = matchTerms.any((kw) {
                final pattern = RegExp(
                  '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                );
                return pattern.hasMatch(titleLower) ||
                    pattern.hasMatch(compLower) ||
                    pattern.hasMatch(locLower);
              });
              if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
                continue;
              }
            }

            final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
            if (seen.add(key)) {
              final durationData = parseDuration(title);
              final exp = parseExperience(title);
              rows.add(
                ScanResultRow(
                  company: comp,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location,
                  duration: durationData.$1,
                  deadline: '—',
                  source: 'Paradigm Careers',
                  error: '',
                  experience: exp,
                ),
              );
            }
          }
        }
        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('panteracapital.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final payload = {
          'meta': {'size': 1000},
          'board': {'id': 'pantera-capital', 'isParent': true},
          'query': {},
          'grouped': false,
        };

        final resp = await _client
            .post(
              careerUri,
              headers: {
                'User-Agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
                'Accept': 'application/json',
                'Content-Type': 'application/json',
              },
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 30));

        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body);
          if (data is Map) {
            final jobsList = data['jobs'] as List? ?? [];
            for (final job in jobsList.whereType<Map>()) {
              final map = job.map((k, v) => MapEntry(k.toString(), v));
              final title = (map['title'] ?? '').toString().trim();
              if (title.isEmpty) continue;

              final comp = (map['companyName'] ?? companyName)
                  .toString()
                  .trim();
              final applyLink = (map['applyUrl'] ?? map['url'] ?? '')
                  .toString()
                  .trim();
              if (applyLink.isEmpty) continue;

              final locs = map['locations'] as List? ?? [];
              final location = locs.isEmpty ? 'Not specified' : locs.join(', ');

              if (matchTerms.isNotEmpty) {
                final titleLower = title.toLowerCase();
                final compLower = comp.toLowerCase();
                final locLower = location.toLowerCase();
                final exactWordMatch = matchTerms.any((kw) {
                  final pattern = RegExp(
                    '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                  );
                  return pattern.hasMatch(titleLower) ||
                      pattern.hasMatch(compLower) ||
                      pattern.hasMatch(locLower);
                });
                if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
                  continue;
                }
              }

              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.add(key)) {
                final isContract = map['contractor'] == true;
                final duration = isContract
                    ? 'Contract'
                    : parseDuration(title).$1;
                final minYears = map['minYearsExp'];
                var exp = '—';
                if (minYears is num) {
                  final suffix = minYears == 1 ? 'year' : 'years';
                  exp = '$minYears+ $suffix';
                } else {
                  exp = parseExperience(title);
                }

                rows.add(
                  ScanResultRow(
                    company: comp,
                    title: title,
                    companyUrl: careerUri.toString(),
                    applyLink: applyLink,
                    location: location,
                    duration: duration,
                    deadline: '—',
                    source: 'Pantera Capital Jobs',
                    error: '',
                    experience: exp,
                  ),
                );
              }
            }
          }
        }
        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('orange.jobs') || host.contains('pgcareers.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        int totalHits = 0;
        int from = 0;
        int emptyStreak = 0;

        while (true) {
          final path = careerUri.path.isEmpty || careerUri.path == '/'
              ? (host.contains('orange.jobs')
                    ? '/gb/en/search-results'
                    : '/in/en/search-results')
              : careerUri.path;
          final uri = Uri.parse(
            '${careerUri.scheme}://${careerUri.host}$path?from=$from&s=1&sortBy=Most+recent',
          );
          final resp = await _client
              .get(
                uri,
                headers: {
                  'User-Agent':
                      userAgents[DateTime.now().millisecond %
                          userAgents.length],
                  'Accept':
                      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                },
              )
              .timeout(const Duration(seconds: 15));

          if (resp.statusCode != 200) {
            emptyStreak++;
            if (emptyStreak > 3) break;
            from += 10;
            continue;
          }

          final html = resp.body;
          final marker = '"eagerLoadRefineSearch":';
          final startIndex = html.indexOf(marker);
          if (startIndex < 0) {
            emptyStreak++;
            if (emptyStreak > 3) break;
            from += 10;
            continue;
          }

          final jsonStart = html.indexOf('{', startIndex + marker.length);
          if (jsonStart < 0) {
            emptyStreak++;
            if (emptyStreak > 3) break;
            from += 10;
            continue;
          }

          int depth = 0;
          int jsonEnd = jsonStart;
          for (int i = jsonStart; i < html.length; i++) {
            if (html[i] == '{') depth++;
            if (html[i] == '}') {
              depth--;
              if (depth == 0) {
                jsonEnd = i + 1;
                break;
              }
            }
          }

          Map<String, dynamic> data;
          try {
            final jsonStr = html.substring(jsonStart, jsonEnd);
            data = jsonDecode(jsonStr) as Map<String, dynamic>;
          } catch (e) {
            emptyStreak++;
            if (emptyStreak > 3) break;
            from += 10;
            continue;
          }

          if (from == 0) {
            totalHits = data['totalHits'] as int? ?? 0;
          }

          final dataObj = data['data'] as Map<String, dynamic>? ?? {};
          final jobsList = dataObj['jobs'] as List? ?? [];
          final jobs = jobsList.whereType<Map<String, dynamic>>().toList();

          if (jobs.isEmpty) {
            emptyStreak++;
            if (emptyStreak > 3) break;
          } else {
            emptyStreak = 0;
            for (final job in jobs) {
              final title = (job['title'] as String? ?? '').trim();
              if (title.isEmpty) continue;

              final applyLink = (job['applyUrl'] as String? ?? '').trim();
              if (applyLink.isEmpty) continue;

              final location =
                  (job['location'] as String? ??
                          job['cityStateCountry'] as String? ??
                          (job['multi_location'] as List?)?.join(', ') ??
                          'Not specified')
                      .trim();

              final descTeaser = (job['descriptionTeaser'] as String? ?? '')
                  .trim();
              final descTeaserKeyword =
                  (job['ml_job_parser']?['descriptionTeaser_keyword']
                              as String? ??
                          '')
                      .trim();
              final fullDesc = '$descTeaser\n$descTeaserKeyword';

              if (matchTerms.isNotEmpty) {
                final titleLower = title.toLowerCase();
                final descLower = fullDesc.toLowerCase();
                final locLower = location.toLowerCase();
                final exactWordMatch = matchTerms.any((kw) {
                  final pattern = RegExp(
                    '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                  );
                  return pattern.hasMatch(titleLower) ||
                      pattern.hasMatch(descLower) ||
                      pattern.hasMatch(locLower);
                });
                if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
                  continue;
                }
              }

              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.add(key)) {
                final durationData = parseDuration(fullDesc);
                final exp = parseExperience(fullDesc);
                rows.add(
                  ScanResultRow(
                    company: companyName,
                    title: title,
                    companyUrl: careerUri.toString(),
                    applyLink: applyLink,
                    location: location.isEmpty ? 'Not specified' : location,
                    duration: durationData.$1,
                    deadline: '—',
                    source: host.contains('orange.jobs')
                        ? 'Orange Jobs'
                        : 'P&G Careers',
                    error: '',
                    experience: exp,
                  ),
                );
              }
            }
          }

          from += 10;
          if (from > totalHits + 50) break;
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('explore.jobs.netflix.net') ||
        host.contains('netflix.com') ||
        host.contains('jobs.netflix.net')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        const pageSize = 10;
        int start = 0;
        int totalCount = 0;

        Future<Map<String, dynamic>?> fetchPage(int offset) async {
          final uri = Uri.parse(
            'https://explore.jobs.netflix.net/api/apply/v2/jobs'
            '?domain=netflix.com&start=$offset&num=10',
          );
          try {
            final resp = await _client
                .get(
                  uri,
                  headers: {
                    'User-Agent':
                        userAgents[DateTime.now().millisecond %
                            userAgents.length],
                    'Accept': 'application/json, */*',
                    'Accept-Language': 'en-US,en;q=0.9',
                    'Referer': 'https://explore.jobs.netflix.net/careers',
                  },
                )
                .timeout(const Duration(seconds: 20));
            if (resp.statusCode != 200) return null;
            return jsonDecode(resp.body) as Map<String, dynamic>?;
          } catch (_) {
            return null;
          }
        }

        // First page – also gets total count
        final firstPage = await fetchPage(start);
        if (firstPage == null) return const [];

        totalCount = (firstPage['count'] as num?)?.toInt() ?? 0;
        final positions = (firstPage['positions'] as List<dynamic>?) ?? [];

        void parsePositions(List<dynamic> positionList) {
          for (final pos in positionList) {
            if (pos is! Map<String, dynamic>) continue;
            final title = (pos['name'] as String? ?? '').trim();
            if (title.isEmpty) continue;
            final location = (pos['location'] as String? ?? '').trim();
            final applyLink =
                (pos['canonicalPositionUrl'] as String? ??
                        'https://explore.jobs.netflix.net/careers/job/${pos['id']}')
                    .trim();
            final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
            if (!seen.contains(key)) {
              seen.add(key);
              final description =
                  (pos['description'] ??
                          pos['job_description'] ??
                          pos['name'] ??
                          '')
                      .toString();
              final exp = parseExperience(description);
              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: 'https://explore.jobs.netflix.net/careers',
                  applyLink: applyLink,
                  location: location.isEmpty ? 'Not specified' : location,
                  duration: '—',
                  deadline: '—',
                  source: 'Netflix Careers (Eightfold API)',
                  error: '',
                  experience: exp,
                ),
              );
            }
          }
        }

        parsePositions(positions);
        start += pageSize;

        // Paginate until all jobs are fetched
        while (start < totalCount) {
          await _limiter.wait(host);
          final page = await fetchPage(start);
          if (page == null) break;
          final pagePositions = (page['positions'] as List<dynamic>?) ?? [];
          if (pagePositions.isEmpty) break;
          parsePositions(pagePositions);
          start += pageSize;
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('gem.com')) {
      try {
        final rows = <ScanResultRow>[];
        final boardId = careerUri.pathSegments.firstWhere(
          (s) => s.isNotEmpty,
          orElse: () => '',
        );
        if (boardId.isEmpty) return const [];

        final body = jsonEncode([
          {
            'operationName': 'JobBoardList',
            'variables': {'boardId': boardId},
            'query':
                'query JobBoardList(\$boardId: String!) { oatsExternalJobPostings(boardId: \$boardId) { jobPostings { id extId title locations { id name city isoCountry isRemote } } } }',
          },
        ]);

        final response = await _client
            .post(
              Uri.parse('https://jobs.gem.com/api/public/graphql/batch'),
              headers: {
                'User-Agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
                'Content-Type': 'application/json',
                'batch': 'true',
              },
              body: body,
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode != 200 || response.body.trim().isEmpty) {
          return const [];
        }

        final resList = jsonDecode(response.body) as List<dynamic>;
        if (resList.isEmpty) return const [];
        final firstRes = resList[0] as Map<String, dynamic>;
        final data = firstRes['data'] as Map<String, dynamic>;
        final oats = data['oatsExternalJobPostings'] as Map<String, dynamic>;
        final jobPostings = oats['jobPostings'] as List<dynamic>? ?? [];

        for (final job in jobPostings) {
          if (job is! Map<String, dynamic>) continue;
          final title = (job['title'] as String? ?? '').trim();
          final id = (job['id'] as String? ?? '').trim();
          if (title.isEmpty || id.isEmpty) continue;

          final applyLink = 'https://jobs.gem.com/$boardId/$id';
          final locs = job['locations'] as List<dynamic>? ?? [];
          var location = 'See listing';
          if (locs.isNotEmpty) {
            final loc = locs[0] as Map<String, dynamic>;
            location = (loc['name'] as String? ?? 'See listing').trim();
          }

          final exp = parseExperience(title);
          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location,
              duration: '—',
              deadline: '—',
              source: 'Gem Job Board (GraphQL API)',
              error: '',
              experience: exp,
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('niramai.com')) {
      try {
        final rows = <ScanResultRow>[];
        final response = await _client
            .get(
              Uri.parse('https://niramai.com/wp-json/wp/v2/jobpost'),
              headers: {
                'User-Agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
              },
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode != 200 || response.body.trim().isEmpty) {
          return const [];
        }

        final data = jsonDecode(response.body) as List<dynamic>;
        for (final item in data) {
          if (item is! Map<String, dynamic>) continue;

          final titleObj = item['title'] as Map<String, dynamic>?;
          var title = (titleObj?['rendered'] as String? ?? '').trim();
          title = title.replaceAll('&#8211;', '–').replaceAll('&amp;', '&');

          final applyLink = (item['link'] as String? ?? '').trim();
          if (title.isEmpty || applyLink.isEmpty) continue;

          final contentObj = item['content'] as Map<String, dynamic>?;
          final contentStr = contentObj?['rendered'] as String? ?? '';
          var location = 'See listing';
          final locMatch = RegExp(
            r'Location:\s*([^\n<]+)',
            caseSensitive: false,
          ).firstMatch(contentStr);
          if (locMatch != null) {
            location = locMatch.group(1)!.trim();
            location = location.replaceAll(RegExp(r'<[^>]*>'), '').trim();
          }

          final exp = parseExperience(contentStr);
          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: 'https://niramai.com/careers/',
              applyLink: applyLink,
              location: location,
              duration: '—',
              deadline: '—',
              source: 'Niramai Careers (WP API)',
              error: '',
              experience: exp,
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('nvidia.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};

        final headers = {
          'User-Agent':
              userAgents[DateTime.now().millisecond % userAgents.length],
          'Accept': 'application/json, text/plain, */*',
          'Content-Type': 'application/json',
        };

        final firstPageBody = jsonEncode({
          'appliedFacets': {},
          'limit': 20,
          'offset': 0,
          'searchText': '',
        });

        final firstPageResp = await _client.post(
          Uri.parse(
            'https://nvidia.wd5.myworkdayjobs.com/wday/cxs/nvidia/NVIDIAExternalCareerSite/jobs',
          ),
          headers: headers,
          body: firstPageBody,
        );

        if (firstPageResp.statusCode != 200) {
          return const [];
        }

        final firstPageData =
            jsonDecode(firstPageResp.body) as Map<String, dynamic>;
        final facets = firstPageData['facets'] as List<dynamic>? ?? [];
        final jobFamilyGroupFacet = facets.firstWhere(
          (f) =>
              f is Map<String, dynamic> &&
              f['facetParameter'] == 'jobFamilyGroup',
          orElse: () => null,
        );

        void addJob(Map<String, dynamic> job) {
          final title = (job['title'] as String? ?? '').trim();
          final externalPath = (job['externalPath'] as String? ?? '').trim();
          if (title.isEmpty || externalPath.isEmpty) return;

          final applyLink =
              'https://nvidia.wd5.myworkdayjobs.com/en-US/NVIDIAExternalCareerSite$externalPath';
          final location = (job['locationsText'] as String? ?? 'See listing')
              .trim();

          if (!seen.contains(applyLink)) {
            seen.add(applyLink);
            final exp = parseExperience(title);
            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: 'https://jobs.nvidia.com/careers',
                applyLink: applyLink,
                location: location,
                duration: '—',
                deadline: '—',
                source: 'NVIDIA Careers (Workday API)',
                error: '',
                experience: exp,
              ),
            );
          }
        }

        final firstPageJobs =
            firstPageData['jobPostings'] as List<dynamic>? ?? [];
        for (final job in firstPageJobs) {
          if (job is Map<String, dynamic>) {
            addJob(job);
          }
        }

        final facetTasks = <({String id, int offset})>[];
        if (jobFamilyGroupFacet != null) {
          final values = jobFamilyGroupFacet['values'] as List<dynamic>? ?? [];
          for (final val in values) {
            if (val is Map<String, dynamic>) {
              final id = val['id'] as String?;
              final count = val['count'] as int? ?? 0;
              if (id != null && count > 0) {
                for (int offset = 0; offset < count; offset += 20) {
                  facetTasks.add((id: id, offset: offset));
                }
              }
            }
          }
        }

        // Run concurrently with a workers pool
        final concurrency = 15;
        final queue = List<({String id, int offset})>.from(facetTasks);

        Future<void> worker() async {
          while (queue.isNotEmpty) {
            final task = queue.removeLast();
            final body = jsonEncode({
              'appliedFacets': {
                'jobFamilyGroup': [task.id],
              },
              'limit': 20,
              'offset': task.offset,
              'searchText': '',
            });

            try {
              final resp = await _client.post(
                Uri.parse(
                  'https://nvidia.wd5.myworkdayjobs.com/wday/cxs/nvidia/NVIDIAExternalCareerSite/jobs',
                ),
                headers: headers,
                body: body,
              );

              if (resp.statusCode == 200) {
                final data = jsonDecode(resp.body) as Map<String, dynamic>;
                final jobPostings = data['jobPostings'] as List<dynamic>? ?? [];
                for (final job in jobPostings) {
                  if (job is Map<String, dynamic>) {
                    addJob(job);
                  }
                }
              }
            } catch (_) {}
          }
        }

        await Future.wait(List.generate(concurrency, (_) => worker()));
        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('novartis.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};

        final response = await _client
            .get(
              Uri.parse('https://www.novartis.com/sitemap.xml'),
              headers: {
                'User-Agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
                'Accept': 'application/xml,text/xml,*/*',
              },
            )
            .timeout(const Duration(seconds: 30));

        if (response.statusCode != 200 || response.body.trim().isEmpty) {
          return const [];
        }

        final jobUrlRegex = RegExp(
          r'<loc>(https://www\.novartis\.com/careers/career-search/job/details/[^<]+)</loc>',
        );

        final matches = jobUrlRegex.allMatches(response.body);

        for (final m in matches) {
          final url = m.group(1)!.trim();
          if (!seen.contains(url)) {
            seen.add(url);

            final slugMatch = RegExp(r'/job/details/(.+)$').firstMatch(url);
            var title = 'Novartis Job';
            if (slugMatch != null) {
              var titleSlug = slugMatch.group(1)!;
              titleSlug = titleSlug.replaceFirst(RegExp(r'^req-\d+-'), '');
              titleSlug = titleSlug.replaceFirst(
                RegExp(r'-[a-z]{2}-[a-z]{2}$'),
                '',
              );
              title = titleSlug
                  .replaceAll('-', ' ')
                  .split(' ')
                  .map(
                    (w) => w.isEmpty
                        ? ''
                        : '${w[0].toUpperCase()}${w.substring(1)}',
                  )
                  .join(' ');
            }

            final exp = parseExperience(title);
            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: 'https://www.novartis.com/careers/career-search',
                applyLink: url,
                location: 'See listing',
                duration: '—',
                deadline: '—',
                source: 'Novartis Careers Sitemap',
                error: '',
                experience: exp,
              ),
            );
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('nestle.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};

        final response = await _client
            .get(
              careerUri,
              headers: {
                'User-Agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
                'Accept': 'application/xml,text/xml,*/*',
                'Accept-Language': 'en-US,en;q=0.9',
              },
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode != 200 || response.body.trim().isEmpty) {
          return const [];
        }

        final doc = html_parser.parse(response.body);
        final locs = doc
            .querySelectorAll('url loc')
            .map((el) => el.text.trim())
            .where((t) => t.isNotEmpty)
            .toList();

        String decodeComponentRobust(String s) {
          try {
            return Uri.decodeComponent(s);
          } catch (_) {
            try {
              return Uri.decodeFull(s);
            } catch (_) {
              return s
                  .replaceAll('%28', '(')
                  .replaceAll('%29', ')')
                  .replaceAll('%20', ' ');
            }
          }
        }

        String cleanTitle(String title) {
          var t = title.trim();
          final trailingPattern = RegExp(
            r'\s+(?:[A-Z]{2,3}\b\s+)?(?:\d+[\s\d-]*)$',
          );
          t = t.replaceFirst(trailingPattern, '').trim();

          t = t.replaceAll(
            RegExp(r'\s*\(mwd\)\s*$', caseSensitive: false),
            ' (m/w/d)',
          );
          t = t.replaceAll(
            RegExp(r'\s*\(hf\)\s*$', caseSensitive: false),
            ' (h/f)',
          );
          t = t.replaceAll(
            RegExp(r'\s*\(mwd\)-\s*$', caseSensitive: false),
            ' (m/w/d)',
          );
          t = t.replaceAll(
            RegExp(r'\s*\(m\/w\/d\)\s*$', caseSensitive: false),
            ' (m/w/d)',
          );
          return t;
        }

        for (final u in locs) {
          try {
            final uri = Uri.parse(u);
            final segments = uri.pathSegments
                .where((s) => s.isNotEmpty)
                .toList();
            if (segments.length >= 3 && segments[0] == 'job') {
              final jobInfo = segments[1];
              final firstHyphen = jobInfo.indexOf('-');
              if (firstHyphen != -1) {
                final locationRaw = jobInfo.substring(0, firstHyphen);
                final titleRaw = jobInfo.substring(firstHyphen + 1);

                final location = decodeComponentRobust(
                  locationRaw,
                ).replaceAll('-', ' ').trim();
                final title = cleanTitle(
                  decodeComponentRobust(titleRaw).replaceAll('-', ' ').trim(),
                );

                if (title.isNotEmpty) {
                  final key = '${title.toLowerCase()}|${u.toLowerCase()}';
                  if (!seen.contains(key)) {
                    seen.add(key);
                    final exp = parseExperience(title);
                    rows.add(
                      ScanResultRow(
                        company: companyName,
                        title: title,
                        companyUrl: 'https://www.nestle.com/jobs/search-jobs',
                        applyLink: u,
                        location: location.isEmpty ? 'Not specified' : location,
                        duration: '—',
                        deadline: '—',
                        source: 'Nestle Careers Sitemap',
                        error: '',
                        experience: exp,
                      ),
                    );
                  }
                }
              }
            }
          } catch (_) {}
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('careers.mars.com') ||
        host.contains('mars.com') ||
        host.contains('careers.mastercard.com') ||
        host.contains('mastercard.com') ||
        host.contains('roche.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        const pageSize = 100;

        Future<Map?> fetchOffset(int offset) async {
          final widgetHost = careerUri.host;
          final uri = Uri.https(widgetHost, '/widgets');
          try {
            final response = await _client
                .post(
                  uri,
                  headers: const {
                    'Content-Type': 'application/json',
                    'User-Agent':
                        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
                  },
                  body: jsonEncode({
                    "lang": "",
                    "deviceType": "desktop",
                    "country": "",
                    "pageName": "search-results",
                    "ddoKey": "refineSearch",
                    "sortBy": "",
                    "subsearch": "",
                    "from": offset,
                    "jobs": true,
                    "counts": true,
                    "all_fields": [
                      "remote",
                      "country",
                      "state",
                      "city",
                      "experienceLevel",
                      "category",
                      "profession",
                      "employmentType",
                      "jobLevel",
                    ],
                    "pageType": "search-results",
                    "size": pageSize,
                    "clearAll": false,
                    "jdsource": "facets",
                    "isSliderEnable": false,
                    "pageId": "page1",
                    "siteType": "external",
                    "keywords": "",
                    "global": true,
                    "selected_fields": {},
                    "locationData": {},
                  }),
                )
                .timeout(const Duration(seconds: 15));

            if (response.statusCode == 200) {
              return jsonDecode(response.body);
            } else {
              print(
                'Phenom fetchOffset(\$offset) failed with \${response.statusCode}',
              );
            }
          } catch (e) {
            print('Phenom fetchOffset(\$offset) exception: \$e');
          }
          return null;
        }

        void processJobs(List jobs) {
          for (final job in jobs.whereType<Map>()) {
            final title = (job['title'] ?? '').toString().trim();
            if (title.isEmpty) continue;

            final jobSeq = job['jobSeqNo'] ?? job['reqId'] ?? '';
            if (jobSeq.toString().isEmpty) continue;

            var applyLink = (job['applyUrl'] ?? '').toString().trim();
            if (applyLink.isEmpty) {
              applyLink = 'https://${careerUri.host}/global/en/job/$jobSeq';
            }

            final location = (job['location'] ?? '').toString().trim();
            final postedDate = (job['postedDate'] ?? '').toString().trim();
            final teaser = (job['descriptionTeaser'] ?? '').toString().trim();
            final category = (job['category'] ?? '').toString().trim();

            final searchable = [
              title,
              location,
              teaser,
              category,
            ].where((p) => p.trim().isNotEmpty).join(' | ').toLowerCase();

            if (keywords.isNotEmpty) {
              bool hasKeywordVariant(String kw) {
                final k = kw.toLowerCase().trim();
                if (k.isEmpty || k.length < 3) return false;
                if (searchable.contains(k)) return true;
                if (k.endsWith('y') && k.length > 1) {
                  final stem = k.substring(0, k.length - 1);
                  if (searchable.contains('${stem}ies')) return true;
                }
                if (k.endsWith('e') && k.length > 1) {
                  final stem = k.substring(0, k.length - 1);
                  if (searchable.contains('${k}d') ||
                      searchable.contains('${stem}ing')) {
                    return true;
                  }
                }
                return searchable.contains('${k}s') ||
                    searchable.contains('${k}es') ||
                    searchable.contains('${k}ing') ||
                    searchable.contains('${k}ed');
              }

              final titleLower = title.toLowerCase();
              final exactWordMatch = matchTerms.any((kw) {
                final pattern = RegExp(
                  '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                );
                return pattern.hasMatch(searchable);
              });
              final variantMatch = matchTerms.any(hasKeywordVariant);
              if (!exactWordMatch &&
                  !variantMatch &&
                  !fuzzyMatch(titleLower, matchTerms) &&
                  !fuzzyMatch(searchable, matchTerms)) {
                continue;
              }
            }

            final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
            if (!seen.contains(key)) {
              seen.add(key);
              final exp = parseExperience(teaser);
              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location.isEmpty ? 'Not specified' : location,
                  duration: postedDate.isEmpty ? '—' : 'Posted: $postedDate',
                  deadline: '—',
                  source: '$companyName Phenom People API',
                  error: '',
                  experience: exp,
                ),
              );
            }
          }
        }

        final firstData = await fetchOffset(0);
        if (firstData != null) {
          final refineSearch = firstData['refineSearch'];
          if (refineSearch is Map) {
            final totalHits = refineSearch['totalHits'] ?? 0;
            final jobsData = refineSearch['data'];
            if (jobsData is Map && jobsData['jobs'] is List) {
              final initialJobs = jobsData['jobs'] as List;
              processJobs(initialJobs);

              if (totalHits > pageSize) {
                final totalPages = (totalHits / pageSize).ceil();
                final offsets = List.generate(
                  totalPages - 1,
                  (i) => (i + 1) * pageSize,
                );

                const batchSize = 3;
                for (var i = 0; i < offsets.length; i += batchSize) {
                  final chunk = offsets.sublist(
                    i,
                    i + batchSize > offsets.length
                        ? offsets.length
                        : i + batchSize,
                  );

                  await Future.wait(
                    chunk.map((offset) async {
                      final pageData = await fetchOffset(offset);
                      if (pageData != null) {
                        final ref = pageData['refineSearch'];
                        if (ref is Map) {
                          final d = ref['data'];
                          if (d is Map && d['jobs'] is List) {
                            processJobs(d['jobs'] as List);
                          }
                        }
                      }
                    }),
                  );
                  await Future.delayed(const Duration(milliseconds: 300));
                }
              }
            }
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('careers.m2pfintech.com') ||
        host.contains('m2pfintech.com')) {
      try {
        final uri = Uri.parse(
          'https://lead.m2pfintech.com/api/darwin/careers/job-list',
        );
        final response = await _client
            .get(
              uri,
              headers: const {
                'accept': 'application/json, text/plain, */*',
                'user-agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
              },
            )
            .timeout(const Duration(seconds: 12));

        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map || decoded['data'] is! List) {
          return const [];
        }

        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        for (final item in decoded['data'].whereType<Map>()) {
          final map = item.map((k, v) => MapEntry(k.toString(), v));

          final title = (map['job_title'] ?? '').toString().trim();
          if (title.isEmpty) continue;

          final locationList = map['location_city'];
          String location = 'Not specified';
          if (locationList is List && locationList.isNotEmpty) {
            location = locationList
                .map((e) => e?.toString().trim() ?? '')
                .where((e) => e.isNotEmpty)
                .join(', ');
          } else if (locationList != null &&
              locationList.toString().isNotEmpty) {
            location = locationList.toString();
          }

          final dept = (map['department'] ?? '').toString().trim();
          final parentDept = (map['parent_department'] ?? '').toString().trim();
          final employeeType = (map['employee_type'] ?? '').toString().trim();

          final jobId = (map['job_id'] ?? '').toString().trim();
          if (jobId.isEmpty) continue;

          final applyLink =
              'https://careers.m2pfintech.com/job-description/$jobId';

          final searchable = [
            title,
            dept,
            parentDept,
            employeeType,
            location,
          ].where((p) => p.trim().isNotEmpty).join(' | ').toLowerCase();

          if (keywords.isNotEmpty) {
            bool hasKeywordVariant(String kw) {
              final k = kw.toLowerCase().trim();
              if (k.isEmpty || k.length < 3) return false;
              if (searchable.contains(k)) return true;
              if (k.endsWith('y') && k.length > 1) {
                final stem = k.substring(0, k.length - 1);
                if (searchable.contains('${stem}ies')) return true;
              }
              if (k.endsWith('e') && k.length > 1) {
                final stem = k.substring(0, k.length - 1);
                if (searchable.contains('${k}d') ||
                    searchable.contains('${stem}ing')) {
                  return true;
                }
              }
              return searchable.contains('${k}s') ||
                  searchable.contains('${k}es') ||
                  searchable.contains('${k}ing') ||
                  searchable.contains('${k}ed');
            }

            final titleLower = title.toLowerCase();
            final exactWordMatch = matchTerms.any((kw) {
              final pattern = RegExp(
                '\\b${RegExp.escape(kw.toLowerCase())}\\b',
              );
              return pattern.hasMatch(searchable);
            });
            final variantMatch = matchTerms.any(hasKeywordVariant);
            if (!exactWordMatch &&
                !variantMatch &&
                !fuzzyMatch(titleLower, matchTerms) &&
                !fuzzyMatch(searchable, matchTerms)) {
              continue;
            }
          }

          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          final expField =
              map['experience_required'] ?? map['experience'] ?? '';
          final exp = parseExperience('$expField $title');
          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location.isEmpty ? 'Not specified' : location,
              duration: employeeType.isEmpty ? '—' : employeeType,
              deadline: '—',
              source: 'M2P Careers API',
              error: '',
              experience: exp,
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('accenture.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final query = keywords.isEmpty ? '' : keywords.join(' ');

        final random = math.Random();
        // The API caps results at ~10k (totalHits overMaxHits) and honours
        // maxResultSize=100, so the whole catalogue needs ~100 requests of 100
        // instead of 834 of 12. ~8x fewer requests => the scan finishes in
        // ~20s instead of 80-150s (and >300s from CI's datacenter IP, where the
        // per-company timeout was cutting it to zero), for the same job yield.
        const totalEstimatedPages = 100;
        const pagesToScrape = 100;
        const batchSize = 6;

        // Random order across the pages (mild bot-detection evasion).
        final pageSet = <int>{};
        while (pageSet.length < pagesToScrape) {
          pageSet.add(random.nextInt(totalEstimatedPages) + 1);
        }
        final pageList = pageSet.toList();

        for (var i = 0; i < pageList.length; i += batchSize) {
          final currentBatch = pageList.sublist(
            i,
            i + batchSize > pageList.length ? pageList.length : i + batchSize,
          );

          await Future.wait(
            currentBatch.map((pageNumber) async {
              int resultsPerPage = 100;
              int startIndex = (pageNumber - 1) * resultsPerPage;

              final apiUri = Uri.parse(
                'https://www.accenture.com/api/accenture/elastic/findjobs',
              );
              var request = http.MultipartRequest('POST', apiUri);

              request.headers.addAll({
                'Accept': '*/*',
                'User-Agent':
                    userAgents[math.Random().nextInt(userAgents.length)],
                'Origin': 'https://www.accenture.com',
              });

              request.fields.addAll({
                'startIndex': startIndex.toString(),
                'maxResultSize': resultsPerPage.toString(),
                'jobKeyword': query,
                'jobCountry': 'India',
                'jobLanguage': 'en',
                'countrySite': 'in-en',
                'sortBy': '0',
                'searchType': 'vectorSearch',
                'enableQueryBoost': 'true',
                'minScore': '0.6',
                'getFeedbackJudgmentEnabled': 'true',
                'useCleanEmbedding': 'true',
                'score': 'true',
                'totalHits': 'true',
                'debugQuery': 'false',
                'jobFilters': '[]',
              });

              try {
                final streamedResponse = await _client
                    .send(request)
                    .timeout(const Duration(seconds: 10));
                final response = await http.Response.fromStream(
                  streamedResponse,
                );

                if (response.statusCode == 200 &&
                    response.body.trim().isNotEmpty) {
                  final decoded = jsonDecode(response.body);
                  if (decoded is Map && decoded['data'] is List) {
                    final jobs = decoded['data'] as List;
                    for (final item in jobs.whereType<Map>()) {
                      final map = item.map((k, v) => MapEntry(k.toString(), v));
                      final title = (map['title'] ?? '').toString().trim();
                      if (title.isEmpty) continue;

                      final description = (map['jobDescription'] ?? '')
                          .toString()
                          .trim();
                      final searchable = [
                        title,
                        description,
                      ].where((v) => v.isNotEmpty).join(' | ').toLowerCase();

                      final exactWordMatch = matchTerms.any((kw) {
                        final pattern = RegExp(
                          r'\b' + RegExp.escape(kw.toLowerCase()) + r'\b',
                        );
                        return pattern.hasMatch(searchable);
                      });

                      if (!exactWordMatch &&
                          !fuzzyMatch(title.toLowerCase(), matchTerms) &&
                          !fuzzyMatch(searchable, matchTerms)) {
                        continue;
                      }

                      final applyLink =
                          (map['jobDetailUrl'] ?? careerUri.toString())
                              .toString()
                              .trim()
                              .replaceAll('{0}', 'in-en');
                      final key =
                          '${title.toLowerCase()}|${applyLink.toLowerCase()}';

                      if (!seen.contains(key)) {
                        seen.add(key);
                        final locationsList = map['location'];
                        final location =
                            (locationsList is List && locationsList.isNotEmpty)
                            ? locationsList.join(', ')
                            : 'Not specified';
                        final durationData = parseDuration(description);

                        final exp = parseExperience(description);
                        rows.add(
                          ScanResultRow(
                            company: companyName,
                            title: title,
                            companyUrl: careerUri.toString(),
                            applyLink: applyLink,
                            location: location,
                            duration: durationData.$1,
                            deadline: '—',
                            source: 'Accenture API (Randomized Scan)',
                            error: '',
                            experience: exp,
                          ),
                        );
                      }
                    }
                  }
                }
              } catch (_) {}
            }),
          );
          await Future.delayed(const Duration(milliseconds: 200));
        }
        return rows;
      } catch (_) {
        return const [];
      }
    }

    // Handle Intel, Samsung, Sanofi, CoinDesk specifically, or any Workday-based site
    final workday = extractWorkdayTenantAndSite(careerUri);
    if (host.contains('intel.wd1.myworkdayjobs.com') ||
        host.contains('sec.wd3.myworkdayjobs.com') ||
        host.contains('sanofi.wd3.myworkdayjobs.com') ||
        host.contains('bullish.wd3.myworkdayjobs.com') ||
        host.contains('sonyglobal.wd1.myworkdayjobs.com') ||
        workday != null) {
      final tenant = workday?.tenant ?? 'intel';
      final site = workday?.site ?? 'External';
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final query = keywords.isEmpty ? '' : keywords.join(' ');

        final apiUri = Uri(
          scheme: careerUri.scheme,
          host: careerUri.host,
          path: '/wday/cxs/$tenant/$site/jobs',
        );

        final firstResponse = await _client
            .post(
              apiUri,
              headers: {
                'Content-Type': 'application/json',
                'Accept': 'application/json',
              },
              body: jsonEncode({
                "appliedFacets": {},
                "limit": 20,
                "offset": 0,
                "searchText": query,
              }),
            )
            .timeout(const Duration(seconds: 15));

        if (firstResponse.statusCode == 200) {
          final firstData = jsonDecode(firstResponse.body);
          final totalJobs = firstData['total'] ?? 0;
          final initialJobs = firstData['jobPostings'] as List? ?? [];

          void processJobs(List jobs) {
            for (final item in jobs.whereType<Map>()) {
              final title = (item['title'] ?? '').toString().trim();
              if (title.isEmpty) continue;

              final externalPath = item['externalPath'] ?? '';
              final applyLink =
                  'https://${careerUri.host}/en-US/$site$externalPath';
              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';

              if (!seen.contains(key)) {
                seen.add(key);
                final location = item['locationsText'] ?? 'Not specified';
                final postedOn = item['postedOn'] ?? '—';

                final exp = parseExperience(title);
                rows.add(
                  ScanResultRow(
                    company: companyName,
                    title: title,
                    companyUrl: careerUri.toString(),
                    applyLink: applyLink,
                    location: location,
                    duration: 'Posted: $postedOn',
                    deadline: '—',
                    source: 'Workday CXS API',
                    error: '',
                    experience: exp,
                  ),
                );
              }
            }
          }

          processJobs(initialJobs);

          if (totalJobs > 20) {
            final random = math.Random();
            final resultsPerPage = 20;
            final totalPages = (totalJobs / resultsPerPage).ceil();
            final pagesToFetch = totalPages > 200 ? 200 : totalPages;
            final pageSet = <int>{};
            while (pageSet.length < pagesToFetch - 1 &&
                pageSet.length < totalPages - 1) {
              pageSet.add(random.nextInt(totalPages - 1) + 1);
            }
            final pageList = pageSet.toList();
            const batchSize = 10;

            for (var i = 0; i < pageList.length; i += batchSize) {
              final currentBatch = pageList.sublist(
                i,
                i + batchSize > pageList.length
                    ? pageList.length
                    : i + batchSize,
              );

              await Future.wait(
                currentBatch.map((pageNumber) async {
                  final offset = pageNumber * resultsPerPage;
                  try {
                    final response = await _client
                        .post(
                          apiUri,
                          headers: {
                            'Content-Type': 'application/json',
                            'Accept': 'application/json',
                          },
                          body: jsonEncode({
                            "appliedFacets": {},
                            "limit": resultsPerPage,
                            "offset": offset,
                            "searchText": query,
                          }),
                        )
                        .timeout(const Duration(seconds: 10));

                    if (response.statusCode == 200) {
                      final data = jsonDecode(response.body);
                      final jobs = data['jobPostings'] as List? ?? [];
                      processJobs(jobs);
                    }
                  } catch (_) {}
                }),
              );
              await Future.delayed(const Duration(milliseconds: 200));
            }
          }
        }
        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('shopify.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};

        final urls = [
          'https://www.shopify.com/careers/search',
          'https://www.shopify.com/in/careers/disciplines/engineering-data',
        ];

        for (final u in urls) {
          try {
            final response = await _client
                .get(
                  Uri.parse(u),
                  headers: const {
                    'User-Agent':
                        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                  },
                )
                .timeout(const Duration(seconds: 15));

            if (response.statusCode == 200) {
              final body = response.body;

              // 1. HTML Query Parsing
              final doc = html_parser.parse(body);
              final aTags = doc.querySelectorAll('a[href*="/careers/"]');
              for (final a in aTags) {
                final href = a.attributes['href'] ?? '';
                final h4 = a.querySelector('h4');
                final title = (h4?.text ?? a.text).trim();

                final jidMatch = RegExp(
                  r'([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})',
                ).firstMatch(href);
                if (jidMatch != null &&
                    title.isNotEmpty &&
                    title.length > 2 &&
                    !title.contains('View all') &&
                    !title.contains('Careers')) {
                  final link = href.startsWith('http')
                      ? href
                      : 'https://www.shopify.com$href';
                  final key = '${title.toLowerCase()}|${link.toLowerCase()}';

                  if (!seen.contains(key)) {
                    seen.add(key);
                    final locSpan = a.querySelector(
                      '.location span, span.text-sm',
                    );
                    final location =
                        locSpan?.text.trim() ?? 'Remote / Americas / EMEA';
                    final exp = parseExperience(title);

                    rows.add(
                      ScanResultRow(
                        company: companyName,
                        title: title,
                        companyUrl: careerUri.toString(),
                        applyLink: link,
                        location: location,
                        duration: 'Full-time',
                        deadline: '—',
                        source: 'Shopify Careers API',
                        error: '',
                        experience: exp,
                      ),
                    );
                  }
                }
              }

              // 2. Remix Stream regex parsing
              final unescaped = body
                  .replaceAll(r'\"', '"')
                  .replaceAll(r'\\', r'\');

              final remixRegex = RegExp(
                r'"([^"]{3,120})",\s*"(?:20\d\d-\d\d-\d\d)?"?\s*,\s*"https:\/\/www\.shopify\.com\/careers\?ashby_jid=([a-f0-9\-]{36})"',
              );

              for (final m in remixRegex.allMatches(unescaped)) {
                final title = m.group(1)!.trim();
                final jid = m.group(2)!;
                final link = 'https://www.shopify.com/careers?ashby_jid=$jid';
                final key = '${title.toLowerCase()}|${link.toLowerCase()}';

                if (!seen.contains(key) &&
                    title.isNotEmpty &&
                    title.length > 2) {
                  seen.add(key);
                  final exp = parseExperience(title);

                  rows.add(
                    ScanResultRow(
                      company: companyName,
                      title: title,
                      companyUrl: careerUri.toString(),
                      applyLink: link,
                      location: 'Remote / Americas / EMEA',
                      duration: 'Full-time',
                      deadline: '—',
                      source: 'Shopify Careers API',
                      error: '',
                      experience: exp,
                    ),
                  );
                }
              }
            }
          } catch (_) {}
        }
        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('signzy.keka.com') || host.contains('signzy.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};

        final response = await _client
            .get(
              Uri.parse(
                'https://signzy.keka.com/careers/api/embedjobs/default/active/54e30b3d-e138-4862-8055-8b2ce8c31009',
              ),
              headers: const {'accept': 'application/json, text/plain, */*'},
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final jobs = jsonDecode(response.body) as List? ?? [];
          for (final item in jobs.whereType<Map>()) {
            final id = item['id'];
            final title = (item['title'] ?? '').toString().trim();
            if (title.isEmpty || id == null) continue;

            final applyLink = 'https://signzy.keka.com/careers/job/$id';
            final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';

            if (!seen.contains(key)) {
              seen.add(key);

              String locationStr = 'Bengaluru, India';
              final locs = item['jobLocations'] as List? ?? [];
              if (locs.isNotEmpty) {
                final names = locs
                    .map((l) {
                      if (l is Map) {
                        final city =
                            l['city'] ??
                            l['name'] ??
                            l['title'] ??
                            l['location'] ??
                            '';
                        final country = l['country'] ?? '';
                        return [
                          city,
                          country,
                        ].where((s) => s.toString().isNotEmpty).join(', ');
                      }
                      return l.toString();
                    })
                    .where((s) => s.isNotEmpty)
                    .join(' | ');
                if (names.isNotEmpty) locationStr = names;
              }

              final description = (item['description'] ?? '').toString();
              final exp = parseExperience(
                description.isNotEmpty ? description : title,
              );

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: locationStr,
                  duration: 'Full-time',
                  deadline: '—',
                  source: 'Keka API',
                  error: '',
                  experience: exp,
                ),
              );
            }
          }
        }
        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('pyjamahr.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};

        final queryParams = careerUri.queryParameters;
        final companyUuid = queryParams['company_uuid'] ?? '2615584222';
        final companySlug = queryParams['company'] ?? 'smallcase';

        String? nextUrl =
            'https://api.pyjamahr.com/api/career/jobs/?company_uuid=$companyUuid';

        while (nextUrl != null) {
          try {
            final response = await _client
                .get(
                  Uri.parse(nextUrl),
                  headers: const {
                    'accept': 'application/json, text/plain, */*',
                  },
                )
                .timeout(const Duration(seconds: 15));

            if (response.statusCode == 200) {
              final data = jsonDecode(response.body);
              if (data is Map && data['results'] is List) {
                final results = data['results'] as List;
                for (final item in results.whereType<Map>()) {
                  final title = (item['title'] ?? '').toString().trim();
                  if (title.isEmpty) continue;

                  final jobUuid =
                      item['job_uuid'] ?? item['slug'] ?? item['id'];
                  final applyLink =
                      'https://app.pyjamahr.com/careers?company=$companySlug&company_uuid=$companyUuid&job_uuid=$jobUuid';
                  final key =
                      '${title.toLowerCase()}|${applyLink.toLowerCase()}';

                  if (!seen.contains(key)) {
                    seen.add(key);

                    final locationStr =
                        (item['location'] ??
                                item['country'] ??
                                'Bengaluru, India')
                            .toString()
                            .trim();

                    final minExp = item['min_experience'];
                    final maxExp = item['max_experience'];
                    String exp = '—';
                    if (minExp != null || maxExp != null) {
                      final minVal = (minExp ?? 0).toString().replaceAll(
                        '.0',
                        '',
                      );
                      final maxVal = (maxExp ?? '').toString().replaceAll(
                        '.0',
                        '',
                      );
                      exp = maxVal.isNotEmpty
                          ? '$minVal-$maxVal years'
                          : '$minVal+ years';
                    } else {
                      exp = parseExperience(title);
                    }

                    rows.add(
                      ScanResultRow(
                        company: companyName,
                        title: title,
                        companyUrl: careerUri.toString(),
                        applyLink: applyLink,
                        location: locationStr,
                        duration: 'Full-time',
                        deadline: '—',
                        source: 'PyjamaHR API',
                        error: '',
                        experience: exp,
                      ),
                    );
                  }
                }
                nextUrl = data['next'] as String?;
              } else {
                break;
              }
            } else {
              break;
            }
          } catch (_) {
            break;
          }
        }
        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('smartowner.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};

        final response = await _client
            .get(
              Uri.parse('https://www.smartowner.com/so/of/career.htm'),
              headers: const {
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
              },
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final doc = html_parser.parse(response.body);
          final panelHeadings = doc.querySelectorAll(
            '.panel-heading, .card-header, h3, h4, a[data-toggle="collapse"]',
          );

          final validJobKeywords = [
            'executive',
            'manager',
            'developer',
            'architect',
            'avp',
            'vp',
            'lead',
            'analyst',
            'specialist',
            'assistant',
            'counsel',
            'engineer',
          ];

          for (final el in panelHeadings) {
            final text = el.text.trim();
            final lines = text
                .split('\n')
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList();

            if (lines.isNotEmpty) {
              final title = lines[0];

              if (validJobKeywords.any(
                    (k) => title.toLowerCase().contains(k),
                  ) &&
                  !title.toLowerCase().contains('privacy') &&
                  !title.toLowerCase().contains('cookie') &&
                  !title.toLowerCase().contains('term')) {
                String location = 'Bangalore, India';
                if (lines.length > 1 && lines[1].isNotEmpty) {
                  location = lines[1];
                }

                final applyLink = 'https://www.smartowner.com/so/of/career.htm';
                final key = title.toLowerCase();

                if (!seen.contains(key)) {
                  seen.add(key);

                  String exp = '—';
                  final parentPanel = el.parent;
                  if (parentPanel != null) {
                    final fullText = parentPanel.text;
                    final expMatch = RegExp(
                      r'(\d+\s*[-–to\s]*\d*\s*\+?\s*years?)',
                      caseSensitive: false,
                    ).firstMatch(fullText);
                    if (expMatch != null) {
                      exp = expMatch.group(1)!;
                    } else {
                      exp = parseExperience(fullText);
                    }
                  } else {
                    exp = parseExperience(title);
                  }

                  rows.add(
                    ScanResultRow(
                      company: companyName,
                      title: title,
                      companyUrl: careerUri.toString(),
                      applyLink: applyLink,
                      location: location,
                      duration: 'Full-time',
                      deadline: '—',
                      source: 'SmartOwner HTML Scraper',
                      error: '',
                      experience: exp,
                    ),
                  );
                }
              }
            }
          }
        }
        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('jobs.standardchartered.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};

        final feedId =
            careerUri.queryParameters['feedid'] ??
            careerUri.queryParameters['feedId'] ??
            '363857';
        final rssUri = Uri.parse(
          'https://jobs.standardchartered.com/services/rss/job/?feedid=$feedId',
        );

        final response = await _client
            .get(
              rssUri,
              headers: const {
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
              },
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final itemMatches = RegExp(
            r'<item>(.*?)</item>',
            dotAll: true,
          ).allMatches(response.body);

          for (final m in itemMatches) {
            final itemXml = m.group(1)!;
            final titleMatch = RegExp(
              r'<title>(.*?)</title>',
              dotAll: true,
            ).firstMatch(itemXml);
            final linkMatch = RegExp(
              r'<link>(.*?)</link>',
              dotAll: true,
            ).firstMatch(itemXml);

            var fullTitle = (titleMatch?.group(1) ?? '')
                .replaceAll('<![CDATA[', '')
                .replaceAll(']]>', '')
                .replaceAll('&amp;', '&')
                .trim();

            if (fullTitle.isEmpty) continue;

            var applyLink = (linkMatch?.group(1) ?? '')
                .replaceAll('<![CDATA[', '')
                .replaceAll(']]>', '')
                .replaceAll('&amp;', '&')
                .trim();

            String locationStr = 'Not specified';
            final locMatch = RegExp(r'\(([^()]+)\)$').firstMatch(fullTitle);
            if (locMatch != null) {
              locationStr = locMatch.group(1)!.trim();
              fullTitle = fullTitle
                  .replaceAll(RegExp(r'\s*\([^()]+\)$'), '')
                  .trim();
            }

            final key = '${fullTitle.toLowerCase()}|${applyLink.toLowerCase()}';
            if (!seen.contains(key)) {
              seen.add(key);

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: fullTitle,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: locationStr,
                  duration: 'Full-time',
                  deadline: '—',
                  source: 'Standard Chartered RSS Feed',
                  error: '',
                  experience: parseExperience(fullTitle),
                ),
              );
            }
          }
        }
        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('eightfold.ai')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};

        String tenant = host.split('.').first;
        if (tenant == 'app' || tenant == 'careers') tenant = 'starbucks';
        final domain = careerUri.queryParameters['domain'] ?? '$tenant.com';

        const maxTotal = 10000;
        const batchSize =
            20; // 20 concurrent requests per batch (200 jobs/batch)
        final totalPages = (maxTotal / 10).ceil();
        final hardTimeout = const Duration(seconds: 180);
        final stopwatch = Stopwatch()..start();

        for (
          var pageBatchStart = 0;
          pageBatchStart < totalPages;
          pageBatchStart += batchSize
        ) {
          if (rows.length >= maxTotal || stopwatch.elapsed > hardTimeout) break;

          final batchOffsets = <int>[];
          for (
            var i = 0;
            i < batchSize && (pageBatchStart + i) < totalPages;
            i++
          ) {
            batchOffsets.add((pageBatchStart + i) * 10);
          }

          final responses = await Future.wait(
            batchOffsets.map((startOffset) async {
              try {
                final apiUrl = Uri.parse(
                  'https://$host/api/pcsx/search?domain=$domain&sort_by=timestamp&start=$startOffset',
                );

                final response = await _client
                    .get(
                      apiUrl,
                      headers: const {
                        'User-Agent':
                            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                        'Accept': 'application/json, text/plain, */*',
                      },
                    )
                    .timeout(const Duration(seconds: 12));

                if (response.statusCode == 200) {
                  final data =
                      jsonDecode(response.body)['data']
                          as Map<String, dynamic>? ??
                      {};
                  return data['positions'] as List<dynamic>? ?? [];
                }
              } catch (_) {}
              return <dynamic>[];
            }),
          );

          var newInBatch = 0;
          for (final positions in responses) {
            for (final p in positions) {
              final title = (p['name'] as String? ?? 'Untitled').trim();
              final pid = (p['id'] ?? p['displayJobId'] ?? '').toString();
              if (title.isEmpty || pid.isEmpty) continue;

              final locs = (p['locations'] as List<dynamic>? ?? [])
                  .map((e) => e.toString().trim())
                  .where((e) => e.isNotEmpty)
                  .join(', ');
              final locationStr = locs.isEmpty ? 'Not specified' : locs;

              final applyLink = 'https://$host/careers?pid=$pid';
              final key = '$pid|${title.toLowerCase()}';

              if (!seen.contains(key)) {
                seen.add(key);

                rows.add(
                  ScanResultRow(
                    company: companyName,
                    title: title,
                    companyUrl: careerUri.toString(),
                    applyLink: applyLink,
                    location: locationStr,
                    duration: 'Full-time',
                    deadline: '—',
                    source: 'Eightfold PCSX API',
                    error: '',
                    experience: parseExperience(title),
                  ),
                );
                newInBatch++;
              }
            }
          }

          if (newInBatch == 0) break;
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('greenhouse.io')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};

        final response = await _client
            .get(
              careerUri,
              headers: const {
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
              },
            )
            .timeout(const Duration(seconds: 20));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final jobs = data['jobs'] as List? ?? [];

          for (final item in jobs) {
            final title = (item['title'] as String? ?? '').trim();
            final id = (item['id'] ?? '').toString();
            if (title.isEmpty) continue;

            final locMap = item['location'];
            final locationStr = (locMap is Map && locMap['name'] != null)
                ? locMap['name'].toString().trim()
                : 'Not specified';

            var applyLink = item['absolute_url'] as String? ?? '';
            if (applyLink.isEmpty) {
              applyLink =
                  'https://boards.greenhouse.io/embed/job_app?for=stripe&token=$id';
            }

            final key = '$id|${title.toLowerCase()}';
            if (!seen.contains(key)) {
              seen.add(key);

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: locationStr.isEmpty ? 'Not specified' : locationStr,
                  duration: 'Full-time',
                  deadline: '—',
                  source: 'Greenhouse API',
                  error: '',
                  experience: parseExperience(title),
                ),
              );
            }
          }
        }
        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('jobs.intuit.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final query = keywords.isEmpty ? 'software' : keywords.first;

        const maxPages = 35;
        const batchSize = 10;
        final pageList = List.generate(maxPages, (i) => i + 1);

        for (var i = 0; i < pageList.length; i += batchSize) {
          final currentBatch = pageList.sublist(
            i,
            i + batchSize > pageList.length ? pageList.length : i + batchSize,
          );

          await Future.wait(
            currentBatch.map((pageNumber) async {
              final uri = Uri.parse(
                'https://jobs.intuit.com/search-jobs/$query/27595/$pageNumber',
              );
              try {
                final response = await _client
                    .get(
                      uri,
                      headers: {
                        'User-Agent':
                            userAgents[math.Random().nextInt(
                              userAgents.length,
                            )],
                      },
                    )
                    .timeout(const Duration(seconds: 15));

                if (response.statusCode == 200) {
                  final doc = html_parser.parse(response.body);
                  final jobElements = doc.querySelectorAll(
                    '#search-results-list ul li',
                  );

                  for (final element in jobElements) {
                    final title =
                        element.querySelector('h2')?.text.trim() ?? '';
                    if (title.isEmpty) continue;

                    final path = element.querySelector('a')?.attributes['href'];
                    final applyLink = path != null
                        ? 'https://jobs.intuit.com$path'
                        : uri.toString();
                    final key =
                        '${title.toLowerCase()}|${applyLink.toLowerCase()}';

                    if (!seen.contains(key)) {
                      seen.add(key);
                      final location =
                          element
                              .querySelector('span.job-location')
                              ?.text
                              .trim() ??
                          'Not specified';

                      final exp = parseExperience(title);
                      rows.add(
                        ScanResultRow(
                          company: companyName,
                          title: title,
                          companyUrl: careerUri.toString(),
                          applyLink: applyLink,
                          location: location,
                          duration: '—',
                          deadline: '—',
                          source: 'Intuit HTML Scan',
                          error: '',
                          experience: exp,
                        ),
                      );
                    }
                  }
                }
              } catch (_) {}
            }),
          );
          await Future.delayed(const Duration(milliseconds: 300));
        }
        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('careers.jnj.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final query = keywords.isEmpty ? 'software' : keywords.first;

        const maxPages = 83;
        const batchSize = 10;
        final pageList = List.generate(maxPages, (i) => i + 1);

        for (var i = 0; i < pageList.length; i += batchSize) {
          final currentBatch = pageList.sublist(
            i,
            i + batchSize > pageList.length ? pageList.length : i + batchSize,
          );

          await Future.wait(
            currentBatch.map((pageNumber) async {
              final uri = Uri.parse(
                'https://www.careers.jnj.com/en/jobs/?page=$pageNumber&search=$query&origin=global#results',
              );
              try {
                final response = await _client
                    .get(
                      uri,
                      headers: {
                        'User-Agent':
                            userAgents[math.Random().nextInt(
                              userAgents.length,
                            )],
                      },
                    )
                    .timeout(const Duration(seconds: 15));

                if (response.statusCode == 200) {
                  final doc = html_parser.parse(response.body);
                  final jobLinks = doc.querySelectorAll(
                    'a.stretched-link.Link.js-view-job',
                  );

                  for (final link in jobLinks) {
                    final title = link.text.trim();
                    if (title.isEmpty) continue;

                    final path = link.attributes['href'];
                    final applyLink = path != null
                        ? 'https://www.careers.jnj.com$path'
                        : uri.toString();
                    final key =
                        '${title.toLowerCase()}|${applyLink.toLowerCase()}';

                    if (!seen.contains(key)) {
                      seen.add(key);
                      final jobCard = link.parent?.parent;
                      final location =
                          jobCard?.querySelector('address')?.text.trim() ??
                          'Not specified';

                      final exp = parseExperience(title);
                      rows.add(
                        ScanResultRow(
                          company: companyName,
                          title: title,
                          companyUrl: careerUri.toString(),
                          applyLink: applyLink,
                          location: location,
                          duration: '—',
                          deadline: '—',
                          source: 'J&J HTML Scan',
                          error: '',
                          experience: exp,
                        ),
                      );
                    }
                  }
                }
              } catch (_) {}
            }),
          );
          await Future.delayed(const Duration(milliseconds: 10));
        }
        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('myjar.app') || host.contains('applytojob.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};

        final pageHtml = await _fetch(careerUri);
        if (pageHtml == null || pageHtml.trim().isEmpty) {
          return const [];
        }

        final doc = html_parser.parse(pageHtml);

        // Try MyJar custom layout first
        var jobItems = doc.querySelectorAll('.job-item');
        if (jobItems.isNotEmpty) {
          for (final item in jobItems) {
            final title =
                item.querySelector('.font-bold.text-xl')?.text.trim() ?? '';
            if (title.isEmpty) continue;

            final link = item.querySelector('a[href*="applytojob.com"]');
            final applyLink = link?.attributes['href']?.trim() ?? '';
            if (applyLink.isEmpty) continue;

            final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
            if (!seen.contains(key)) {
              seen.add(key);
              final locationSpans = item.querySelectorAll('div.text-xs span');
              String location = 'Not specified';
              for (final span in locationSpans) {
                final t = span.text
                    .replaceAll('•', '')
                    .replaceAll('·', '')
                    .trim();
                if (t.isNotEmpty &&
                    ![
                      'on site',
                      'remote',
                      'hybrid',
                      'engineering',
                    ].contains(t.toLowerCase())) {
                  location = t;
                }
              }
              final exp = parseExperience(title);
              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location,
                  duration: '—',
                  deadline: '—',
                  source: 'MyJar HTML Scan',
                  error: '',
                  experience: exp,
                ),
              );
            }
          }
        } else {
          // Fallback to standard JazzHR layout
          final jobLinks = doc.querySelectorAll(
            '.resumator-job-title a, a.resumator-job-link',
          );
          for (final link in jobLinks) {
            final title = link.text.trim();
            if (title.isEmpty) continue;
            final href = link.attributes['href']?.trim() ?? '';
            if (href.isEmpty) continue;
            final applyLink = careerUri.resolve(href).toString();
            final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
            if (!seen.contains(key)) {
              seen.add(key);
              final location =
                  link.parent?.parent
                      ?.querySelector('.resumator-job-location')
                      ?.text
                      .trim() ??
                  'Not specified';
              final exp = parseExperience(title);
              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location,
                  duration: '—',
                  deadline: '—',
                  source: 'JazzHR HTML Scan',
                  error: '',
                  experience: exp,
                ),
              );
            }
          }
        }
        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('robinhood.com')) {
      try {
        final apiUri = Uri.parse(
          'https://boards-api.greenhouse.io/v1/boards/robinhood/jobs?content=true',
        );
        final response = await _client
            .get(apiUri)
            .timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final decoded = jsonDecode(response.body);
          if (decoded is Map && decoded['jobs'] is List) {
            final rows = <ScanResultRow>[];
            for (final item in (decoded['jobs'] as List).whereType<Map>()) {
              final title = (item['title'] ?? '').toString().trim();
              if (title.isEmpty) continue;

              final applyLink = (item['absolute_url'] ?? '').toString().trim();
              final location = (item['location']?['name'] ?? 'Not specified')
                  .toString()
                  .trim();

              final exp = parseExperience(title);

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location,
                  duration: '—',
                  deadline: '—',
                  source: 'Greenhouse API',
                  error: '',
                  experience: exp,
                ),
              );
            }
            return rows;
          }
        }
        return const [];
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('ripple.com')) {
      try {
        final apiUri = Uri.parse(
          'https://boards-api.greenhouse.io/v1/boards/ripple/jobs?content=true',
        );
        final response = await _client
            .get(apiUri)
            .timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final decoded = jsonDecode(response.body);
          if (decoded is Map && decoded['jobs'] is List) {
            final rows = <ScanResultRow>[];
            for (final item in (decoded['jobs'] as List).whereType<Map>()) {
              final title = (item['title'] ?? '').toString().trim();
              if (title.isEmpty) continue;

              final applyLink = (item['absolute_url'] ?? '').toString().trim();
              final location = (item['location']?['name'] ?? 'Not specified')
                  .toString()
                  .trim();

              final exp = parseExperience(title);

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location,
                  duration: '—',
                  deadline: '—',
                  source: 'Greenhouse API',
                  error: '',
                  experience: exp,
                ),
              );
            }
            return rows;
          }
        }
        return const [];
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('revolut.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final response = await _client
            .get(Uri.parse('https://www.revolut.com/careers/'))
            .timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final document = html_parser.parse(response.body);
          final scriptTag = document.querySelector('#__NEXT_DATA__');
          if (scriptTag != null) {
            final jsonData = jsonDecode(scriptTag.text);
            final pageProps = jsonData['props']?['pageProps'];
            if (pageProps != null && pageProps.containsKey('positions')) {
              final positions = pageProps['positions'];
              if (positions is List) {
                for (final job in positions) {
                  if (job is Map<String, dynamic>) {
                    final title = (job['text'] ?? '').toString().trim();
                    final jobId = (job['id'] ?? '').toString().trim();
                    if (title.isEmpty || jobId.isEmpty) continue;

                    final applyLink =
                        'https://www.revolut.com/careers/position/$jobId';
                    final key =
                        '${title.toLowerCase()}|${applyLink.toLowerCase()}';

                    if (!seen.contains(key)) {
                      seen.add(key);

                      String location = 'Not specified';
                      final locs = job['locations'];
                      if (locs is List && locs.isNotEmpty) {
                        final locNames = locs
                            .map((l) {
                              if (l is Map)
                                return (l['name'] ?? '').toString().trim();
                              return '';
                            })
                            .where((l) => l.isNotEmpty)
                            .toList();
                        if (locNames.isNotEmpty) location = locNames.join(', ');
                      }

                      final exp = parseExperience(title);

                      rows.add(
                        ScanResultRow(
                          company: companyName,
                          title: title,
                          companyUrl: careerUri.toString(),
                          applyLink: applyLink,
                          location: location,
                          duration: '—',
                          deadline: '—',
                          source: 'Revolut SSR (Next.js)',
                          error: '',
                          experience: exp,
                        ),
                      );
                    }
                  }
                }
                return rows;
              }
            }
          }
        }
        return const [];
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('rupeek.com')) {
      try {
        final response = await _client
            .get(careerUri)
            .timeout(const Duration(seconds: 15));
        if (response.statusCode == 200) {
          final html = response.body;
          final cleanHtml = html.replaceAll(r'\"', '"').replaceAll(r'\\"', '"');
          final parts = cleanHtml.split('https://www.linkedin.com/jobs/view/');
          final seen = <String>{};
          final rows = <ScanResultRow>[];

          for (int i = 1; i < parts.length; i++) {
            final part = parts[i];
            final urlEnd = part.indexOf('"');
            if (urlEnd == -1) continue;

            final urlSlug = part.substring(0, urlEnd);
            final applyLink = 'https://www.linkedin.com/jobs/view/$urlSlug';
            if (seen.contains(applyLink)) continue;
            seen.add(applyLink);

            String title = '';
            if (urlSlug.contains('-at-')) {
              final rawTitle = urlSlug.split('-at-').first;
              title = rawTitle
                  .replaceAll('-', ' ')
                  .split(' ')
                  .map(
                    (s) => s.isNotEmpty
                        ? '${s[0].toUpperCase()}${s.substring(1)}'
                        : '',
                  )
                  .join(' ');
            } else {
              title = urlSlug;
            }
            if (title.isEmpty) continue;

            final exp = parseExperience(title);

            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: careerUri.toString(),
                applyLink: applyLink,
                location: 'India',
                duration: '—',
                deadline: '—',
                source: 'Rupeek (Next.js)',
                error: '',
                experience: exp,
              ),
            );
          }
          return rows;
        }
      } catch (_) {
        return const [];
      }
      return const [];
    }

    if (host.contains('personio.com') || host.contains('personio.de')) {
      try {
        final xmlUri = Uri.parse('https://${careerUri.host}/xml');
        final response = await _client
            .get(xmlUri)
            .timeout(const Duration(seconds: 15));
        if (response.statusCode == 200) {
          final xml = response.body;
          final regex = RegExp(r'<position>.*?</position>', dotAll: true);
          final idRegex = RegExp(r'<id>(.*?)</id>');
          final nameRegex = RegExp(r'<name>(.*?)</name>');
          final officeRegex = RegExp(r'<office>(.*?)</office>');
          final expRegex = RegExp(
            r'<yearsOfExperience>(.*?)</yearsOfExperience>',
          );

          final rows = <ScanResultRow>[];
          final matches = regex.allMatches(xml);

          for (var match in matches) {
            final block = match.group(0)!;
            final id = idRegex.firstMatch(block)?.group(1)?.trim() ?? '';
            var title = nameRegex.firstMatch(block)?.group(1)?.trim() ?? '';
            // Remove CDATA if present
            title = title.replaceAll('<![CDATA[', '').replaceAll(']]>', '');

            final office =
                officeRegex.firstMatch(block)?.group(1)?.trim() ??
                'Not specified';
            final expYears = expRegex.firstMatch(block)?.group(1)?.trim() ?? '';

            if (id.isEmpty || title.isEmpty) continue;

            final applyLink = 'https://${careerUri.host}/job/$id';

            var exp = parseExperience(title);
            if (exp == '—' && expYears.isNotEmpty) {
              if (expYears.toLowerCase().contains('entry') ||
                  expYears.contains('< 1') ||
                  expYears.contains('0-')) {
                exp = 'Entry Level';
              } else if (expYears.contains('senior') ||
                  expYears.contains('5')) {
                exp = 'Senior Level';
              } else {
                exp = 'Mid Level';
              }
            }

            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: careerUri.toString(),
                applyLink: applyLink,
                location: office,
                duration: '—',
                deadline: '—',
                source: 'Personio XML',
                error: '',
                experience: exp,
              ),
            );
          }
          return rows;
        }
      } catch (_) {
        return const [];
      }
      return const [];
    }

    if (host.contains('jumpcrypto.com')) {
      try {
        final apiUri = Uri.parse(
          'https://boards-api.greenhouse.io/v1/boards/jumpcrypto/jobs?content=true',
        );
        final response = await _client
            .get(apiUri)
            .timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final decoded = jsonDecode(response.body);
          if (decoded is Map && decoded['jobs'] is List) {
            final rows = <ScanResultRow>[];
            for (final item in (decoded['jobs'] as List).whereType<Map>()) {
              final title = (item['title'] ?? '').toString().trim();
              if (title.isEmpty) continue;

              final applyLink = (item['absolute_url'] ?? '').toString().trim();
              final location = (item['location']?['name'] ?? 'Not specified')
                  .toString()
                  .trim();

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location,
                  duration: '—',
                  deadline: '—',
                  source: 'Greenhouse API',
                  error: '',
                ),
              );
            }
            return rows;
          }
        }
        return const [];
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('juspay.io')) {
      try {
        final rows = <ScanResultRow>[];
        final pageHtml = await _fetch(careerUri);
        if (pageHtml == null || pageHtml.trim().isEmpty) {
          return const [];
        }

        final regExp = RegExp(
          r'&quot;job_id&quot;:\[0,&quot;([^&]+)&quot;\],&quot;job_location&quot;:\[0,&quot;([^&]+)&quot;\],&quot;job_title&quot;:\[0,&quot;([^&]+)&quot;\]',
        );
        final matches = regExp.allMatches(pageHtml);

        for (final m in matches) {
          final id = m.group(1);
          final loc = m.group(2) ?? 'Not specified';
          final title = m.group(3) ?? 'No Title';

          final cleanTitle = title.replaceAll('&amp;', '&');
          final cleanLoc = loc.replaceAll('&amp;', '&');

          rows.add(
            ScanResultRow(
              company: companyName,
              title: cleanTitle,
              companyUrl: careerUri.toString(),
              applyLink: 'https://juspay.io/careers/$id',
              location: cleanLoc,
              duration: '—',
              deadline: '—',
              source: 'Juspay HTML Regex Scan',
              error: '',
            ),
          );
        }
        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('jobs.kellanova.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final query = keywords.isEmpty ? '' : keywords.join(' ');

        final startRows = [0, 51, 102];

        await Future.wait(
          startRows.map((start) async {
            final uri = Uri.parse(
              'https://jobs.kellanova.com/search/?q=$query&sortColumn=referencedate&sortDirection=desc&startrow=$start',
            );
            try {
              final response = await _client
                  .get(
                    uri,
                    headers: {
                      'User-Agent':
                          userAgents[math.Random().nextInt(userAgents.length)],
                    },
                  )
                  .timeout(const Duration(seconds: 15));

              if (response.statusCode == 200) {
                final doc = html_parser.parse(response.body);
                final jobLinks = doc.querySelectorAll('a.jobTitle-link');

                for (final link in jobLinks) {
                  final title = link.text.trim();
                  if (title.isEmpty) continue;

                  final path = link.attributes['href'];
                  final applyLink = path != null
                      ? 'https://jobs.kellanova.com$path'
                      : uri.toString();
                  final key =
                      '${title.toLowerCase()}|${applyLink.toLowerCase()}';

                  if (!seen.contains(key)) {
                    seen.add(key);
                    final row = link.parent?.parent?.parent;
                    final location =
                        row?.querySelector('span.jobLocation')?.text.trim() ??
                        'Not specified';

                    rows.add(
                      ScanResultRow(
                        company: companyName,
                        title: title,
                        companyUrl: careerUri.toString(),
                        applyLink: applyLink,
                        location: location,
                        duration: '—',
                        deadline: '—',
                        source: 'SuccessFactors Scan',
                        error: '',
                      ),
                    );
                  }
                }
              }
            } catch (_) {}
          }),
        );

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('khatabook.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final categories = [
          'Analytics',
          'Finance',
          'Technology',
          'Business',
          'Data Science',
          'Product & Design',
          'Risk, Policy & Underwriting',
        ];

        await Future.wait(
          categories.map((cat) async {
            final uri = Uri.parse(
              'https://khatabook.com/hiring/recruiter/list?category=${Uri.encodeComponent(cat)}',
            );
            try {
              final response = await _client
                  .get(
                    uri,
                    headers: {
                      'Accept':
                          'application/json, text/javascript, */*; q=0.01',
                      'X-Requested-With': 'XMLHttpRequest',
                      'User-Agent':
                          userAgents[math.Random().nextInt(userAgents.length)],
                    },
                  )
                  .timeout(const Duration(seconds: 15));

              if (response.statusCode == 200) {
                final decoded = jsonDecode(response.body);
                final jobs = decoded['data']?['Jobs'];
                if (jobs is List) {
                  for (final job in jobs) {
                    final title = (job['JobTitle'] ?? '').toString().trim();
                    if (title.isEmpty) continue;

                    final applyLink = (job['ApplyUrl'] ?? '').toString().trim();
                    if (applyLink.isEmpty) continue;

                    final key =
                        '${title.toLowerCase()}|${applyLink.toLowerCase()}';
                    if (!seen.contains(key)) {
                      seen.add(key);

                      String location = 'Not specified';
                      final rawLoc = job['Location'];
                      if (rawLoc is String && rawLoc.startsWith('[')) {
                        try {
                          final locList = jsonDecode(rawLoc);
                          if (locList is List && locList.isNotEmpty) {
                            location = locList[0]['Address'] ?? 'Not specified';
                          }
                        } catch (_) {}
                      }

                      rows.add(
                        ScanResultRow(
                          company: companyName,
                          title: title,
                          companyUrl: careerUri.toString(),
                          applyLink: applyLink,
                          location: location,
                          duration: '—',
                          deadline: '—',
                          source: 'Khatabook API Scan',
                          error: '',
                        ),
                      );
                    }
                  }
                }
              }
            } catch (_) {}
          }),
        );

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('illuvium.io')) {
      try {
        final apiUri = Uri.parse('https://illuvium.recruitee.com/api/offers');
        final response = await _client
            .get(
              apiUri,
              headers: {
                'accept': 'application/json, text/plain, */*',
                'user-agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
                'referer': careerUri.toString(),
              },
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map || decoded['offers'] is! List) {
          return const [];
        }

        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        for (final item in (decoded['offers'] as List).whereType<Map>()) {
          final map = item.map((k, v) => MapEntry(k.toString(), v));

          final title = (map['title'] ?? '').toString().trim();
          if (title.isEmpty) continue;

          final description = (map['sharing_description'] ?? '')
              .toString()
              .trim();
          final searchable = [
            title,
            description,
          ].where((v) => v.trim().isNotEmpty).join(' | ').toLowerCase();

          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp(r'\b${RegExp.escape(kw.toLowerCase())}\b');
            return pattern.hasMatch(searchable);
          });
          if (!exactWordMatch &&
              !fuzzyMatch(title.toLowerCase(), matchTerms) &&
              !fuzzyMatch(searchable, matchTerms)) {
            continue;
          }

          final rawLink = (map['careers_url'] ?? '').toString().trim();
          final applyLink = rawLink.isNotEmpty ? rawLink : careerUri.toString();

          final isRemote = map['remote'] == true;
          final city = (map['city'] ?? '').toString().trim();
          final country = (map['country'] ?? '').toString().trim();
          final region = (map['state_name'] ?? '').toString().trim();
          final locationParts = <String>[];
          if (isRemote) locationParts.add('Remote');
          if (city.isNotEmpty) locationParts.add(city);
          if (region.isNotEmpty && region != city) locationParts.add(region);
          if (country.isNotEmpty) locationParts.add(country);
          final location = locationParts.isEmpty
              ? 'Not specified'
              : locationParts.toSet().join(', ');

          final durationData = parseDuration(description);

          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location,
              duration: durationData.$1,
              deadline: '—',
              source: 'Recruitee API',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('www.google.com') &&
        careerUri.path.toLowerCase().contains(
          '/about/careers/applications/jobs/results',
        )) {
      try {
        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        String decodeEscaped(String input) {
          return input
              .replaceAll('\\/', '/')
              .replaceAll('\\u003d', '=')
              .replaceAll('\\u0026', '&')
              .replaceAll('\\u003f', '?')
              .replaceAll('\\u0027', "'")
              .replaceAll('&amp;', '&');
        }

        bool matchesWholeWordOrPlural(String text, String term) {
          final normalizedTerm = term.trim().toLowerCase();
          if (normalizedTerm.isEmpty) return false;

          final candidates = <String>{normalizedTerm};
          if (normalizedTerm.endsWith('s') && normalizedTerm.length > 1) {
            candidates.add(
              normalizedTerm.substring(0, normalizedTerm.length - 1),
            );
          } else {
            candidates.add('${normalizedTerm}s');
          }

          for (final candidate in candidates) {
            final pattern = RegExp('\\b${RegExp.escape(candidate)}\\b');
            if (pattern.hasMatch(text)) {
              return true;
            }
          }
          return false;
        }

        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final baseUri = careerUri.replace(fragment: '');
        const maxGooglePageCap = 96;
        final requestedMaxPage = int.tryParse(
          careerUri.queryParameters['page'] ?? '',
        );
        final maxGooglePages =
            (requestedMaxPage != null && requestedMaxPage > 0)
            ? (requestedMaxPage > maxGooglePageCap
                  ? maxGooglePageCap
                  : requestedMaxPage)
            : maxGooglePageCap;
        const googleBatchSize = 12;

        Future<MapEntry<Uri, String?>> fetchGooglePage(Uri uri) async {
          try {
            final response = await _client
                .get(
                  uri,
                  headers: {
                    'User-Agent':
                        userAgents[DateTime.now().millisecond %
                            userAgents.length],
                    'Accept-Language': 'en-US,en;q=0.9',
                    'Accept':
                        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                    'DNT': '1',
                  },
                )
                .timeout(const Duration(seconds: 10));
            if (response.statusCode < 400 && response.body.trim().isNotEmpty) {
              return MapEntry(uri, response.body);
            }
          } catch (_) {}

          final rendered = await _fetchRendered(uri);
          return MapEntry(uri, rendered);
        }

        final jobEntryPattern = RegExp(
          r'\["([0-9A-Za-z_-]+)","([^"]+)","(https://www\.google\.com/about/careers/applications/signin\?jobId\\u003d[^"]+)"',
        );
        for (
          var startPage = 1;
          startPage <= maxGooglePages;
          startPage += googleBatchSize
        ) {
          final endPage = (startPage + googleBatchSize - 1) > maxGooglePages
              ? maxGooglePages
              : (startPage + googleBatchSize - 1);
          final batchUris = <Uri>[];
          for (var page = startPage; page <= endPage; page++) {
            batchUris.add(
              baseUri.replace(
                queryParameters: {...baseUri.queryParameters, 'page': '$page'},
              ),
            );
          }

          final batchResults = await Future.wait(
            batchUris.map(fetchGooglePage),
          );

          for (final result in batchResults) {
            final pageUri = result.key;
            final html = result.value;
            if (html == null || html.trim().isEmpty) {
              continue;
            }

            final matches = jobEntryPattern.allMatches(html);
            for (final m in matches) {
              final rawTitle = m.group(2) ?? '';
              final rawLink = m.group(3) ?? '';

              final title = normalize(decodeEscaped(rawTitle));
              final applyLink = decodeEscaped(rawLink);
              if (title.isEmpty || applyLink.isEmpty) continue;

              final searchable = [title, applyLink].join(' | ').toLowerCase();
              final exactWordMatch = matchTerms.any((kw) {
                return matchesWholeWordOrPlural(searchable, kw);
              });
              if (!exactWordMatch &&
                  !fuzzyMatch(title.toLowerCase(), matchTerms) &&
                  !fuzzyMatch(searchable, matchTerms)) {
                continue;
              }

              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.contains(key)) continue;
              seen.add(key);

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: pageUri.toString(),
                  applyLink: applyLink,
                  location: 'Not specified',
                  duration: 'Unknown',
                  deadline: '—',
                  source: 'Google Careers Embedded Data',
                  error: '',
                ),
              );
            }
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('jobs.gsk.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final query = keywords.isEmpty ? 'intern' : keywords.join(' ');
        final limit =
            int.tryParse(careerUri.queryParameters['limit'] ?? '100') ?? 100;

        for (var pageNumber = 1; pageNumber <= 8; pageNumber++) {
          final uri = Uri(
            scheme: careerUri.scheme,
            host: careerUri.host,
            path: '/api/jobs',
            queryParameters: {
              'keywords': query,
              'page': '$pageNumber',
              'limit': '$limit',
            },
          );

          final response = await _client
              .get(
                uri,
                headers: const {'accept': 'application/json, text/plain, */*'},
              )
              .timeout(const Duration(seconds: 12));

          if (response.statusCode >= 400 || response.body.trim().isEmpty) {
            continue;
          }

          final decoded = jsonDecode(response.body);
          if (decoded is! Map || decoded['jobs'] is! List) {
            continue;
          }

          for (final item in (decoded['jobs'] as List).whereType<Map>()) {
            final data = item['data'];
            if (data is! Map) continue;
            final map = data.map((k, v) => MapEntry(k.toString(), v));

            final title = (map['title'] ?? '').toString().trim();
            if (title.isEmpty) continue;

            final description = (map['description'] ?? '').toString().trim();
            final searchable = [
              title,
              description,
              (map['searchable'] ?? '').toString(),
            ].where((p) => p.trim().isNotEmpty).join(' | ').toLowerCase();

            final titleLower = title.toLowerCase();
            final exactWordMatch = matchTerms.any((kw) {
              final pattern = RegExp(
                '\\b${RegExp.escape(kw.toLowerCase())}\\b',
              );
              return pattern.hasMatch(searchable);
            });
            if (!exactWordMatch &&
                !fuzzyMatch(titleLower, matchTerms) &&
                !fuzzyMatch(searchable, matchTerms)) {
              continue;
            }

            final durationData = parseDuration(description);

            final locationParts = <String>[];
            final street = (map['street_address'] ?? '').toString().trim();
            final city = (map['city'] ?? '').toString().trim();
            final state = (map['state'] ?? '').toString().trim();
            final country = (map['country'] ?? '').toString().trim();
            if (street.isNotEmpty) locationParts.add(street);
            if (city.isNotEmpty) locationParts.add(city);
            if (state.isNotEmpty) locationParts.add(state);
            if (country.isNotEmpty) locationParts.add(country);
            var location = locationParts.join(', ');
            if (location.isEmpty) {
              final additionalLocations = map['additional_locations'];
              if (additionalLocations is List &&
                  additionalLocations.isNotEmpty) {
                final locs = additionalLocations
                    .whereType<Map>()
                    .map((e) => (e['location'] ?? '').toString().trim())
                    .where((v) => v.isNotEmpty)
                    .toList();
                if (locs.isNotEmpty) {
                  location = locs.join(', ');
                }
              }
            }
            if (location.isEmpty) {
              location = 'Not specified';
            }

            final applyLink = (map['apply_url'] ?? careerUri.toString())
                .toString()
                .trim();
            final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
            if (seen.contains(key)) continue;
            seen.add(key);

            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: careerUri.toString(),
                applyLink: applyLink.isEmpty ? careerUri.toString() : applyLink,
                location: location,
                duration: durationData.$1,
                deadline: '—',
                source: 'GSK Jobs API',
                error: '',
              ),
            );
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('careers.hcltech.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final query = keywords.isEmpty ? '' : keywords.join(' ');

        for (var pageNumber = 0; pageNumber <= 117; pageNumber++) {
          final uri = Uri(
            scheme: careerUri.scheme,
            host: careerUri.host,
            path: '/services/recruiting/v1/jobs',
          );

          final response = await _client
              .post(
                uri,
                headers: const {
                  'content-type': 'application/json',
                  'accept': 'application/json, text/plain, */*',
                },
                body: jsonEncode({
                  'keywords': query,
                  'locale': 'en_US',
                  'location': '',
                  'pageNumber': pageNumber,
                  'sortBy': 'recent',
                }),
              )
              .timeout(const Duration(seconds: 15));

          if (response.statusCode >= 400 || response.body.trim().isEmpty) {
            continue;
          }

          final decoded = jsonDecode(response.body);
          if (decoded is! Map || decoded['jobSearchResult'] is! List) {
            continue;
          }

          for (final item
              in (decoded['jobSearchResult'] as List).whereType<Map>()) {
            final responseData = item['response'];
            if (responseData is! Map) continue;

            final title = (responseData['unifiedStandardTitle'] ?? '')
                .toString()
                .trim();
            if (title.isEmpty) continue;

            final searchable = [
              title,
              (responseData['unifiedUrlTitle'] ?? '').toString(),
              (responseData['custprimecity'] ?? '').toString(),
              (responseData['custCountryRegion'] ?? '').toString(),
            ].where((part) => part.trim().isNotEmpty).join(' | ').toLowerCase();

            final exactWordMatch = matchTerms.any((kw) {
              final pattern = RegExp(
                '\\b${RegExp.escape(kw.toLowerCase())}\\b',
              );
              return pattern.hasMatch(searchable);
            });
            if (!exactWordMatch &&
                !fuzzyMatch(title.toLowerCase(), matchTerms) &&
                !fuzzyMatch(searchable, matchTerms)) {
              continue;
            }

            final id = (responseData['id'] ?? '').toString().trim();
            final applyUri = careerUri.replace(queryParameters: {'jobId': id});

            final city = (responseData['custprimecity'] ?? '')
                .toString()
                .trim();
            final country =
                ((responseData['custCountryRegion'] ?? []) is List
                        ? (responseData['custCountryRegion'] as List)
                              .whereType<String>()
                              .join(', ')
                        : responseData['custCountryRegion']?.toString() ?? '')
                    .trim();
            final location = [
              city,
              country,
            ].where((part) => part.isNotEmpty).join(', ');

            final durationText = (responseData['unifiedStandardStart'] ?? '')
                .toString()
                .trim();

            final key =
                '${title.toLowerCase()}|${applyUri.toString().toLowerCase()}';
            if (seen.contains(key)) continue;
            seen.add(key);

            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: careerUri.toString(),
                applyLink: applyUri.toString(),
                location: location.isEmpty ? 'Not specified' : location,
                duration: durationText.isEmpty ? 'Not specified' : durationText,
                deadline: '—',
                source: 'HCL Careers API',
                error: '',
              ),
            );
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('apply.hp.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final query = keywords.isEmpty ? '' : keywords.join(' ');
        final pageSize = 10;
        const maxHpPages = 46;
        final apiDomain = host.endsWith('.hp.com') ? 'hp.com' : host;
        final sortBy =
            careerUri.queryParameters['sort_by']?.trim() ?? 'timestamp';
        final hl = careerUri.queryParameters['hl']?.trim();
        var totalCount = -1;

        for (var page = 0; page < maxHpPages; page++) {
          final start = page * pageSize;
          if (totalCount >= 0 && start >= totalCount) {
            break;
          }

          final queryParameters = <String, String>{
            'domain': apiDomain,
            'query': query,
            'location': '',
            'start': '$start',
            'sort_by': sortBy,
          };
          if (hl != null && hl.isNotEmpty) {
            queryParameters['hl'] = hl;
          }

          final uri = Uri(
            scheme: careerUri.scheme,
            host: careerUri.host,
            path: '/api/pcsx/search',
            queryParameters: queryParameters,
          );

          final response = await _client
              .get(
                uri,
                headers: {
                  'accept': 'application/json, text/plain, */*',
                  'User-Agent':
                      userAgents[DateTime.now().millisecond %
                          userAgents.length],
                  'Accept-Language': 'en-US,en;q=0.9',
                },
              )
              .timeout(const Duration(seconds: 15));

          if (response.statusCode >= 400 || response.body.trim().isEmpty) {
            continue;
          }

          final decoded = jsonDecode(response.body);
          if (decoded is! Map || decoded['data'] is! Map) {
            continue;
          }

          final data = decoded['data'] as Map;
          final countValue = data['count'];
          if (countValue is int) {
            totalCount = countValue;
          } else if (countValue is String) {
            totalCount = int.tryParse(countValue) ?? totalCount;
          }

          final positions = data['positions'];
          if (positions is! List || positions.isEmpty) {
            break;
          }

          for (final item in positions.whereType<Map>()) {
            final positionMap = item.map((k, v) => MapEntry(k.toString(), v));
            final title = (positionMap['name'] ?? '').toString().trim();
            if (title.isEmpty) continue;

            final locations =
                (positionMap['locations'] as List?)
                    ?.whereType<String>()
                    .map((value) => value.trim())
                    .where((value) => value.isNotEmpty)
                    .toList() ??
                [];
            final location = locations.isNotEmpty
                ? locations.join(', ')
                : 'Not specified';

            final positionUrl = (positionMap['positionUrl'] ?? '')
                .toString()
                .trim();
            final applyLink = positionUrl.isNotEmpty
                ? careerUri.resolve(positionUrl).toString()
                : careerUri.toString();

            final searchable = [
              title,
              location,
              (positionMap['department'] ?? '').toString().trim(),
              applyLink,
            ].where((part) => part.trim().isNotEmpty).join(' | ').toLowerCase();

            if (matchTerms.isNotEmpty) {
              final exactWordMatch = matchTerms.any((kw) {
                final pattern = RegExp(
                  '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                );
                return pattern.hasMatch(searchable);
              });
              if (!exactWordMatch && !fuzzyMatch(searchable, matchTerms)) {
                continue;
              }
            }

            final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
            if (seen.contains(key)) continue;
            seen.add(key);

            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: careerUri.toString(),
                applyLink: applyLink,
                location: location,
                duration: 'Not specified',
                deadline: '—',
                source: 'HP Careers API',
                error: '',
              ),
            );
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('hyperverge.co')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final pageHtml = await _fetch(careerUri);
        if (pageHtml == null || pageHtml.trim().isEmpty) {
          return const [];
        }

        final doc = html_parser.parse(pageHtml);
        final jobCards = doc.querySelectorAll('div.job-col');
        for (final card in jobCards) {
          final title = card.querySelector('p.job-title')?.text.trim() ?? '';
          if (title.isEmpty) continue;

          final applyAnchor = card.querySelector('a.btn[href]');
          final applyLink =
              applyAnchor?.attributes['href']?.trim().isNotEmpty == true
              ? careerUri
                    .resolve(applyAnchor!.attributes['href']!.trim())
                    .toString()
              : careerUri.toString();

          final location =
              card.querySelector('div.job-meta span')?.text.trim() ??
              'Not specified';

          final searchable = [
            title,
            location,
            applyLink,
          ].where((part) => part.trim().isNotEmpty).join(' | ').toLowerCase();

          if (matchTerms.isNotEmpty) {
            final exactWordMatch = matchTerms.any((kw) {
              final pattern = RegExp(
                '\\b${RegExp.escape(kw.toLowerCase())}\\b',
              );
              return pattern.hasMatch(searchable);
            });
            if (!exactWordMatch && !fuzzyMatch(searchable, matchTerms)) {
              continue;
            }
          }

          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location.isEmpty ? 'Not specified' : location,
              duration: 'Not specified',
              deadline: '—',
              source: 'Hyperverge HTML',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('consensys.io')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final pageHtml = await _fetch(careerUri);
        if (pageHtml == null || pageHtml.trim().isEmpty) {
          return const [];
        }

        final doc = html_parser.parse(pageHtml);
        final jobCards = doc.querySelectorAll('a.card-job');
        for (final card in jobCards) {
          final title = card.querySelector('.job-title')?.text.trim() ?? '';
          if (title.isEmpty) continue;

          final applyLinkAttr = card.attributes['href']?.trim() ?? '';
          final applyLink = applyLinkAttr.isNotEmpty
              ? careerUri.resolve(applyLinkAttr).toString()
              : careerUri.toString();

          final location =
              card.querySelector('.job-location')?.text.trim() ??
              'Not specified';

          final searchable = [
            title,
            location,
            applyLink,
          ].where((part) => part.trim().isNotEmpty).join(' | ').toLowerCase();

          if (matchTerms.isNotEmpty) {
            final exactWordMatch = matchTerms.any((kw) {
              final pattern = RegExp(
                '\\b${RegExp.escape(kw.toLowerCase())}\\b',
              );
              return pattern.hasMatch(searchable);
            });
            if (!exactWordMatch && !fuzzyMatch(searchable, matchTerms)) {
              continue;
            }
          }

          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location.isEmpty ? 'Not specified' : location,
              duration: 'Not specified',
              deadline: '—',
              source: 'Consensys HTML',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('hashgraph.com')) {
      try {
        final response = await _client
            .get(
              Uri.parse(
                'https://boards-api.greenhouse.io/v1/boards/hashgraph/jobs?content=true',
              ),
              headers: const {'accept': 'application/json, text/plain, */*'},
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map || decoded['jobs'] is! List) {
          return const [];
        }

        final jobs = (decoded['jobs'] as List).whereType<Map>();
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        for (final item in jobs) {
          final map = item.map((k, v) => MapEntry(k.toString(), v));
          final title = (map['title'] ?? '').toString().trim();
          final content = (map['content'] ?? '').toString().trim();
          if (title.isEmpty) continue;

          final titleLower = title.toLowerCase();
          final contentLower = content.toLowerCase();
          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\b${RegExp.escape(kw.toLowerCase())}\b');
            return pattern.hasMatch(titleLower) ||
                pattern.hasMatch(contentLower);
          });
          if (!exactWordMatch &&
              !fuzzyMatch(titleLower, matchTerms) &&
              !fuzzyMatch(contentLower, matchTerms)) {
            continue;
          }

          final applyLink = (map['absolute_url'] ?? careerUri.toString())
              .toString()
              .trim();
          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          String location = 'Not specified';
          final locationObj = map['location'];
          if (locationObj is Map) {
            final name = (locationObj['name'] ?? '').toString().trim();
            if (name.isNotEmpty) {
              location = name;
            }
          } else {
            final name = locationObj?.toString().trim() ?? '';
            if (name.isNotEmpty) {
              location = name;
            }
          }

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location,
              duration: parseDuration(content).$1,
              deadline: '—',
              source: 'Hashgraph Greenhouse API',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('group.hashkey.com')) {
      try {
        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        String findTitle(html_dom.Element anchor) {
          var current = anchor.parent;
          while (current != null) {
            final heading = current.querySelector('h1,h2,h3,h4,h5');
            if (heading != null) {
              final text = normalize(heading.text);
              if (text.isNotEmpty) {
                return text;
              }
            }
            current = current.parent;
          }

          final href = anchor.attributes['href'] ?? '';
          final uri = Uri.tryParse(href);
          if (uri != null && uri.pathSegments.length >= 2) {
            return Uri.decodeComponent(
              uri.pathSegments.last,
            ).replaceAll('-', ' ').replaceAll('_', ' ').trim();
          }
          return '';
        }

        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final visitedPages = <String>{};
        final pageQueue = <Uri>[careerUri.replace(fragment: '')];
        final matchTerms = keywords;

        while (pageQueue.isNotEmpty && visitedPages.length < 8) {
          final current = pageQueue.removeAt(0).replace(fragment: '');
          final currentKey = current.toString();
          if (visitedPages.contains(currentKey)) {
            continue;
          }
          visitedPages.add(currentKey);

          final pageHtml = await _fetch(current);
          if (pageHtml == null || pageHtml.trim().isEmpty) {
            continue;
          }

          final doc = html_parser.parse(pageHtml);
          final anchors = doc
              .querySelectorAll('a[href*="/job/"]')
              .where((a) => (a.attributes['href'] ?? '').trim().isNotEmpty)
              .toList();

          for (final anchor in anchors) {
            final href = (anchor.attributes['href'] ?? '').trim();
            final jobUri = current.resolve(href);
            final jobLink = jobUri.toString();
            final title = findTitle(anchor);
            if (title.isEmpty) {
              continue;
            }

            final context = normalize(anchor.parent?.text ?? anchor.text);
            final searchable = [
              title,
              context,
              jobLink,
            ].where((v) => v.trim().isNotEmpty).join(' | ').toLowerCase();

            final exactWordMatch = matchTerms.any((kw) {
              final pattern = RegExp('\b${RegExp.escape(kw.toLowerCase())}\b');
              return pattern.hasMatch(searchable);
            });
            if (!exactWordMatch &&
                !fuzzyMatch(title.toLowerCase(), matchTerms) &&
                !fuzzyMatch(searchable, matchTerms)) {
              continue;
            }

            final key = '${title.toLowerCase()}|${jobLink.toLowerCase()}';
            if (seen.contains(key)) continue;
            seen.add(key);

            final location = parseLocation(context);
            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: careerUri.toString(),
                applyLink: jobLink,
                location: location.isEmpty ? 'Not specified' : location,
                duration: parseDuration(context).$1,
                deadline: '—',
                source: 'HashKey Careers HTML',
                error: '',
              ),
            );
          }

          final pageLinks = doc
              .querySelectorAll('a[href*="?dynamic_page="]')
              .where((a) => (a.attributes['href'] ?? '').trim().isNotEmpty)
              .map((a) => current.resolve((a.attributes['href'] ?? '').trim()))
              .where((uri) => uri.host.toLowerCase() == host)
              .toList();

          for (final pageUri in pageLinks) {
            final pageKey = pageUri.toString();
            if (!visitedPages.contains(pageKey) &&
                !pageQueue.any((u) => u.toString() == pageKey)) {
              pageQueue.add(pageUri);
            }
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('search-careers.gm.com') &&
        careerUri.path.toLowerCase().contains('/jobs')) {
      try {
        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final visitedPages = <String>{};
        final pageQueue = <Uri>[careerUri.replace(fragment: '')];
        final matchTerms = keywords;

        while (pageQueue.isNotEmpty && visitedPages.length < 28) {
          final current = pageQueue.removeAt(0).replace(fragment: '');
          final currentKey = current.toString();
          if (visitedPages.contains(currentKey)) {
            continue;
          }
          visitedPages.add(currentKey);

          final rendered = await _fetchRendered(current);
          if (rendered == null || rendered.trim().isEmpty) {
            continue;
          }

          final doc = html_parser.parse(rendered);

          final jobAnchors = doc
              .querySelectorAll(
                'h2.card-title a[href*="/jobs/"], a.stretched-link[href*="/jobs/"]',
              )
              .where((a) => (a.attributes['href'] ?? '').trim().isNotEmpty)
              .toList();

          for (final anchor in jobAnchors) {
            final href = (anchor.attributes['href'] ?? '').trim();
            final jobUri = current.resolve(href);
            final jobLink = jobUri.toString();
            final title = normalize(anchor.text);
            if (title.isEmpty) continue;

            final parentText = normalize(anchor.parent?.text ?? '');
            final grandParentText = normalize(
              anchor.parent?.parent?.text ?? '',
            );
            final context = [
              parentText,
              grandParentText,
            ].where((v) => v.isNotEmpty).join(' | ');

            final searchable = [
              title,
              context,
              jobLink,
            ].where((v) => v.isNotEmpty).join(' | ').toLowerCase();

            final exactWordMatch = matchTerms.any((kw) {
              final pattern = RegExp(
                '\\b${RegExp.escape(kw.toLowerCase())}\\b',
              );
              return pattern.hasMatch(searchable);
            });
            if (!exactWordMatch &&
                !fuzzyMatch(title.toLowerCase(), matchTerms) &&
                !fuzzyMatch(searchable, matchTerms)) {
              continue;
            }

            final key = '${title.toLowerCase()}|${jobLink.toLowerCase()}';
            if (seen.contains(key)) continue;
            seen.add(key);

            final location = parseLocation(context);
            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: careerUri.toString(),
                applyLink: jobLink,
                location: location.isEmpty ? 'Not specified' : location,
                duration: parseDuration(context).$1,
                deadline: '—',
                source: 'GM Careers Search',
                error: '',
              ),
            );
          }

          final pageLinks = doc
              .querySelectorAll(
                'ul.pagination a.page-link[href*="/jobs/"][href*="page="]',
              )
              .where((a) => (a.attributes['href'] ?? '').trim().isNotEmpty)
              .toList();

          for (final link in pageLinks) {
            final href = (link.attributes['href'] ?? '').trim();
            final pageUri = current.resolve(href).replace(fragment: '');
            final pageHost = pageUri.host.toLowerCase();
            if (pageHost != host) continue;
            final pageKey = pageUri.toString();
            if (!visitedPages.contains(pageKey) &&
                !pageQueue.any((u) => u.toString() == pageKey)) {
              pageQueue.add(pageUri);
            }
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('careers.ford.com') &&
        careerUri.path.toLowerCase().contains('/search-jobs')) {
      try {
        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final visitedPages = <String>{};
        final pageQueue = <Uri>[careerUri];
        final matchTerms = keywords;

        while (pageQueue.isNotEmpty && visitedPages.length < 16) {
          final current = pageQueue.removeAt(0);
          final currentKey = current.toString();
          if (visitedPages.contains(currentKey)) {
            continue;
          }
          visitedPages.add(currentKey);

          final response = await _client
              .get(
                current,
                headers: {
                  'accept':
                      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                  'user-agent':
                      userAgents[DateTime.now().millisecond %
                          userAgents.length],
                },
              )
              .timeout(const Duration(seconds: 20));
          if (response.statusCode >= 400 || response.body.trim().isEmpty) {
            continue;
          }

          final doc = html_parser.parse(response.body);

          final jobAnchors = doc
              .querySelectorAll('a[href*="/job/"]')
              .where((a) => (a.attributes['href'] ?? '').trim().isNotEmpty)
              .toList();

          for (final anchor in jobAnchors) {
            final href = (anchor.attributes['href'] ?? '').trim();
            final jobUri = current.resolve(href);
            final jobLink = jobUri.toString();
            final title = normalize(anchor.text);
            if (title.isEmpty) continue;

            final context = normalize(anchor.parent?.text ?? anchor.text);
            final searchable = [
              title,
              context,
              jobLink,
            ].where((v) => v.isNotEmpty).join(' | ').toLowerCase();

            final exactWordMatch = matchTerms.any((kw) {
              final pattern = RegExp(
                '\\b${RegExp.escape(kw.toLowerCase())}\\b',
              );
              return pattern.hasMatch(searchable);
            });
            if (!exactWordMatch &&
                !fuzzyMatch(title.toLowerCase(), matchTerms) &&
                !fuzzyMatch(searchable, matchTerms)) {
              continue;
            }

            final key = '${title.toLowerCase()}|${jobLink.toLowerCase()}';
            if (seen.contains(key)) continue;
            seen.add(key);

            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: careerUri.toString(),
                applyLink: jobLink,
                location: parseLocation(context).isEmpty
                    ? 'Not specified'
                    : parseLocation(context),
                duration: parseDuration(context).$1,
                deadline: '—',
                source: 'Ford Careers Search',
                error: '',
              ),
            );
          }

          final pageLinks = doc
              .querySelectorAll('a[href*="search-jobs"][href*="p="]')
              .where((a) => (a.attributes['href'] ?? '').trim().isNotEmpty)
              .toList();
          for (final link in pageLinks) {
            final href = (link.attributes['href'] ?? '').trim();
            final pageUri = current.resolve(href);
            final pageKey = pageUri.toString();
            if (!visitedPages.contains(pageKey) &&
                !pageQueue.any((u) => u.toString() == pageKey)) {
              pageQueue.add(pageUri);
            }
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('finhaat.com') &&
        careerUri.path.toLowerCase().contains('/careers')) {
      try {
        final response = await _client
            .get(
              careerUri,
              headers: {
                'accept':
                    'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                'user-agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
              },
            )
            .timeout(const Duration(seconds: 20));

        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        String decodeSlugTitle(String slug) {
          final clean = slug
              .replaceAll('-', ' ')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
          if (clean.isEmpty) return clean;
          return clean
              .split(' ')
              .where((w) => w.isNotEmpty)
              .map((w) {
                if (w.length <= 2) return w.toUpperCase();
                return '${w[0].toUpperCase()}${w.substring(1)}';
              })
              .join(' ');
        }

        final doc = html_parser.parse(response.body);
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final anchors = doc
            .querySelectorAll('a[href*="/careers/"]')
            .where((a) => (a.attributes['href'] ?? '').trim().isNotEmpty)
            .toList();

        for (final anchor in anchors) {
          final href = (anchor.attributes['href'] ?? '').trim();
          if (href.isEmpty || href.endsWith('/careers')) continue;

          final applyUri = careerUri.resolve(href);
          final applyPath = applyUri.path.toLowerCase();
          if (!applyPath.contains('/careers/') || applyPath == '/careers') {
            continue;
          }

          final segments = applyUri.pathSegments
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
          if (segments.length < 2) continue;

          final slug = segments.last;
          if (slug.isEmpty || slug == 'careers') continue;

          var title = normalize(
            anchor.parent?.parent?.querySelector('h3, h4, h5, h6')?.text ?? '',
          );
          if (title.isEmpty || title.toLowerCase() == 'apply now') {
            title = decodeSlugTitle(slug);
          }
          if (title.isEmpty) continue;

          final applyLink = applyUri.toString();
          final context = normalize(
            anchor.parent?.parent?.text ?? anchor.parent?.text ?? anchor.text,
          );
          final searchable = [
            title,
            context,
            applyLink,
          ].where((v) => v.isNotEmpty).join(' | ').toLowerCase();

          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(searchable);
          });
          if (!exactWordMatch &&
              !fuzzyMatch(title.toLowerCase(), matchTerms) &&
              !fuzzyMatch(searchable, matchTerms)) {
            continue;
          }

          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: parseLocation(context).isEmpty
                  ? 'Not specified'
                  : parseLocation(context),
              duration: parseDuration(context).$1,
              deadline: '—',
              source: 'Finhaat Careers HTML',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('jobs.fidelity.com') &&
        careerUri.path.toLowerCase().contains('/ie/jobs')) {
      try {
        final response = await _client
            .get(
              Uri.https(careerUri.host, '/sitemap.xml'),
              headers: {
                'accept': 'application/xml,text/xml;q=0.9,*/*;q=0.8',
                'user-agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
              },
            )
            .timeout(const Duration(seconds: 20));

        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        String decodeSlugTitle(String slug) {
          final clean = slug
              .replaceAll('-', ' ')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
          if (clean.isEmpty) return clean;
          return clean
              .split(' ')
              .where((w) => w.isNotEmpty)
              .map((w) {
                if (w.length <= 2) return w.toUpperCase();
                return '${w[0].toUpperCase()}${w.substring(1)}';
              })
              .join(' ');
        }

        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final locMatches = RegExp(
          r'<loc>([^<]+)</loc>',
          caseSensitive: false,
        ).allMatches(response.body);

        for (final m in locMatches) {
          final rawUrl = normalize(m.group(1) ?? '');
          if (rawUrl.isEmpty) continue;

          final uri = Uri.tryParse(rawUrl);
          if (uri == null) continue;
          if (uri.host.toLowerCase() != careerUri.host.toLowerCase()) continue;

          final loweredPath = uri.path.toLowerCase();
          if (!loweredPath.contains('/ie/jobs/')) continue;

          final segments = uri.pathSegments
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
          if (segments.length < 4) continue;

          final slug = segments.last;
          final title = decodeSlugTitle(slug);
          if (title.isEmpty) continue;

          final searchable = [title, rawUrl].join(' | ').toLowerCase();
          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(searchable);
          });
          if (!exactWordMatch &&
              !fuzzyMatch(title.toLowerCase(), matchTerms) &&
              !fuzzyMatch(searchable, matchTerms)) {
            continue;
          }

          final key = '${title.toLowerCase()}|${rawUrl.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: rawUrl,
              location: 'Not specified',
              duration: 'Not specified',
              deadline: '—',
              source: 'Fidelity Jobs Sitemap',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('finbox.in') || host.contains('jobs.reczee.com')) {
      try {
        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        Uri boardUri = careerUri;
        if (!host.contains('jobs.reczee.com')) {
          final candidates = <Uri>{
            careerUri,
            Uri.https(careerUri.host, '/careers'),
          };
          if (careerUri.path.toLowerCase() == '/career') {
            candidates.add(careerUri.replace(path: '/careers'));
          }

          final embedRegex = RegExp(
            r'''https?://jobs\.reczee\.com/[^"'\s<>]+/job-embed''',
            caseSensitive: false,
          );

          for (final uri in candidates) {
            try {
              final response = await _client
                  .get(
                    uri,
                    headers: {
                      'user-agent':
                          userAgents[DateTime.now().millisecond %
                              userAgents.length],
                      'accept':
                          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                    },
                  )
                  .timeout(const Duration(seconds: 20));
              if (response.statusCode >= 400 || response.body.trim().isEmpty) {
                continue;
              }
              final match = embedRegex.firstMatch(response.body);
              if (match != null) {
                final parsed = Uri.tryParse(match.group(0) ?? '');
                if (parsed != null) {
                  boardUri = parsed;
                  break;
                }
              }
            } catch (_) {
              continue;
            }
          }

          if (!boardUri.host.toLowerCase().contains('jobs.reczee.com')) {
            boardUri = Uri.parse('https://jobs.reczee.com/finbox/job-embed');
          }
        }

        String? html = await _fetchRendered(boardUri);
        html ??= await _fetch(boardUri);

        if (html == null || html.trim().isEmpty) {
          return const [];
        }

        final doc = html_parser.parse(html);
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final anchors = doc
            .querySelectorAll('a[href*="/apply"]')
            .where((a) => (a.attributes['href'] ?? '').trim().isNotEmpty)
            .toList();

        for (final anchor in anchors) {
          final href = (anchor.attributes['href'] ?? '').trim();
          final applyLink = boardUri.resolve(href).toString();

          html_dom.Element? cursor = anchor;
          List<String> h6s = const [];
          for (var depth = 0; depth < 8 && cursor != null; depth++) {
            final collected = cursor
                .querySelectorAll('h6')
                .map((e) => normalize(e.text))
                .where((t) => t.isNotEmpty)
                .toList();
            if (collected.isNotEmpty) {
              h6s = collected;
              break;
            }
            cursor = cursor.parent;
          }

          final title = h6s.isNotEmpty ? h6s.first : '';
          if (title.isEmpty) continue;
          final location = h6s.length >= 3 ? h6s[2] : 'Not specified';
          final context = h6s.join(' | ');

          final searchable = [
            title,
            location,
            context,
            applyLink,
          ].where((v) => v.isNotEmpty).join(' | ').toLowerCase();

          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(searchable);
          });
          if (!exactWordMatch &&
              !fuzzyMatch(title.toLowerCase(), matchTerms) &&
              !fuzzyMatch(searchable, matchTerms)) {
            continue;
          }

          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location,
              duration: parseDuration(context).$1,
              deadline: '—',
              source: 'FinBox Reczee Careers',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('metacareers.com') &&
        careerUri.path.toLowerCase().contains('/jobsearch')) {
      try {
        Future<String?> fetchMetaHtml(Uri uri) async {
          final rendered = await _fetchRendered(uri);
          if (rendered != null && rendered.trim().isNotEmpty) {
            return rendered;
          }
          return await _fetch(uri);
        }

        var workingUri = careerUri;
        final hasRoleFilter = careerUri.queryParameters.keys.any(
          (k) => k == 'roles[0]' || k == 'roles',
        );

        String? html = await fetchMetaHtml(workingUri);
        if ((html == null || html.trim().isEmpty) && !hasRoleFilter) {
          final qp = <String, String>{...careerUri.queryParameters};
          qp['roles[0]'] = 'Internship';
          workingUri = careerUri.replace(queryParameters: qp);
          html = await fetchMetaHtml(workingUri);
        }
        if (html == null || html.trim().isEmpty) {
          return const [];
        }

        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        var doc = html_parser.parse(html);
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        var anchors = doc
            .querySelectorAll('a[href*="/profile/job_details/"]')
            .where((a) => (a.attributes['href'] ?? '').trim().isNotEmpty)
            .toList();

        if (anchors.isEmpty && !hasRoleFilter) {
          final qp = <String, String>{...careerUri.queryParameters};
          qp['roles[0]'] = 'Internship';
          workingUri = careerUri.replace(queryParameters: qp);
          final filteredHtml = await fetchMetaHtml(workingUri);
          if (filteredHtml != null && filteredHtml.trim().isNotEmpty) {
            doc = html_parser.parse(filteredHtml);
            anchors = doc
                .querySelectorAll('a[href*="/profile/job_details/"]')
                .where((a) => (a.attributes['href'] ?? '').trim().isNotEmpty)
                .toList();
          }
        }

        for (final anchor in anchors) {
          final href = (anchor.attributes['href'] ?? '').trim();
          if (href.isEmpty) continue;

          final applyLink = workingUri.resolve(href).toString();
          var title = normalize(anchor.querySelector('h3')?.text ?? '');
          if (title.isEmpty) {
            title = normalize(anchor.text);
          }
          if (title.isEmpty) continue;

          final location = normalize(anchor.querySelector('span')?.text ?? '');
          final context = normalize(anchor.text);
          final searchable = [
            title,
            location,
            context,
            applyLink,
          ].where((v) => v.isNotEmpty).join(' | ').toLowerCase();

          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(searchable);
          });
          if (!exactWordMatch &&
              !fuzzyMatch(title.toLowerCase(), matchTerms) &&
              !fuzzyMatch(searchable, matchTerms)) {
            continue;
          }

          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: workingUri.toString(),
              applyLink: applyLink,
              location: location.isEmpty ? 'Not specified' : location,
              duration: parseDuration(context).$1,
              deadline: '—',
              source: 'Meta Careers Job Search',
              error: '',
            ),
          );
        }

        final wantsIntern = matchTerms.any(
          (kw) => kw.toLowerCase().contains('intern'),
        );
        if (rows.isEmpty && !hasRoleFilter && wantsIntern) {
          final qp = <String, String>{...careerUri.queryParameters};
          qp['roles[0]'] = 'Internship';
          final internshipUri = careerUri.replace(queryParameters: qp);
          final internshipHtml = await fetchMetaHtml(internshipUri);
          if (internshipHtml != null && internshipHtml.trim().isNotEmpty) {
            final internshipDoc = html_parser.parse(internshipHtml);
            final internshipAnchors = internshipDoc
                .querySelectorAll('a[href*="/profile/job_details/"]')
                .where((a) => (a.attributes['href'] ?? '').trim().isNotEmpty)
                .toList();

            for (final anchor in internshipAnchors) {
              final href = (anchor.attributes['href'] ?? '').trim();
              if (href.isEmpty) continue;

              final applyLink = internshipUri.resolve(href).toString();
              var title = normalize(anchor.querySelector('h3')?.text ?? '');
              if (title.isEmpty) {
                title = normalize(anchor.text);
              }
              if (title.isEmpty) continue;

              final location = normalize(
                anchor.querySelector('span')?.text ?? '',
              );
              final context = normalize(anchor.text);
              final searchable = [
                title,
                location,
                context,
                applyLink,
              ].where((v) => v.isNotEmpty).join(' | ').toLowerCase();

              final exactWordMatch = matchTerms.any((kw) {
                final pattern = RegExp(
                  '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                );
                return pattern.hasMatch(searchable);
              });
              if (!exactWordMatch &&
                  !fuzzyMatch(title.toLowerCase(), matchTerms) &&
                  !fuzzyMatch(searchable, matchTerms)) {
                continue;
              }

              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.contains(key)) continue;
              seen.add(key);

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: internshipUri.toString(),
                  applyLink: applyLink,
                  location: location.isEmpty ? 'Not specified' : location,
                  duration: parseDuration(context).$1,
                  deadline: '—',
                  source: 'Meta Careers Job Search',
                  error: '',
                ),
              );
            }

            if (rows.isNotEmpty) {
              workingUri = internshipUri;
              anchors = internshipAnchors;
            }
          }
        }

        if (anchors.isNotEmpty && rows.isEmpty) {
          return [
            ScanResultRow(
              company: companyName,
              title: 'No internship found',
              companyUrl: workingUri.toString(),
              applyLink: workingUri.toString(),
              location: '—',
              duration: '—',
              deadline: '—',
              source: 'Meta Careers Job Search',
              error: '',
            ),
          ];
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('jobs.electriccapital.com')) {
      try {
        final response = await _client
            .get(
              Uri.https(careerUri.host, '/sitemap.xml'),
              headers: {
                'accept': 'application/xml,text/xml;q=0.9,*/*;q=0.8',
                'user-agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
              },
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        String decodeSlugTitle(String slug) {
          final clean = slug
              .replaceAll('-', ' ')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
          if (clean.isEmpty) return clean;
          return clean
              .split(' ')
              .where((w) => w.isNotEmpty)
              .map((w) {
                if (w.length <= 2) return w.toUpperCase();
                return '${w[0].toUpperCase()}${w.substring(1)}';
              })
              .join(' ');
        }

        final locMatches = RegExp(
          r'<loc>([^<]+)</loc>',
          caseSensitive: false,
        ).allMatches(response.body);

        for (final m in locMatches) {
          final url = normalize(m.group(1) ?? '');
          if (url.isEmpty) continue;

          final uri = Uri.tryParse(url);
          if (uri == null) continue;
          final segs = uri.pathSegments
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
          if (segs.length < 4) continue;

          final jobsIndex = segs.indexOf('jobs');
          if (jobsIndex < 0 || jobsIndex + 1 >= segs.length) continue;
          final slug = segs[jobsIndex + 1];
          if (slug.isEmpty) continue;

          final title = decodeSlugTitle(slug);
          if (title.isEmpty) continue;

          final searchable = [title, url].join(' | ').toLowerCase();
          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(searchable);
          });
          if (!exactWordMatch &&
              !fuzzyMatch(title.toLowerCase(), matchTerms) &&
              !fuzzyMatch(searchable, matchTerms)) {
            continue;
          }

          final key = '${title.toLowerCase()}|${url.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: url,
              location: 'Not specified',
              duration: 'Not specified',
              deadline: '—',
              source: 'Electric Capital Sitemap',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('careers.etsy.com') &&
        careerUri.path.toLowerCase().contains('/jobs/search')) {
      try {
        final response = await _client
            .get(
              Uri.https(careerUri.host, '/sitemap.xml'),
              headers: {
                'accept': 'application/xml,text/xml;q=0.9,*/*;q=0.8',
                'user-agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
              },
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        String decodeSlugTitle(String slug) {
          final clean = slug
              .replaceAll('-', ' ')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
          if (clean.isEmpty) return clean;
          return clean
              .split(' ')
              .where((w) => w.isNotEmpty)
              .map((w) {
                if (w.length <= 2) return w.toUpperCase();
                return '${w[0].toUpperCase()}${w.substring(1)}';
              })
              .join(' ');
        }

        final locMatches = RegExp(
          r'<loc>([^<]+)</loc>',
          caseSensitive: false,
        ).allMatches(response.body);

        for (final m in locMatches) {
          final url = normalize(m.group(1) ?? '');
          if (url.isEmpty) continue;

          final uri = Uri.tryParse(url);
          if (uri == null) continue;
          final segs = uri.pathSegments
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
          if (segs.length < 2) continue;

          final jobsIndex = segs.indexOf('jobs');
          if (jobsIndex < 0 || jobsIndex + 1 >= segs.length) continue;
          final slug = segs[jobsIndex + 1];
          if (slug.isEmpty) continue;

          final title = decodeSlugTitle(slug);
          if (title.isEmpty) continue;

          final searchable = [title, url].join(' | ').toLowerCase();
          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(searchable);
          });
          if (!exactWordMatch &&
              !fuzzyMatch(title.toLowerCase(), matchTerms) &&
              !fuzzyMatch(searchable, matchTerms)) {
            continue;
          }

          final key = '${title.toLowerCase()}|${url.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: url,
              location: 'Not specified',
              duration: 'Not specified',
              deadline: '—',
              source: 'Etsy Careers Sitemap',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('careers.fabric.vc') &&
        careerUri.path.toLowerCase().contains('/jobs')) {
      try {
        final rendered = await _fetchRendered(careerUri);
        final html = (rendered != null && rendered.trim().isNotEmpty)
            ? rendered
            : await _fetch(careerUri);
        if (html == null || html.trim().isEmpty) {
          return const [];
        }

        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        final doc = html_parser.parse(html);
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final anchors = doc
            .querySelectorAll('a[href]')
            .where((a) => (a.attributes['href'] ?? '').trim().isNotEmpty)
            .toList();

        for (final anchor in anchors) {
          final href = (anchor.attributes['href'] ?? '').trim();
          if (href.isEmpty ||
              href.startsWith('#') ||
              href.startsWith('javascript:') ||
              href.startsWith('mailto:')) {
            continue;
          }

          final applyLink = careerUri.resolve(href).toString();
          final applyUri = Uri.tryParse(applyLink);
          if (applyUri == null) continue;

          final applyHost = applyUri.host.toLowerCase();
          if (applyHost.contains('careers.fabric.vc') ||
              applyHost.contains('fabric.vc') ||
              applyHost.contains('consider.com')) {
            continue;
          }

          final title = normalize(anchor.text);
          if (title.isEmpty ||
              title.length < 4 ||
              title.toLowerCase() == 'apply' ||
              title.toLowerCase() == 'show more jobs') {
            continue;
          }

          final context = normalize(
            anchor.parent?.parent?.text ?? anchor.parent?.text ?? anchor.text,
          );
          final searchable = [
            title,
            context,
            applyLink,
          ].where((v) => v.isNotEmpty).join(' | ').toLowerCase();

          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(searchable);
          });
          if (!exactWordMatch &&
              !fuzzyMatch(title.toLowerCase(), matchTerms) &&
              !fuzzyMatch(searchable, matchTerms)) {
            continue;
          }

          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: parseLocation(context).isEmpty
                  ? 'Not specified'
                  : parseLocation(context),
              duration: parseDuration(context).$1,
              deadline: '—',
              source: 'Fabric Ventures Talent Board',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if ((host.contains('yello.co') || host.contains('recsolu.com')) &&
        careerUri.path.toLowerCase().contains('/job_boards/')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        final baseQuery = Map<String, String>.from(careerUri.queryParameters);
        if ((baseQuery['locale'] ?? '').trim().isEmpty) {
          baseQuery['locale'] = 'en';
        }

        for (final term in matchTerms) {
          final termQuery = Map<String, String>.from(baseQuery);
          if ((termQuery['query'] ?? '').trim().isEmpty) {
            termQuery['query'] = term;
          }

          var consecutiveNoHitPages = 0;
          for (var page = 1; page <= 40; page++) {
            final qp = Map<String, String>.from(termQuery)..['page'] = '$page';
            final pageUri = Uri.https(careerUri.host, careerUri.path, qp);

            final response = await _client
                .get(
                  pageUri,
                  headers: {
                    'accept':
                        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                    'user-agent':
                        userAgents[DateTime.now().millisecond %
                            userAgents.length],
                  },
                )
                .timeout(const Duration(seconds: 15));

            if (response.statusCode >= 400 || response.body.trim().isEmpty) {
              break;
            }

            final doc = html_parser.parse(response.body);
            final anchors = doc
                .querySelectorAll('a[href*="/jobs/"][href*="job_board_id="]')
                .where((a) => (a.attributes['href'] ?? '').trim().isNotEmpty)
                .toList();

            if (anchors.isEmpty) {
              consecutiveNoHitPages += 1;
              if (consecutiveNoHitPages >= 2) {
                break;
              }
              continue;
            }

            var pageAdded = 0;
            for (final a in anchors) {
              final title = normalize(a.text);
              if (title.isEmpty) continue;

              final href = (a.attributes['href'] ?? '').trim();
              final applyLink = pageUri.resolve(href).toString();

              final context = normalize(
                a.parent?.parent?.text ?? a.parent?.text ?? a.text,
              );
              final searchable = [
                title,
                context,
                applyLink,
              ].where((v) => v.isNotEmpty).join(' | ').toLowerCase();

              final exactWordMatch = matchTerms.any((kw) {
                final pattern = RegExp(
                  '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                );
                return pattern.hasMatch(searchable);
              });
              if (!exactWordMatch &&
                  !fuzzyMatch(title.toLowerCase(), matchTerms) &&
                  !fuzzyMatch(searchable, matchTerms)) {
                continue;
              }

              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.contains(key)) continue;
              seen.add(key);
              pageAdded += 1;

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: 'Not specified',
                  duration: parseDuration(context).$1,
                  deadline: '—',
                  source: 'EY Yello Job Board HTML',
                  error: '',
                ),
              );
            }

            if (pageAdded == 0) {
              consecutiveNoHitPages += 1;
              if (consecutiveNoHitPages >= 2) {
                break;
              }
            } else {
              consecutiveNoHitPages = 0;
            }
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('eigenlabs.org')) {
      return await _fetchAshbyRows(
        board: 'eigen-labs',
        companyName: companyName,
        careerUri: careerUri,
        keywords: keywords,
      );
    }

    if (host.contains('careers.lilly.com') &&
        careerUri.path.toLowerCase().contains('/search-results')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final searchPath =
            careerUri.path.toLowerCase().contains('/search-results')
            ? careerUri.path
            : '/us/en/search-results';

        final baseQuery = Map<String, String>.from(careerUri.queryParameters);
        final requestedOffset = int.tryParse(baseQuery['from'] ?? '') ?? 0;
        if ((baseQuery['s'] ?? '').trim().isEmpty) {
          baseQuery['s'] = '1';
        }

        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        var offset = requestedOffset < 0 ? 0 : requestedOffset;
        var pageSize = 10;
        int? totalHits;

        for (var page = 0; page < 120; page++) {
          final qp = Map<String, String>.from(baseQuery);
          if (offset > 0) {
            qp['from'] = '$offset';
          } else {
            qp.remove('from');
          }

          final pageUri = Uri.https(
            careerUri.host,
            searchPath,
            qp.isEmpty ? null : qp,
          );

          final response = await _client
              .get(
                pageUri,
                headers: {
                  'accept':
                      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                  'user-agent':
                      userAgents[DateTime.now().millisecond %
                          userAgents.length],
                },
              )
              .timeout(const Duration(seconds: 15));

          if (response.statusCode >= 400 || response.body.trim().isEmpty) {
            break;
          }

          final eagerJson = _extractJsonObjectValueByKey(
            response.body,
            'eagerLoadRefineSearch',
          );
          if (eagerJson == null || eagerJson.trim().isEmpty) {
            break;
          }

          final eagerDecoded = jsonDecode(eagerJson);
          if (eagerDecoded is! Map) {
            break;
          }

          final eager = eagerDecoded.map((k, v) => MapEntry('$k', v));
          final parsedTotalHits = int.tryParse('${eager['totalHits'] ?? ''}');
          if (parsedTotalHits != null && parsedTotalHits > 0) {
            totalHits = parsedTotalHits;
          }

          final data = eager['data'];
          if (data is! Map) {
            break;
          }

          final jobs = data['jobs'];
          if (jobs is! List || jobs.isEmpty) {
            break;
          }

          pageSize = jobs.length;

          for (final rawJob in jobs.whereType<Map>()) {
            final job = rawJob.map((k, v) => MapEntry('$k', v));
            final title = normalize((job['title'] ?? '').toString());
            if (title.isEmpty) continue;

            final applyLink = normalize((job['applyUrl'] ?? '').toString());
            if (applyLink.isEmpty) continue;

            final location = normalize(
              (job['location'] ??
                      job['cityStateCountry'] ??
                      job['cityState'] ??
                      job['city'] ??
                      '')
                  .toString(),
            );
            final description = normalize(
              (job['descriptionTeaser'] ??
                      job['description'] ??
                      (job['ml_job_parser'] is Map
                          ? (job['ml_job_parser'] as Map)['descriptionTeaser']
                          : '') ??
                      '')
                  .toString(),
            );
            final postedDate = normalize((job['postedDate'] ?? '').toString());

            final searchable = [
              title,
              location,
              description,
              applyLink,
            ].where((v) => v.isNotEmpty).join(' | ').toLowerCase();

            final titleLower = title.toLowerCase();
            final exactWordMatch = matchTerms.any((kw) {
              final pattern = RegExp(
                '\\b${RegExp.escape(kw.toLowerCase())}\\b',
              );
              return pattern.hasMatch(searchable);
            });
            if (!exactWordMatch &&
                !fuzzyMatch(titleLower, matchTerms) &&
                !fuzzyMatch(searchable, matchTerms)) {
              continue;
            }

            final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
            if (seen.contains(key)) continue;
            seen.add(key);

            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: careerUri.toString(),
                applyLink: applyLink,
                location: location.isEmpty ? 'Not specified' : location,
                duration: parseDuration('$description $postedDate').$1,
                deadline: '—',
                source: 'Lilly Phenom Search Results',
                error: '',
              ),
            );
          }

          if (pageSize <= 0) {
            break;
          }

          if (totalHits != null && totalHits > 0) {
            final maxOffset = totalHits - pageSize;
            if (offset >= maxOffset) {
              break;
            }
          }

          offset += pageSize;
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('jobs.ebayinc.com') &&
        careerUri.path.toLowerCase().contains('/search-results')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final searchPath =
            careerUri.path.toLowerCase().contains('/search-results')
            ? careerUri.path
            : '/us/en/search-results';

        final baseQuery = Map<String, String>.from(careerUri.queryParameters);
        final requestedOffset = int.tryParse(baseQuery['from'] ?? '') ?? 0;
        if ((baseQuery['s'] ?? '').trim().isEmpty) {
          baseQuery['s'] = '1';
        }

        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        var offset = requestedOffset < 0 ? 0 : requestedOffset;
        var pageSize = 10;
        int? totalHits;

        for (var page = 0; page < 120; page++) {
          final qp = Map<String, String>.from(baseQuery);
          if (offset > 0) {
            qp['from'] = '$offset';
          } else {
            qp.remove('from');
          }

          final pageUri = Uri.https(
            careerUri.host,
            searchPath,
            qp.isEmpty ? null : qp,
          );

          final response = await _client
              .get(
                pageUri,
                headers: {
                  'accept':
                      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                  'user-agent':
                      userAgents[DateTime.now().millisecond %
                          userAgents.length],
                },
              )
              .timeout(const Duration(seconds: 15));

          if (response.statusCode >= 400 || response.body.trim().isEmpty) {
            break;
          }

          final eagerJson = _extractJsonObjectValueByKey(
            response.body,
            'eagerLoadRefineSearch',
          );
          if (eagerJson == null || eagerJson.trim().isEmpty) {
            break;
          }

          final eagerDecoded = jsonDecode(eagerJson);
          if (eagerDecoded is! Map) {
            break;
          }

          final eager = eagerDecoded.map((k, v) => MapEntry('$k', v));
          final parsedTotalHits = int.tryParse('${eager['totalHits'] ?? ''}');
          if (parsedTotalHits != null && parsedTotalHits > 0) {
            totalHits = parsedTotalHits;
          }

          final data = eager['data'];
          if (data is! Map) {
            break;
          }

          final jobs = data['jobs'];
          if (jobs is! List || jobs.isEmpty) {
            break;
          }

          pageSize = jobs.length;

          for (final rawJob in jobs.whereType<Map>()) {
            final job = rawJob.map((k, v) => MapEntry('$k', v));
            final title = normalize((job['title'] ?? '').toString());
            if (title.isEmpty) continue;

            final applyLink = normalize((job['applyUrl'] ?? '').toString());
            if (applyLink.isEmpty) continue;

            final location = normalize(
              (job['location'] ??
                      job['cityStateCountry'] ??
                      job['cityState'] ??
                      job['city'] ??
                      '')
                  .toString(),
            );
            final description = normalize(
              (job['descriptionTeaser'] ??
                      job['description'] ??
                      (job['ml_job_parser'] is Map
                          ? (job['ml_job_parser'] as Map)['descriptionTeaser']
                          : '') ??
                      '')
                  .toString(),
            );
            final postedDate = normalize((job['postedDate'] ?? '').toString());

            final searchable = [
              title,
              location,
              description,
              applyLink,
            ].where((v) => v.isNotEmpty).join(' | ').toLowerCase();

            final titleLower = title.toLowerCase();
            final exactWordMatch = matchTerms.any((kw) {
              final pattern = RegExp(
                '\\b${RegExp.escape(kw.toLowerCase())}\\b',
              );
              return pattern.hasMatch(searchable);
            });
            if (!exactWordMatch &&
                !fuzzyMatch(titleLower, matchTerms) &&
                !fuzzyMatch(searchable, matchTerms)) {
              continue;
            }

            final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
            if (seen.contains(key)) continue;
            seen.add(key);

            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: careerUri.toString(),
                applyLink: applyLink,
                location: location.isEmpty ? 'Not specified' : location,
                duration: parseDuration('$description $postedDate').$1,
                deadline: '—',
                source: 'eBay Phenom Search Results',
                error: '',
              ),
            );
          }

          if (pageSize <= 0) {
            break;
          }

          if (totalHits != null && totalHits > 0) {
            final maxOffset = totalHits - pageSize;
            if (offset >= maxOffset) {
              break;
            }
          }

          offset += pageSize;
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if ((host.contains('zohorecruit.in') || host.contains('zohorecruit.com'))) {
      try {
        Uri zohoUri = careerUri;
        final lowerPath = careerUri.path.toLowerCase();
        if (!lowerPath.contains('/jobs/careers')) {
          zohoUri = Uri.https(careerUri.host, '/jobs/careers');
        }

        final response = await _client
            .get(
              zohoUri,
              headers: {
                'accept':
                    'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                'user-agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
              },
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        final document = html_parser.parse(response.body);
        final jobsAttrValue =
            document.querySelector('input#jobs')?.attributes['value'] ?? '';
        if (jobsAttrValue.isEmpty) {
          return const [];
        }

        final decodedJobsJson = _decodeHtmlAttributeValue(jobsAttrValue);
        if (decodedJobsJson.isEmpty) {
          return const [];
        }

        final parsed = jsonDecode(decodedJobsJson);
        if (parsed is! List) {
          return const [];
        }

        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        bool matchesKeyword(String searchable, String title) {
          final searchableLower = searchable.toLowerCase();
          final titleLower = title.toLowerCase();
          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(searchableLower);
          });
          return exactWordMatch ||
              fuzzyMatch(titleLower, matchTerms) ||
              fuzzyMatch(searchableLower, matchTerms);
        }

        for (final item in parsed.whereType<Map>()) {
          final map = item.map((k, v) => MapEntry(k.toString(), v));
          final isPublished = map['Publish'] == true;
          if (!isPublished) continue;

          final title = normalize(
            (map['Posting_Title'] ?? map['Job_Opening_Name'] ?? '').toString(),
          );
          if (title.isEmpty) continue;

          final city = normalize((map['City'] ?? '').toString());
          final state = normalize((map['State'] ?? '').toString());
          final country = normalize((map['Country'] ?? '').toString());
          final remote = map['Remote_Job'] == true;

          final locationParts = <String>[];
          if (city.isNotEmpty && city.toLowerCase() != 'na') {
            locationParts.add(city);
          }
          if (state.isNotEmpty && state.toLowerCase() != 'na') {
            locationParts.add(state);
          }
          if (country.isNotEmpty && country.toLowerCase() != 'na') {
            locationParts.add(country);
          }
          if (remote) {
            locationParts.add('Remote');
          }
          final location = locationParts.isNotEmpty
              ? locationParts.join(', ')
              : 'Not specified';

          final jobId = normalize((map['id'] ?? '').toString());
          final applyLink = jobId.isNotEmpty
              ? Uri.https(careerUri.host, '/jobs/Careers/$jobId').toString()
              : zohoUri.toString();
          final description = normalize(
            _decodeHtmlAttributeValue(
              (map['Job_Description'] ?? '').toString(),
            ),
          );

          final searchable = [
            title,
            location,
            applyLink,
            description,
          ].where((v) => v.isNotEmpty).join(' | ');
          if (!matchesKeyword(searchable, title)) {
            continue;
          }

          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location,
              duration: parseDuration(description).$1,
              deadline: '—',
              source: 'Zoho Recruit Careers JSON',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('dydx.exchange') &&
        careerUri.path.toLowerCase().contains('/careers')) {
      try {
        final source = Uri.parse(
          'https://api.gem.com/job_board/v0/dydx/job_posts/',
        );
        final response = await _client
            .get(
              source,
              headers: const {'accept': 'application/json, text/plain, */*'},
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! List) {
          return const [];
        }

        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        for (final item in decoded.whereType<Map>()) {
          final map = item.map((k, v) => MapEntry(k.toString(), v));
          final title = normalize((map['title'] ?? '').toString());
          if (title.isEmpty) continue;

          String location = 'Not specified';
          final locationObj = map['location'];
          if (locationObj is Map) {
            final loc = locationObj.map((k, v) => MapEntry(k.toString(), v));
            final locName = normalize((loc['name'] ?? '').toString());
            if (locName.isNotEmpty) {
              location = locName;
            }
          } else {
            final locText = normalize(locationObj?.toString() ?? '');
            if (locText.isNotEmpty) {
              location = locText;
            }
          }

          final content = normalize((map['content'] ?? '').toString());
          final applyLink = normalize((map['absolute_url'] ?? '').toString());

          final searchable = [
            title,
            location,
            applyLink,
          ].where((v) => v.trim().isNotEmpty).join(' | ').toLowerCase();

          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(searchable);
          });
          if (!exactWordMatch &&
              !fuzzyMatch(title.toLowerCase(), matchTerms) &&
              !fuzzyMatch(searchable, matchTerms)) {
            continue;
          }

          final resolvedApplyLink = applyLink.isNotEmpty
              ? applyLink
              : careerUri.toString();
          final key =
              '${title.toLowerCase()}|${resolvedApplyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: resolvedApplyLink,
              location: location,
              duration: parseDuration(content).$1,
              deadline: '—',
              source: 'Gem Job Board API',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('southasiacareers.deloitte.com') &&
        careerUri.path.toLowerCase().contains('/go/')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final segments = careerUri.pathSegments
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        if (segments.length < 3 || segments.first.toLowerCase() != 'go') {
          return const [];
        }

        final baseSegments = segments.take(3).toList();
        final basePath = '/${baseSegments.join('/')}';
        final qp = Map<String, String>.from(careerUri.queryParameters);
        final requestedOffset = segments.length >= 4
            ? int.tryParse(segments[3]) ?? 0
            : 0;

        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        int extractTotalPages(String html) {
          final pageOfMatch = RegExp(
            r'Page\s*\d+\s*of\s*(\d+)',
            caseSensitive: false,
          ).firstMatch(html);
          final fromPageOf = int.tryParse(pageOfMatch?.group(1) ?? '');
          if (fromPageOf != null && fromPageOf > 0) {
            return fromPageOf;
          }

          final lastHref = RegExp(
            r'class="paginationItemLast"[^>]*href="([^"]+)"',
            caseSensitive: false,
          ).firstMatch(html);
          final href = lastHref?.group(1) ?? '';
          if (href.isNotEmpty) {
            final uri = careerUri.resolve(href);
            final parts = uri.pathSegments
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList();
            if (parts.length >= 4) {
              final maxOffset = int.tryParse(parts[3]) ?? 0;
              if (maxOffset >= 0) {
                return (maxOffset ~/ 25) + 1;
              }
            }
          }

          return 1;
        }

        bool matches(String title, String location, String rowText) {
          final searchable = [
            title,
            location,
            rowText,
          ].where((s) => s.trim().isNotEmpty).join(' | ').toLowerCase();
          final titleLower = title.toLowerCase();
          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(searchable);
          });
          return exactWordMatch ||
              fuzzyMatch(titleLower, matchTerms) ||
              fuzzyMatch(searchable, matchTerms);
        }

        for (final term in matchTerms) {
          final baseQuery = Map<String, String>.from(qp);
          if ((baseQuery['q'] ?? '').trim().isEmpty) {
            baseQuery['q'] = term;
          }

          final firstPath = requestedOffset > 0
              ? '$basePath/$requestedOffset/'
              : '$basePath/';
          final firstUri = Uri.https(
            careerUri.host,
            firstPath,
            baseQuery.isEmpty ? null : baseQuery,
          );
          final firstResponse = await _client
              .get(
                firstUri,
                headers: {
                  'accept':
                      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                  'user-agent':
                      userAgents[DateTime.now().millisecond %
                          userAgents.length],
                },
              )
              .timeout(const Duration(seconds: 15));

          if (firstResponse.statusCode >= 400 ||
              firstResponse.body.trim().isEmpty) {
            continue;
          }

          final maxPages = extractTotalPages(firstResponse.body);
          final pageSize = RegExp(
            'class="data-row"',
            caseSensitive: false,
          ).allMatches(firstResponse.body).length;
          final effectivePageSize = pageSize > 0 ? pageSize : 25;

          for (var page = 1; page <= maxPages && page <= 120; page++) {
            final offset = ((page - 1) * effectivePageSize) + requestedOffset;
            final path = offset > 0 ? '$basePath/$offset/' : '$basePath/';
            final pageUri = Uri.https(
              careerUri.host,
              path,
              baseQuery.isEmpty ? null : baseQuery,
            );

            final response = page == 1 && requestedOffset == 0
                ? firstResponse
                : await _client
                      .get(
                        pageUri,
                        headers: {
                          'accept':
                              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                          'user-agent':
                              userAgents[DateTime.now().millisecond %
                                  userAgents.length],
                        },
                      )
                      .timeout(const Duration(seconds: 15));

            if (response.statusCode >= 400 || response.body.trim().isEmpty) {
              if (page == 1) {
                break;
              }
              continue;
            }

            final doc = html_parser.parse(response.body);
            final jobRows = doc.querySelectorAll('tr.data-row');
            if (jobRows.isEmpty) {
              break;
            }

            var pageAdded = 0;
            for (final jobRow in jobRows) {
              final linkEl = jobRow.querySelector('a.jobTitle-link');
              final href = (linkEl?.attributes['href'] ?? '').trim();
              final title = normalize(linkEl?.text ?? '');
              if (title.isEmpty || href.isEmpty) continue;

              final location = normalize(
                jobRow.querySelector('.colLocation .jobLocation')?.text ??
                    jobRow.querySelector('.visible-phone .jobLocation')?.text ??
                    '',
              );
              final rowText = normalize(jobRow.text);
              if (!matches(title, location, rowText)) {
                continue;
              }

              final applyLink = pageUri.resolve(href).toString();
              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.contains(key)) continue;
              seen.add(key);
              pageAdded += 1;

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location.isEmpty ? 'Not specified' : location,
                  duration: parseDuration(rowText).$1,
                  deadline: '—',
                  source: 'Deloitte South Asia Careers HTML',
                  error: '',
                ),
              );
            }

            if (pageAdded == 0 && page > 1) {
              break;
            }
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('cybrilla.com') &&
        careerUri.path.toLowerCase().contains('/careers')) {
      try {
        final response = await _client
            .get(
              Uri.parse('https://app.recruiterbox.com/widget/5346/openings/'),
              headers: const {'accept': 'application/json, text/plain, */*'},
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! List) {
          return const [];
        }

        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        for (final item in decoded.whereType<Map>()) {
          final map = item.map((k, v) => MapEntry(k.toString(), v));
          final title = (map['title'] ?? '').toString().trim();
          if (title.isEmpty) continue;

          final description = (map['description'] ?? '').toString().trim();
          final team = (map['team'] ?? '').toString().trim();
          final positionType = (map['position_type'] ?? '').toString().trim();

          String location = 'Not specified';
          final locationObj = map['location'];
          if (locationObj is Map) {
            final loc = locationObj.map((k, v) => MapEntry(k.toString(), v));
            final city = (loc['city'] ?? '').toString().trim();
            final state = (loc['state'] ?? '').toString().trim();
            final country = (loc['country'] ?? '').toString().trim();
            final parts = [
              city,
              state,
              country,
            ].where((v) => v.isNotEmpty).toList();
            if (parts.isNotEmpty) {
              location = parts.join(', ');
            }
          }

          final searchable = [
            title,
            description,
            team,
            positionType,
            location,
          ].where((v) => v.trim().isNotEmpty).join(' | ').toLowerCase();

          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(searchable);
          });
          if (!exactWordMatch &&
              !fuzzyMatch(title.toLowerCase(), matchTerms) &&
              !fuzzyMatch(searchable, matchTerms)) {
            continue;
          }

          final hashId = (map['hash_id'] ?? '').toString().trim();
          final applyLink = hashId.isNotEmpty
              ? 'https://cybrilla.recruiterbox.com/jobs/$hashId'
              : careerUri.toString();
          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location,
              duration: parseDuration('$description $positionType').$1,
              deadline: '—',
              source: 'Recruiterbox API',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('dapperlabs.com') &&
        careerUri.path.toLowerCase().contains('/careers')) {
      try {
        final source = Uri.parse(
          'https://careers.kula.ai/dapperlabs?jobs=true',
        );
        final response = await _client
            .get(
              source,
              headers: const {
                'accept':
                    'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
              },
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        final doc = html_parser.parse(response.body);
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final applyAnchors = doc
            .querySelectorAll('a[href*="/dapperlabs/"]')
            .where((a) => (a.attributes['href'] ?? '').trim().isNotEmpty)
            .toList();

        for (final anchor in applyAnchors) {
          final href = (anchor.attributes['href'] ?? '').trim();
          final applyLink = source.resolve(href).toString();

          html_dom.Element? container = anchor;
          String title = '';
          String cardText = '';
          for (var i = 0; i < 10 && container != null; i++) {
            final t = normalize(
              container.querySelector('p.css-hqxkdi')?.text ??
                  container.querySelector('h3')?.text ??
                  '',
            );
            if (t.isNotEmpty) {
              title = t;
              cardText = normalize(container.text);
              break;
            }
            container = container.parent;
          }

          if (title.isEmpty) continue;
          final searchable = [
            title,
            cardText,
            applyLink,
          ].where((v) => v.trim().isNotEmpty).join(' | ').toLowerCase();

          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(searchable);
          });
          if (!exactWordMatch &&
              !fuzzyMatch(title.toLowerCase(), matchTerms) &&
              !fuzzyMatch(searchable, matchTerms)) {
            continue;
          }

          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          final location = parseLocation(cardText);
          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location.isEmpty ? 'Not specified' : location,
              duration: parseDuration(cardText).$1,
              deadline: '—',
              source: 'Kula Careers HTML',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('instahyre.com') &&
        careerUri.path.toLowerCase().contains('/jobs-at-')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final rendered = await _fetchRendered(careerUri);
        final html = (rendered != null && rendered.trim().isNotEmpty)
            ? rendered
            : await _fetch(careerUri);
        if (html == null || html.trim().isEmpty) {
          return const [];
        }

        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        final doc = html_parser.parse(html);
        final anchors = doc
            .querySelectorAll('a[href*="/job-"]')
            .where((a) => (a.attributes['href'] ?? '').trim().isNotEmpty)
            .toList();

        for (final anchor in anchors) {
          final href = (anchor.attributes['href'] ?? '').trim();
          if (href.isEmpty) continue;

          final applyLink = careerUri.resolve(href).toString();
          final title = normalize(anchor.text);
          if (title.isEmpty || title.toLowerCase() == 'employer logo') {
            continue;
          }

          final cardText = normalize(anchor.parent?.text ?? anchor.text);
          final searchable = [
            title,
            cardText,
            applyLink,
          ].where((v) => v.trim().isNotEmpty).join(' | ').toLowerCase();

          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(searchable);
          });
          if (!exactWordMatch &&
              !fuzzyMatch(title.toLowerCase(), matchTerms) &&
              !fuzzyMatch(searchable, matchTerms)) {
            continue;
          }

          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          final location = parseLocation(cardText);
          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location.isEmpty ? 'Not specified' : location,
              duration: parseDuration(cardText).$1,
              deadline: '—',
              source: 'Instahyre Careers HTML',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('notion.site')) {
      try {
        final rendered = await _fetchRendered(careerUri);
        final html = (rendered != null && rendered.trim().isNotEmpty)
            ? rendered
            : await _fetch(careerUri);
        if (html == null || html.trim().isEmpty) {
          return const [];
        }

        String normalize(String value) {
          return value.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        final doc = html_parser.parse(html);
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        bool matchesKeyword(String searchable, String titleLower) {
          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(searchable);
          });
          if (exactWordMatch) return true;
          if (fuzzyMatch(titleLower, matchTerms)) return true;
          return fuzzyMatch(searchable, matchTerms);
        }

        final anchors = doc.querySelectorAll('a[href]');
        for (final a in anchors) {
          final href = (a.attributes['href'] ?? '').trim();
          if (href.isEmpty ||
              href.startsWith('#') ||
              href.startsWith('javascript:') ||
              href.startsWith('mailto:')) {
            continue;
          }

          final title = normalize(a.text);
          if (title.isEmpty) continue;

          final applyLink = careerUri.resolve(href).toString();
          final cardText = normalize(
            a.parent?.parent?.text ?? a.parent?.text ?? a.text,
          );
          final searchable = [
            title,
            cardText,
            applyLink,
          ].where((v) => v.trim().isNotEmpty).join(' | ').toLowerCase();

          final titleLower = title.toLowerCase();
          if (!matchesKeyword(searchable, titleLower)) {
            continue;
          }

          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          final location = parseLocation(cardText);
          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location.isEmpty ? 'Not specified' : location,
              duration: parseDuration(cardText).$1,
              deadline: '—',
              source: 'Notion Careers Page',
              error: '',
            ),
          );
        }

        if (rows.isNotEmpty) {
          return rows;
        }

        final headings = doc.querySelectorAll('h1,h2,h3');
        for (final h in headings) {
          final title = normalize(h.text);
          if (title.isEmpty) continue;
          final searchable = title.toLowerCase();
          if (!matchesKeyword(searchable, searchable)) continue;

          final key =
              '${title.toLowerCase()}|${careerUri.toString().toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: careerUri.toString(),
              location: 'Not specified',
              duration: 'Not specified',
              deadline: '—',
              source: 'Notion Careers Page',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('chaoslabs.xyz')) {
      try {
        final pageResponse = await _client
            .get(
              careerUri,
              headers: {
                'accept':
                    'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                'user-agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
              },
            )
            .timeout(const Duration(seconds: 12));

        if (pageResponse.statusCode >= 400 ||
            pageResponse.body.trim().isEmpty) {
          return const [];
        }

        final endpointMatch = RegExp(
          r'https://www\.comeet\.co/careers-api/2\.0/company/([A-Za-z0-9\.\-]+)/positions/[A-Za-z0-9\.\-]+\?token=([A-Za-z0-9]+)',
          caseSensitive: false,
        ).firstMatch(pageResponse.body);

        if (endpointMatch == null) {
          return const [];
        }

        final companyId = endpointMatch.group(1)?.trim() ?? '';
        final token = endpointMatch.group(2)?.trim() ?? '';
        if (companyId.isEmpty || token.isEmpty) {
          return const [];
        }

        final listUri = Uri.parse(
          'https://www.comeet.co/careers-api/2.0/company/$companyId/positions?token=$token',
        );

        final response = await _client
            .get(
              listUri,
              headers: const {'accept': 'application/json, text/plain, */*'},
            )
            .timeout(const Duration(seconds: 12));

        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! List) {
          return const [];
        }

        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        for (final item in decoded.whereType<Map>()) {
          final map = item.map((k, v) => MapEntry(k.toString(), v));

          final title = (map['name'] ?? '').toString().trim();
          if (title.isEmpty) continue;

          final department = (map['department'] ?? '').toString().trim();
          final experienceLevel = (map['experience_level'] ?? '')
              .toString()
              .trim();
          final employmentType = (map['employment_type'] ?? '')
              .toString()
              .trim();

          final combined = '$title $department $experienceLevel $employmentType'
              .toLowerCase();
          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(combined);
          });
          if (!exactWordMatch && !fuzzyMatch(title.toLowerCase(), matchTerms)) {
            continue;
          }

          final locationObj = map['location'];
          var location = '';
          if (locationObj is Map) {
            final loc = locationObj.map((k, v) => MapEntry(k.toString(), v));
            location = (loc['name'] ?? loc['city'] ?? loc['country'] ?? '')
                .toString();
          }
          location = location.trim();

          final applyLink =
              (map['url_active_page'] ??
                      map['url_comeet_hosted_page'] ??
                      map['url_recruit_hosted_page'] ??
                      careerUri.toString())
                  .toString()
                  .trim();

          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location.isEmpty ? 'Not specified' : location,
              duration: parseDuration(title).$1,
              deadline: '—',
              source: 'Comeet API',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('etoro.com') &&
        careerUri.path.toLowerCase().contains('/about/careers')) {
      try {
        final pageResponse = await _client
            .get(
              careerUri,
              headers: {
                'accept':
                    'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                'user-agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
              },
            )
            .timeout(const Duration(seconds: 12));

        if (pageResponse.statusCode >= 400 ||
            pageResponse.body.trim().isEmpty) {
          return const [];
        }

        final token = RegExp(
          r'"token"\s*:\s*"([A-Za-z0-9]+)"',
          caseSensitive: false,
        ).firstMatch(pageResponse.body)?.group(1)?.trim();
        final companyUid = RegExp(
          r'"company-uid"\s*:\s*"([A-Za-z0-9\.\-]+)"',
          caseSensitive: false,
        ).firstMatch(pageResponse.body)?.group(1)?.trim();

        if (token == null ||
            token.isEmpty ||
            companyUid == null ||
            companyUid.isEmpty) {
          return const [];
        }

        final listUri = Uri.parse(
          'https://www.comeet.co/careers-api/2.0/company/$companyUid/positions?token=$token',
        );

        final response = await _client
            .get(
              listUri,
              headers: const {'accept': 'application/json, text/plain, */*'},
            )
            .timeout(const Duration(seconds: 12));

        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! List) {
          return const [];
        }

        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        for (final item in decoded.whereType<Map>()) {
          final map = item.map((k, v) => MapEntry(k.toString(), v));

          final title = normalize((map['name'] ?? '').toString());
          if (title.isEmpty) continue;

          final department = normalize((map['department'] ?? '').toString());
          final experienceLevel = normalize(
            (map['experience_level'] ?? '').toString(),
          );
          final employmentType = normalize(
            (map['employment_type'] ?? '').toString(),
          );

          String location = 'Not specified';
          final locationObj = map['location'];
          if (locationObj is Map) {
            final loc = locationObj.map((k, v) => MapEntry(k.toString(), v));
            final locText = normalize(
              (loc['name'] ?? loc['city'] ?? loc['country'] ?? '').toString(),
            );
            if (locText.isNotEmpty) {
              location = locText;
            }
          }

          final applyLink = normalize(
            (map['url_active_page'] ??
                    map['url_comeet_hosted_page'] ??
                    map['url_recruit_hosted_page'] ??
                    careerUri.toString())
                .toString(),
          );

          final searchable = [
            title,
            department,
            experienceLevel,
            employmentType,
            location,
            applyLink,
          ].where((v) => v.isNotEmpty).join(' | ').toLowerCase();

          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\b${RegExp.escape(kw.toLowerCase())}\b');
            return pattern.hasMatch(searchable);
          });
          if (!exactWordMatch && !fuzzyMatch(title.toLowerCase(), matchTerms)) {
            continue;
          }

          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location,
              duration: parseDuration(
                '$department $experienceLevel $employmentType',
              ).$1,
              deadline: '—',
              source: 'eToro Comeet API',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('chainlinklabs.com')) {
      try {
        final pageResponse = await _client
            .get(
              careerUri,
              headers: {
                'accept':
                    'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                'user-agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
              },
            )
            .timeout(const Duration(seconds: 12));

        if (pageResponse.statusCode >= 400 ||
            pageResponse.body.trim().isEmpty) {
          return const [];
        }

        final ashbyMatch = RegExp(
          r'jobs\.ashbyhq\.com/([a-zA-Z0-9\-]+)/?',
          caseSensitive: false,
        ).firstMatch(pageResponse.body);

        final board = ashbyMatch?.group(1)?.trim().isNotEmpty == true
            ? ashbyMatch!.group(1)!.trim()
            : 'chainlink-labs';

        return await _fetchAshbyRows(
          board: board,
          companyName: companyName,
          careerUri: careerUri,
          keywords: keywords,
        );
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('capitalonecareers.com') &&
        careerUri.path.toLowerCase().contains('/category/')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final basePath = careerUri.path.endsWith('/')
            ? careerUri.path.substring(0, careerUri.path.length - 1)
            : careerUri.path;

        for (var page = 1; page <= 80; page++) {
          final pagePath = page == 1 ? basePath : '$basePath/$page';
          final pageUri = careerUri.replace(path: pagePath);

          final response = await _client
              .get(
                pageUri,
                headers: {
                  'accept':
                      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                  'user-agent':
                      userAgents[DateTime.now().millisecond %
                          userAgents.length],
                },
              )
              .timeout(const Duration(seconds: 15));

          if (response.statusCode >= 400 || response.body.trim().isEmpty) {
            if (page == 1) {
              return const [];
            }
            break;
          }

          final doc = html_parser.parse(response.body);
          final links = doc
              .querySelectorAll('a[href*="/job/"]')
              .where((a) => (a.attributes['href'] ?? '').trim().isNotEmpty)
              .toList();
          if (links.isEmpty) {
            break;
          }

          var pageAdded = 0;
          for (final a in links) {
            final href = (a.attributes['href'] ?? '').trim();
            final applyLink = pageUri.resolve(href).toString();
            final applyUri = Uri.tryParse(applyLink);
            if (applyUri == null) continue;

            final segments = applyUri.pathSegments
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList();
            if (segments.length < 5 || segments.first.toLowerCase() != 'job') {
              continue;
            }

            final locationRaw = segments[1];
            final slug = segments[2];
            final slugText = slug.replaceAll('-', ' ').trim();
            if (slugText.isEmpty) continue;

            final title = slugText
                .split(' ')
                .where((w) => w.trim().isNotEmpty)
                .map(
                  (w) => w.length == 1
                      ? w.toUpperCase()
                      : '${w[0].toUpperCase()}${w.substring(1)}',
                )
                .join(' ');

            final titleLower = title.toLowerCase();
            final exactWordMatch = matchTerms.any((kw) {
              final pattern = RegExp(
                '\\b${RegExp.escape(kw.toLowerCase())}\\b',
              );
              return pattern.hasMatch(titleLower);
            });
            if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
              continue;
            }

            final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
            if (seen.contains(key)) continue;
            seen.add(key);
            pageAdded += 1;

            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: careerUri.toString(),
                applyLink: applyLink,
                location: locationRaw.replaceAll('-', ' '),
                duration: parseDuration(title).$1,
                deadline: '—',
                source: 'Capital One Careers HTML',
                error: '',
              ),
            );
          }

          if (pageAdded == 0) {
            break;
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('capgemini.com') &&
        careerUri.path.toLowerCase().contains(
          '/careers/join-capgemini/job-search',
        )) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final baseQuery = Map<String, String>.from(careerUri.queryParameters);
        final countryCode = (baseQuery['country_code'] ?? '').trim();
        final pageSize = int.tryParse(baseQuery['size'] ?? '') ?? 11;
        final startPage = 1;

        for (final term in matchTerms) {
          var page = startPage;
          var maxPage = startPage + 80;
          int? total;

          while (page <= maxPage) {
            final qp = <String, String>{
              'search': term,
              'size': '$pageSize',
              'page': '$page',
            };
            if (countryCode.isNotEmpty) {
              qp['country_code'] = countryCode;
            }

            final apiUri = Uri.https(
              'cg-jobstream-api.azurewebsites.net',
              '/api/job-search',
              qp,
            );

            final response = await _client
                .get(
                  apiUri,
                  headers: {
                    'accept': 'application/json, text/plain, */*',
                    'referer': careerUri.toString(),
                    'user-agent':
                        userAgents[DateTime.now().millisecond %
                            userAgents.length],
                  },
                )
                .timeout(const Duration(seconds: 15));

            if (response.statusCode >= 400 || response.body.trim().isEmpty) {
              break;
            }

            final decoded = jsonDecode(response.body);
            if (decoded is! Map) {
              break;
            }

            total ??= int.tryParse('${decoded['total'] ?? ''}');
            if (total != null && total > 0) {
              final computedMaxPage = ((total - 1) ~/ pageSize) + 1;
              if (computedMaxPage < maxPage) {
                maxPage = computedMaxPage;
              }
            }

            final jobs = (decoded['data'] is List)
                ? (decoded['data'] as List).whereType<Map>().toList()
                : const <Map>[];
            if (jobs.isEmpty) {
              break;
            }

            for (final item in jobs) {
              final map = item.map((k, v) => MapEntry(k.toString(), v));
              final title = (map['title'] ?? '').toString().trim();
              if (title.isEmpty) continue;

              final location = (map['location'] ?? '').toString().trim();
              final rawDescription =
                  '${map['description_stripped'] ?? map['description'] ?? ''}';
              final titleLower = title.toLowerCase();
              final locationLower = location.toLowerCase();
              final descriptionLower = rawDescription.toLowerCase();

              final exactWordMatch = matchTerms.any((kw) {
                final pattern = RegExp(
                  '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                );
                return pattern.hasMatch(titleLower) ||
                    pattern.hasMatch(locationLower) ||
                    pattern.hasMatch(descriptionLower);
              });
              if (!exactWordMatch &&
                  !fuzzyMatch(titleLower, matchTerms) &&
                  !fuzzyMatch(descriptionLower, matchTerms)) {
                continue;
              }

              var applyLink = (map['apply_job_url'] ?? '').toString().trim();
              if (applyLink.isEmpty) {
                final ref = (map['ref'] ?? '').toString().trim();
                applyLink = ref.isNotEmpty
                    ? 'https://www.capgemini.com/jobs/$ref'
                    : careerUri.toString();
              }

              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.contains(key)) continue;
              seen.add(key);

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location.isEmpty ? 'Not specified' : location,
                  duration: parseDuration('$title $rawDescription').$1,
                  deadline: '—',
                  source: 'Capgemini Jobstream API',
                  error: '',
                ),
              );
            }

            if (jobs.length < pageSize) {
              break;
            }

            page += 1;
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('myworkdaysite.com') ||
        host.contains('myworkdayjobs.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final queryTerms = keywords.isEmpty ? [''] : keywords;

        final workdayParams = extractWorkdayTenantAndSite(careerUri);
        if (workdayParams == null) {
          return const [];
        }

        final tenant = workdayParams.tenant;
        final site = workdayParams.site;

        final apiUri = Uri.https(
          careerUri.host,
          '/wday/cxs/$tenant/$site/jobs',
        );

        for (final term in queryTerms) {
          var offset = 0;
          const limit = 20;
          int? total;

          while (total == null || offset < total) {
            final payload = jsonEncode({
              'limit': limit,
              'offset': offset,
              'searchText': term,
            });

            final response = await _client
                .post(
                  apiUri,
                  headers: {
                    'accept': 'application/json, text/plain, */*',
                    'content-type': 'application/json',
                    'origin': '${careerUri.scheme}://${careerUri.host}',
                    'referer': careerUri.toString(),
                    'user-agent':
                        userAgents[DateTime.now().millisecond %
                            userAgents.length],
                  },
                  body: payload,
                )
                .timeout(const Duration(seconds: 15));

            if (response.statusCode >= 400 || response.body.trim().isEmpty) {
              break;
            }

            final decoded = jsonDecode(response.body);
            if (decoded is! Map) {
              break;
            }

            total ??= int.tryParse('${decoded['total'] ?? ''}');
            final jobs = (decoded['jobPostings'] is List)
                ? (decoded['jobPostings'] as List).whereType<Map>().toList()
                : const <Map>[];

            if (jobs.isEmpty) {
              break;
            }

            for (final item in jobs) {
              final map = item.map((k, v) => MapEntry(k.toString(), v));
              final title = (map['title'] ?? '').toString().trim();
              if (title.isEmpty) continue;

              final location = (map['locationsText'] ?? '').toString().trim();
              final postedOn = (map['postedOn'] ?? '').toString().trim();
              final titleLower = title.toLowerCase();
              final locationLower = location.toLowerCase();

              final exactWordMatch = matchTerms.any((kw) {
                final pattern = RegExp(
                  '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                );
                return pattern.hasMatch(titleLower) ||
                    pattern.hasMatch(locationLower);
              });
              if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
                continue;
              }

              final externalPath = (map['externalPath'] ?? '')
                  .toString()
                  .trim();
              final applyLink = externalPath.isNotEmpty
                  ? careerUri.resolve(externalPath).toString()
                  : careerUri.toString();
              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.contains(key)) continue;
              seen.add(key);

              final exp = parseExperience(title);
              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location.isEmpty ? 'Not specified' : location,
                  duration: parseDuration('$title $postedOn').$1,
                  deadline: '—',
                  source: 'Workday CXS Jobs API',
                  error: '',
                  experience: exp,
                ),
              );
            }

            offset += limit;
            if (total != null && offset >= total) {
              break;
            }
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('avature.net') || host.contains('jobs.ea.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final searchPath =
            careerUri.path.toLowerCase().contains('/search-results')
            ? careerUri.path
            : '/us/en/search-results';

        final baseQuery = Map<String, String>.from(careerUri.queryParameters);
        final recordsPerPage =
            int.tryParse(baseQuery['jobRecordsPerPage'] ?? '') ?? 12;

        var offset = int.tryParse(baseQuery['jobOffset'] ?? '') ?? 0;
        for (var page = 0; page < 60; page++) {
          final qp = Map<String, String>.from(baseQuery);
          qp['jobRecordsPerPage'] = '$recordsPerPage';
          if (offset > 0) {
            qp['jobOffset'] = '$offset';
          } else {
            qp.remove('jobOffset');
          }

          final pageUri = Uri.https(
            careerUri.host,
            searchPath,
            qp.isEmpty ? null : qp,
          );

          final response = await _client
              .get(
                pageUri,
                headers: {
                  'accept':
                      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                  'user-agent':
                      userAgents[DateTime.now().millisecond %
                          userAgents.length],
                },
              )
              .timeout(const Duration(seconds: 15));

          if (response.statusCode >= 400 || response.body.trim().isEmpty) {
            break;
          }

          final doc = html_parser.parse(response.body);
          final links = doc
              .querySelectorAll('a[href*="/careers/JobDetail/"]')
              .where((a) => (a.attributes['href'] ?? '').trim().isNotEmpty)
              .toList();
          if (links.isEmpty) {
            break;
          }

          var pageAdded = 0;
          for (final link in links) {
            final rawTitle = link.text.replaceAll(RegExp(r'\s+'), ' ').trim();
            if (rawTitle.isEmpty) continue;

            final titleLower = rawTitle.toLowerCase();
            if (titleLower == 'apply' || titleLower.startsWith('apply now')) {
              continue;
            }

            var contextText = rawTitle;
            html_dom.Element? node = link;
            for (var i = 0; i < 5 && node != null; i++) {
              final t = node.text.replaceAll(RegExp(r'\s+'), ' ').trim();
              if (t.length > contextText.length) {
                contextText = t;
              }
              node = node.parent;
            }

            final contextLower = contextText.toLowerCase();
            final exactWordMatch = matchTerms.any((kw) {
              final pattern = RegExp(
                '\\b${RegExp.escape(kw.toLowerCase())}\\b',
              );
              return pattern.hasMatch(titleLower) ||
                  pattern.hasMatch(contextLower);
            });
            if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
              continue;
            }

            final href = (link.attributes['href'] ?? '').trim();
            final applyLink = pageUri.resolve(href).toString();
            final key = '${rawTitle.toLowerCase()}|${applyLink.toLowerCase()}';
            if (seen.contains(key)) continue;
            seen.add(key);

            pageAdded += 1;
            rows.add(
              ScanResultRow(
                company: companyName,
                title: rawTitle,
                companyUrl: careerUri.toString(),
                applyLink: applyLink,
                location: 'Not specified',
                duration: parseDuration(contextText).$1,
                deadline: '—',
                source: 'Avature Careers HTML',
                error: '',
              ),
            );
          }

          if (pageAdded == 0) {
            break;
          }

          if (links.length < recordsPerPage) {
            break;
          }

          offset += recordsPerPage;
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('blockchain.com')) {
      try {
        final response = await _client
            .get(
              Uri.parse(
                'https://boards-api.greenhouse.io/v1/boards/blockchain/jobs?content=true',
              ),
              headers: const {'accept': 'application/json, text/plain, */*'},
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map || decoded['jobs'] is! List) {
          return const [];
        }

        final jobs = (decoded['jobs'] as List).whereType<Map>();
        final rows = <ScanResultRow>[];
        final seen = <String>{};

        for (final item in jobs) {
          final map = item.map((k, v) => MapEntry(k.toString(), v));

          final title = (map['title'] ?? '').toString().trim();
          final content = (map['content'] ?? '').toString().trim();
          if (title.isEmpty) continue;

          final titleLower = title.toLowerCase();
          final contentLower = content.toLowerCase();
          final exactWordMatch = keywords.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(titleLower) ||
                pattern.hasMatch(contentLower);
          });
          if (!exactWordMatch && !fuzzyMatch(titleLower, keywords)) continue;

          final applyLink = (map['absolute_url'] ?? careerUri.toString())
              .toString()
              .trim();
          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          String location = 'Not specified';
          final locationObj = map['location'];
          if (locationObj is Map) {
            final name = (locationObj['name'] ?? '').toString().trim();
            if (name.isNotEmpty) {
              location = name;
            }
          } else {
            final name = locationObj?.toString().trim() ?? '';
            if (name.isNotEmpty) {
              location = name;
            }
          }

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location,
              duration: parseDuration(content).$1,
              deadline: '—',
              source: 'Blockchain.com Greenhouse API',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('jobs.blockchaincapital.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        for (final term in matchTerms) {
          final queryUri = Uri.https('jobs.blockchaincapital.com', '/jobs', {
            'q': term,
          });
          final response = await _client
              .get(
                queryUri,
                headers: {
                  'accept':
                      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                  'user-agent':
                      userAgents[DateTime.now().millisecond %
                          userAgents.length],
                },
              )
              .timeout(const Duration(seconds: 15));

          if (response.statusCode >= 400 || response.body.trim().isEmpty) {
            continue;
          }

          final doc = html_parser.parse(response.body);
          final links = doc
              .querySelectorAll('a[href*="/companies/"][href*="/jobs/"]')
              .where(
                (a) => (a.attributes['href'] ?? '').toLowerCase().contains(
                  '/jobs/',
                ),
              )
              .toList();

          for (final link in links) {
            final href = (link.attributes['href'] ?? '').trim();
            if (href.isEmpty) continue;

            final title = link.text.replaceAll(RegExp(r'\s+'), ' ').trim();
            if (title.isEmpty || title.toLowerCase().startsWith('read more')) {
              continue;
            }

            final titleLower = title.toLowerCase();
            final exactWordMatch = matchTerms.any((kw) {
              final pattern = RegExp(
                '\\b${RegExp.escape(kw.toLowerCase())}\\b',
              );
              return pattern.hasMatch(titleLower);
            });
            if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
              continue;
            }

            final applyLink = queryUri.resolve(href).toString();
            final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
            if (seen.contains(key)) continue;
            seen.add(key);

            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: careerUri.toString(),
                applyLink: applyLink,
                location: 'Not specified',
                duration: 'Unknown',
                deadline: '—',
                source: 'Blockchain Capital Getro Jobs',
                error: '',
              ),
            );
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('block.xyz')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        var page = 1;
        while (page <= 30) {
          final apiUri = Uri.https('block.xyz', '/api/careers/jobs', {
            'page': '$page',
          });

          final response = await _client
              .get(
                apiUri,
                headers: {
                  'accept': 'application/json, text/plain, */*',
                  'user-agent':
                      userAgents[DateTime.now().millisecond %
                          userAgents.length],
                  'referer': careerUri.toString(),
                },
              )
              .timeout(const Duration(seconds: 15));
          if (response.statusCode >= 400 || response.body.trim().isEmpty) {
            break;
          }

          final decoded = jsonDecode(response.body);
          if (decoded is! Map || decoded['currentPage'] is! List) {
            break;
          }

          final jobs = (decoded['currentPage'] as List).whereType<Map>();
          if (jobs.isEmpty) {
            break;
          }

          var pageAdded = 0;
          for (final item in jobs) {
            final map = item.map((k, v) => MapEntry(k.toString(), v));
            final title = (map['title'] ?? '').toString().trim();
            if (title.isEmpty) continue;

            final jobFunction = (map['jobFunction'] ?? '').toString().trim();
            final employeeType = (map['employeeType'] ?? '').toString().trim();
            final locationObj = map['location'];
            final location = locationObj is List
                ? locationObj
                      .map((e) => e.toString().trim())
                      .where((e) => e.isNotEmpty)
                      .toSet()
                      .join(', ')
                : locationObj?.toString().trim() ?? '';

            final searchable = [
              title,
              jobFunction,
              employeeType,
              location,
            ].where((e) => e.isNotEmpty).join(' | ').toLowerCase();
            final titleLower = title.toLowerCase();
            final exactWordMatch = matchTerms.any((kw) {
              final pattern = RegExp(
                '\\b${RegExp.escape(kw.toLowerCase())}\\b',
              );
              return pattern.hasMatch(searchable);
            });
            if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
              continue;
            }

            final id = (map['id'] ?? '').toString().trim();
            final applyLink = id.isNotEmpty
                ? Uri.https('block.xyz', '/careers/jobs/$id').toString()
                : careerUri.toString();
            final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
            if (seen.contains(key)) continue;
            seen.add(key);

            pageAdded += 1;
            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: careerUri.toString(),
                applyLink: applyLink,
                location: location.isEmpty ? 'Not specified' : location,
                duration: parseDuration(searchable).$1,
                deadline: '—',
                source: 'Block Careers API',
                error: '',
              ),
            );
          }

          final total = int.tryParse((decoded['total'] ?? '').toString());
          if (total != null && page * jobs.length >= total) {
            break;
          }

          if (jobs.length < 50 && pageAdded == 0) {
            break;
          }

          page += 1;
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('bitso.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final apiUri = Uri.https(
          'boards-api.greenhouse.io',
          '/v1/boards/bitso/jobs',
          {'content': 'true'},
        );
        final response = await _client
            .get(
              apiUri,
              headers: {
                'accept': 'application/json, text/plain, */*',
                'user-agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
                'referer': careerUri.toString(),
              },
            )
            .timeout(const Duration(seconds: 15));
        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map || decoded['jobs'] is! List) {
          return const [];
        }

        final jobs = (decoded['jobs'] as List).whereType<Map>();
        for (final item in jobs) {
          final map = item.map((k, v) => MapEntry(k.toString(), v));
          final title = (map['title'] ?? '').toString().trim();
          final content = (map['content'] ?? '').toString().trim();
          if (title.isEmpty) continue;

          final titleLower = title.toLowerCase();
          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(titleLower);
          });
          if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
            continue;
          }

          final rawLink = (map['absolute_url'] ?? '').toString().trim();
          final applyLink = rawLink.isNotEmpty ? rawLink : careerUri.toString();
          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          String location = 'Not specified';
          final locationObj = map['location'];
          if (locationObj is Map) {
            final name = (locationObj['name'] ?? '').toString().trim();
            if (name.isNotEmpty) {
              location = name;
            }
          } else {
            final name = locationObj?.toString().trim() ?? '';
            if (name.isNotEmpty) {
              location = name;
            }
          }

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location,
              duration: parseDuration(content).$1,
              deadline: '—',
              source: 'Bitso Greenhouse API',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('careers.blackline.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final apiUri = Uri.https('careers.blackline.com', '/api/jobs');
        final response = await _client
            .get(
              apiUri,
              headers: {
                'accept': 'application/json, text/plain, */*',
                'user-agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
                'referer': careerUri.toString(),
              },
            )
            .timeout(const Duration(seconds: 15));
        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map || decoded['jobs'] is! List) {
          return const [];
        }

        final jobs = (decoded['jobs'] as List).whereType<Map>();
        for (final item in jobs) {
          final map = item.map((k, v) => MapEntry(k.toString(), v));
          final dataObj = map['data'];
          final data = dataObj is Map
              ? dataObj.map((k, v) => MapEntry(k.toString(), v))
              : map;

          final title = (data['title'] ?? '').toString().trim();
          if (title.isEmpty) continue;

          final description =
              (data['descriptionPlain'] ?? data['description'] ?? '')
                  .toString()
                  .trim();
          final titleLower = title.toLowerCase();
          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(titleLower);
          });
          if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
            continue;
          }

          final slug = (data['slug'] ?? data['req_id'] ?? data['id'] ?? '')
              .toString()
              .trim();
          final applyLink = slug.isNotEmpty
              ? Uri.https(
                  'careers.blackline.com',
                  '/careers-home/jobs/$slug',
                ).toString()
              : careerUri.toString();
          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          String location = 'Not specified';
          final locationObj = data['location'];
          if (locationObj is Map) {
            final text = (locationObj['name'] ?? locationObj['city'] ?? '')
                .toString()
                .trim();
            if (text.isNotEmpty) {
              location = text;
            }
          } else {
            final text = locationObj?.toString().trim() ?? '';
            if (text.isNotEmpty) {
              location = text;
            }
          }

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location,
              duration: parseDuration(description).$1,
              deadline: '—',
              source: 'BlackLine Jobs API',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('binance.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final apiUri = Uri.https('api.lever.co', '/v0/postings/binance', {
          'mode': 'json',
        });
        final response = await _client
            .get(
              apiUri,
              headers: {
                'user-agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
                'accept': 'application/json, text/plain, */*',
                'accept-language': 'en-US,en;q=0.9',
                'referer': careerUri.toString(),
              },
            )
            .timeout(const Duration(seconds: 20));
        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! List) {
          return const [];
        }

        for (final item in decoded.whereType<Map>()) {
          final map = item.map((k, v) => MapEntry(k.toString(), v));
          final title = (map['text'] ?? '').toString().trim();
          if (title.isEmpty) continue;

          final categories = map['categories'] is Map
              ? (map['categories'] as Map).map(
                  (k, v) => MapEntry(k.toString(), v?.toString().trim() ?? ''),
                )
              : <String, String>{};
          final team = (categories['team'] ?? '').trim();
          final location = (categories['location'] ?? '').trim();
          final commitment = (categories['commitment'] ?? '').trim();
          final department = (categories['department'] ?? '').trim();

          final searchable = [
            title,
            team,
            location,
            commitment,
            department,
          ].where((e) => e.isNotEmpty).join(' | ').toLowerCase();
          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\b${RegExp.escape(kw.toLowerCase())}\b');
            return pattern.hasMatch(searchable);
          });
          if (!exactWordMatch && !fuzzyMatch(title.toLowerCase(), matchTerms)) {
            continue;
          }

          final rawLink = (map['hostedUrl'] ?? map['applyUrl'] ?? '')
              .toString()
              .trim();
          final applyLink = rawLink.isNotEmpty ? rawLink : careerUri.toString();
          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          final detailText = [
            team,
            department,
            commitment,
          ].where((e) => e.isNotEmpty).join(' | ');
          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location.isEmpty ? 'Not specified' : location,
              duration: parseDuration(detailText).$1,
              deadline: '—',
              source: 'Binance Lever API',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('bitcoinsuisse.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final apiUri = Uri.https('bitcoinsuisse.com', '/api/careers');
        final response = await _client
            .get(
              apiUri,
              headers: {
                'user-agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
                'accept': 'application/json, text/plain, */*',
                'accept-language': 'en-US,en;q=0.9',
                'referer': careerUri.toString(),
              },
            )
            .timeout(const Duration(seconds: 12));

        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! List) {
          return const [];
        }

        for (final item in decoded.whereType<Map>()) {
          final map = item.map((k, v) => MapEntry(k.toString(), v));
          final title = (map['title'] ?? '').toString().trim();
          if (title.isEmpty) continue;

          final departments = map['departments'] is List
              ? (map['departments'] as List)
                    .map((e) => e.toString().trim())
                    .where((e) => e.isNotEmpty)
                    .toList()
              : <String>[];
          final departmentText = departments.join(' | ');

          final titleLower = title.toLowerCase();
          final deptLower = departmentText.toLowerCase();
          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\b${RegExp.escape(kw.toLowerCase())}\b');
            return pattern.hasMatch(titleLower) || pattern.hasMatch(deptLower);
          });
          if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
            continue;
          }

          final rawUrl = (map['url'] ?? '').toString().trim();
          final applyLink = rawUrl.isNotEmpty ? rawUrl : careerUri.toString();
          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: 'Not specified',
              duration: parseDuration(departmentText).$1,
              deadline: '—',
              source: 'Bitcoin Suisse Careers API',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('cwan.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final apiUri = Uri.https(
          'cwan.com',
          '/wp-content/themes/wp-clearwater/blocks/workday/api.php',
        );
        final response = await _client
            .get(
              apiUri,
              headers: {
                'user-agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
                'accept': 'application/json, text/plain, */*',
                'accept-language': 'en-US,en;q=0.9',
                'referer': careerUri.toString(),
              },
            )
            .timeout(const Duration(seconds: 20));

        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map || decoded['Job_Posting'] is! List) {
          return const [];
        }

        for (final item in (decoded['Job_Posting'] as List).whereType<Map>()) {
          final map = item.map((k, v) => MapEntry(k.toString(), v));
          final dataObj = map['Job_Posting_Data'];
          if (dataObj is! Map) continue;
          final data = dataObj.map((k, v) => MapEntry(k.toString(), v));

          final title = (data['Job_Posting_Title'] ?? '').toString().trim();
          if (title.isEmpty) continue;

          final externalApply = (data['External_Apply_URL'] ?? '')
              .toString()
              .trim();
          final externalPath = (data['External_Job_Path'] ?? '')
              .toString()
              .trim();
          final applyLink = externalApply.isNotEmpty
              ? externalApply
              : (externalPath.isNotEmpty ? externalPath : careerUri.toString());

          final familyRef = data['Job_Family_Reference'];
          String department = '';
          if (familyRef is Map && familyRef['ID'] is List) {
            final ids = (familyRef['ID'] as List)
                .map((e) => e.toString().trim())
                .where((e) => e.isNotEmpty)
                .toList();
            if (ids.length > 1) {
              department = ids[1];
            } else if (ids.isNotEmpty) {
              department = ids.first;
            }
          }

          final locationRef = data['Job_Posting_Location_Data'];
          String location = 'Not specified';
          if (locationRef is Map) {
            final primary = locationRef['Primary_Location_Reference'];
            if (primary is Map && primary['ID'] is List) {
              final ids = (primary['ID'] as List)
                  .map((e) => e.toString().trim())
                  .where((e) => e.isNotEmpty)
                  .toList();
              if (ids.length > 1) {
                location = ids[1]
                    .replaceFirst(RegExp(r'^LOC-', caseSensitive: false), '')
                    .replaceAll(' Office', '')
                    .trim();
              }
            }
          }

          final searchable = [
            title,
            department,
            location,
          ].where((e) => e.isNotEmpty).join(' | ').toLowerCase();
          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(searchable);
          });
          if (!exactWordMatch) {
            continue;
          }

          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location,
              duration: parseDuration(department).$1,
              deadline: '—',
              source: 'CWAN Workday Feed API',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('careers.dxc.com') &&
        careerUri.path.toLowerCase().contains('/job-search-results')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final baseQuery = Map<String, String>.from(careerUri.queryParameters);
        final requestedPage = int.tryParse(baseQuery['pg'] ?? '') ?? 1;
        final startPage = keywords.isEmpty
            ? (requestedPage < 1 ? 1 : requestedPage)
            : 1;
        final facets = <String>{'is_internal:DXCJobs'};

        final countries =
            careerUri.queryParametersAll['compliment[]'] ??
            careerUri.queryParametersAll['compliment'] ??
            const <String>[];
        for (final country in countries) {
          final c = country.trim();
          if (c.isNotEmpty) {
            facets.add('compliment:$c');
          }
        }
        if (countries.isEmpty) {
          final singleCountry =
              (baseQuery['compliment[]'] ?? baseQuery['compliment'] ?? '')
                  .trim();
          if (singleCountry.isNotEmpty) {
            facets.add('compliment:$singleCountry');
          }
        }

        const limit = 10;
        const orgId = '2492';
        const maxPagesToScan = 120;

        for (final term in matchTerms) {
          var currentPage = startPage;
          var pagesScanned = 0;
          var consecutiveNoHitPages = 0;
          int? total;

          while (pagesScanned < maxPagesToScan) {
            final offset = ((currentPage - 1) * limit) + 1;
            final queryParams = <String, dynamic>{
              'Organization': orgId,
              'SearchText': term,
              'Limit': '$limit',
              'offset': '$offset',
            };
            for (final facet in facets) {
              queryParams.putIfAbsent('facet', () => <String>[]);
              (queryParams['facet'] as List<String>).add(facet);
            }

            final apiUri = Uri.https(
              'jobsapi-internal.m-cloud.io',
              '/api/job',
              queryParams,
            );

            final response = await _client
                .get(
                  apiUri,
                  headers: {
                    'user-agent':
                        userAgents[DateTime.now().millisecond %
                            userAgents.length],
                    'accept': 'application/json, text/plain, */*',
                    'accept-language': 'en-US,en;q=0.9',
                    'referer': careerUri.toString(),
                  },
                )
                .timeout(const Duration(seconds: 20));

            if (response.statusCode >= 400 || response.body.trim().isEmpty) {
              break;
            }

            final decoded = jsonDecode(response.body);
            if (decoded is! Map) {
              break;
            }

            total ??= int.tryParse('${decoded['totalHits'] ?? ''}');
            final jobs = (decoded['queryResult'] is List)
                ? (decoded['queryResult'] as List).whereType<Map>().toList()
                : const <Map>[];
            if (jobs.isEmpty) {
              break;
            }

            final rowsBeforePage = rows.length;
            for (final item in jobs) {
              final map = item.map((k, v) => MapEntry(k.toString(), v));

              final title = (map['title'] ?? '').toString().trim();
              if (title.isEmpty) continue;

              final description = (map['description'] ?? '').toString().trim();
              final city = (map['primary_city'] ?? '').toString().trim();
              final state = (map['primary_state'] ?? '').toString().trim();
              final country = (map['primary_country'] ?? '').toString().trim();
              final function = (map['function'] ?? '').toString().trim();
              final industry = (map['industry'] ?? '').toString().trim();

              final searchable = [
                title,
                description,
                city,
                state,
                country,
                function,
                industry,
              ].where((v) => v.trim().isNotEmpty).join(' | ').toLowerCase();

              final exactWordMatch = matchTerms.any((kw) {
                final pattern = RegExp(
                  '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                );
                return pattern.hasMatch(searchable);
              });
              if (!exactWordMatch &&
                  !fuzzyMatch(title.toLowerCase(), matchTerms) &&
                  !fuzzyMatch(searchable, matchTerms)) {
                continue;
              }

              final seoUrl = (map['seo_url'] ?? '').toString().trim();
              final applyLink = seoUrl.isNotEmpty
                  ? seoUrl
                  : careerUri.toString();
              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.contains(key)) continue;
              seen.add(key);

              final locationParts = [
                city,
                state,
                country,
              ].where((v) => v.isNotEmpty).toList();
              final location = locationParts.isEmpty
                  ? 'Not specified'
                  : locationParts.join(', ');

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location,
                  duration: parseDuration(description).$1,
                  deadline: '—',
                  source: 'DXC Careers API',
                  error: '',
                ),
              );
            }

            if (rows.length == rowsBeforePage) {
              consecutiveNoHitPages++;
            } else {
              consecutiveNoHitPages = 0;
            }

            pagesScanned += 1;
            if (consecutiveNoHitPages >= 20) {
              break;
            }

            if (total != null && total > 0 && offset + jobs.length > total) {
              break;
            }
            if (jobs.length < limit) {
              break;
            }

            currentPage += 1;
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('careers.coca-colacompany.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final baseQuery = Map<String, String>.from(careerUri.queryParameters);
        final requestedStartPage = int.tryParse(baseQuery['pg'] ?? '') ?? 1;
        final startPage = keywords.isEmpty
            ? (requestedStartPage < 1 ? 1 : requestedStartPage)
            : 1;

        const limit = 20;
        const maxPagesToScan = 96;

        for (final term in matchTerms) {
          var offset = ((startPage - 1) * limit) + 1;
          var pagesScanned = 0;
          var consecutiveNoHitPages = 0;
          int? total;

          while (pagesScanned < maxPagesToScan) {
            final query =
                'Organization=2110&Limit=$limit&offset=$offset&sortfield=open_date&sortorder=descending&'
                'facet=ats_portalid%3ACocaCola-Workday-External&facet=is_internal%3Acoca-cola-careers&'
                'SearchText=${Uri.encodeQueryComponent(term)}';
            final apiUri = Uri.parse(
              'https://jobsapi-internal.m-cloud.io/api/job?$query',
            );

            final response = await _client
                .get(
                  apiUri,
                  headers: {
                    'user-agent':
                        userAgents[DateTime.now().millisecond %
                            userAgents.length],
                    'accept': 'application/json, text/plain, */*',
                    'accept-language': 'en-US,en;q=0.9',
                    'referer': careerUri.toString(),
                  },
                )
                .timeout(const Duration(seconds: 20));

            if (response.statusCode >= 400 || response.body.trim().isEmpty) {
              break;
            }

            final decoded = jsonDecode(response.body);
            if (decoded is! Map) {
              break;
            }

            total ??= int.tryParse('${decoded['totalHits'] ?? ''}');
            final jobs = (decoded['queryResult'] is List)
                ? (decoded['queryResult'] as List).whereType<Map>().toList()
                : const <Map>[];
            if (jobs.isEmpty) {
              break;
            }

            final rowsBeforePage = rows.length;
            for (final item in jobs) {
              final map = item.map((k, v) => MapEntry(k.toString(), v));

              final title = (map['title'] ?? map['job_title'] ?? '')
                  .toString()
                  .trim();
              if (title.isEmpty) continue;

              final description =
                  (map['description'] ??
                          map['description_short'] ??
                          map['job_description'] ??
                          '')
                      .toString()
                      .trim();
              final city = (map['primary_city'] ?? '').toString().trim();
              final state = (map['primary_state'] ?? '').toString().trim();
              final country = (map['primary_country'] ?? '').toString().trim();
              final location = [
                city,
                state,
                country,
              ].where((p) => p.isNotEmpty).join(', ');

              final searchable = [
                title,
                description,
                location,
              ].where((p) => p.isNotEmpty).join(' | ').toLowerCase();

              final exactWordMatch = matchTerms.any((kw) {
                final pattern = RegExp(
                  '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                );
                return pattern.hasMatch(searchable);
              });
              if (!exactWordMatch &&
                  !fuzzyMatch(title.toLowerCase(), matchTerms) &&
                  !fuzzyMatch(description.toLowerCase(), matchTerms)) {
                continue;
              }

              final seoUrl = (map['seo_url'] ?? '').toString().trim();
              final rawUrl = (map['url'] ?? '').toString().trim();
              final applyLink = seoUrl.isEmpty
                  ? (rawUrl.isNotEmpty ? rawUrl : careerUri.toString())
                  : (seoUrl.startsWith('http')
                        ? seoUrl
                        : 'https://careers.coca-colacompany.com/job/$seoUrl');

              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.contains(key)) continue;
              seen.add(key);

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location.isEmpty ? 'Not specified' : location,
                  duration: parseDuration('$title $description').$1,
                  deadline: '—',
                  source: 'Coca-Cola Careers API',
                  error: '',
                ),
              );
            }

            if (rows.length == rowsBeforePage) {
              consecutiveNoHitPages++;
            } else {
              consecutiveNoHitPages = 0;
            }

            pagesScanned += 1;
            if (consecutiveNoHitPages >= 20) {
              break;
            }

            if (total != null && total > 0 && offset + jobs.length > total) {
              break;
            }
            if (jobs.length < limit) {
              break;
            }

            offset += limit;
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('coinbase.com') &&
        careerUri.path.toLowerCase().contains('/careers/positions')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final baseQuery = Map<String, String>.from(careerUri.queryParameters);
        final requestedCountry = (baseQuery['country'] ?? '')
            .trim()
            .toLowerCase();
        const countryNameByCode = <String, String>{
          'in': 'india',
          'us': 'usa',
          'gb': 'uk',
          'uk': 'uk',
          'sg': 'singapore',
          'ca': 'canada',
          'ae': 'united arab emirates',
          'au': 'australia',
          'br': 'brazil',
          'cy': 'cyprus',
          'ie': 'ireland',
          'lu': 'luxembourg',
        };
        final requestedCountryName =
            countryNameByCode[requestedCountry] ?? requestedCountry;

        final apiUri = Uri.https(
          'boards-api.greenhouse.io',
          '/v1/boards/coinbase/jobs',
          {'content': 'true'},
        );

        final response = await _client
            .get(
              apiUri,
              headers: {
                'user-agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
                'accept': 'application/json, text/plain, */*',
                'accept-language': 'en-US,en;q=0.9',
                'referer': careerUri.toString(),
              },
            )
            .timeout(const Duration(seconds: 20));

        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map || decoded['jobs'] is! List) {
          return const [];
        }

        bool matchesRequestedCountry(String locationLower) {
          if (requestedCountry.isEmpty) return true;
          if (locationLower.contains(requestedCountryName)) return true;
          if (requestedCountry.length == 2) {
            final pattern = RegExp('\\b${RegExp.escape(requestedCountry)}\\b');
            return pattern.hasMatch(locationLower);
          }
          return false;
        }

        for (final item in (decoded['jobs'] as List).whereType<Map>()) {
          final map = item.map((k, v) => MapEntry(k.toString(), v));

          final title = (map['title'] ?? '').toString().trim();
          if (title.isEmpty) continue;

          final locationObj = map['location'];
          final location = locationObj is Map
              ? (locationObj['name'] ?? '').toString().trim()
              : '';
          final locationLower = location.toLowerCase();
          if (!matchesRequestedCountry(locationLower)) {
            continue;
          }

          final rawContent = (map['content'] ?? '').toString();
          final normalizedHtml = rawContent
              .replaceAll('&lt;', '<')
              .replaceAll('&gt;', '>')
              .replaceAll('&amp;', '&');
          final contentText =
              html_parser.parse(normalizedHtml).documentElement?.text ??
              rawContent;

          final searchable = [
            title,
            location,
            contentText,
          ].where((p) => p.trim().isNotEmpty).join(' | ').toLowerCase();

          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(searchable);
          });
          if (!exactWordMatch &&
              !fuzzyMatch(title.toLowerCase(), matchTerms) &&
              !fuzzyMatch(contentText.toLowerCase(), matchTerms)) {
            continue;
          }

          final applyLink = (map['absolute_url'] ?? map['url'] ?? '')
              .toString()
              .trim();
          final resolvedApplyLink = applyLink.isNotEmpty
              ? applyLink
              : careerUri.toString();

          final key =
              '${title.toLowerCase()}|${resolvedApplyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: resolvedApplyLink,
              location: location.isEmpty ? 'Not specified' : location,
              duration: parseDuration('$title $contentText').$1,
              deadline: '—',
              source: 'Coinbase Greenhouse API',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('darwinbox.in')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final rendered = await _fetchRendered(careerUri);
        final html = (rendered != null && rendered.trim().isNotEmpty)
            ? rendered
            : await _fetch(careerUri);
        if (html == null || html.trim().isEmpty) {
          return const [];
        }

        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        final doc = html_parser.parse(html);
        final ctas = doc.querySelectorAll('a,button,span,div').where((el) {
          final t = normalize(el.text).toLowerCase();
          return t == 'view and apply' || t.contains('view and apply');
        }).toList();

        for (final cta in ctas) {
          html_dom.Element? card = cta;
          String cardText = '';
          for (var i = 0; i < 7 && card != null; i++) {
            final t = normalize(card.text);
            if (t.toLowerCase().contains('view and apply') && t.length > 20) {
              cardText = t;
              break;
            }
            card = card.parent;
          }
          if (card == null || cardText.isEmpty) continue;

          final prefix = cardText
              .split(RegExp('view and apply', caseSensitive: false))
              .first;
          final titleMatch = RegExp(
            r'^\s*([A-Za-z0-9][A-Za-z0-9 &\-_/]{2,120})',
          ).firstMatch(prefix);
          final title = normalize(titleMatch?.group(1) ?? '');
          if (title.isEmpty) continue;
          final titleLower = title.toLowerCase();
          final looksLikeUiNoise =
              title.length > 90 ||
              titleLower.contains('search by role') ||
              titleLower.contains('recommended jobs') ||
              titleLower.contains('discover opportunities') ||
              titleLower.contains('drag and drop your resume') ||
              titleLower.contains('open jobs') ||
              titleLower.contains('sign in');
          if (looksLikeUiNoise) continue;

          final locationMatch = RegExp(
            r'([A-Za-z_ ]+,\s*[A-Za-z ]+,\s*[A-Za-z ]+,\s*[A-Za-z ]+)',
            caseSensitive: false,
          ).firstMatch(cardText);
          final location = normalize(locationMatch?.group(1) ?? '');

          final textLower = cardText.toLowerCase();
          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(titleLower) || pattern.hasMatch(textLower);
          });
          if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
            continue;
          }

          final anchor = cta.localName == 'a'
              ? cta
              : (card.querySelector('a[href]') ?? cta.querySelector('a[href]'));
          final href = (anchor?.attributes['href'] ?? '').trim();
          final applyLink = href.isNotEmpty
              ? careerUri.resolve(href).toString()
              : careerUri.toString();

          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          final durationData = parseDuration(cardText);
          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location.isEmpty ? 'Not specified' : location,
              duration: durationData.$1,
              deadline: '—',
              source: 'Darwinbox Rendered Careers',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('careers.bcg.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        String decodePhenomText(String value) {
          return value
              .replaceAll(r'\/', '/')
              .replaceAll('&amp;', '&')
              .replaceAll(r'\"', '"')
              .replaceAll(r'\n', ' ')
              .trim();
        }

        for (final term in matchTerms) {
          final searchUri = Uri.https(
            'careers.bcg.com',
            '/global/en/search-results',
            {'keywords': term, 'from': '0', 's': '1'},
          );

          String? html;
          for (final ua in userAgents.take(3)) {
            final resp = await _client
                .get(
                  searchUri,
                  headers: {
                    'User-Agent': ua,
                    'Accept-Language': 'en-US,en;q=0.9',
                    'Accept':
                        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                    'DNT': '1',
                  },
                )
                .timeout(const Duration(seconds: 12));
            if (resp.statusCode >= 400 || resp.body.trim().isEmpty) {
              continue;
            }
            if (resp.body.contains(
              '"applyUrl":"https://experiencedtalent.bcg.com/careerhub/explore/jobs/',
            )) {
              html = resp.body;
              break;
            }
            html ??= resp.body;
          }

          if (html == null || html.trim().isEmpty) {
            continue;
          }

          final objectMatches = RegExp(
            r'"title":"([^"\\]*(?:\\.[^"\\]*)*)".{0,2500}?"applyUrl":"(https://experiencedtalent\.bcg\.com/careerhub/explore/jobs/[^"\\]+)"',
            caseSensitive: false,
            dotAll: true,
          ).allMatches(html);

          for (final match in objectMatches) {
            final title = decodePhenomText(match.group(1)?.trim() ?? '');
            if (title.isEmpty) continue;
            final applyLink = decodePhenomText(match.group(2)?.trim() ?? '');
            if (applyLink.isEmpty) continue;

            final index = match.start;
            final windowStart = (index - 400) < 0 ? 0 : index - 400;
            final windowEnd = (index + 2800) > html.length
                ? html.length
                : index + 2800;
            final window = html.substring(windowStart, windowEnd);

            final description = decodePhenomText(
              RegExp(
                    r'"descriptionTeaser":"([^"\\]*(?:\\.[^"\\]*)*)"',
                  ).firstMatch(window)?.group(1) ??
                  '',
            );
            final location = decodePhenomText(
              RegExp(
                    r'"location":"([^"\\]*(?:\\.[^"\\]*)*)"',
                  ).firstMatch(window)?.group(1) ??
                  '',
            );

            final titleLower = title.toLowerCase();
            final descLower = description.toLowerCase();
            final locLower = location.toLowerCase();
            final exactWordMatch = matchTerms.any((kw) {
              final pattern = RegExp(
                '\\b${RegExp.escape(kw.toLowerCase())}\\b',
              );
              return pattern.hasMatch(titleLower) ||
                  pattern.hasMatch(descLower) ||
                  pattern.hasMatch(locLower);
            });
            if (!exactWordMatch &&
                !fuzzyMatch(titleLower, matchTerms) &&
                !fuzzyMatch(descLower, matchTerms)) {
              continue;
            }

            final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
            if (seen.contains(key)) continue;
            seen.add(key);

            final durationData = parseDuration(description);
            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: searchUri.toString(),
                applyLink: applyLink,
                location: location.isEmpty ? 'Not specified' : location,
                duration: durationData.$1,
                deadline: '—',
                source: 'BCG Phenom Search HTML',
                error: '',
              ),
            );
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('careers.breadfinancial.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final searchPath =
            careerUri.path.toLowerCase().contains('/search-results')
            ? careerUri.path
            : '/us/en/search-results';

        String decodePhenomText(String value) {
          return value
              .replaceAllMapped(RegExp(r'\\u([0-9a-fA-F]{4})'), (m) {
                final code = int.tryParse(m.group(1) ?? '', radix: 16);
                return code == null ? '' : String.fromCharCode(code);
              })
              .replaceAll(r'\/', '/')
              .replaceAll('&amp;', '&')
              .replaceAll(r'\"', '"')
              .replaceAll(r'\n', ' ')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
        }

        final pageSize = 10;
        final baseQuery = Map<String, String>.from(careerUri.queryParameters);
        final startOffset = int.tryParse(baseQuery['from'] ?? '') ?? 0;

        var maxOffset = startOffset + 90;
        for (
          var offset = startOffset;
          offset <= maxOffset && offset <= (startOffset + 120);
          offset += pageSize
        ) {
          final query = Map<String, String>.from(baseQuery)
            ..remove('from')
            ..remove('s')
            ..['from'] = '$offset'
            ..['s'] = '1';

          final pageUri = Uri.https(
            careerUri.host,
            searchPath,
            query.isEmpty ? null : query,
          );

          final resp = await _client
              .get(
                pageUri,
                headers: {
                  'User-Agent':
                      userAgents[DateTime.now().millisecond %
                          userAgents.length],
                  'Accept-Language': 'en-US,en;q=0.9',
                  'Accept':
                      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                  'DNT': '1',
                },
              )
              .timeout(const Duration(seconds: 12));

          if (resp.statusCode >= 400 || resp.body.trim().isEmpty) {
            continue;
          }

          if (offset == startOffset) {
            final totalResultsMatch = RegExp(
              r'(\d+)\s*results',
              caseSensitive: false,
            ).firstMatch(resp.body);
            final totalResults = int.tryParse(
              totalResultsMatch?.group(1) ?? '',
            );
            if (totalResults != null && totalResults > 0) {
              maxOffset = ((totalResults - 1) ~/ pageSize) * pageSize;
            }
          }

          final applyMatches = RegExp(
            r'"applyUrl":"(https?:[^"\\]+)"',
            caseSensitive: false,
            dotAll: true,
          ).allMatches(resp.body);

          if (applyMatches.isEmpty) {
            continue;
          }

          for (final match in applyMatches) {
            final applyLinkRaw = decodePhenomText(match.group(1)?.trim() ?? '');
            if (applyLinkRaw.isEmpty) continue;

            final index = match.start;
            final beforeStart = (index - 2600) < 0 ? 0 : index - 2600;
            final before = resp.body.substring(beforeStart, index);

            final titleMatches = RegExp(
              r'"title":"([^"\\]*(?:\\.[^"\\]*)*)"',
              caseSensitive: false,
              dotAll: true,
            ).allMatches(before);
            if (titleMatches.isEmpty) continue;

            final title = decodePhenomText(
              titleMatches.last.group(1)?.trim() ?? '',
            );
            if (title.isEmpty) continue;

            final windowStart = (index - 600) < 0 ? 0 : index - 600;
            final windowEnd = (index + 3000) > resp.body.length
                ? resp.body.length
                : index + 3000;
            final window = resp.body.substring(windowStart, windowEnd);

            final description = decodePhenomText(
              RegExp(
                    r'"descriptionTeaser":"([^"\\]*(?:\\.[^"\\]*)*)"',
                  ).firstMatch(window)?.group(1) ??
                  '',
            );
            final location = decodePhenomText(
              RegExp(
                    r'"location":"([^"\\]*(?:\\.[^"\\]*)*)"',
                  ).firstMatch(window)?.group(1) ??
                  '',
            );

            final titleLower = title.toLowerCase();
            final descLower = description.toLowerCase();
            final locLower = location.toLowerCase();
            final exactWordMatch = matchTerms.any((kw) {
              final pattern = RegExp(
                '\\b${RegExp.escape(kw.toLowerCase())}\\b',
              );
              return pattern.hasMatch(titleLower) ||
                  pattern.hasMatch(descLower) ||
                  pattern.hasMatch(locLower);
            });
            if (!exactWordMatch &&
                !fuzzyMatch(titleLower, matchTerms) &&
                !fuzzyMatch(descLower, matchTerms)) {
              continue;
            }

            final applyLink = applyLinkRaw.startsWith('http')
                ? applyLinkRaw
                : pageUri.resolve(applyLinkRaw).toString();
            final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
            if (seen.contains(key)) continue;
            seen.add(key);

            final durationData = parseDuration(description);
            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: careerUri.toString(),
                applyLink: applyLink,
                location: location.isEmpty ? 'Not specified' : location,
                duration: durationData.$1,
                deadline: '—',
                source: 'Bread Financial Phenom Search HTML',
                error: '',
              ),
            );
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('jobs.thecignagroup.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final searchPath =
            careerUri.path.toLowerCase().contains('/search-results')
            ? careerUri.path
            : '/us/en/search-results';

        String decodePhenomText(String value) {
          return value
              .replaceAllMapped(RegExp(r'\\u([0-9a-fA-F]{4})'), (m) {
                final code = int.tryParse(m.group(1) ?? '', radix: 16);
                return code == null ? '' : String.fromCharCode(code);
              })
              .replaceAll(r'\/', '/')
              .replaceAll('&amp;', '&')
              .replaceAll(r'\"', '"')
              .replaceAll(r'\n', ' ')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
        }

        final pageSize = 10;
        final baseQuery = Map<String, String>.from(careerUri.queryParameters);
        final startOffset = int.tryParse(baseQuery['from'] ?? '') ?? 0;

        var maxOffset = startOffset + 90;
        for (
          var offset = startOffset;
          offset <= maxOffset && offset <= (startOffset + 120);
          offset += pageSize
        ) {
          final query = Map<String, String>.from(baseQuery)
            ..remove('from')
            ..remove('s')
            ..['from'] = '$offset'
            ..['s'] = '1';

          final pageUri = Uri.https(
            careerUri.host,
            searchPath,
            query.isEmpty ? null : query,
          );

          final resp = await _client
              .get(
                pageUri,
                headers: {
                  'User-Agent':
                      userAgents[DateTime.now().millisecond %
                          userAgents.length],
                  'Accept-Language': 'en-US,en;q=0.9',
                  'Accept':
                      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                  'DNT': '1',
                },
              )
              .timeout(const Duration(seconds: 12));

          if (resp.statusCode >= 400 || resp.body.trim().isEmpty) {
            continue;
          }

          if (offset == startOffset) {
            final totalResultsMatch = RegExp(
              r'(\d+)\s*results',
              caseSensitive: false,
            ).firstMatch(resp.body);
            final totalResults = int.tryParse(
              totalResultsMatch?.group(1) ?? '',
            );
            if (totalResults != null && totalResults > 0) {
              maxOffset = ((totalResults - 1) ~/ pageSize) * pageSize;
            }
          }

          final applyMatches = RegExp(
            r'"applyUrl":"(https?:[^"\\]+)"',
            caseSensitive: false,
            dotAll: true,
          ).allMatches(resp.body);

          if (applyMatches.isEmpty) {
            continue;
          }

          for (final match in applyMatches) {
            final applyLinkRaw = decodePhenomText(match.group(1)?.trim() ?? '');
            if (applyLinkRaw.isEmpty) continue;

            final applyLink = applyLinkRaw.startsWith('http')
                ? applyLinkRaw
                : pageUri.resolve(applyLinkRaw).toString();

            String titleFromApplyLink(String url) {
              final uri = Uri.tryParse(url);
              if (uri == null || uri.pathSegments.isEmpty) return '';
              final applyIndex = uri.pathSegments.lastIndexOf('apply');
              if (applyIndex <= 0) return '';
              var slug = uri.pathSegments[applyIndex - 1];
              slug = slug.replaceFirst(RegExp(r'_[0-9]+$'), '');
              slug = slug
                  .replaceAll('---', ' - ')
                  .replaceAll('-', ' ')
                  .replaceAll(RegExp(r'\s+'), ' ')
                  .trim();
              return slug;
            }

            final index = match.start;
            final beforeStart = (index - 2600) < 0 ? 0 : index - 2600;
            final before = resp.body.substring(beforeStart, index);

            final titleMatches = RegExp(
              r'"title":"([^"\\]*(?:\\.[^"\\]*)*)"',
              caseSensitive: false,
              dotAll: true,
            ).allMatches(before);
            if (titleMatches.isEmpty) continue;

            final title = decodePhenomText(
              titleMatches.last.group(1)?.trim() ?? '',
            );
            final derivedTitle = titleFromApplyLink(applyLink);
            final chosenTitle = derivedTitle.isNotEmpty ? derivedTitle : title;
            if (chosenTitle.isEmpty) continue;

            final windowStart = (index - 600) < 0 ? 0 : index - 600;
            final windowEnd = (index + 3000) > resp.body.length
                ? resp.body.length
                : index + 3000;
            final window = resp.body.substring(windowStart, windowEnd);

            final description = decodePhenomText(
              RegExp(
                    r'"descriptionTeaser":"([^"\\]*(?:\\.[^"\\]*)*)"',
                  ).firstMatch(window)?.group(1) ??
                  '',
            );
            final location = decodePhenomText(
              RegExp(
                    r'"location":"([^"\\]*(?:\\.[^"\\]*)*)"',
                  ).firstMatch(window)?.group(1) ??
                  '',
            );

            final titleLower = chosenTitle.toLowerCase();
            final descLower = description.toLowerCase();
            final locLower = location.toLowerCase();
            final exactWordMatch = matchTerms.any((kw) {
              final pattern = RegExp(
                '\\b${RegExp.escape(kw.toLowerCase())}\\b',
              );
              return pattern.hasMatch(titleLower) ||
                  pattern.hasMatch(descLower) ||
                  pattern.hasMatch(locLower);
            });
            if (!exactWordMatch &&
                !fuzzyMatch(titleLower, matchTerms) &&
                !fuzzyMatch(descLower, matchTerms)) {
              continue;
            }

            final key =
                '${chosenTitle.toLowerCase()}|${applyLink.toLowerCase()}';
            if (seen.contains(key)) continue;
            seen.add(key);

            final durationData = parseDuration(description);
            rows.add(
              ScanResultRow(
                company: companyName,
                title: chosenTitle,
                companyUrl: careerUri.toString(),
                applyLink: applyLink,
                location: location.isEmpty ? 'Not specified' : location,
                duration: durationData.$1,
                deadline: '—',
                source: 'Cigna Phenom Search HTML',
                error: '',
              ),
            );
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('careers.circle.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final searchPath =
            careerUri.path.toLowerCase().contains('/search-results')
            ? careerUri.path
            : '/us/en/search-results';

        String decodePhenomText(String value) {
          return value
              .replaceAllMapped(RegExp(r'\\u([0-9a-fA-F]{4})'), (m) {
                final code = int.tryParse(m.group(1) ?? '', radix: 16);
                return code == null ? '' : String.fromCharCode(code);
              })
              .replaceAll(r'\/', '/')
              .replaceAll('&amp;', '&')
              .replaceAll(r'\"', '"')
              .replaceAll(r'\n', ' ')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
        }

        final pageSize = 10;
        final baseQuery = Map<String, String>.from(careerUri.queryParameters);
        final startOffset = int.tryParse(baseQuery['from'] ?? '') ?? 0;

        var maxOffset = startOffset + 90;
        for (
          var offset = startOffset;
          offset <= maxOffset && offset <= (startOffset + 160);
          offset += pageSize
        ) {
          final query = Map<String, String>.from(baseQuery)
            ..remove('from')
            ..remove('s')
            ..['from'] = '$offset'
            ..['s'] = '1';

          final pageUri = Uri.https(
            careerUri.host,
            searchPath,
            query.isEmpty ? null : query,
          );

          final resp = await _client
              .get(
                pageUri,
                headers: {
                  'User-Agent':
                      userAgents[DateTime.now().millisecond %
                          userAgents.length],
                  'Accept-Language': 'en-US,en;q=0.9',
                  'Accept':
                      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                  'DNT': '1',
                },
              )
              .timeout(const Duration(seconds: 12));

          if (resp.statusCode >= 400 || resp.body.trim().isEmpty) {
            continue;
          }

          if (offset == startOffset) {
            final totalResultsMatch = RegExp(
              r'(\d+)\s*results',
              caseSensitive: false,
            ).firstMatch(resp.body);
            final totalResults = int.tryParse(
              totalResultsMatch?.group(1) ?? '',
            );
            if (totalResults != null && totalResults > 0) {
              maxOffset = ((totalResults - 1) ~/ pageSize) * pageSize;
            }
          }

          final applyMatches = RegExp(
            r'"applyUrl":"(https?:[^"\\]+)"',
            caseSensitive: false,
            dotAll: true,
          ).allMatches(resp.body);

          if (applyMatches.isEmpty) {
            continue;
          }

          for (final match in applyMatches) {
            final applyLinkRaw = decodePhenomText(match.group(1)?.trim() ?? '');
            if (applyLinkRaw.isEmpty) continue;

            final applyLink = applyLinkRaw.startsWith('http')
                ? applyLinkRaw
                : pageUri.resolve(applyLinkRaw).toString();

            String titleFromApplyLink(String url) {
              final uri = Uri.tryParse(url);
              if (uri == null || uri.pathSegments.isEmpty) return '';
              final applyIndex = uri.pathSegments.lastIndexOf('apply');
              if (applyIndex <= 0) return '';
              var slug = uri.pathSegments[applyIndex - 1];
              slug = slug.replaceFirst(RegExp(r'_[0-9]+$'), '');
              slug = slug
                  .replaceAll('---', ' - ')
                  .replaceAll('-', ' ')
                  .replaceAll(RegExp(r'\s+'), ' ')
                  .trim();
              return slug;
            }

            final index = match.start;
            final beforeStart = (index - 2600) < 0 ? 0 : index - 2600;
            final before = resp.body.substring(beforeStart, index);

            final titleMatches = RegExp(
              r'"title":"([^"\\]*(?:\\.[^"\\]*)*)"',
              caseSensitive: false,
              dotAll: true,
            ).allMatches(before);
            if (titleMatches.isEmpty) continue;

            final title = decodePhenomText(
              titleMatches.last.group(1)?.trim() ?? '',
            );
            final derivedTitle = titleFromApplyLink(applyLink);
            final chosenTitle = derivedTitle.isNotEmpty ? derivedTitle : title;
            if (chosenTitle.isEmpty) continue;

            final windowStart = (index - 600) < 0 ? 0 : index - 600;
            final windowEnd = (index + 3000) > resp.body.length
                ? resp.body.length
                : index + 3000;
            final window = resp.body.substring(windowStart, windowEnd);

            final description = decodePhenomText(
              RegExp(
                    r'"descriptionTeaser":"([^"\\]*(?:\\.[^"\\]*)*)"',
                  ).firstMatch(window)?.group(1) ??
                  '',
            );
            final location = decodePhenomText(
              RegExp(
                    r'"location":"([^"\\]*(?:\\.[^"\\]*)*)"',
                  ).firstMatch(window)?.group(1) ??
                  '',
            );

            final titleLower = chosenTitle.toLowerCase();
            final descLower = description.toLowerCase();
            final locLower = location.toLowerCase();
            final exactWordMatch = matchTerms.any((kw) {
              final pattern = RegExp(
                '\\b${RegExp.escape(kw.toLowerCase())}\\b',
              );
              return pattern.hasMatch(titleLower) ||
                  pattern.hasMatch(descLower) ||
                  pattern.hasMatch(locLower);
            });
            if (!exactWordMatch &&
                !fuzzyMatch(titleLower, matchTerms) &&
                !fuzzyMatch(descLower, matchTerms)) {
              continue;
            }

            final key =
                '${chosenTitle.toLowerCase()}|${applyLink.toLowerCase()}';
            if (seen.contains(key)) continue;
            seen.add(key);

            final durationData = parseDuration(description);
            rows.add(
              ScanResultRow(
                company: companyName,
                title: chosenTitle,
                companyUrl: careerUri.toString(),
                applyLink: applyLink,
                location: location.isEmpty ? 'Not specified' : location,
                duration: durationData.$1,
                deadline: '—',
                source: 'Circle Phenom Search HTML',
                error: '',
              ),
            );
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('careers.cisco.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final searchPath =
            careerUri.path.toLowerCase().contains('/search-results')
            ? careerUri.path
            : '/global/en/search-results';

        String decodePhenomText(String value) {
          return value
              .replaceAllMapped(RegExp(r'\\u([0-9a-fA-F]{4})'), (m) {
                final code = int.tryParse(m.group(1) ?? '', radix: 16);
                return code == null ? '' : String.fromCharCode(code);
              })
              .replaceAll(r'\/', '/')
              .replaceAll('&amp;', '&')
              .replaceAll(r'\"', '"')
              .replaceAll(r'\n', ' ')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
        }

        final pageSize = 10;
        final baseQuery = Map<String, String>.from(careerUri.queryParameters);
        final startOffset = int.tryParse(baseQuery['from'] ?? '') ?? 0;

        // Cisco currently exposes deep pagination; keep a deterministic fallback.
        var maxOffset = startOffset + 840;
        for (
          var offset = startOffset;
          offset <= maxOffset && offset <= (startOffset + 360);
          offset += pageSize
        ) {
          final query = Map<String, String>.from(baseQuery)
            ..remove('from')
            ..remove('s')
            ..['from'] = '$offset'
            ..['s'] = '1';

          final pageUri = Uri.https(
            careerUri.host,
            searchPath,
            query.isEmpty ? null : query,
          );

          final resp = await _client
              .get(
                pageUri,
                headers: {
                  'User-Agent':
                      userAgents[DateTime.now().millisecond %
                          userAgents.length],
                  'Accept-Language': 'en-US,en;q=0.9',
                  'Accept':
                      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                  'DNT': '1',
                },
              )
              .timeout(const Duration(seconds: 12));

          if (resp.statusCode >= 400 || resp.body.trim().isEmpty) {
            continue;
          }

          if (offset == startOffset) {
            final totalResultsMatch = RegExp(
              r'(\d+)\s*results',
              caseSensitive: false,
            ).firstMatch(resp.body);
            final totalResults = int.tryParse(
              totalResultsMatch?.group(1) ?? '',
            );
            if (totalResults != null && totalResults > 0) {
              maxOffset = ((totalResults - 1) ~/ pageSize) * pageSize;
            }
          }

          final applyMatches = RegExp(
            r'"applyUrl":"(https?:[^"\\]+)"',
            caseSensitive: false,
            dotAll: true,
          ).allMatches(resp.body);

          if (applyMatches.isEmpty) {
            continue;
          }

          for (final match in applyMatches) {
            final applyLinkRaw = decodePhenomText(match.group(1)?.trim() ?? '');
            if (applyLinkRaw.isEmpty) continue;

            final applyLink = applyLinkRaw.startsWith('http')
                ? applyLinkRaw
                : pageUri.resolve(applyLinkRaw).toString();

            String titleFromApplyLink(String url) {
              final uri = Uri.tryParse(url);
              if (uri == null || uri.pathSegments.isEmpty) return '';
              final applyIndex = uri.pathSegments.lastIndexOf('apply');
              if (applyIndex <= 0) return '';
              var slug = uri.pathSegments[applyIndex - 1];
              slug = slug.replaceFirst(RegExp(r'_[0-9]+$'), '');
              slug = slug
                  .replaceAll('---', ' - ')
                  .replaceAll('-', ' ')
                  .replaceAll(RegExp(r'\s+'), ' ')
                  .trim();
              return slug;
            }

            final index = match.start;
            final beforeStart = (index - 2600) < 0 ? 0 : index - 2600;
            final before = resp.body.substring(beforeStart, index);

            final titleMatches = RegExp(
              r'"title":"([^"\\]*(?:\\.[^"\\]*)*)"',
              caseSensitive: false,
              dotAll: true,
            ).allMatches(before);
            if (titleMatches.isEmpty) continue;

            final title = decodePhenomText(
              titleMatches.last.group(1)?.trim() ?? '',
            );
            final derivedTitle = titleFromApplyLink(applyLink);
            final chosenTitle = derivedTitle.isNotEmpty ? derivedTitle : title;
            if (chosenTitle.isEmpty) continue;

            final windowStart = (index - 600) < 0 ? 0 : index - 600;
            final windowEnd = (index + 3000) > resp.body.length
                ? resp.body.length
                : index + 3000;
            final window = resp.body.substring(windowStart, windowEnd);

            final description = decodePhenomText(
              RegExp(
                    r'"descriptionTeaser":"([^"\\]*(?:\\.[^"\\]*)*)"',
                  ).firstMatch(window)?.group(1) ??
                  '',
            );
            final location = decodePhenomText(
              RegExp(
                    r'"location":"([^"\\]*(?:\\.[^"\\]*)*)"',
                  ).firstMatch(window)?.group(1) ??
                  '',
            );

            final titleLower = chosenTitle.toLowerCase();
            final descLower = description.toLowerCase();
            final locLower = location.toLowerCase();
            final exactWordMatch = matchTerms.any((kw) {
              final pattern = RegExp(
                '\\b${RegExp.escape(kw.toLowerCase())}\\b',
              );
              return pattern.hasMatch(titleLower) ||
                  pattern.hasMatch(descLower) ||
                  pattern.hasMatch(locLower);
            });
            if (!exactWordMatch &&
                !fuzzyMatch(titleLower, matchTerms) &&
                !fuzzyMatch(descLower, matchTerms)) {
              continue;
            }

            final key =
                '${chosenTitle.toLowerCase()}|${applyLink.toLowerCase()}';
            if (seen.contains(key)) continue;
            seen.add(key);

            final durationData = parseDuration(description);
            rows.add(
              ScanResultRow(
                company: companyName,
                title: chosenTitle,
                companyUrl: careerUri.toString(),
                applyLink: applyLink,
                location: location.isEmpty ? 'Not specified' : location,
                duration: durationData.$1,
                deadline: '—',
                source: 'Cisco Phenom Search HTML',
                error: '',
              ),
            );
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('jobs.citi.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final searchPath = careerUri.path.toLowerCase().contains('/search-jobs')
            ? careerUri.path
            : '/search-jobs';

        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        final baseQuery = Map<String, String>.from(careerUri.queryParameters);
        final requestedStartPage = int.tryParse(baseQuery['p'] ?? '') ?? 1;
        final startPage = requestedStartPage < 1 ? 1 : requestedStartPage;

        for (final term in matchTerms) {
          final termQuery = Map<String, String>.from(baseQuery);
          if ((termQuery['k'] ?? '').trim().isEmpty) {
            termQuery['k'] = term;
          }

          final firstQuery = Map<String, String>.from(termQuery)
            ..['p'] = '$startPage';
          final firstPageUri = Uri.https(
            careerUri.host,
            searchPath,
            firstQuery.isEmpty ? null : firstQuery,
          );

          final firstResp = await _client
              .get(
                firstPageUri,
                headers: {
                  'User-Agent':
                      userAgents[DateTime.now().millisecond %
                          userAgents.length],
                  'Accept-Language': 'en-US,en;q=0.9',
                  'Accept':
                      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                  'DNT': '1',
                },
              )
              .timeout(const Duration(seconds: 12));

          if (firstResp.statusCode >= 400 || firstResp.body.trim().isEmpty) {
            continue;
          }

          final maxFromInput = int.tryParse(
            RegExp(
                  r'<input[^>]*class="[^"]*pagination-current[^"]*"[^>]*max="(\d+)"',
                  caseSensitive: false,
                ).firstMatch(firstResp.body)?.group(1) ??
                '',
          );
          final maxFromText = int.tryParse(
            RegExp(
                  r'pagination-total-pages">\s*/\s*(\d+)',
                  caseSensitive: false,
                ).firstMatch(firstResp.body)?.group(1) ??
                '',
          );
          final discoveredMaxPage = (maxFromInput ?? maxFromText ?? startPage);
          final cappedMaxPage = discoveredMaxPage > 300
              ? 300
              : discoveredMaxPage;
          var consecutiveNoHitPages = 0;

          for (var page = startPage; page <= cappedMaxPage; page++) {
            final rowsBeforePage = rows.length;
            final pageQuery = Map<String, String>.from(termQuery)
              ..['p'] = '$page';
            final pageUri = Uri.https(
              careerUri.host,
              searchPath,
              pageQuery.isEmpty ? null : pageQuery,
            );

            final resp = page == startPage
                ? firstResp
                : await _client
                      .get(
                        pageUri,
                        headers: {
                          'User-Agent':
                              userAgents[DateTime.now().millisecond %
                                  userAgents.length],
                          'Accept-Language': 'en-US,en;q=0.9',
                          'Accept':
                              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                          'DNT': '1',
                        },
                      )
                      .timeout(const Duration(seconds: 12));

            if (resp.statusCode >= 400 || resp.body.trim().isEmpty) {
              continue;
            }

            final doc = html_parser.parse(resp.body);
            final jobItems = doc.querySelectorAll('li.sr-job-item');
            if (jobItems.isEmpty && page > startPage) {
              break;
            }

            for (final item in jobItems) {
              final anchor =
                  item.querySelector('h3.sr-job-item__title a[href]') ??
                  item.querySelector('a.sr-job-item__link[href]') ??
                  item.querySelector('a[href*="/job/"]');
              final href = (anchor?.attributes['href'] ?? '').trim();
              if (href.isEmpty) continue;

              final title = normalize(anchor?.text ?? '');
              if (title.isEmpty) continue;

              final applyLink = pageUri.resolve(href).toString();
              final location = normalize(
                item.querySelector('.sr-job-location')?.text ?? '',
              );
              final cardText = normalize(item.text);

              final titleLower = title.toLowerCase();
              final textLower = cardText.toLowerCase();
              final locLower = location.toLowerCase();
              final exactWordMatch = matchTerms.any((kw) {
                final pattern = RegExp(
                  '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                );
                return pattern.hasMatch(titleLower) ||
                    pattern.hasMatch(textLower) ||
                    pattern.hasMatch(locLower);
              });
              if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
                continue;
              }

              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.contains(key)) continue;
              seen.add(key);

              final durationData = parseDuration(cardText);
              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location.isEmpty ? 'Not specified' : location,
                  duration: durationData.$1,
                  deadline: '—',
                  source: 'Citi TalentBrew Search HTML',
                  error: '',
                ),
              );
            }

            if (rows.length == rowsBeforePage) {
              consecutiveNoHitPages++;
            } else {
              consecutiveNoHitPages = 0;
            }

            if (consecutiveNoHitPages >= 20) {
              break;
            }
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('jobs.disneycareers.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final queryTerms = keywords.isEmpty ? [''] : keywords;

        final latitude =
            (careerUri.queryParameters['glat'] ??
                    careerUri.queryParameters['Latitude'] ??
                    '')
                .trim();
        final longitude =
            (careerUri.queryParameters['glon'] ??
                    careerUri.queryParameters['Longitude'] ??
                    '')
                .trim();
        final distance =
            (careerUri.queryParameters['Distance'] ??
                    careerUri.queryParameters['distance'] ??
                    '50')
                .trim();

        for (final query in queryTerms) {
          var totalPages = 1;
          var recordsPerPage = 100;

          for (var page = 1; page <= totalPages && page <= 120; page++) {
            final uri =
                Uri.https('jobs.disneycareers.com', '/search-jobs/results', {
                  'Keywords': query,
                  'Location': '',
                  'Distance': distance.isEmpty ? '50' : distance,
                  'Latitude': latitude,
                  'Longitude': longitude,
                  'ShowRadius': 'False',
                  'CurrentPage': '$page',
                  'RecordsPerPage': '$recordsPerPage',
                  'ActiveFacetID': '0',
                  'CustomFacetName': '',
                  'FacetTerm': '',
                  'FacetType': '0',
                  'SearchResultsModuleName': 'Search Results',
                  'SortCriteria': '0',
                  'SortDirection': '0',
                  'SearchType': '5',
                  'KeywordType': '',
                  'LocationType': '',
                  'LocationPath': '',
                  'OrganizationIds': '',
                  'PostalCode': '',
                  'ResultsType': '0',
                  'TotalContentResults': '0',
                  'IsPagination': 'False',
                });

            final response = await _client
                .get(
                  uri,
                  headers: const {
                    'accept': 'application/json, text/javascript, */*; q=0.01',
                    'x-requested-with': 'XMLHttpRequest',
                    'referer': 'https://jobs.disneycareers.com/search-jobs',
                  },
                )
                .timeout(const Duration(seconds: 15));

            if (response.statusCode >= 400 || response.body.trim().isEmpty) {
              continue;
            }

            final decoded = jsonDecode(response.body);
            if (decoded is! Map) {
              continue;
            }

            final resultsHtml = (decoded['results'] ?? '').toString();
            if (resultsHtml.trim().isEmpty) {
              continue;
            }

            final doc = html_parser.parse(resultsHtml);
            final section = doc.querySelector('section#search-results');
            final totalPagesAttr = section?.attributes['data-total-pages']
                ?.trim();
            final parsedTotalPages = int.tryParse(totalPagesAttr ?? '');
            if (parsedTotalPages != null && parsedTotalPages > 0) {
              totalPages = parsedTotalPages;
            }

            final recordsPerPageAttr = section
                ?.attributes['data-records-per-page']
                ?.trim();
            final parsedRecordsPerPage = int.tryParse(recordsPerPageAttr ?? '');
            if (parsedRecordsPerPage != null && parsedRecordsPerPage > 0) {
              recordsPerPage = parsedRecordsPerPage;
            }

            final entries = _extractTalentBrewEntries(doc, baseUri: careerUri);
            if (entries.isEmpty) {
              continue;
            }

            for (final entry in entries) {
              final title = (entry['title'] ?? '').trim();
              if (title.isEmpty) continue;

              final description = (entry['description'] ?? '').trim();
              final titleLower = title.toLowerCase();
              final descLower = description.toLowerCase();

              if (keywords.isNotEmpty) {
                final exactWordMatch = matchTerms.any((kw) {
                  final pattern = RegExp(
                    '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                  );
                  return pattern.hasMatch(titleLower) ||
                      pattern.hasMatch(descLower);
                });
                if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
                  continue;
                }
              }

              final applyLink = (entry['applyLink'] ?? careerUri.toString())
                  .trim();
              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.contains(key)) continue;
              seen.add(key);

              final location = (entry['location'] ?? '').trim();
              final durationData = parseDuration(description);

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location.isEmpty ? 'Not specified' : location,
                  duration: durationData.$1,
                  deadline: '—',
                  source: 'Disney TalentBrew Results API',
                  error: '',
                ),
              );
            }
          }

          if (rows.length >= 800) {
            break;
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('jobs.comcast.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords.isEmpty ? [''] : keywords;
        final searchPath = careerUri.path.toLowerCase().contains('/search-jobs')
            ? careerUri.path
            : '/search-jobs';

        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        final baseQuery = Map<String, String>.from(careerUri.queryParameters);
        final requestedStartPage = int.tryParse(baseQuery['p'] ?? '') ?? 1;
        final startPage = requestedStartPage < 1 ? 1 : requestedStartPage;

        for (final term in matchTerms) {
          final termQuery = Map<String, String>.from(baseQuery);
          if ((termQuery['k'] ?? '').trim().isEmpty) {
            termQuery['k'] = term;
          }

          final firstQuery = Map<String, String>.from(termQuery)
            ..['p'] = '$startPage';
          final firstPageUri = Uri.https(
            careerUri.host,
            searchPath,
            firstQuery.isEmpty ? null : firstQuery,
          );

          final firstResp = await _client
              .get(
                firstPageUri,
                headers: {
                  'User-Agent':
                      userAgents[DateTime.now().millisecond %
                          userAgents.length],
                  'Accept-Language': 'en-US,en;q=0.9',
                  'Accept':
                      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                  'DNT': '1',
                },
              )
              .timeout(const Duration(seconds: 12));

          if (firstResp.statusCode >= 400 || firstResp.body.trim().isEmpty) {
            continue;
          }

          final firstDoc = html_parser.parse(firstResp.body);
          final searchResultsEl = firstDoc.querySelector('#search-results');

          final pageSize =
              int.tryParse(
                searchResultsEl?.attributes['data-records-per-page'] ?? '',
              ) ??
              int.tryParse(
                RegExp(
                      r'(\d+)\s+of\s+\d+\s+results\s+are\s+now\s+available',
                      caseSensitive: false,
                    ).firstMatch(firstResp.body)?.group(1) ??
                    '',
              );
          final totalResults =
              int.tryParse(
                searchResultsEl?.attributes['data-total-results'] ?? '',
              ) ??
              int.tryParse(
                RegExp(r'([0-9,]+)\s+Results\s+Found', caseSensitive: false)
                        .firstMatch(firstResp.body)
                        ?.group(1)
                        ?.replaceAll(',', '') ??
                    '',
              );

          var discoveredMaxPage =
              int.tryParse(
                searchResultsEl?.attributes['data-total-pages'] ?? '',
              ) ??
              startPage;
          if (discoveredMaxPage == startPage &&
              pageSize != null &&
              pageSize > 0 &&
              totalResults != null) {
            discoveredMaxPage = ((totalResults - 1) ~/ pageSize) + 1;
          }
          final cappedMaxPage = discoveredMaxPage > 300
              ? 300
              : discoveredMaxPage;
          var consecutiveNoHitPages = 0;

          for (var page = startPage; page <= cappedMaxPage; page++) {
            final rowsBeforePage = rows.length;
            final pageQuery = Map<String, String>.from(termQuery)
              ..['p'] = '$page';
            final pageUri = Uri.https(
              careerUri.host,
              searchPath,
              pageQuery.isEmpty ? null : pageQuery,
            );

            final resp = page == startPage
                ? firstResp
                : await _client
                      .get(
                        pageUri,
                        headers: {
                          'User-Agent':
                              userAgents[DateTime.now().millisecond %
                                  userAgents.length],
                          'Accept-Language': 'en-US,en;q=0.9',
                          'Accept':
                              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                          'DNT': '1',
                        },
                      )
                      .timeout(const Duration(seconds: 12));

            if (resp.statusCode >= 400 || resp.body.trim().isEmpty) {
              continue;
            }

            final doc = html_parser.parse(resp.body);
            final anchors = doc.querySelectorAll('a[href*="/job/"]');
            if (anchors.isEmpty && page > startPage) {
              break;
            }

            for (final anchor in anchors) {
              final href = (anchor.attributes['href'] ?? '').trim();
              if (href.isEmpty) continue;

              final resolved = pageUri.resolve(href);
              final segments = resolved.pathSegments
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty)
                  .toList();
              if (segments.length < 4 ||
                  segments.first.toLowerCase() != 'job') {
                continue;
              }

              final title = normalize(anchor.text);
              if (title.isEmpty) continue;

              final container =
                  anchor.parent?.parent?.parent?.parent ??
                  anchor.parent?.parent ??
                  anchor.parent;
              final cardText = normalize(container?.text ?? '');

              final titleLower = title.toLowerCase();
              final textLower = cardText.toLowerCase();
              if (keywords.isNotEmpty) {
                final exactWordMatch = keywords.any((kw) {
                  final pattern = RegExp(
                    '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                  );
                  return pattern.hasMatch(titleLower) ||
                      pattern.hasMatch(textLower);
                });
                if (!exactWordMatch && !fuzzyMatch(titleLower, keywords)) {
                  continue;
                }
              }

              final applyLink = resolved.toString();
              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.contains(key)) continue;
              seen.add(key);

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: 'Not specified',
                  duration: parseDuration(cardText).$1,
                  deadline: '—',
                  source: 'Comcast TalentBrew Search HTML',
                  error: '',
                ),
              );
            }

            if (rows.length == rowsBeforePage) {
              consecutiveNoHitPages++;
            } else {
              consecutiveNoHitPages = 0;
            }

            if (consecutiveNoHitPages >= 20) {
              break;
            }
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('careers.cognizant.com') &&
        careerUri.path.toLowerCase().contains('/jobs')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords.isEmpty ? [''] : keywords;
        final searchPath = careerUri.path.toLowerCase().contains('/jobs')
            ? careerUri.path
            : '/india-en/jobs';

        Future<int> appendFromJinaFallback({
          required String term,
          required Map<String, String> querySeed,
        }) async {
          int totalAdded = 0;
          int page = 1;
          int consecutiveEmptyPages = 0;

          while (page <= 85) {
            try {
              final fallbackQuery = Map<String, String>.from(querySeed)
                ..remove('page')
                ..['page'] = '$page';
              if ((fallbackQuery['keyword'] ?? '').trim().isEmpty) {
                fallbackQuery['keyword'] = term;
              }

              final sourceUri = Uri.https(
                careerUri.host,
                searchPath,
                fallbackQuery.isEmpty ? null : fallbackQuery,
              );

              final sourceUrl = sourceUri.toString();
              final passthroughUrl = sourceUrl.startsWith('https://')
                  ? 'http://${sourceUrl.substring(8)}'
                  : sourceUrl;
              final jinaUri = Uri.parse('https://r.jina.ai/$passthroughUrl');

              final response = await _client
                  .get(
                    jinaUri,
                    headers: {
                      'accept': 'text/plain, text/markdown, */*',
                      'user-agent':
                          userAgents[DateTime.now().millisecond %
                              userAgents.length],
                      'referer': careerUri.toString(),
                    },
                  )
                  .timeout(const Duration(seconds: 20));

              if (response.statusCode >= 400 || response.body.trim().isEmpty) {
                break;
              }

              String normalize(String input) {
                return input.replaceAll(RegExp(r'\s+'), ' ').trim();
              }

              final markdown = response.body;
              final entries = RegExp(
                r'##\s+\[([^\]]+)\]\((https?://[^)]+/india-en/jobs/[^)]+)\)',
                caseSensitive: false,
              ).allMatches(markdown);

              if (entries.isEmpty) {
                consecutiveEmptyPages++;
                if (consecutiveEmptyPages >= 2) {
                  break;
                }
              } else {
                consecutiveEmptyPages = 0;
              }

              var added = 0;
              for (final entry in entries) {
                final title = normalize(entry.group(1) ?? '');
                final applyLink = normalize(entry.group(2) ?? '');
                if (title.isEmpty || applyLink.isEmpty) continue;

                final titleLower = title.toLowerCase();
                if (keywords.isNotEmpty) {
                  final exactWordMatch = keywords.any((kw) {
                    final pattern = RegExp(
                      '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                    );
                    return pattern.hasMatch(titleLower);
                  });
                  if (!exactWordMatch && !fuzzyMatch(titleLower, keywords)) {
                    continue;
                  }
                }

                final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
                if (seen.contains(key)) continue;
                seen.add(key);

                rows.add(
                  ScanResultRow(
                    company: companyName,
                    title: title,
                    companyUrl: sourceUri.toString(),
                    applyLink: applyLink,
                    location: 'Not specified',
                    duration: 'Unknown',
                    deadline: '—',
                    source: 'Cognizant Careers Jina Fallback',
                    error: '',
                  ),
                );
                added++;
              }

              totalAdded += added;
              page++;
            } catch (_) {
              break;
            }
          }

          return totalAdded;
        }

        String normalize(String input) {
          return input.replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        final baseQuery = Map<String, String>.from(careerUri.queryParameters);
        final requestedStartPage = int.tryParse(baseQuery['page'] ?? '') ?? 1;
        final startPage = requestedStartPage < 1 ? 1 : requestedStartPage;

        for (final term in matchTerms) {
          final termQuery = Map<String, String>.from(baseQuery);
          if ((termQuery['keyword'] ?? '').trim().isEmpty) {
            termQuery['keyword'] = term;
          }

          final firstQuery = Map<String, String>.from(termQuery)
            ..['page'] = '$startPage';
          final firstPageUri = Uri.https(
            careerUri.host,
            searchPath,
            firstQuery.isEmpty ? null : firstQuery,
          );

          final firstResp = await _client
              .get(
                firstPageUri,
                headers: {
                  'User-Agent':
                      userAgents[DateTime.now().millisecond %
                          userAgents.length],
                  'Accept-Language': 'en-US,en;q=0.9',
                  'Accept':
                      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                  'DNT': '1',
                },
              )
              .timeout(const Duration(seconds: 15));

          if (firstResp.statusCode >= 400 || firstResp.body.trim().isEmpty) {
            await appendFromJinaFallback(term: term, querySeed: termQuery);
            continue;
          }

          final maxFromLastPageLink = int.tryParse(
            RegExp(
                  r'Last\s+page\s+(\d+)',
                  caseSensitive: false,
                ).firstMatch(firstResp.body)?.group(1) ??
                '',
          );
          final totalResults = int.tryParse(
            RegExp(
                  r'Displaying\s+\d+\s+to\s+\d+\s+of\s+([0-9,]+)\s+matching\s+jobs',
                  caseSensitive: false,
                ).firstMatch(firstResp.body)?.group(1)?.replaceAll(',', '') ??
                '',
          );

          var discoveredMaxPage = maxFromLastPageLink ?? startPage;
          if (totalResults != null &&
              totalResults > 0 &&
              maxFromLastPageLink == null) {
            const defaultPageSize = 10;
            discoveredMaxPage = ((totalResults - 1) ~/ defaultPageSize) + 1;
          }
          final cappedMaxPage = discoveredMaxPage > 500
              ? 500
              : discoveredMaxPage;
          var consecutiveNoHitPages = 0;

          for (var page = startPage; page <= cappedMaxPage; page++) {
            final rowsBeforePage = rows.length;
            final pageQuery = Map<String, String>.from(termQuery)
              ..['page'] = '$page';
            final pageUri = Uri.https(
              careerUri.host,
              searchPath,
              pageQuery.isEmpty ? null : pageQuery,
            );

            final resp = page == startPage
                ? firstResp
                : await _client
                      .get(
                        pageUri,
                        headers: {
                          'User-Agent':
                              userAgents[DateTime.now().millisecond %
                                  userAgents.length],
                          'Accept-Language': 'en-US,en;q=0.9',
                          'Accept':
                              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                          'DNT': '1',
                        },
                      )
                      .timeout(const Duration(seconds: 15));

            if (resp.statusCode >= 400 || resp.body.trim().isEmpty) {
              continue;
            }

            final doc = html_parser.parse(resp.body);
            final anchors = doc.querySelectorAll('a[href*="/india-en/jobs/"]');
            if (anchors.isEmpty && page > startPage) {
              break;
            }

            for (final anchor in anchors) {
              final href = (anchor.attributes['href'] ?? '').trim();
              if (href.isEmpty) continue;

              final resolved = pageUri.resolve(href);
              final segments = resolved.pathSegments
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty)
                  .toList();
              if (segments.length < 4 ||
                  segments[0].toLowerCase() != 'india-en' ||
                  segments[1].toLowerCase() != 'jobs') {
                continue;
              }
              final jobId = segments[2];
              if (!RegExp(r'^\d+$').hasMatch(jobId)) {
                continue;
              }

              final title = normalize(anchor.text);
              if (title.isEmpty) continue;

              final container =
                  anchor.parent?.parent?.parent ??
                  anchor.parent?.parent ??
                  anchor.parent;
              final cardText = normalize(container?.text ?? '');

              final titleLower = title.toLowerCase();
              final textLower = cardText.toLowerCase();
              if (keywords.isNotEmpty) {
                final exactWordMatch = keywords.any((kw) {
                  final pattern = RegExp(
                    '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                  );
                  return pattern.hasMatch(titleLower) ||
                      pattern.hasMatch(textLower);
                });
                if (!exactWordMatch && !fuzzyMatch(titleLower, keywords)) {
                  continue;
                }
              }

              final applyLink = resolved.toString();
              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.contains(key)) continue;
              seen.add(key);

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: 'Not specified',
                  duration: parseDuration(cardText).$1,
                  deadline: '—',
                  source: 'Cognizant Careers HTML',
                  error: '',
                ),
              );
            }

            if (rows.length == rowsBeforePage) {
              consecutiveNoHitPages++;
            } else {
              consecutiveNoHitPages = 0;
            }

            if (consecutiveNoHitPages >= 20) {
              break;
            }
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    // SuccessFactors (SAP) - Kellanova, etc.
    if (host.contains('jobs.') &&
        (host.endsWith('.com') || host.contains('successfactors'))) {
      try {
        final response = await _client
            .get(
              careerUri,
              headers: {
                'User-Agent':
                    userAgents[math.Random().nextInt(userAgents.length)],
              },
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final document = html_parser.parse(response.body);
          final rows = <ScanResultRow>[];

          // SuccessFactors usually uses a table with class 'job-tile' or links starting with /job/
          final jobLinks = document.querySelectorAll('a').where((e) {
            final href = e.attributes['href'] ?? '';
            return href.contains('/job/') && !href.contains('/job-invite/');
          }).toList();

          for (final link in jobLinks) {
            final title = link.text.trim();
            if (title.isEmpty) continue;

            var applyLink = link.attributes['href'] ?? '';
            if (!applyLink.startsWith('http')) {
              applyLink = '${careerUri.scheme}://${careerUri.host}$applyLink';
            }

            // Find location (usually in a sibling or parent div)
            var location = 'Not specified';
            final parent = link.parent;
            if (parent != null) {
              final locElem = parent.querySelector(
                '.location, .jobLocation, .job-location',
              );
              if (locElem != null) {
                location = locElem.text.trim();
              }
            }

            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: careerUri.toString(),
                applyLink: applyLink,
                location: location,
                duration: '—',
                deadline: '—',
                source: 'SuccessFactors Scan',
                error: '',
              ),
            );
          }
          if (rows.isNotEmpty) return rows;
        }
      } catch (_) {}
    }

    // Eightfold.ai (Kraft Heinz, Starbucks, etc.)
    if (host.contains('eightfold.ai') || host.contains('jobs.kraftheinz.com')) {
      try {
        final domain = host.contains('kraftheinz.com')
            ? 'kraftheinz.com'
            : host;
        final apiUrl = Uri.parse('https://$host/api/v1/get_objects');

        final query = keywords.isEmpty ? '' : keywords.join(' ');
        final rows = <ScanResultRow>[];

        final payload = {
          "query": query,
          "start": 0,
          "num": 100,
          "domain": domain,
        };

        final response = await _client
            .post(
              apiUrl,
              headers: {
                'Accept': 'application/json',
                'Content-Type': 'application/json',
                'X-Requested-With': 'XMLHttpRequest',
                'User-Agent':
                    userAgents[math.Random().nextInt(userAgents.length)],
                'Referer': careerUri.toString(),
              },
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final decoded = jsonDecode(response.body);
          final items = decoded['results'] ?? [];
          if (items is List) {
            for (final job in items) {
              final title = (job['title'] ?? '').toString().trim();
              if (title.isEmpty) continue;

              final id = (job['id'] ?? '').toString().trim();
              final location = (job['location'] ?? 'Not specified')
                  .toString()
                  .trim();
              final applyLink =
                  'https://$host/careers/job?domain=$domain&pid=$id';

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location,
                  duration: '—',
                  deadline: '—',
                  source: 'Eightfold API Scan',
                  error: '',
                ),
              );
            }
            if (rows.isNotEmpty) return rows;
          }
        }

        // Fallback to Rendered HTML if API fails or returns no jobs
        final html = await _fetchRendered(careerUri);
        if (html != null && html.isNotEmpty) {
          final document = html_parser.parse(html);
          // Selector based on browser subagent findings
          final cards = document.querySelectorAll(
            'a[id^="job-card-"], a.card-F1ebU',
          );
          for (final card in cards) {
            final titleElem =
                card.querySelector('div:first-child div:first-child') ?? card;
            final title = titleElem.text.trim();
            if (title.isEmpty) continue;

            var href = card.attributes['href'] ?? '';
            if (!href.startsWith('http')) {
              href = 'https://$host$href';
            }

            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: careerUri.toString(),
                applyLink: href,
                location: 'Check site',
                duration: '—',
                deadline: '—',
                source: 'Eightfold DOM Scan',
                error: '',
              ),
            );
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    // Khatabook
    if (host.contains('khatabook.com')) {
      try {
        final html = await _fetchRendered(careerUri);
        if (html != null && html.isNotEmpty) {
          final document = html_parser.parse(html);
          final rows = <ScanResultRow>[];

          // Khatabook cards usually have titles in h3 or h4
          final jobLinks = document.querySelectorAll('a').where((e) {
            final text = e.text.toLowerCase();
            return text.contains('apply') ||
                text.contains('view') ||
                text.contains('opening');
          }).toList();

          for (final link in jobLinks) {
            final titleElem =
                link.parent?.querySelector('h1, h2, h3, h4, h5') ?? link;
            final title = titleElem.text.trim();
            if (title.isEmpty || title.length < 3) continue;

            var href = link.attributes['href'] ?? '';
            if (href.isEmpty) continue;
            if (!href.startsWith('http')) {
              href = 'https://khatabook.com$href';
            }

            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: careerUri.toString(),
                applyLink: href,
                location: 'Remote/Bengaluru',
                duration: '—',
                deadline: '—',
                source: 'Khatabook DOM Scan',
                error: '',
              ),
            );
          }
          if (rows.isNotEmpty) return rows;
        }
      } catch (_) {}
    }

    // KreditBee (Custom Portal)
    if (host.contains('kreditbee.in')) {
      try {
        final html = await _fetchRendered(careerUri);
        if (html != null && html.isNotEmpty) {
          final document = html_parser.parse(html);
          final rows = <ScanResultRow>[];

          // KreditBee uses job cards with "Apply" buttons in a slider
          // Based on DOM inspection, job titles are inside the cards
          final cards = document.querySelectorAll('div').where((e) {
            final text = e.text.toLowerCase();
            return text.contains('open role') && text.contains('apply');
          }).toList();

          for (final card in cards) {
            final titleElem = card.querySelector(
              'h1, h2, h3, h4, h5, div:first-child',
            );
            if (titleElem == null) continue;

            final title = titleElem.text.trim();
            if (title.isEmpty) continue;

            // Link is usually in the Apply button or parent anchor
            final anchor = card.querySelector('a');
            var applyLink = anchor?.attributes['href'] ?? '';
            if (applyLink.isEmpty) {
              // Construct link from title if direct link not found
              final slug = title
                  .toLowerCase()
                  .replaceAll(' ', '-')
                  .replaceAll('"', '');
              applyLink = 'https://www.kreditbee.in/careers/$slug';
            } else if (!applyLink.startsWith('http')) {
              applyLink = 'https://www.kreditbee.in$applyLink';
            }

            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: careerUri.toString(),
                applyLink: applyLink,
                location: 'Check site',
                duration: '—',
                deadline: '—',
                source: 'KreditBee DOM Scan',
                error: '',
              ),
            );
          }
          if (rows.isNotEmpty) return rows;
        }
      } catch (_) {}
    }

    // Leap Finance (Custom Portal)
    if (host.contains('leapfinance.com')) {
      try {
        final html = await _fetchRendered(careerUri);
        if (html != null && html.isNotEmpty) {
          final document = html_parser.parse(html);
          final rows = <ScanResultRow>[];

          // Leap Finance uses job cards with titles and location/type on the right
          final cards = document.querySelectorAll('div').where((e) {
            final text = e.text.toLowerCase();
            // Catch any card that mentions job types (intern, full-time, etc.)
            return text.contains('intern') ||
                text.contains('full time') ||
                text.contains('full-time') ||
                text.contains('contract') ||
                text.contains('permanent');
          }).toList();

          for (final card in cards) {
            // Find the title element (usually the largest text in the card)
            final titleElem = card.querySelector(
              'h1, h2, h3, h4, h5, div:first-child',
            );
            var title = titleElem?.text.trim() ?? '';

            // If title is too short or just says "Bengaluru", try sibling or parent
            if (title.length < 5 || title == 'Bengaluru' || title == 'Remote') {
              final allTexts = card.nodes
                  .map((n) => n.text?.trim() ?? '')
                  .where((s) => s.isNotEmpty)
                  .toList();
              if (allTexts.isNotEmpty) title = allTexts.first;
            }

            if (title.isEmpty || title.length < 3) continue;

            // Link is usually the whole card or a chevron button
            var applyLink = card.attributes['href'] ?? '';
            if (applyLink.isEmpty) {
              final anchor = card.querySelector('a');
              applyLink = anchor?.attributes['href'] ?? '';
            }

            if (applyLink.isEmpty || applyLink == '#') {
              // Fallback: Construct a search link or use base
              applyLink = 'https://careers.leapfinance.com/#openings';
            } else if (!applyLink.startsWith('http')) {
              applyLink = 'https://careers.leapfinance.com$applyLink';
            }

            final locationElem = card.querySelector('div:last-child') ?? card;
            final locationText = locationElem.text.trim();

            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: careerUri.toString(),
                applyLink: applyLink,
                location: locationText.contains(',')
                    ? locationText.split(',').first
                    : 'Bengaluru',
                duration: '—',
                deadline: '—',
                source: 'Leap DOM Scan',
                error: '',
              ),
            );
          }
          if (rows.isNotEmpty) return rows;
        }
      } catch (_) {}
    }

    if ((host.contains('oraclecloud.com') &&
            careerUri.path.toLowerCase().contains(
              '/hcmui/candidateexperience/',
            )) ||
        (host.contains('oracle.com') &&
            careerUri.path.toLowerCase().contains('/sites/jobsearch/'))) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        String? siteNumber;
        String? backendHost;
        final landingHtml = await _fetch(careerUri);
        if (landingHtml != null && landingHtml.isNotEmpty) {
          final siteMatch = RegExp(
            r"siteNumber\s*:\s*'([^']+)'",
            caseSensitive: false,
          ).firstMatch(landingHtml);
          siteNumber = siteMatch?.group(1)?.trim();

          final cloudMatch = RegExp(
            r'https?://([a-zA-Z0-9.-]+\.oraclecloud\.com)',
            caseSensitive: false,
          ).firstMatch(landingHtml);
          backendHost = cloudMatch?.group(1)?.trim();
        }

        final apiHost = backendHost ?? careerUri.host;

        final siteCandidates = <String>{};
        if (siteNumber != null && siteNumber.isNotEmpty) {
          siteCandidates.add(siteNumber);
        }

        final pathSegments = careerUri.pathSegments;
        final sitesIndex = pathSegments.indexWhere(
          (s) => s.toLowerCase() == 'sites',
        );
        final siteUrlName =
            (sitesIndex >= 0 && sitesIndex + 1 < pathSegments.length)
            ? pathSegments[sitesIndex + 1].trim()
            : '';

        if (siteCandidates.isEmpty && siteUrlName.isNotEmpty) {
          final sitesUri = Uri.https(
            apiHost,
            '/hcmRestApi/resources/latest/recruitingCESites',
            {'onlyData': 'true', 'limit': '200', 'offset': '0'},
          );
          final sitesResp = await _client
              .get(
                sitesUri,
                headers: {
                  'user-agent':
                      userAgents[DateTime.now().millisecond %
                          userAgents.length],
                  'accept': 'application/json, text/plain, */*',
                  'referer': careerUri.toString(),
                },
              )
              .timeout(const Duration(seconds: 12));
          if (sitesResp.statusCode < 400 && sitesResp.body.trim().isNotEmpty) {
            final decoded = jsonDecode(sitesResp.body);
            if (decoded is Map && decoded['items'] is List) {
              final items = (decoded['items'] as List).whereType<Map>();
              for (final item in items) {
                final map = item.map((k, v) => MapEntry(k.toString(), v));
                final sn = (map['SiteNumber'] ?? '').toString().trim();
                if (sn.isEmpty) continue;
                final siteName = (map['SiteName'] ?? '').toString().trim();
                final siteCode = (map['SiteCode'] ?? '').toString().trim();
                final siteUrl = (map['SiteURLName'] ?? '').toString().trim();
                if (siteUrlName.isNotEmpty &&
                    (siteUrl.toLowerCase() == siteUrlName.toLowerCase() ||
                        siteName.toLowerCase() == siteUrlName.toLowerCase() ||
                        siteCode.toLowerCase() == siteUrlName.toLowerCase())) {
                  siteCandidates.add(sn);
                }
              }
            }
          }
        }

        if (siteCandidates.isEmpty) {
          if (host.contains('oracle.com')) {
            siteCandidates.add('CX_45001');
          } else {
            return const [];
          }
        }

        for (final sn in siteCandidates) {
          final cleanSn = sn.replaceAll("'", '');
          final firstLimit = 200;
          final firstFinder =
              'findReqs;siteNumber=$cleanSn,limit=$firstLimit,offset=0';
          final firstUri = Uri.https(
            apiHost,
            '/hcmRestApi/resources/latest/recruitingCEJobRequisitions',
            {
              'onlyData': 'true',
              'expand':
                  'requisitionList.workLocation,requisitionList.otherWorkLocations,requisitionList.secondaryLocations,flexFieldsFacet.values,requisitionList.requisitionFlexFields',
              'finder': firstFinder,
            },
          );

          final firstResp = await _client
              .get(
                firstUri,
                headers: {
                  'user-agent':
                      userAgents[DateTime.now().millisecond %
                          userAgents.length],
                  'accept': 'application/json, text/plain, */*',
                  'referer': careerUri.toString(),
                },
              )
              .timeout(const Duration(seconds: 15));

          if (firstResp.statusCode >= 400 || firstResp.body.trim().isEmpty) {
            continue;
          }

          final decoded = jsonDecode(firstResp.body);
          if (decoded is! Map) continue;
          final items = decoded['items'];
          if (items is! List || items.isEmpty) continue;
          final searchContainer = items.first;
          if (searchContainer is! Map) continue;

          final requisitions = searchContainer['requisitionList'];
          if (requisitions is! List) continue;

          void processReqs(List reqList) {
            for (final item in reqList.whereType<Map>()) {
              final map = item.map((k, v) => MapEntry(k.toString(), v));
              String cleanValue(dynamic value) {
                final text = value?.toString().trim() ?? '';
                return text.toLowerCase() == 'null' ? '' : text;
              }

              final title =
                  ((map['Title'] ?? map['JobTitle']) ?? map['RequisitionTitle'])
                      .toString()
                      .trim();
              if (title.isEmpty) continue;

              final desc =
                  (((map['Description'] ?? map['JobDescription']) ??
                              map['ExternalDescription']) ??
                          map['ShortDescriptionStr'])
                      .toString()
                      .trim();
              final location =
                  ((map['PrimaryLocation'] ?? map['Location']) ??
                          map['Locations'])
                      .toString()
                      .trim();

              if (matchTerms.isNotEmpty) {
                final titleLower = title.toLowerCase();
                final descLower = desc.toLowerCase();
                final locLower = location.toLowerCase();
                final exactWordMatch = matchTerms.any((kw) {
                  final pattern = RegExp(
                    '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                  );
                  return pattern.hasMatch(titleLower) ||
                      pattern.hasMatch(descLower) ||
                      pattern.hasMatch(locLower);
                });
                if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
                  continue;
                }
              }

              final id = cleanValue(
                (map['Id'] ?? map['RequisitionNumber']) ?? map['JobId'],
              );
              final rawLink = cleanValue(
                (map['ExternalURL'] ?? map['JobLink']) ?? map['JobDetailURL'],
              );
              final applyLink = rawLink.isNotEmpty
                  ? rawLink
                  : (id.isEmpty
                        ? careerUri.toString()
                        : '${careerUri.scheme}://${careerUri.host}/hcmUI/CandidateExperience/en/sites/$siteUrlName/job/$id');

              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.contains(key)) continue;
              seen.add(key);

              final durationData = parseDuration(desc);
              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location.isEmpty ? 'Not specified' : location,
                  duration: durationData.$1,
                  deadline: '—',
                  source: 'Oracle Candidate Experience API',
                  error: '',
                ),
              );
            }
          }

          processReqs(requisitions);

          final organizationsFacet =
              searchContainer['organizationsFacet'] as List? ?? [];
          var totalJobs = 0;
          if (organizationsFacet.isNotEmpty) {
            totalJobs = organizationsFacet[0]['TotalCount'] as int? ?? 0;
          }

          if (totalJobs == 0) {
            if (requisitions.length < firstLimit) {
              totalJobs = requisitions.length;
            } else {
              totalJobs = 3000;
            }
          }

          final futures = <Future<void>>[];
          final limit = 200;
          for (
            int offset = limit;
            offset < totalJobs + limit;
            offset += limit
          ) {
            final currentOffset = offset;
            futures.add(() async {
              final finder =
                  'findReqs;siteNumber=$cleanSn,limit=$limit,offset=$currentOffset';
              final reqUri = Uri.https(
                apiHost,
                '/hcmRestApi/resources/latest/recruitingCEJobRequisitions',
                {
                  'onlyData': 'true',
                  'expand':
                      'requisitionList.workLocation,requisitionList.otherWorkLocations,requisitionList.secondaryLocations,flexFieldsFacet.values,requisitionList.requisitionFlexFields',
                  'finder': finder,
                },
              );

              try {
                final resp = await _client
                    .get(
                      reqUri,
                      headers: {
                        'user-agent':
                            userAgents[DateTime.now().millisecond %
                                userAgents.length],
                        'accept': 'application/json, text/plain, */*',
                        'referer': careerUri.toString(),
                      },
                    )
                    .timeout(const Duration(seconds: 15));

                if (resp.statusCode == 200) {
                  final pageDecoded = jsonDecode(resp.body);
                  final pageItems = pageDecoded['items'] as List?;
                  if (pageItems != null && pageItems.isNotEmpty) {
                    final pageContainer = pageItems.first;
                    if (pageContainer is Map) {
                      final pageReqs =
                          pageContainer['requisitionList'] as List?;
                      if (pageReqs != null) {
                        processReqs(pageReqs);
                      }
                    }
                  }
                }
              } catch (_) {}
            }());
          }

          await Future.wait(futures);
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('careers.bankofamerica.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final queryTerms = keywords.isEmpty ? [''] : keywords;
        const pageSize = 50;

        Future<void> collectFromQuery(Map<String, String> baseParams) async {
          var start = 0;
          var totalMatches = pageSize;

          while (start < totalMatches && start < 300) {
            final qp = <String, String>{
              ...baseParams,
              'start': '$start',
              'rows': '$pageSize',
            };

            final uri = Uri.https(
              'careers.bankofamerica.com',
              '/services/jobssearchservlet',
              qp,
            );

            final response = await _client
                .get(
                  uri,
                  headers: {
                    'user-agent':
                        userAgents[DateTime.now().millisecond %
                            userAgents.length],
                    'accept': 'application/json, text/plain, */*',
                    'x-requested-with': 'XMLHttpRequest',
                    'referer': careerUri.toString(),
                  },
                )
                .timeout(const Duration(seconds: 12));

            if (response.statusCode >= 400 || response.body.trim().isEmpty) {
              break;
            }

            final decoded = jsonDecode(response.body);
            if (decoded is! Map) {
              break;
            }

            final parsedTotal = int.tryParse(
              (decoded['totalMatches'] ?? '').toString(),
            );
            if (parsedTotal != null && parsedTotal > 0) {
              totalMatches = parsedTotal;
            }

            final jobs = decoded['jobsList'];
            if (jobs is! List || jobs.isEmpty) {
              break;
            }

            for (final item in jobs.whereType<Map>()) {
              final map = item.map((k, v) => MapEntry(k.toString(), v));
              final title = (map['postingTitle'] ?? '').toString().trim();
              if (title.isEmpty) continue;

              final country = (map['country'] ?? '').toString().trim();
              final city = (map['city'] ?? '').toString().trim();
              final state = (map['state'] ?? '').toString().trim();
              final division = (map['division'] ?? '').toString().trim();
              final lob = (map['lob'] ?? '').toString().trim();
              final family = (map['family'] ?? '').toString().trim();
              final locationString = (map['locationString'] ?? '')
                  .toString()
                  .trim();
              final description = [
                division,
                lob,
                family,
                city,
                state,
                country,
                locationString,
              ].where((e) => e.isNotEmpty).join(' | ');

              final rawLink = (map['jcrURL'] ?? '').toString().trim();
              final applyLink = rawLink.isEmpty
                  ? careerUri.toString()
                  : careerUri.resolve(rawLink).toString();
              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.contains(key)) continue;
              seen.add(key);

              final durationData = parseDuration(description);
              final location =
                  (map['location'] ?? '').toString().trim().isNotEmpty
                  ? (map['location'] ?? '').toString().trim()
                  : [
                      city,
                      state,
                      country,
                    ].where((e) => e.isNotEmpty).join(', ').trim();

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location.isEmpty ? 'Not specified' : location,
                  duration: durationData.$1,
                  deadline: '—',
                  source: 'Bank of America Jobs API',
                  error: '',
                ),
              );
            }

            if (jobs.length < pageSize) {
              break;
            }
            start += pageSize;
          }
        }

        for (final query in queryTerms) {
          await collectFromQuery({'search': 'jobsByKeyword', 'term': query});
          if (rows.length >= 300) {
            break;
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('workforcenow.adp.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final cid = (careerUri.queryParameters['cid'] ?? '').trim();
        if (cid.isEmpty) {
          return const [];
        }

        final lang = (careerUri.queryParameters['lang'] ?? 'en_US').trim();
        final apiUri = Uri.https(
          'workforcenow.adp.com',
          '/mascsr/default/careercenter/public/events/staffing/v1/job-requisitions',
          {'cid': cid, 'lang': lang},
        );

        final response = await _client
            .get(
              apiUri,
              headers: {
                'user-agent':
                    userAgents[DateTime.now().millisecond % userAgents.length],
                'accept': 'application/json, text/plain, */*',
                'x-requested-with': 'XMLHttpRequest',
                'referer': careerUri.toString(),
              },
            )
            .timeout(const Duration(seconds: 12));

        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map) {
          return const [];
        }

        final reqs = decoded['jobRequisitions'];
        if (reqs is! List || reqs.isEmpty) {
          return const [];
        }

        for (final item in reqs.whereType<Map>()) {
          final map = item.map((k, v) => MapEntry(k.toString(), v));
          final title = (map['requisitionTitle'] ?? '').toString().trim();
          if (title.isEmpty) continue;

          final workLevel = ((map['workLevelCode'] as Map?)?['shortName'] ?? '')
              .toString();
          final description = workLevel.trim();
          final titleLower = title.toLowerCase();
          final descLower = description.toLowerCase();
          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(titleLower) || pattern.hasMatch(descLower);
          });
          if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
            continue;
          }

          final itemId = (map['itemID'] ?? '').toString().trim();
          final applyLink = itemId.isEmpty
              ? careerUri.toString()
              : Uri.https(
                  'workforcenow.adp.com',
                  '/mascsr/default/careercenter/public/events/staffing/v1/job-requisitions/$itemId',
                  {'cid': cid, 'lang': lang},
                ).toString();
          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          String location = 'Not specified';
          final locations = map['requisitionLocations'];
          if (locations is List && locations.isNotEmpty) {
            final first = locations.first;
            if (first is Map) {
              final firstMap = first.map((k, v) => MapEntry(k.toString(), v));
              final addressMap = (firstMap['address'] as Map?)?.map(
                (k, v) => MapEntry(k.toString(), v),
              );
              final city = (addressMap?['cityName'] ?? '').toString().trim();
              final state =
                  ((addressMap?['countrySubdivisionLevel1']
                              as Map?)?['codeValue'] ??
                          '')
                      .toString()
                      .trim();
              final country =
                  ((firstMap['nameCode'] as Map?)?['shortName'] ?? '')
                      .toString()
                      .trim();
              final parts = [
                city,
                state,
                country,
              ].where((e) => e.isNotEmpty).toList();
              if (parts.isNotEmpty) {
                location = parts.join(', ');
              }
            }
          }

          final durationData = parseDuration(description);
          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location,
              duration: durationData.$1,
              deadline: '—',
              source: 'ADP CareerCenter API',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('awign.com')) {
      try {
        final html = await _fetch(careerUri);
        if (html == null || html.trim().isEmpty) {
          return const [];
        }

        final doc = html_parser.parse(html);
        final cards = doc.querySelectorAll('div[class*="vacancies_job_card"]');
        if (cards.isEmpty) {
          return const [];
        }

        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        for (final card in cards) {
          final title =
              (card.querySelector('div[class*="vacancies_title"]')?.text ?? '')
                  .trim();
          if (title.isEmpty) continue;

          final description = card.text.trim();
          final titleLower = title.toLowerCase();
          final descLower = description.toLowerCase();
          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(titleLower) || pattern.hasMatch(descLower);
          });
          if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
            continue;
          }

          final durationData = parseDuration(description);
          final applyLink = careerUri.toString();
          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: 'Not specified',
              duration: durationData.$1,
              deadline: '—',
              source: 'Awign Careers HTML',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('bain.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final queryTerms = keywords.isEmpty ? [''] : keywords;
        final filters = (careerUri.queryParameters['filters'] ?? '').trim();
        const pageSize = 800; // Large pageSize to get all jobs in one go

        for (final query in queryTerms) {
          final qp = <String, String>{
            'start': '0',
            'results': '$pageSize',
            'searchValue': query,
            'filters': filters,
          };

          final uri = Uri.https(
            'www.bain.com',
            '/en/api/jobsearch/keyword/get',
            qp,
          );

          final response = await _client
              .get(
                uri,
                headers: {
                  'user-agent':
                      userAgents[DateTime.now().millisecond %
                          userAgents.length],
                  'accept': 'application/json, text/plain, */*',
                  'x-requested-with': 'XMLHttpRequest',
                  'referer': careerUri.toString(),
                },
              )
              .timeout(const Duration(seconds: 15));

          if (response.statusCode >= 400 || response.body.trim().isEmpty) {
            continue;
          }

          final decoded = jsonDecode(response.body);
          if (decoded is! Map) {
            continue;
          }

          final results = decoded['results'];
          if (results is! List || results.isEmpty) {
            continue;
          }

          for (final item in results.whereType<Map>()) {
            final map = item.map((k, v) => MapEntry(k.toString(), v));
            final title = (map['JobTitle'] ?? '').toString().trim();
            if (title.isEmpty) continue;

            final descriptionHtml = (map['JobDescription'] ?? '')
                .toString()
                .trim();
            final descriptionDoc = html_parser.parse(descriptionHtml);
            final description =
                descriptionDoc.documentElement?.text.trim() ?? '';

            final titleLower = title.toLowerCase();
            final descLower = description.toLowerCase();

            if (keywords.isNotEmpty) {
              final exactWordMatch = matchTerms.any((kw) {
                final pattern = RegExp(
                  '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                );
                return pattern.hasMatch(titleLower) ||
                    pattern.hasMatch(descLower);
              });
              if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
                continue;
              }
            }

            final rawLink = (map['Link'] ?? '').toString().trim();
            final applyLink = rawLink.isEmpty
                ? careerUri.toString()
                : careerUri.resolve(rawLink).toString();
            final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
            if (seen.contains(key)) continue;
            seen.add(key);

            final locationValue = map['Location'];
            String location = 'Not specified';
            if (locationValue is List) {
              final normalized = locationValue
                  .map((e) => e.toString().trim())
                  .where((e) => e.isNotEmpty)
                  .toSet()
                  .toList();
              if (normalized.isNotEmpty) {
                location = normalized.take(3).join(', ');
              }
            } else {
              final text = locationValue?.toString().trim() ?? '';
              if (text.isNotEmpty) {
                location = text;
              }
            }

            final durationData = parseDuration(description);

            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: careerUri.toString(),
                applyLink: applyLink,
                location: location,
                duration: durationData.$1,
                deadline: '—',
                source: 'Bain Job Search API',
                error: '',
              ),
            );
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('att.jobs')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final queryTerms = keywords.isEmpty ? [''] : keywords;

        for (final query in queryTerms) {
          var totalPages = 162;
          var recordsPerPage = 100;

          for (var page = 1; page <= totalPages && page <= 60; page++) {
            try {
              final uri = Uri.https('www.att.jobs', '/search-jobs/results', {
                'Keywords': query,
                'Location': '',
                'Distance': '50',
                'Latitude': '',
                'Longitude': '',
                'ShowRadius': 'False',
                'CurrentPage': '$page',
                'RecordsPerPage': '$recordsPerPage',
                'ActiveFacetID': '0',
                'CustomFacetName': '',
                'FacetTerm': '',
                'FacetType': '0',
                'SearchResultsModuleName': 'Search Results',
                'SortCriteria': '0',
                'SortDirection': '0',
                'SearchType': '5',
                'KeywordType': '',
                'LocationType': '',
                'LocationPath': '',
                'OrganizationIds': '',
                'PostalCode': '',
                'ResultsType': '0',
                'TotalContentResults': '0',
                'IsPagination': 'False',
              });

              final response = await _client
                  .get(
                    uri,
                    headers: const {
                      'accept':
                          'application/json, text/javascript, */*; q=0.01',
                      'x-requested-with': 'XMLHttpRequest',
                      'referer': 'https://www.att.jobs/search-jobs',
                    },
                  )
                  .timeout(const Duration(seconds: 12));

              if (response.statusCode >= 400 || response.body.trim().isEmpty) {
                continue;
              }

              final decoded = jsonDecode(response.body);
              if (decoded is! Map) {
                continue;
              }

              final resultsHtml = (decoded['results'] ?? '').toString();
              if (resultsHtml.trim().isEmpty) {
                continue;
              }

              final doc = html_parser.parse(resultsHtml);
              final section = doc.querySelector('section#search-results');
              final totalPagesAttr = section?.attributes['data-total-pages']
                  ?.trim();
              final parsedTotalPages = int.tryParse(totalPagesAttr ?? '');
              if (parsedTotalPages != null && parsedTotalPages > 0) {
                totalPages = parsedTotalPages;
              }

              final recordsPerPageAttr = section
                  ?.attributes['data-records-per-page']
                  ?.trim();
              final parsedRecordsPerPage = int.tryParse(
                recordsPerPageAttr ?? '',
              );
              if (parsedRecordsPerPage != null && parsedRecordsPerPage > 0) {
                recordsPerPage = parsedRecordsPerPage;
              }

              final entries = _extractTalentBrewEntries(
                doc,
                baseUri: careerUri,
              );
              if (entries.isEmpty) {
                continue;
              }

              for (final entry in entries) {
                final title = (entry['title'] ?? '').trim();
                if (title.isEmpty) continue;

                final description = (entry['description'] ?? '').trim();
                final titleLower = title.toLowerCase();
                final descLower = description.toLowerCase();

                if (keywords.isNotEmpty) {
                  final exactWordMatch = matchTerms.any((kw) {
                    final pattern = RegExp(
                      '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                    );
                    return pattern.hasMatch(titleLower) ||
                        pattern.hasMatch(descLower);
                  });
                  if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
                    continue;
                  }
                }

                final durationData = parseDuration(description);

                final applyLink = (entry['applyLink'] ?? careerUri.toString())
                    .trim();
                final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
                if (seen.contains(key)) continue;
                seen.add(key);

                final location = (entry['location'] ?? '').trim();

                rows.add(
                  ScanResultRow(
                    company: companyName,
                    title: title,
                    companyUrl: careerUri.toString(),
                    applyLink: applyLink,
                    location: location.isEmpty ? 'Not specified' : location,
                    duration: durationData.$1,
                    deadline: '—',
                    source: 'ATT TalentBrew Results API',
                    error: '',
                  ),
                );
              }
            } catch (_) {
              continue;
            }
          }

          if (rows.length >= 800) {
            break;
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('careers.astrazeneca.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final queryTerms = keywords.isEmpty ? [''] : keywords;

        for (final query in queryTerms) {
          var totalPages = 75;
          var recordsPerPage = 100;

          for (var page = 1; page <= totalPages && page <= 60; page++) {
            final uri =
                Uri.https('careers.astrazeneca.com', '/search-jobs/results', {
                  'Keywords': query,
                  'Location': '',
                  'Distance': '50',
                  'Latitude': '',
                  'Longitude': '',
                  'ShowRadius': 'False',
                  'CurrentPage': '$page',
                  'RecordsPerPage': '$recordsPerPage',
                  'ActiveFacetID': '0',
                  'CustomFacetName': '',
                  'FacetTerm': '',
                  'FacetType': '0',
                  'SearchResultsModuleName': 'Search Results',
                  'SortCriteria': '0',
                  'SortDirection': '0',
                  'SearchType': '5',
                  'KeywordType': '',
                  'LocationType': '',
                  'LocationPath': '',
                  'OrganizationIds': '',
                  'PostalCode': '',
                  'ResultsType': '0',
                  'TotalContentResults': '0',
                  'IsPagination': 'False',
                });

            final response = await _client
                .get(
                  uri,
                  headers: const {
                    'accept': 'application/json, text/javascript, */*; q=0.01',
                    'x-requested-with': 'XMLHttpRequest',
                    'referer': 'https://careers.astrazeneca.com/search-jobs',
                  },
                )
                .timeout(const Duration(seconds: 12));

            if (response.statusCode >= 400 || response.body.trim().isEmpty) {
              continue;
            }

            final decoded = jsonDecode(response.body);
            if (decoded is! Map) {
              continue;
            }

            final resultsHtml = (decoded['results'] ?? '').toString();
            if (resultsHtml.trim().isEmpty) {
              continue;
            }

            final doc = html_parser.parse(resultsHtml);
            final section = doc.querySelector('section#search-results');
            final totalPagesAttr = section?.attributes['data-total-pages']
                ?.trim();
            final parsedTotalPages = int.tryParse(totalPagesAttr ?? '');
            if (parsedTotalPages != null && parsedTotalPages > 0) {
              totalPages = parsedTotalPages;
            }

            final recordsPerPageAttr = section
                ?.attributes['data-records-per-page']
                ?.trim();
            final parsedRecordsPerPage = int.tryParse(recordsPerPageAttr ?? '');
            if (parsedRecordsPerPage != null && parsedRecordsPerPage > 0) {
              recordsPerPage = parsedRecordsPerPage;
            }

            final entries = _extractTalentBrewEntries(doc, baseUri: careerUri);
            if (entries.isEmpty) {
              continue;
            }

            for (final entry in entries) {
              final title = (entry['title'] ?? '').trim();
              if (title.isEmpty) continue;

              final description = (entry['description'] ?? '').trim();
              final titleLower = title.toLowerCase();
              final descLower = description.toLowerCase();

              if (keywords.isNotEmpty) {
                final exactWordMatch = matchTerms.any((kw) {
                  final pattern = RegExp(
                    '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                  );
                  return pattern.hasMatch(titleLower) ||
                      pattern.hasMatch(descLower);
                });
                if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
                  continue;
                }
              }

              final durationData = parseDuration(description);

              final applyLink = (entry['applyLink'] ?? careerUri.toString())
                  .trim();
              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.contains(key)) continue;
              seen.add(key);

              final location = (entry['location'] ?? '').trim();

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location.isEmpty ? 'Not specified' : location,
                  duration: durationData.$1,
                  deadline: '—',
                  source: 'AstraZeneca TalentBrew Results API',
                  error: '',
                ),
              );
            }
          }

          if (rows.length >= 800) {
            break;
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('careers.blackrock.com') ||
        host.contains('blackrock.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final queryTerms = keywords.isEmpty ? [''] : keywords;

        for (final query in queryTerms) {
          var totalPages = 1;

          for (var page = 1; page <= totalPages; page++) {
            final uri =
                Uri.https('careers.blackrock.com', '/search-jobs/results', {
                  'Keywords': query,
                  'Location': '',
                  'Distance': '50',
                  'Latitude': '',
                  'Longitude': '',
                  'ShowRadius': 'False',
                  'CurrentPage': '$page',
                  'RecordsPerPage': '100',
                  'ActiveFacetID': '0',
                  'CustomFacetName': '',
                  'FacetTerm': '',
                  'FacetType': '0',
                  'SearchResultsModuleName': 'Section 3 - Search Results',
                  'SortCriteria': '0',
                  'SortDirection': '0',
                  'SearchType': '5',
                  'KeywordType': '',
                  'LocationType': '',
                  'LocationPath': '',
                  'OrganizationIds': '',
                  'PostalCode': '',
                  'ResultsType': '0',
                  'TotalContentResults': '0',
                  'IsPagination': 'False',
                });

            final response = await _client
                .get(
                  uri,
                  headers: const {
                    'accept': 'application/json, text/javascript, */*; q=0.01',
                    'x-requested-with': 'XMLHttpRequest',
                    'referer': 'https://careers.blackrock.com/search-jobs',
                  },
                )
                .timeout(const Duration(seconds: 12));

            if (response.statusCode >= 400 || response.body.trim().isEmpty) {
              continue;
            }

            final decoded = jsonDecode(response.body);
            if (decoded is! Map) {
              continue;
            }

            final resultsHtml = (decoded['results'] ?? '').toString();
            if (resultsHtml.trim().isEmpty) {
              continue;
            }

            final doc = html_parser.parse(resultsHtml);
            final section = doc.querySelector('section#search-results');
            final totalPagesAttr = section?.attributes['data-total-pages']
                ?.trim();
            final parsedTotalPages = int.tryParse(totalPagesAttr ?? '');
            if (parsedTotalPages != null && parsedTotalPages > 0) {
              totalPages = parsedTotalPages;
            }

            final entries = _extractTalentBrewEntries(doc, baseUri: careerUri);
            if (entries.isEmpty) {
              continue;
            }

            for (final entry in entries) {
              final title = (entry['title'] ?? '').trim();
              if (title.isEmpty) continue;

              final description = (entry['description'] ?? '').trim();
              final titleLower = title.toLowerCase();
              final descLower = description.toLowerCase();

              if (keywords.isNotEmpty) {
                final exactWordMatch = matchTerms.any((kw) {
                  final pattern = RegExp(
                    '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                  );
                  return pattern.hasMatch(titleLower) ||
                      pattern.hasMatch(descLower);
                });
                if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
                  continue;
                }
              }

              final applyLink = (entry['applyLink'] ?? careerUri.toString())
                  .trim();
              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.contains(key)) continue;
              seen.add(key);

              final location = (entry['location'] ?? '').trim();
              final durationData = parseDuration(description);

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location.isEmpty ? 'Not specified' : location,
                  duration: durationData.$1,
                  deadline: '—',
                  source: 'BlackRock TalentBrew Results API',
                  error: '',
                ),
              );
            }
          }

          if (rows.length >= 800) {
            break;
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('artivatic.ai')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        final manifestResp = await _client
            .get(
              Uri.parse('https://artivatic.ai/asset-manifest.json'),
              headers: const {'accept': 'application/json, text/plain, */*'},
            )
            .timeout(const Duration(seconds: 12));

        if (manifestResp.statusCode >= 400 ||
            manifestResp.body.trim().isEmpty) {
          return const [];
        }

        final manifest = jsonDecode(manifestResp.body);
        if (manifest is! Map) {
          return const [];
        }

        final files = manifest['files'];
        if (files is! Map) {
          return const [];
        }

        String? chunkPath;
        for (final entry in files.entries) {
          final key = entry.key.toString();
          final value = entry.value?.toString() ?? '';
          if (key.startsWith('static/js/118.') &&
              key.endsWith('.chunk.js') &&
              value.isNotEmpty) {
            chunkPath = value;
            break;
          }
        }

        if (chunkPath == null || chunkPath.isEmpty) {
          return const [];
        }

        final chunkUri = Uri.parse('https://artivatic.ai').resolve(chunkPath);
        final chunkResp = await _client
            .get(
              chunkUri,
              headers: const {
                'accept':
                    'text/javascript, application/javascript, application/ecmascript, */*;q=0.1',
              },
            )
            .timeout(const Duration(seconds: 12));

        if (chunkResp.statusCode >= 400 || chunkResp.body.trim().isEmpty) {
          return const [];
        }

        final script = chunkResp.body;
        final cardMatches = RegExp(
          r'jobid:"([^"]+)"\s*,\s*date:"([^"]*)"\s*,\s*head:"([^"]+)"\s*,\s*description:"([^"]*)"',
          dotAll: true,
        ).allMatches(script);

        for (final m in cardMatches) {
          final jobId = (m.group(1) ?? '').trim();
          final date = (m.group(2) ?? '').trim();
          final title = (m.group(3) ?? '').trim();
          final description = (m.group(4) ?? '').trim();

          if (title.isEmpty) continue;

          final titleLower = title.toLowerCase();
          final descLower = description.toLowerCase();
          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(titleLower) || pattern.hasMatch(descLower);
          });
          if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
            continue;
          }

          final durationData = parseDuration(description);

          final applyLink = jobId.isEmpty
              ? careerUri.toString()
              : Uri.https('artivatic.ai', '/job-details/$jobId').toString();
          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: 'Not specified',
              duration: durationData.$1,
              deadline: date.isEmpty ? '—' : date,
              source: 'Artivatic Career Chunk',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('jobs.apple.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final baseSearchUri = _buildAppleSearchUri(careerUri);
        final locale = baseSearchUri.pathSegments.isNotEmpty
            ? baseSearchUri.pathSegments.first
            : 'en-us';

        for (var page = 1; page <= 120; page++) {
          final searchUri = _withPage(baseSearchUri, page);
          final html = await _fetch(searchUri);
          if (html == null || html.trim().isEmpty) {
            continue;
          }

          final stateJson = _extractAppleInitialStateJson(html);
          if (stateJson == null || stateJson.trim().isEmpty) {
            continue;
          }

          final decoded = jsonDecode(stateJson);
          final jobs = _extractAppleJobs(decoded);
          if (jobs.isEmpty) {
            continue;
          }

          for (final map in jobs) {
            final title = (map['postingTitle'] ?? '').toString().trim();
            final description = (map['jobSummary'] ?? '').toString().trim();
            if (title.isEmpty) continue;

            final titleLower = title.toLowerCase();
            final descLower = description.toLowerCase();
            final exactWordMatch = matchTerms.any((kw) {
              final pattern = RegExp(
                '\\b${RegExp.escape(kw.toLowerCase())}\\b',
              );
              return pattern.hasMatch(titleLower) ||
                  pattern.hasMatch(descLower);
            });
            if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
              continue;
            }

            final durationData = parseDuration(description);

            String location = 'Not specified';
            final locations = map['locations'];
            if (locations is List && locations.isNotEmpty) {
              final names = locations
                  .whereType<Map>()
                  .map((e) => (e['name'] ?? '').toString().trim())
                  .where((v) => v.isNotEmpty)
                  .toList();
              if (names.isNotEmpty) {
                location = names.join(', ');
              }
            }

            final positionId = (map['positionId'] ?? '').toString().trim();
            final slug = (map['transformedPostingTitle'] ?? '')
                .toString()
                .trim();
            final applyLink = positionId.isNotEmpty && slug.isNotEmpty
                ? Uri.https(
                    'jobs.apple.com',
                    '/$locale/details/$positionId/$slug',
                  ).toString()
                : searchUri.toString();

            final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
            if (seen.contains(key)) continue;
            seen.add(key);

            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: searchUri.toString(),
                applyLink: applyLink,
                location: location,
                duration: durationData.$1,
                deadline: '—',
                source: 'Apple Search State',
                error: '',
              ),
            );
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('jobs.aon.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final queryTerms = keywords.isEmpty ? [''] : keywords;
        final locationFilter = (careerUri.queryParameters['location'] ?? '')
            .toString()
            .trim();
        final sortBy = (careerUri.queryParameters['sortBy'] ?? 'relevance')
            .toString();
        final regionCode = (careerUri.queryParameters['regionCode'] ?? '')
            .toString()
            .trim();
        const pageSize = 100;

        for (final query in queryTerms) {
          var currentPage = 1;
          var totalPages = 1;

          while (currentPage <= totalPages && rows.length < 800) {
            final qp = <String, String>{
              'keywords': query,
              'sortBy': sortBy,
              'page': '$currentPage',
              'limit': '$pageSize',
            };
            if (locationFilter.isNotEmpty) {
              qp['location'] = locationFilter;
            }
            if (regionCode.isNotEmpty) {
              qp['regionCode'] = regionCode;
            }

            final uri = Uri.https('jobs.aon.com', '/api/jobs', qp);
            final response = await _client
                .get(
                  uri,
                  headers: const {
                    'accept': 'application/json, text/plain, */*',
                    'user-agent':
                        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                  },
                )
                .timeout(const Duration(seconds: 12));

            if (response.statusCode >= 400 || response.body.trim().isEmpty) {
              break;
            }

            final decoded = jsonDecode(response.body);
            if (decoded is! Map || decoded['jobs'] is! List) {
              break;
            }

            final totalCount = int.tryParse(
              (decoded['totalCount'] ?? '').toString(),
            );
            if (totalCount != null && totalCount > 0) {
              totalPages = (totalCount + pageSize - 1) ~/ pageSize;
            }

            final jobs = (decoded['jobs'] as List).whereType<Map>();
            if (jobs.isEmpty) {
              break;
            }

            for (final item in jobs) {
              final data = item['data'];
              if (data is! Map) continue;
              final map = data.map((k, v) => MapEntry(k.toString(), v));

              final title = (map['title'] ?? '').toString().trim();
              final description = (map['description'] ?? '').toString().trim();
              if (title.isEmpty) continue;

              final titleLower = title.toLowerCase();
              final descLower = description.toLowerCase();

              if (keywords.isNotEmpty) {
                final exactWordMatch = matchTerms.any((kw) {
                  final pattern = RegExp(
                    '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                  );
                  return pattern.hasMatch(titleLower) ||
                      pattern.hasMatch(descLower);
                });
                if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
                  continue;
                }
              }

              final durationData = parseDuration(description);

              final applyLink =
                  (map['apply_url'] ?? map['url'] ?? careerUri.toString())
                      .toString()
                      .trim();
              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.contains(key)) continue;
              seen.add(key);

              String location = (map['location_name'] ?? '').toString().trim();
              final locations = map['locations'];
              if (locations is List && locations.isNotEmpty) {
                final names = locations
                    .whereType<Map>()
                    .map((e) => (e['name'] ?? '').toString().trim())
                    .where((v) => v.isNotEmpty)
                    .toList();
                if (names.isNotEmpty) {
                  location = names.join(', ');
                }
              }

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink.isEmpty
                      ? careerUri.toString()
                      : applyLink,
                  location: location.isEmpty ? 'Not specified' : location,
                  duration: durationData.$1,
                  deadline: '—',
                  source: 'Aon Jobs API',
                  error: '',
                ),
              );
            }

            currentPage++;
          }

          if (rows.length >= 800) {
            break;
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('jobs.ashbyhq.com') || host.contains('ashbyhq.com')) {
      try {
        final segments = careerUri.pathSegments
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        if (segments.isEmpty) {
          return const [];
        }

        final board = segments.first;

        // Dedicated Kraken logic if needed, otherwise use general Ashby fetch
        if (board == 'kraken.com' ||
            companyName.toLowerCase().contains('kraken')) {
          return await _fetchAshbyRows(
            board: 'kraken.com',
            companyName: 'Kraken',
            careerUri: careerUri,
            keywords: keywords,
          );
        }

        return await _fetchAshbyRows(
          board: board,
          companyName: companyName,
          careerUri: careerUri,
          keywords: keywords,
        );
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('jobs.lever.co') ||
        host.contains('careers.coupa.com') ||
        host.contains('careers.cred.club') ||
        host.contains('limitbreak.com')) {
      try {
        late final String board;
        if (host.contains('careers.coupa.com')) {
          board = 'coupa';
        } else if (host.contains('careers.cred.club')) {
          board = 'cred';
        } else if (host.contains('limitbreak.com')) {
          board = 'limitbreak';
        } else {
          final segments = careerUri.pathSegments
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
          if (segments.isEmpty) {
            return const [];
          }
          board = segments.first;
        }

        final uri = Uri.https('api.lever.co', '/v0/postings/$board', {
          'mode': 'json',
        });

        final response = await _client
            .get(
              uri,
              headers: const {'accept': 'application/json, text/plain, */*'},
            )
            .timeout(const Duration(seconds: 12));

        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! List) {
          return const [];
        }

        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        for (final item in decoded.whereType<Map>()) {
          final map = item.map((k, v) => MapEntry(k.toString(), v));

          final title = (map['text'] ?? '').toString().trim();
          final description =
              (map['descriptionPlain'] ?? map['description'] ?? '')
                  .toString()
                  .trim();
          if (title.isEmpty) continue;

          final categories = map['categories'];
          String categoriesText = '';
          if (categories is Map) {
            final parts = categories.values
                .map((v) => (v ?? '').toString().trim())
                .where((v) => v.isNotEmpty)
                .toList();
            categoriesText = parts.join(' | ');
          }

          final searchable = [
            title,
            description,
            categoriesText,
          ].where((p) => p.trim().isNotEmpty).join(' | ').toLowerCase();

          bool hasKeywordVariant(String kw) {
            final k = kw.toLowerCase().trim();
            if (k.isEmpty || k.length < 3) return false;
            if (searchable.contains(k)) return true;
            if (k.endsWith('y') && k.length > 1) {
              final stem = k.substring(0, k.length - 1);
              if (searchable.contains('${stem}ies')) return true;
            }
            if (k.endsWith('e') && k.length > 1) {
              final stem = k.substring(0, k.length - 1);
              if (searchable.contains('${k}d') ||
                  searchable.contains('${stem}ing')) {
                return true;
              }
            }
            return searchable.contains('${k}s') ||
                searchable.contains('${k}es') ||
                searchable.contains('${k}ing') ||
                searchable.contains('${k}ed');
          }

          final titleLower = title.toLowerCase();
          final exactWordMatch = matchTerms.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(searchable);
          });
          final variantMatch = matchTerms.any(hasKeywordVariant);
          if (!exactWordMatch &&
              !variantMatch &&
              !fuzzyMatch(titleLower, matchTerms) &&
              !fuzzyMatch(searchable, matchTerms)) {
            continue;
          }

          final durationData = parseDuration(description);

          final applyLink = (map['hostedUrl'] ?? careerUri.toString())
              .toString()
              .trim();
          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          String location = 'Not specified';
          if (categories is Map) {
            final loc = (categories['location'] ?? '').toString().trim();
            if (loc.isNotEmpty) {
              location = loc;
            }
          }

          final exp = parseExperience(description);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink.isEmpty ? careerUri.toString() : applyLink,
              location: location,
              duration: durationData.$1,
              deadline: '—',
              source: 'Lever Postings API',
              error: '',
              experience: exp,
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('careers.amgen.com') || host.contains('amgen.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final queryTerms = keywords.isEmpty ? [''] : keywords;

        for (final query in queryTerms) {
          var totalPages = 1;
          var recordsPerPage = 100;

          for (var page = 1; page <= totalPages && page <= 60; page++) {
            final uri =
                Uri.https('careers.amgen.com', '/en/search-jobs/results', {
                  'Keywords': query,
                  'Location': '',
                  'Distance': '50',
                  'Latitude': '',
                  'Longitude': '',
                  'ShowRadius': 'False',
                  'CurrentPage': '$page',
                  'RecordsPerPage': '$recordsPerPage',
                  'ActiveFacetID': '0',
                  'CustomFacetName': '',
                  'FacetTerm': '',
                  'FacetType': '0',
                  'SearchResultsModuleName': 'Search Results v2 - Module',
                  'SortCriteria': '0',
                  'SortDirection': '0',
                  'SearchType': '5',
                  'KeywordType': '',
                  'LocationType': '',
                  'LocationPath': '',
                  'OrganizationIds': '87',
                  'PostalCode': '',
                  'ResultsType': '0',
                  'TotalContentResults': '0',
                  'IsPagination': 'False',
                });

            final response = await _client
                .get(
                  uri,
                  headers: const {
                    'accept': 'application/json, text/javascript, */*; q=0.01',
                    'x-requested-with': 'XMLHttpRequest',
                    'referer': 'https://careers.amgen.com/en/search-jobs',
                  },
                )
                .timeout(const Duration(seconds: 12));

            if (response.statusCode >= 400 || response.body.trim().isEmpty) {
              continue;
            }

            final decoded = jsonDecode(response.body);
            if (decoded is! Map) {
              continue;
            }

            final resultsHtml = (decoded['results'] ?? '').toString();
            if (resultsHtml.trim().isEmpty) {
              continue;
            }

            final doc = html_parser.parse(resultsHtml);
            final section = doc.querySelector('section#search-results');
            final totalPagesAttr = section?.attributes['data-total-pages']
                ?.trim();
            final parsedTotalPages = int.tryParse(totalPagesAttr ?? '');
            if (parsedTotalPages != null && parsedTotalPages > 0) {
              totalPages = parsedTotalPages;
            }

            final recordsPerPageAttr = section
                ?.attributes['data-records-per-page']
                ?.trim();
            final parsedRecordsPerPage = int.tryParse(recordsPerPageAttr ?? '');
            if (parsedRecordsPerPage != null && parsedRecordsPerPage > 0) {
              recordsPerPage = parsedRecordsPerPage;
            }

            final cards = doc.querySelectorAll(
              'ul#search-results-jobs li > a[href]',
            );

            for (final card in cards) {
              final title =
                  card.querySelector('h3')?.text.trim() ?? card.text.trim();
              if (title.isEmpty) continue;

              final description = card.text.trim();
              final titleLower = title.toLowerCase();
              final descLower = description.toLowerCase();

              if (keywords.isNotEmpty) {
                final exactWordMatch = matchTerms.any((kw) {
                  final pattern = RegExp(
                    '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                  );
                  return pattern.hasMatch(titleLower) ||
                      pattern.hasMatch(descLower);
                });
                if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
                  continue;
                }
              }

              final durationData = parseDuration(description);

              final href = card.attributes['href'] ?? '';
              final applyLink = href.isEmpty
                  ? careerUri.toString()
                  : Uri.https('careers.amgen.com', href).toString();

              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.contains(key)) continue;
              seen.add(key);

              final location =
                  card.querySelector('.job-location')?.text.trim() ?? '';

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location.isEmpty ? 'Not specified' : location,
                  duration: durationData.$1,
                  deadline: '—',
                  source: 'Amgen TalentBrew API',
                  error: '',
                ),
              );
            }
          }

          if (rows.length >= 800) {
            break;
          }
        }
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('globalcareers.lge.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;

        var page = 1;
        var totalPages = 1;
        const size = 100;

        while (page <= totalPages && page <= 20) {
          final uri = Uri.parse(
            'https://globalcareers.lge.com/api/job/v1/jobs/?page=$page&size=$size',
          );
          final response = await _client
              .get(
                uri,
                headers: const {
                  'Accept': 'application/json',
                  'User-Agent':
                      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
                },
              )
              .timeout(const Duration(seconds: 15));

          if (response.statusCode >= 400 || response.body.trim().isEmpty) {
            break;
          }

          final decoded = jsonDecode(response.body);
          if (decoded is! Map || decoded['successOrNot'] != 'Y') {
            break;
          }

          final data = decoded['data'];
          if (data is! Map) {
            break;
          }

          final list = data['list'] as List? ?? [];
          if (list.isEmpty) {
            break;
          }

          final total = data['total'] ?? 0;
          totalPages = (total / size).ceil();

          for (final item in list.whereType<Map>()) {
            final id = item['id']?.toString() ?? '';
            final title = (item['title'] ?? '').toString().trim();
            if (title.isEmpty || id.isEmpty) continue;

            final descriptionHtml = (item['content'] ?? '').toString();
            final doc = html_parser.parse(descriptionHtml);
            final description = doc.body?.text.trim() ?? '';

            final titleLower = title.toLowerCase();
            final descLower = description.toLowerCase();

            if (keywords.isNotEmpty) {
              final exactWordMatch = matchTerms.any((kw) {
                final pattern = RegExp(
                  '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                );
                return pattern.hasMatch(titleLower) ||
                    pattern.hasMatch(descLower);
              });
              if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
                continue;
              }
            }

            final applyLink = 'https://globalcareers.lge.com/jobs/$id';
            final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
            if (seen.contains(key)) continue;
            seen.add(key);

            // Format location as "location, country (corp)" if available
            final locationVal = (item['location'] ?? '').toString().trim();
            final countryVal = (item['cntryNm'] ?? '').toString().trim();
            final corpVal = (item['corpNm'] ?? item['corpCd'] ?? '')
                .toString()
                .trim();

            final locParts = <String>[];
            if (locationVal.isNotEmpty) locParts.add(locationVal);
            if (countryVal.isNotEmpty) locParts.add(countryVal);
            var locationStr = locParts.join(', ');
            if (locationStr.isEmpty) locationStr = 'Not specified';
            if (corpVal.isNotEmpty) {
              locationStr = '$locationStr ($corpVal)';
            }

            final durationData = parseDuration(description);

            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: careerUri.toString(),
                applyLink: applyLink,
                location: locationStr,
                duration: durationData.$1,
                deadline: '—',
                source: 'LG Careers API',
                error: '',
              ),
            );
          }

          page++;
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('search.jobs.barclays')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final matchTerms = keywords;
        final queryTerms = keywords.isEmpty ? [''] : keywords;

        for (final query in queryTerms) {
          var totalPages = 1;
          var recordsPerPage = 100;

          for (var page = 1; page <= totalPages && page <= 120; page++) {
            final uri =
                Uri.https('search.jobs.barclays', '/search-jobs/results', {
                  'Keywords': query,
                  'Location': '',
                  'Distance': '50',
                  'Latitude': '',
                  'Longitude': '',
                  'ShowRadius': 'False',
                  'CurrentPage': '$page',
                  'RecordsPerPage': '$recordsPerPage',
                  'ActiveFacetID': '0',
                  'CustomFacetName': '',
                  'FacetTerm': '',
                  'FacetType': '0',
                  'SearchResultsModuleName': 'Search Results',
                  'SortCriteria': '0',
                  'SortDirection': '0',
                  'SearchType': '5',
                  'KeywordType': '',
                  'LocationType': '',
                  'LocationPath': '',
                  'OrganizationIds': '13015',
                  'PostalCode': '',
                  'ResultsType': '0',
                  'TotalContentResults': '0',
                  'IsPagination': 'False',
                });

            final response = await _client
                .get(
                  uri,
                  headers: const {
                    'accept': 'application/json, text/javascript, */*; q=0.01',
                    'x-requested-with': 'XMLHttpRequest',
                    'referer': 'https://search.jobs.barclays/search-jobs',
                  },
                )
                .timeout(const Duration(seconds: 12));

            if (response.statusCode >= 400 || response.body.trim().isEmpty) {
              continue;
            }

            final decoded = jsonDecode(response.body);
            if (decoded is! Map) {
              continue;
            }

            final resultsHtml = (decoded['results'] ?? '').toString();
            if (resultsHtml.trim().isEmpty) {
              continue;
            }

            final doc = html_parser.parse(resultsHtml);
            final section = doc.querySelector('#search-results');
            final totalPagesAttr = section?.attributes['data-total-pages']
                ?.trim();
            final parsedTotalPages = int.tryParse(totalPagesAttr ?? '');
            if (parsedTotalPages != null && parsedTotalPages > 0) {
              totalPages = parsedTotalPages;
            }

            final recordsPerPageAttr = section
                ?.attributes['data-records-per-page']
                ?.trim();
            final parsedRecordsPerPage = int.tryParse(recordsPerPageAttr ?? '');
            if (parsedRecordsPerPage != null && parsedRecordsPerPage > 0) {
              recordsPerPage = parsedRecordsPerPage;
            }

            final entries = _extractTalentBrewEntries(doc, baseUri: careerUri);
            if (entries.isEmpty) {
              continue;
            }

            for (final entry in entries) {
              final title = (entry['title'] ?? '').trim();
              if (title.isEmpty) continue;

              final description = (entry['description'] ?? '').trim();
              final titleLower = title.toLowerCase();
              final descLower = description.toLowerCase();

              if (keywords.isNotEmpty) {
                final exactWordMatch = matchTerms.any((kw) {
                  final pattern = RegExp(
                    '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                  );
                  return pattern.hasMatch(titleLower) ||
                      pattern.hasMatch(descLower);
                });
                if (!exactWordMatch && !fuzzyMatch(titleLower, matchTerms)) {
                  continue;
                }
              }

              final applyLink = (entry['applyLink'] ?? careerUri.toString())
                  .trim();
              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.contains(key)) continue;
              seen.add(key);

              final location = (entry['location'] ?? '').trim();
              final durationData = parseDuration(description);

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location.isEmpty ? 'Not specified' : location,
                  duration: durationData.$1,
                  deadline: '—',
                  source: 'Barclays TalentBrew API',
                  error: '',
                ),
              );
            }
          }

          if (rows.length >= 800) {
            break;
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('careers.amd.com') || host.contains('amd.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};

        final country = (careerUri.queryParameters['country'] ?? 'India')
            .toString()
            .trim();
        final page =
            int.tryParse(careerUri.queryParameters['page'] ?? '1') ?? 1;
        final requestedLimit =
            int.tryParse(careerUri.queryParameters['limit'] ?? '30') ?? 30;
        final limit = requestedLimit.clamp(1, 100);

        final queryTerms = keywords;
        for (final query in queryTerms) {
          final uri = Uri.https('careers.amd.com', '/api/jobs', {
            'country': country,
            'keywords': query,
            'page': '$page',
            'limit': '$limit',
          });

          final response = await _client
              .get(
                uri,
                headers: const {'accept': 'application/json, text/plain, */*'},
              )
              .timeout(const Duration(seconds: 12));

          if (response.statusCode >= 400 || response.body.trim().isEmpty) {
            continue;
          }

          final decoded = jsonDecode(response.body);
          if (decoded is! Map || decoded['jobs'] is! List) {
            continue;
          }

          final jobs = (decoded['jobs'] as List).whereType<Map>();
          for (final item in jobs) {
            final data = item['data'];
            if (data is! Map) continue;
            final map = data.map((k, v) => MapEntry(k.toString(), v));

            final title = (map['title'] ?? '').toString().trim();
            final description =
                (map['description'] ?? map['qualifications'] ?? '')
                    .toString()
                    .trim();
            if (title.isEmpty) continue;

            final titleLower = title.toLowerCase();
            final descLower = description.toLowerCase();
            final exactWordMatch = keywords.any((kw) {
              final pattern = RegExp(
                '\\b${RegExp.escape(kw.toLowerCase())}\\b',
              );
              return pattern.hasMatch(titleLower) ||
                  pattern.hasMatch(descLower);
            });
            if (!exactWordMatch && !fuzzyMatch(titleLower, keywords)) continue;

            final durationData = parseDuration(description);

            final applyLink =
                (map['apply_url'] ??
                        map['url_next_step'] ??
                        map['external'] ??
                        careerUri.toString())
                    .toString()
                    .trim();
            final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
            if (seen.contains(key)) continue;
            seen.add(key);

            final location =
                (map['location_name'] ??
                        map['full_location'] ??
                        map['city'] ??
                        map['country'] ??
                        '')
                    .toString()
                    .trim();

            rows.add(
              ScanResultRow(
                company: companyName,
                title: title,
                companyUrl: careerUri.toString(),
                applyLink: applyLink.isEmpty ? careerUri.toString() : applyLink,
                location: location.isEmpty ? 'Not specified' : location,
                duration: durationData.$1,
                deadline: '—',
                source: 'AMD Jobs API',
                error: '',
              ),
            );
          }

          if (rows.length >= 200) {
            break;
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('amazon.jobs')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};

        final countryFilters = <String>[];
        final iso2ToIso3 = {
          'IN': 'IND',
          'US': 'USA',
          'GB': 'GBR',
          'CA': 'CAN',
          'AU': 'AUS',
          'DE': 'DEU',
          'FR': 'FRA',
          'JP': 'JPN',
          'BR': 'BRA',
          'CN': 'CHN',
          'SG': 'SGP',
          'MY': 'MYS',
          'PH': 'PHL',
          'NL': 'NLD',
          'ES': 'ESP',
          'IT': 'ITA',
          'CH': 'CHE',
          'SE': 'SWE',
          'NO': 'NOR',
          'FI': 'FIN',
          'DK': 'DNK',
          'IE': 'IRL',
          'NZ': 'NZL',
        };

        for (final entry in careerUri.queryParametersAll.entries) {
          final key = entry.key.toLowerCase();
          if (key.contains('country') ||
              key.contains('normalized_country_code')) {
            for (final v in entry.value) {
              var val = v.trim().toUpperCase();
              if (val.length == 2) {
                final mapped = iso2ToIso3[val];
                if (mapped != null) {
                  val = mapped;
                }
              }
              if (val.isNotEmpty) {
                countryFilters.add(val);
              }
            }
          }
        }

        final queryTerms = keywords.isEmpty ? [''] : keywords;
        for (final query in queryTerms) {
          int offset = 0;
          const int limit = 100;
          var consecutiveEmptyPages = 0;

          while (true) {
            final qp = <String, dynamic>{
              'base_query': query,
              'offset': '$offset',
              'result_limit': '$limit',
            };
            if (countryFilters.isNotEmpty) {
              qp['normalized_country_code[]'] = countryFilters;
            }

            final uri = Uri.https('www.amazon.jobs', '/en/search.json', qp);
            final response = await _client
                .get(
                  uri,
                  headers: const {
                    'accept': 'application/json, text/plain, */*',
                  },
                )
                .timeout(const Duration(seconds: 12));

            if (response.statusCode >= 400 || response.body.trim().isEmpty) {
              break;
            }

            final decoded = jsonDecode(response.body);
            if (decoded is! Map || decoded['jobs'] is! List) {
              break;
            }

            final jobs = (decoded['jobs'] as List).whereType<Map>();
            if (jobs.isEmpty) {
              consecutiveEmptyPages++;
              if (consecutiveEmptyPages >= 2) {
                break;
              }
            } else {
              consecutiveEmptyPages = 0;
            }

            for (final item in jobs) {
              final map = item.map((k, v) => MapEntry(k.toString(), v));

              final title = (map['title'] ?? '').toString().trim();
              final description = (map['description'] ?? '').toString().trim();
              if (title.isEmpty) continue;

              final titleLower = title.toLowerCase();
              final descLower = description.toLowerCase();

              if (keywords.isNotEmpty) {
                final exactWordMatch = keywords.any((kw) {
                  final pattern = RegExp(
                    '\\b${RegExp.escape(kw.toLowerCase())}\\b',
                  );
                  return pattern.hasMatch(titleLower) ||
                      pattern.hasMatch(descLower);
                });
                if (!exactWordMatch && !fuzzyMatch(titleLower, keywords)) {
                  continue;
                }
              }

              final durationData = parseDuration(description);

              final jobPath = (map['job_path'] ?? '').toString().trim();
              final applyLink = jobPath.isNotEmpty
                  ? Uri.https('www.amazon.jobs', jobPath).toString()
                  : careerUri.toString();
              final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
              if (seen.contains(key)) continue;
              seen.add(key);

              final location =
                  (map['normalized_location'] ?? map['location'] ?? '')
                      .toString()
                      .trim();

              final basicQuals = (map['basic_qualifications'] ?? '')
                  .toString()
                  .trim();
              final prefQuals = (map['preferred_qualifications'] ?? '')
                  .toString()
                  .trim();
              final fullText = '$basicQuals\n$prefQuals\n$description';
              final exp = parseExperience(fullText);

              rows.add(
                ScanResultRow(
                  company: companyName,
                  title: title,
                  companyUrl: careerUri.toString(),
                  applyLink: applyLink,
                  location: location.isEmpty ? 'Not specified' : location,
                  duration: durationData.$1,
                  deadline: '—',
                  source: 'Amazon Search JSON',
                  error: '',
                  experience: exp,
                ),
              );
            }

            if (rows.length >= 800) {
              break;
            }

            offset += limit;
          }
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('0x.org')) {
      try {
        final response = await _client
            .get(
              Uri.parse(
                'https://api.ashbyhq.com/posting-api/job-board/0x?includeCompensation=true',
              ),
              headers: const {'accept': 'application/json, text/plain, */*'},
            )
            .timeout(const Duration(seconds: 12));

        if (response.statusCode >= 400) {
          return const [];
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map || decoded['jobs'] is! List) {
          return const [];
        }

        final jobs = (decoded['jobs'] as List).whereType<Map>();
        final rows = <ScanResultRow>[];
        final seen = <String>{};

        for (final item in jobs) {
          final map = item.map((k, v) => MapEntry(k.toString(), v));

          final title = (map['title'] ?? '').toString().trim();
          final description = (map['descriptionPlain'] ?? '').toString().trim();
          if (title.isEmpty) continue;

          final titleLower = title.toLowerCase();
          final descLower = description.toLowerCase();
          final exactWordMatch = keywords.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(titleLower) || pattern.hasMatch(descLower);
          });
          if (!exactWordMatch && !fuzzyMatch(titleLower, keywords)) continue;

          final durationData = parseDuration(description);

          final applyLink =
              (map['applyUrl'] ?? map['jobUrl'] ?? careerUri.toString())
                  .toString()
                  .trim();
          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          final location = (map['location'] ?? '').toString().trim();

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location.isEmpty ? 'Not specified' : location,
              duration: durationData.$1,
              deadline: '—',
              source: 'Ashby API',
              error: '',
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('acko.com') || host.contains('cashfree.com')) {
      try {
        final source = host.contains('cashfree.com')
            ? Uri.parse('https://careers.kula.ai/cashfree?jobs=true')
            : Uri.parse('https://careers.kula.ai/acko?jobs=true');
        final response = await _client
            .get(
              source,
              headers: const {
                'accept':
                    'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
              },
            )
            .timeout(const Duration(seconds: 12));

        if (response.statusCode >= 400 || response.body.trim().isEmpty) {
          return const [];
        }

        final doc = html_parser.parse(response.body);
        final rows = <ScanResultRow>[];
        final seen = <String>{};
        final cards = doc.querySelectorAll('div.chakra-card');

        for (final card in cards) {
          final title =
              card.querySelector('p.css-f8zk62')?.text.trim() ??
              card.querySelector('p.chakra-text')?.text.trim() ??
              '';
          if (title.isEmpty) continue;

          final titleLower = title.toLowerCase();
          final context = card.text;
          final contextLower = context.toLowerCase();
          final exactWordMatch = keywords.any((kw) {
            final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
            return pattern.hasMatch(titleLower) ||
                pattern.hasMatch(contextLower);
          });
          if (!exactWordMatch && !fuzzyMatch(titleLower, keywords)) continue;

          final durationData = parseDuration(context);

          final href = card.querySelector('a[href]')?.attributes['href'];
          final applyLink = href == null
              ? source.toString()
              : source.resolve(href).toString();
          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          final location =
              card.querySelector('p.css-de2tee')?.text.trim() ??
              parseLocation(context);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location.isEmpty ? 'Not specified' : location,
              duration: durationData.$1,
              deadline: '—',
              source: 'Kula Careers HTML',
              error: '',
            ),
          );
        }

        if (rows.isNotEmpty) {
          return rows;
        }
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('careers.adyen.com') ||
        host.contains('greenhouse.io') ||
        host.contains('www.exodus.com') ||
        host.contains('copper.co') ||
        host.contains('consensys.io') ||
        host.contains('layerzero.network')) {
      try {
        var board = 'adyen';
        if (host.contains('copper.co')) {
          board = 'copperco';
        } else if (host.contains('consensys.io')) {
          board = 'consensys';
        } else if (host.contains('www.exodus.com')) {
          board = 'exodus54';
        } else if (host.contains('layerzero.network')) {
          board = 'layerzerolabs';
        } else if (!host.contains('careers.adyen.com')) {
          final segments = careerUri.pathSegments
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
          if (segments.isEmpty) {
            return const [];
          }
          board = segments.first;
        }

        final response = await _client
            .get(
              Uri.parse(
                'https://boards-api.greenhouse.io/v1/boards/$board/jobs?content=true',
              ),
              headers: const {'accept': 'application/json, text/plain, */*'},
            )
            .timeout(const Duration(seconds: 12));

        if (response.statusCode >= 400) {
          return const [];
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map || decoded['jobs'] is! List) {
          return const [];
        }

        final jobs = (decoded['jobs'] as List).whereType<Map>();
        final rows = <ScanResultRow>[];
        final seen = <String>{};

        for (final item in jobs) {
          final map = item.map((k, v) => MapEntry(k.toString(), v));

          final title = (map['title'] ?? '').toString().trim();
          final content = (map['content'] ?? '').toString().trim();
          if (title.isEmpty) continue;

          final titleLower = title.toLowerCase();
          final contentLower = content.toLowerCase();
          if (keywords.isNotEmpty) {
            final exactWordMatch = keywords.any((kw) {
              final pattern = RegExp(
                '\\b${RegExp.escape(kw.toLowerCase())}\\b',
              );
              return pattern.hasMatch(titleLower) ||
                  pattern.hasMatch(contentLower);
            });
            if (!exactWordMatch && !fuzzyMatch(titleLower, keywords)) continue;
          }

          final durationData = parseDuration(content);

          final applyLink = (map['absolute_url'] ?? careerUri.toString())
              .toString()
              .trim();
          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          String location = 'Not specified';
          final locationObj = map['location'];
          if (locationObj is Map) {
            final name = (locationObj['name'] ?? '').toString().trim();
            if (name.isNotEmpty) {
              location = name;
            }
          } else {
            final name = locationObj?.toString().trim() ?? '';
            if (name.isNotEmpty) {
              location = name;
            }
          }

          final exp = parseExperience(content);
          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location,
              duration: durationData.$1,
              deadline: '—',
              source: 'Greenhouse API',
              error: '',
              experience: exp,
            ),
          );
        }

        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('freshteam.com')) {
      try {
        final rows = <ScanResultRow>[];
        final html = await _fetch(careerUri);
        if (html == null || html.trim().isEmpty) {
          return const [];
        }

        final doc = html_parser.parse(html);
        final jobElements = doc.querySelectorAll(
          'a[data-portal-title], .job-list a[href*="/jobs/"]',
        );

        final seen = <String>{};
        for (final element in jobElements) {
          final titleElement = element.querySelector('.job-title');
          final title = titleElement?.text.trim() ?? element.text.trim();
          if (title.isEmpty) continue;

          final href = element.attributes['href']?.trim() ?? '';
          if (href.isEmpty) continue;
          final applyLink = careerUri.resolve(href).toString();

          final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
          if (seen.contains(key)) continue;
          seen.add(key);

          final locationText =
              element.querySelector('.location-info')?.text.trim() ??
              'Not specified';
          final locationParts = locationText
              .split('\n')
              .map((s) => s.trim())
              .where(
                (s) =>
                    s.isNotEmpty &&
                    s.toLowerCase() != 'full time' &&
                    s.toLowerCase() != 'part time',
              )
              .toList();
          final location = locationParts.isEmpty
              ? 'Not specified'
              : locationParts.join(', ');

          final description =
              element.querySelector('.job-desc')?.text.trim() ?? '';
          final durationData = parseDuration(description);

          rows.add(
            ScanResultRow(
              company: companyName,
              title: title,
              companyUrl: careerUri.toString(),
              applyLink: applyLink,
              location: location,
              duration: durationData.$1,
              deadline: '—',
              source: 'Freshteam HTML Scan',
              error: '',
            ),
          );
        }
        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (host.contains('careers.loreal.com') || host.contains('loreal.com')) {
      try {
        final rows = <ScanResultRow>[];
        final seen = <String>{};

        void synchronizedAction(void Function() action) {
          action();
        }

        var nextOffset = 0;
        const pageSize = 20;
        var hasMore = true;
        const workerCount = 80;

        Future<void> worker() async {
          while (true) {
            int currentOffset = -1;
            synchronizedAction(() {
              if (!hasMore) {
                currentOffset = -1;
              } else {
                currentOffset = nextOffset;
                nextOffset += pageSize;
              }
            });

            if (currentOffset == -1) break;

            final pageUri = Uri.parse(
              'https://careers.loreal.com/en_US/jobs/SearchJobsAjax?offset=$currentOffset',
            );
            try {
              final response = await _client
                  .get(
                    pageUri,
                    headers: {
                      'User-Agent':
                          userAgents[DateTime.now().millisecond %
                              userAgents.length],
                      'Accept-Language': 'en-US,en;q=0.9',
                      'Accept':
                          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                      'DNT': '1',
                    },
                  )
                  .timeout(const Duration(seconds: 10));

              if (response.statusCode != 200 ||
                  response.body.contains('No jobs found')) {
                synchronizedAction(() {
                  hasMore = false;
                });
                break;
              }

              final doc = html_parser.parse(response.body);
              final containers = doc.querySelectorAll('.article__header__text');
              if (containers.isEmpty) {
                synchronizedAction(() {
                  hasMore = false;
                });
                break;
              }

              final pageRows = <ScanResultRow>[];
              for (final container in containers) {
                final link = container.querySelector(
                  'a[href*="/jobs/JobDetail/"]',
                );
                if (link == null) continue;
                final title = link.text.trim();
                if (title.isEmpty || title.toLowerCase() == 'apply now') {
                  continue;
                }

                final applyLink = link.attributes['href']?.trim() ?? '';

                final spans = container.querySelectorAll(
                  '.article__header__text__subtitle span',
                );
                String location = 'Not specified';
                String duration = '—';
                if (spans.isNotEmpty) {
                  location = spans[0].text.trim();
                  if (location.isEmpty) location = 'Not specified';
                }
                if (spans.length > 1) {
                  duration = spans[1].text.trim();
                  if (duration.isEmpty) duration = '—';
                }

                pageRows.add(
                  ScanResultRow(
                    company: companyName,
                    title: title,
                    companyUrl: careerUri.toString(),
                    applyLink: applyLink,
                    location: location,
                    duration: duration,
                    deadline: '—',
                    source: 'L\'Oreal Careers Ajax API',
                    error: '',
                  ),
                );
              }

              synchronizedAction(() {
                for (final row in pageRows) {
                  final key =
                      '${row.title.toLowerCase()}|${row.applyLink.toLowerCase()}';
                  if (!seen.contains(key)) {
                    seen.add(key);
                    rows.add(row);
                  }
                }
              });
            } catch (_) {
              // If a page request fails, allow other workers to proceed
            }
          }
        }

        await Future.wait(List.generate(workerCount, (_) => worker()));
        return rows;
      } catch (_) {
        return const [];
      }
    }

    if (!host.contains('aeonsoftware.net')) {
      return const [];
    }

    try {
      final response = await _client
          .post(
            Uri.parse('https://hrdeskbkv2.aeontechhub.com/Jobs/GetJobOpenings'),
            headers: {
              'content-type': 'application/json',
              'accept': 'application/json, text/plain, */*',
            },
            body: jsonEncode({'Status': '1'}),
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode >= 400) {
        return const [];
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! List) {
        return const [];
      }

      final rows = <ScanResultRow>[];
      final seen = <String>{};
      for (final item in decoded.whereType<Map>()) {
        final map = item.map(
          (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
        );

        final title = map['job_Title']?.trim() ?? '';
        final description = map['job_desc']?.trim() ?? '';
        if (title.isEmpty) continue;

        final titleLower = title.toLowerCase();
        final descLower = description.toLowerCase();
        final exactWordMatch = keywords.any((kw) {
          final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
          return pattern.hasMatch(titleLower) || pattern.hasMatch(descLower);
        });
        if (!exactWordMatch && !fuzzyMatch(titleLower, keywords)) continue;

        final durationData = parseDuration(description);

        final postId = map['post_id']?.trim() ?? '';
        final key = '${title.toLowerCase()}|$postId';
        if (seen.contains(key)) continue;
        seen.add(key);

        final location = (map['loc']?.trim().isNotEmpty ?? false)
            ? map['loc']!.trim()
            : 'Not specified';

        rows.add(
          ScanResultRow(
            company: companyName,
            title: title,
            companyUrl: careerUri.toString(),
            applyLink: careerUri.toString(),
            location: location,
            duration: durationData.$1,
            deadline: '—',
            source: 'JSON API',
            error: '',
          ),
        );
      }

      return rows;
    } catch (_) {
      return const [];
    }
  }

  Future<List<ScanResultRow>> _fetchAshbyRows({
    required String board,
    required String companyName,
    required Uri careerUri,
    required List<String> keywords,
  }) async {
    List<Map<String, dynamic>> jobs = const [];

    try {
      final response = await _client
          .get(
            Uri.parse(
              'https://api.ashbyhq.com/posting-api/job-board/$board?includeCompensation=true',
            ),
            headers: const {'accept': 'application/json, text/plain, */*'},
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode < 400 && response.body.trim().isNotEmpty) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['jobs'] is List) {
          jobs = (decoded['jobs'] as List)
              .whereType<Map>()
              .map(
                (e) =>
                    e.map((k, v) => MapEntry(k.toString(), v))
                      ..cast<String, dynamic>(),
              )
              .toList();
        }
      }
    } catch (_) {}

    if (jobs.isEmpty) {
      try {
        final gqlResponse = await _client
            .post(
              Uri.parse(
                'https://jobs.ashbyhq.com/api/non-user-graphql?op=ApiJobBoardWithTeams',
              ),
              headers: const {
                'content-type': 'application/json',
                'accept': 'application/json, text/plain, */*',
              },
              body: jsonEncode({
                'operationName': 'ApiJobBoardWithTeams',
                'query': r'''
query ApiJobBoardWithTeams($organizationHostedJobsPageName: String!) {
  jobBoard: jobBoardWithTeams(
    organizationHostedJobsPageName: $organizationHostedJobsPageName
  ) {
    jobPostings {
      id
      title
      locationName
    }
  }
}
''',
                'variables': {'organizationHostedJobsPageName': board},
              }),
            )
            .timeout(const Duration(seconds: 12));

        if (gqlResponse.statusCode < 400 &&
            gqlResponse.body.trim().isNotEmpty) {
          final decoded = jsonDecode(gqlResponse.body);
          final data = decoded is Map ? decoded['data'] : null;
          final root = data is Map ? data : const {};

          final candidates = <dynamic>[
            root['jobBoard'],
            root['jobBoardWithTeams'],
            root,
          ];

          for (final candidate in candidates) {
            if (candidate is! Map) continue;
            final postings = candidate['jobPostings'];
            if (postings is List && postings.isNotEmpty) {
              jobs = postings
                  .whereType<Map>()
                  .map(
                    (e) =>
                        e.map((k, v) => MapEntry(k.toString(), v))
                          ..cast<String, dynamic>(),
                  )
                  .toList();
              break;
            }
          }
        }
      } catch (_) {}
    }

    if (jobs.isEmpty) {
      return const [];
    }

    final rows = <ScanResultRow>[];
    final seen = <String>{};
    final matchTerms = keywords;

    for (final map in jobs) {
      final title = (map['title'] ?? '').toString().trim();
      final rawDescription =
          (map['descriptionPlain'] ?? map['descriptionHtml'] ?? '')
              .toString()
              .trim();
      final postingId = (map['id'] ?? '').toString().trim();
      if (title.isEmpty) continue;

      final description =
          (html_parser
                      .parse(rawDescription)
                      .documentElement
                      ?.text
                      .replaceAll(RegExp(r'\s+'), ' ')
                      .trim() ??
                  rawDescription)
              .trim();

      final location = (map['location'] ?? map['locationName'] ?? '')
          .toString()
          .trim();
      final department = (map['departmentName'] ?? map['teamName'] ?? '')
          .toString()
          .trim();
      final searchable = [
        title,
        description,
        location,
        department,
      ].where((p) => p.trim().isNotEmpty).join(' | ').toLowerCase();

      bool hasKeywordVariant(String kw) {
        final k = kw.toLowerCase().trim();
        if (k.isEmpty || k.length < 3) return false;
        if (searchable.contains(k)) return true;
        if (k.endsWith('y') && k.length > 1) {
          final stem = k.substring(0, k.length - 1);
          if (searchable.contains('${stem}ies')) return true;
        }
        if (k.endsWith('e') && k.length > 1) {
          final stem = k.substring(0, k.length - 1);
          if (searchable.contains('${k}d') ||
              searchable.contains('${stem}ing')) {
            return true;
          }
        }
        return searchable.contains('${k}s') ||
            searchable.contains('${k}es') ||
            searchable.contains('${k}ing') ||
            searchable.contains('${k}ed');
      }

      final titleLower = title.toLowerCase();
      final exactWordMatch = matchTerms.any((kw) {
        final pattern = RegExp('\\b${RegExp.escape(kw.toLowerCase())}\\b');
        return pattern.hasMatch(searchable);
      });
      final variantMatch = matchTerms.any(hasKeywordVariant);
      if (!exactWordMatch &&
          !variantMatch &&
          !fuzzyMatch(titleLower, matchTerms) &&
          !fuzzyMatch(searchable, matchTerms)) {
        continue;
      }

      final durationData = parseDuration(description);

      final applyLink =
          (map['applyUrl'] ?? map['jobUrl'] ?? '').toString().trim().isNotEmpty
          ? (map['applyUrl'] ?? map['jobUrl']).toString().trim()
          : postingId.isNotEmpty
          ? 'https://jobs.ashbyhq.com/$board/$postingId'
          : careerUri.toString();
      final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
      if (seen.contains(key)) continue;
      seen.add(key);

      final exp = parseExperience(description);
      rows.add(
        ScanResultRow(
          company: companyName,
          title: title,
          companyUrl: careerUri.toString(),
          applyLink: applyLink,
          location: location.isEmpty ? 'Not specified' : location,
          duration: durationData.$1,
          deadline: '—',
          source: 'Ashby API',
          error: '',
          experience: exp,
        ),
      );
    }

    return rows;
  }

  List<Map<String, String>> _extractTalentBrewEntries(
    html_dom.Document doc, {
    required Uri baseUri,
  }) {
    var links = doc.querySelectorAll('a.search-results-link[href]');
    if (links.isEmpty) {
      links = doc.querySelectorAll('section#search-results-list h2 a[href]');
    }
    if (links.isEmpty) {
      links = doc.querySelectorAll(
        'section#search-results-list a.section3__search-results-a[href]',
      );
    }
    if (links.isEmpty) {
      links = doc.querySelectorAll('section#search-results-list a[href]');
    }

    if (links.isEmpty) {
      return const [];
    }

    final out = <Map<String, String>>[];
    final seen = <String>{};

    for (final link in links) {
      final href = (link.attributes['href'] ?? '').trim();
      if (href.isEmpty) continue;

      final title = link.querySelector('h2')?.text.trim() ?? link.text.trim();
      if (title.isEmpty) continue;

      final titleLower = title.toLowerCase();
      if (titleLower == 'prev' ||
          titleLower == 'next' ||
          titleLower == 'previous' ||
          titleLower == 'first' ||
          titleLower == 'last' ||
          titleLower == 'view details' ||
          titleLower == 'apply' ||
          titleLower == 'read more' ||
          titleLower == 'learn more') {
        continue;
      }

      final applyLink = baseUri.resolve(href).toString();
      final key = '${title.toLowerCase()}|${applyLink.toLowerCase()}';
      if (seen.contains(key)) continue;
      seen.add(key);

      var description = link.parent?.text.trim() ?? link.text.trim();
      if (description.isEmpty) {
        description = title;
      }

      String location = '';
      html_dom.Element? node = link;
      for (var i = 0; i < 6 && node != null; i++) {
        final loc = node.querySelector('.job-location')?.text.trim() ?? '';
        if (loc.isNotEmpty) {
          location = loc;
          break;
        }
        node = node.parent;
      }

      out.add({
        'title': title,
        'description': description,
        'applyLink': applyLink,
        'location': location,
      });
    }

    return out;
  }

  Uri _buildAppleSearchUri(Uri seedUri) {
    final segments = seedUri.pathSegments
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    if (segments.length >= 2 && segments[1].toLowerCase() == 'search') {
      return seedUri;
    }

    final locale = segments.isNotEmpty && segments.first.contains('-')
        ? segments.first.toLowerCase()
        : 'en-us';
    final qp = <String, String>{};
    final location = (seedUri.queryParameters['location'] ?? '').toString();
    final page = (seedUri.queryParameters['page'] ?? '1').toString();
    if (location.isNotEmpty) {
      qp['location'] = location;
    }
    qp['page'] = page;

    return Uri.https('jobs.apple.com', '/$locale/search', qp);
  }

  Uri _withPage(Uri uri, int page) {
    final qp = <String, String>{
      ...uri.queryParameters.map((k, v) => MapEntry(k, v.toString())),
      'page': '$page',
    };
    return uri.replace(queryParameters: qp);
  }

  String? _extractAppleInitialStateJson(String html) {
    final parsedMatch = RegExp(
      r'window\.(?:__staticRouterHydrationData|__INITIAL_STATE__)\s*=\s*JSON\.parse\("(.+?)"\);',
      dotAll: true,
    ).firstMatch(html);
    if (parsedMatch != null) {
      final escaped = parsedMatch.group(1);
      if (escaped == null || escaped.isEmpty) return null;
      final unescaped = jsonDecode('"$escaped"');
      return unescaped is String ? unescaped : null;
    }

    final objectMatch = RegExp(
      r'window\.(?:__staticRouterHydrationData|__INITIAL_STATE__)\s*=\s*(\{.+?\});',
      dotAll: true,
    ).firstMatch(html);
    return objectMatch?.group(1);
  }

  String _decodeHtmlAttributeValue(String input) {
    if (input.isEmpty) return input;

    var out = input
        .replaceAll('&quot;', '"')
        .replaceAll('&#34;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');

    out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      final code = int.tryParse(m.group(1) ?? '');
      return code == null ? m.group(0)! : String.fromCharCode(code);
    });

    out = out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
      final code = int.tryParse(m.group(1) ?? '', radix: 16);
      return code == null ? m.group(0)! : String.fromCharCode(code);
    });

    return out;
  }

  String? _extractJsonObjectValueByKey(String text, String key) {
    final keyToken = '"$key"';
    final keyIndex = text.indexOf(keyToken);
    if (keyIndex < 0) return null;

    final colonIndex = text.indexOf(':', keyIndex + keyToken.length);
    if (colonIndex < 0) return null;

    var valueStart = colonIndex + 1;
    while (valueStart < text.length) {
      final ch = text.codeUnitAt(valueStart);
      if (ch == 32 || ch == 10 || ch == 13 || ch == 9) {
        valueStart++;
        continue;
      }
      break;
    }

    if (valueStart >= text.length || text[valueStart] != '{') {
      return null;
    }

    final valueEnd = _findMatchingObjectEnd(text, valueStart);
    if (valueEnd < 0) return null;
    return text.substring(valueStart, valueEnd + 1);
  }

  int _findMatchingObjectEnd(String text, int objectStart) {
    var depth = 0;
    var inString = false;
    var escaping = false;

    for (var i = objectStart; i < text.length; i++) {
      final ch = text.codeUnitAt(i);

      if (inString) {
        if (escaping) {
          escaping = false;
        } else if (ch == 92) {
          escaping = true;
        } else if (ch == 34) {
          inString = false;
        }
        continue;
      }

      if (ch == 34) {
        inString = true;
        continue;
      }

      if (ch == 123) {
        depth++;
      } else if (ch == 125) {
        depth--;
        if (depth == 0) {
          return i;
        }
      }
    }

    return -1;
  }

  List<Map<String, dynamic>> _extractAppleJobs(dynamic root) {
    final stack = <dynamic>[root];

    bool looksLikeAppleJob(Map<String, dynamic> map) {
      return map.containsKey('postingTitle') ||
          map.containsKey('positionId') ||
          map.containsKey('jobSummary') ||
          map.containsKey('transformedPostingTitle');
    }

    List<Map<String, dynamic>> toJobMaps(List jobs) {
      return jobs
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .where(looksLikeAppleJob)
          .toList();
    }

    while (stack.isNotEmpty) {
      final node = stack.removeLast();
      if (node is Map) {
        final jobs = node['jobs'];
        if (jobs is List && jobs.isNotEmpty) {
          final asMaps = toJobMaps(jobs);
          if (asMaps.isNotEmpty) {
            return asMaps;
          }
        }

        final searchResults = node['searchResults'];
        if (searchResults is List && searchResults.isNotEmpty) {
          final asMaps = toJobMaps(searchResults);
          if (asMaps.isNotEmpty) {
            return asMaps;
          }
        }

        stack.addAll(node.values);
      } else if (node is List) {
        stack.addAll(node);
      }
    }
    return const [];
  }

  String _normalize(String raw) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    return 'https://$trimmed';
  }
}
