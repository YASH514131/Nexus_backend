import 'dart:convert';
import 'dart:io';

import 'package:scraper/local_scraper/models.dart';
import 'package:scraper/local_scraper/services/scraper_service.dart';
import 'package:scraper/default_companies.dart';

void main() async {
  print('Starting NEXUS Backend Scraper...');

  final scraperService = ScraperService();

  final companies = defaultCompanyUrls.entries
      .map((e) => CompanyInput(name: e.key, url: e.value))
      .toList();

  final scanConfig = ScanConfig(
    keywords: [], // Empty list allows all jobs because we modified fuzzyMatch
    excludeKeywords: [], // No exclusion
    scanLimit: 50,
    concurrency: 4,
    enableJs: false,
    hardTimeoutSeconds: 40,
  );

  List<Map<String, dynamic>> allJobs = [];
  
  // Implemented concurrent scraping to speed up the process significantly
  int batchSize = 10; 

  for (var i = 0; i < companies.length; i += batchSize) {
    final batch = companies.sublist(
      i, 
      i + batchSize > companies.length ? companies.length : i + batchSize
    );
    
    await Future.wait(batch.map((company) async {
      print('Scraping ${company.name}...');
      try {
        final rows = await scraperService.scrapeCompany(company, scanConfig);
        for (final row in rows) {
          if (row.title == '—' || row.title == 'No internship found') {
            continue;
          }

          allJobs.add({
            "title": row.title,
            "company": row.company,
            "companyUrl": row.companyUrl,
            "applyLink": row.applyLink,
            "location": row.location,
            "duration": row.duration,
            "deadline": row.deadline,
            "source": row.source,
            "tags": [],
            "isNew": true,
          });
        }
      } catch (e) {
        print('Error scraping ${company.name}: $e');
      }
    }));
  }

  print('Scraping completed. Extracted ${allJobs.length} jobs.');

  final file = File('jobs.json');
  await file.writeAsString(jsonEncode(allJobs));

  print('Saved output to jobs.json');
  exit(0);
}
