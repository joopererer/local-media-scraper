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

  group('DoubanScraper', () {
    test('searches by film name and reads the rexxar JSON', () async {
      final urls = <String>[];
      final client = MockClient((request) async {
        urls.add(request.url.toString());
        if (request.url.host == 'movie.douban.com' &&
            request.url.path == '/j/subject_suggest') {
          return http.Response(
            '[{"id":"1292064","title":"楚门的世界","year":"1998",'
            '"type":"movie","sub_title":"The Truman Show"}]',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.host == 'm.douban.com' &&
            request.url.path == '/rexxar/api/v2/movie/1292064') {
          return http.Response(
            '{"title":"楚门的世界","year":"1998","original_title":'
            '"The Truman Show","rating":{"value":9.4},'
            '"pic":{"large":"https://img3.doubanio.com/l.jpg"},'
            '"genres":["剧情","科幻"],'
            '"directors":[{"name":"彼得·威尔"}],'
            '"actors":[{"name":"金·凯瑞"}],"intro":"概要"}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 404);
      });

      final result = await DoubanScraper(client: client).scrape(
        const ScrapeInput(
          subject: ScrapeSubject(id: 'd1'),
          fileName: '楚门的世界.mp4',
        ),
        const ScrapeContext(),
      );

      expect(result.proposedTitle, '楚门的世界');
      expect(result.previewImageUrl, 'https://img3.doubanio.com/l.jpg');
      expect(
        result.fields.firstWhere((f) => f.key == 'douban_rating').valueNum,
        9.4,
      );
      expect(
        result.fields.firstWhere((f) => f.key == 'director').entityName,
        '彼得·威尔',
      );
      expect(
        result.tags.map((t) => t.tagPath.join('/')),
        containsAll(<String>['影视', '影视/剧情', '豆瓣']),
      );
      expect(urls.first, contains('subject_suggest'));
    });

    test('treats a PDF as a book lookup', () async {
      final hosts = <String>[];
      final client = MockClient((request) async {
        hosts.add(request.url.host);
        if (request.url.host == 'book.douban.com') {
          return http.Response(
            '[{"id":"1090109","title":"红岩","year":"1961","type":"b"}]',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          '{"title":"红岩","year":"1961","rating":{"value":7.8},'
          '"pic":{"large":"https://img9.doubanio.com/s21406804.jpg"},'
          '"author":[{"name":"罗广斌"}]}',
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final scraper = DoubanScraper(client: client);
      const input = ScrapeInput(
        subject: ScrapeSubject(id: 'b1', mediaType: 'document'),
        fileName: '红岩.pdf',
      );

      expect(scraper.canHandle(input), isTrue);
      final result = await scraper.scrape(input, const ScrapeContext());

      expect(hosts.first, 'book.douban.com');
      expect(result.proposedTitle, '红岩');
      expect(
        result.fields.firstWhere((f) => f.key == 'author').entityName,
        '罗广斌',
      );
      expect(result.tags.map((t) => t.tagPath.join('/')), contains('图书'));
    });

    test('ignores camera dumps and untitled files', () {
      final scraper = DoubanScraper();
      expect(
        scraper.canHandle(
          const ScrapeInput(
            subject: ScrapeSubject(id: 'x'),
            fileName: 'IMG_1234.mp4',
          ),
        ),
        isFalse,
      );
      expect(
        scraper.canHandle(
          const ScrapeInput(
            subject: ScrapeSubject(id: 'y'),
            fileName: 'untitled.mkv',
          ),
        ),
        isFalse,
      );
    });

    test('falls back to the tv endpoint when the id is a series', () async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/movie/3070706')) {
          return http.Response('', 404);
        }
        if (request.url.path.endsWith('/tv/3070706')) {
          return http.Response(
            '{"title":"红岩","year":"1999","rating":{"value":8.1},'
            '"pic":{"large":"https://img1.doubanio.com/tv.jpg"}}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 404);
      });

      final result = await DoubanScraper(client: client).scrape(
        const ScrapeInput(
          subject: ScrapeSubject(id: 't1'),
          fileName: '[douban:3070706] 红岩.mp4',
        ),
        const ScrapeContext(),
      );

      expect(result.proposedTitle, '红岩');
      expect(result.previewImageUrl, 'https://img1.doubanio.com/tv.jpg');
    });
  });

  group('BangumiScraper', () {
    test('searches by anime name and keeps the episode number', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/v0/search/subjects') {
          return http.Response(
            '{"data":[{"id":400602,"name":"葬送のフリーレン",'
            '"name_cn":"葬送的芙莉莲","date":"2023-09-29",'
            '"rating":{"score":8.5},'
            '"images":{"large":"https://lain.bgm.tv/l.jpg"},'
            '"tags":[{"name":"奇幻"}]}]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 404);
      });

      final result = await BangumiScraper(client: client).scrape(
        const ScrapeInput(
          subject: ScrapeSubject(id: 'bg1'),
          fileName: '[Nekomoe] Frieren - 01 [1080p].mp4',
        ),
        const ScrapeContext(),
      );

      expect(result.proposedTitle, '葬送的芙莉莲 第01话');
      expect(result.previewImageUrl, 'https://lain.bgm.tv/l.jpg');
      expect(
        result.fields.firstWhere((f) => f.key == 'episode').valueText,
        '01',
      );
      expect(
        result.fields.firstWhere((f) => f.key == 'bangumi_rating').valueNum,
        8.5,
      );
    });

    test(
      'keeps the file-name heuristic when the search finds nothing',
      () async {
        final client = MockClient(
          (_) async => http.Response('{"data":[]}', 200),
        );

        final result = await BangumiScraper(client: client).scrape(
          const ScrapeInput(
            subject: ScrapeSubject(id: 'bg2'),
            fileName: '[Sub] Unknown Show - 03 [1080p].mp4',
          ),
          const ScrapeContext(),
        );

        expect(result.proposedTitle, 'Unknown Show 第03话');
        expect(
          result.fields.firstWhere((f) => f.key == 'anime_title').valueText,
          'Unknown Show',
        );
      },
    );
  });
}
