import 'dart:convert';
import 'dart:io';

void main(List<String> arguments) async {
  print('Starting NEXUS Scraper...');

  // TODO: Add your scraping logic here
  // Fetch from APIs or parse HTML, then generate the list of Job objects.

  // Example Job schema based on V3 Architecture:
  final List<Map<String, dynamic>> jobs = [
    {
      "title": "Software Engineer",
      "company": "Bank of America",
      "companyUrl": "https://careers.bankofamerica.com",
      "applyLink": "https://careers.bankofamerica.com/jobs/12345",
      "location": "Bangalore, India",
      "duration": "Full Time",
      "deadline": "—",
      "source": "Bank of America Jobs API",
      "tags": ["fintech", "web3", "india"],
      "isNew": true
    }
  ];

  print('Scraping completed. Extracted ${jobs.length} jobs.');

  // Write the output to jobs.json in the parent directory so the workflow can zip it.
  final file = File('../jobs.json');
  await file.writeAsString(jsonEncode(jobs));

  print('Saved output to jobs.json');
}
