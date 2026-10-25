// Copyright 2026 Jiawei LI
// Licensed under the Apache License, Version 2.0.

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scraper_core/scraper_core.dart';
import 'package:test/test.dart';

void main() {
  group('FileNameScraper', () {
    final scraper = FileNameScraper();

    test('extracts studio, code, year, resolution and tags', () async {
      final input = ScrapeInput(
        subject: const ScrapeSubject(id: 'r1'),
        fileName:
            '[Studio Trigger] SSSS.GRIDMAN ABC-101 (2018) [Anime, Mecha, 1080p].mkv',
      );

      final result = await scraper.scrape(input, const ScrapeContext());

      expect(result.isEmpty, isFalse);
      expect(
        result.fields.firstWhere((f) => f.key == 'studio').entityName,
        'Studio Trigger',
      );
      expect(
        result.fields.firstWhere((f) => f.key == 'code').valueText,
        'ABC-101',
      );
      expect(result.fields.firstWhere((f) => f.key == 'year').valueNum, 2018.0);
      expect(
        result.fields.firstWhere((f) => f.key == 'resolution').valueText,
        '1080p',
      );

      final tagNames = result.tags.map((t) => t.tagPath.first).toList();
      expect(tagNames, containsAll(<String>['Anime', 'Mecha']));
      expect(result.proposedTitle, isNotNull);
    });

    test('extracts season/episode markers', () async {
      final result = await scraper.scrape(
        ScrapeInput(
          subject: const ScrapeSubject(id: 'r2'),
          fileName: 'Some.Show.S01E15.mkv',
        ),
        const ScrapeContext(),
      );

      expect(
        result.fields.firstWhere((f) => f.key == 'episode').valueText,
        'S01E15',
      );
    });

    test(
      'falls back to the subject title when no file name is given',
      () async {
        final result = await scraper.scrape(
          const ScrapeInput(
            subject: ScrapeSubject(id: 'r3', title: 'ABC-777'),
          ),
          const ScrapeContext(),
        );

        expect(
          result.fields.firstWhere((f) => f.key == 'code').valueText,
          'ABC-777',
        );
      },
    );
  });

  group('WebPageScraper', () {
    final scraper = WebPageScraper();

    test('parses OpenGraph and meta tags', () {
      const html = '''
<!DOCTYPE html>
<html>
<head>
  <title>Sample Article - News &amp; Updates</title>
  <meta property="og:title" content="Breaking: Flutter 3.x Released" />
  <meta property="og:description" content="A review of the new features." />
  <meta property="og:image" content="/assets/cover.png" />
  <meta property="og:site_name" content="Flutter News" />
  <meta name="author" content="Dash the Bird" />
  <meta name="keywords" content="flutter, dart, mobile" />
</head>
<body><h1>Hello</h1></body>
</html>
''';

      final result = scraper.parseHtmlMetadata(
        html,
        baseUrl: Uri.parse('https://example.com/blog/article-1'),
      );

      expect(result.proposedTitle, 'Breaking: Flutter 3.x Released');
      expect(result.previewImageUrl, 'https://example.com/assets/cover.png');
      expect(
        result.fields.firstWhere((f) => f.key == 'description').valueText,
        contains('A review of the new features'),
      );
      expect(
        result.fields.firstWhere((f) => f.key == 'author').entityName,
        'Dash the Bird',
      );
      expect(
        result.tags.map((t) => t.tagPath.first),
        containsAll(<String>['flutter', 'dart', 'mobile']),
      );
    });

    test('resolves relative cover URLs against the page URL', () async {
      final client = MockClient(
        (_) async => http.Response(
          '<html><head>'
          '<meta property="og:image" content="cover.png" />'
          '<title>Page</title>'
          '</head></html>',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        ),
      );

      final result = await WebPageScraper(client: client).scrape(
        const ScrapeInput(
          subject: ScrapeSubject(id: 'w1'),
          sourceUrl: 'https://example.com/a/b',
        ),
        const ScrapeContext(),
      );

      expect(result.previewImageUrl, 'https://example.com/a/cover.png');
    });
  });
}
