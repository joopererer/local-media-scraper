// Copyright 2026 Jiawei LI
// Licensed under the Apache License, Version 2.0.

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scraper_core/scraper_core.dart';
import 'package:test/test.dart';

/// These tests pin the YAML rule semantics. Any change in behaviour that makes
/// them fail is a MAJOR (rule-breaking) change to the plugin format.
void main() {
  YamlScraper build(String yaml, {MockClient? client}) =>
      YamlScraper.fromYamlString(
        yaml,
        client: client ?? MockClient((_) async => http.Response('', 200)),
      );

  group('prefix_map', () {
    const yaml = '''
id: "prefix_test"
name: "Prefix Mapper"
description: "Test prefix_map feature"
priority: 70
pattern: '([A-Z]{3,6})-\\d+'
value_maps:
  studios:
    ABC: { value: "ABC Studios Inc.", confidence: 0.98 }
fields:
  - key: "studio"
    source: "prefix_map:studios"
    entity_type: "studio"
    confidence_known: 0.95
    confidence_unknown: 0.70
''';

    test('maps a known prefix to the mapped value and confidence', () async {
      final result = await build(yaml).scrape(
        const ScrapeInput(
          subject: ScrapeSubject(id: 'r1'),
          fileName: 'ABC-1234.mp4',
        ),
        const ScrapeContext(),
      );

      final field = result.fields.firstWhere((f) => f.key == 'studio');
      expect(field.entityName, 'ABC Studios Inc.');
      expect(field.confidence, 0.98);
    });

    test('falls back to the prefix itself with confidence_unknown', () async {
      final result = await build(yaml).scrape(
        const ScrapeInput(
          subject: ScrapeSubject(id: 'r2'),
          fileName: 'NEWCO-5678.mp4',
        ),
        const ScrapeContext(),
      );

      final field = result.fields.firstWhere((f) => f.key == 'studio');
      expect(field.entityName, 'NEWCO');
      expect(field.confidence, 0.70);
    });
  });

  group('value_map', () {
    const yaml = '''
id: "value_map_test"
name: "Exact Mapper"
description: "Test value_map exact-match feature"
priority: 70
pattern: '([A-Z]{3,6})-\\d+'
value_maps:
  studios:
    ABC: { value: "ABC Studios Inc.", confidence: 0.98 }
fields:
  - key: "studio"
    source: "value_map:studios"
    entity_type: "studio"
    confidence_known: 0.95
    confidence_unknown: 0.70
''';

    test('maps a known key exactly', () async {
      final result = await build(yaml).scrape(
        const ScrapeInput(
          subject: ScrapeSubject(id: 'r1'),
          fileName: 'ABC-1234.mp4',
        ),
        const ScrapeContext(),
      );

      final field = result.fields.firstWhere((f) => f.key == 'studio');
      expect(field.entityName, 'ABC Studios Inc.');
      expect(field.confidence, 0.98);
    });

    test(
      'emits no field when the key is unknown (unlike prefix_map)',
      () async {
        final result = await build(yaml).scrape(
          const ScrapeInput(
            subject: ScrapeSubject(id: 'r2'),
            fileName: 'NEWCO-5678.mp4',
          ),
          const ScrapeContext(),
        );

        expect(result.fields.where((f) => f.key == 'studio'), isEmpty);
      },
    );
  });

  group('request_urls cascade', () {
    test(
      'tries addresses in order and stops at the first accepted body',
      () async {
        const yaml = '''
id: "cascade_test"
name: "Cascade"
description: "Cascade fallback"
priority: 70
pattern: 'TEST-(\\d+)'
request_urls:
  - url: "https://primary.example.com/{1}"
    reject_body_contains: ["404 Not Found"]
  - url: "https://mirror1.example.com/{1}"
    require_body_contains: ["<title>"]
  - url: "https://mirror2.example.com/{1}"
fields:
  - key: "title"
    source: "regex:<title>([^<]+)</title>"
    is_title: true
''';

        final requested = <String>[];
        final client = MockClient((request) async {
          requested.add(request.url.host);
          return switch (request.url.host) {
            'primary.example.com' => http.Response(
              '<html>404 Not Found</html>',
              200,
            ),
            'mirror1.example.com' => http.Response(
              '<html><title>Test Video</title></html>',
              200,
            ),
            _ => http.Response('', 500),
          };
        });

        final result = await build(yaml, client: client).scrape(
          const ScrapeInput(
            subject: ScrapeSubject(id: 'r3'),
            fileName: 'TEST-123.mp4',
          ),
          const ScrapeContext(),
        );

        expect(requested, ['primary.example.com', 'mirror1.example.com']);
        expect(
          result.fields.firstWhere((f) => f.key == 'title').valueText,
          'Test Video',
        );
      },
    );

    test(
      'rejects an HTTP 200 age-gate page via reject_body_contains',
      () async {
        const yaml = '''
id: "age_gate"
name: "Age Gate"
description: "Age gates answer 200"
priority: 70
pattern: 'GATE-(\\d+)'
request_urls:
  - url: "https://gated.example.com/{1}"
    reject_body_contains: ["Age Verification"]
  - url: "https://open.example.com/{1}"
fields:
  - key: "title"
    source: "regex:<title>([^<]+)</title>"
    is_title: true
''';

        final requested = <String>[];
        final client = MockClient((request) async {
          requested.add(request.url.host);
          if (request.url.host == 'gated.example.com') {
            return http.Response(
              '<html><title>Age Verification</title></html>',
              200,
            );
          }
          return http.Response('<html><title>Real Page</title></html>', 200);
        });

        final result = await build(yaml, client: client).scrape(
          const ScrapeInput(
            subject: ScrapeSubject(id: 'r5'),
            fileName: 'GATE-42.mp4',
          ),
          const ScrapeContext(),
        );

        expect(requested, ['gated.example.com', 'open.example.com']);
        expect(result.proposedTitle, 'Real Page');
      },
    );
  });

  group('prefix as base URL', () {
    const yaml = '''
id: "prefix_base_url_test"
name: "Prefix Base URL"
description: "prefix resolves relative references only"
priority: 70
pattern: 'COV-(\\d+)'
request_urls:
  - url: "https://site.example.com/{1}"
fields:
  - key: "cover"
    source: 'regex:data-cover="([^"]+)"'
    prefix: "https://site.example.com"
    is_preview_image: true
''';

    Future<ScrapeResult> scrapeBody(String body) =>
        build(
          yaml,
          client: MockClient((_) async => http.Response(body, 200)),
        ).scrape(
          const ScrapeInput(
            subject: ScrapeSubject(id: 'r7'),
            fileName: 'COV-1.mp4',
          ),
          const ScrapeContext(),
        );

    test('prefixes a site-relative path', () async {
      final result = await scrapeBody(
        '<html><body><img data-cover="/pics/a.jpg"></body></html>',
      );
      expect(result.previewImageUrl, 'https://site.example.com/pics/a.jpg');
    });

    test('leaves an absolute URL untouched', () async {
      final result = await scrapeBody(
        '<html><body><img data-cover="https://cdn.other.com/a.jpg"></body></html>',
      );
      expect(result.previewImageUrl, 'https://cdn.other.com/a.jpg');
    });
  });

  group('HTML list page -> detail (items with regex source)', () {
    const listPage = '''
<div class="item"><a href="/v/AAA111" class="box">
  <div class="cover"><img loading="lazy" src="https://cdn.example.com/aaa.jpg"></div>
  <div class="video-title"><strong>ABC-123</strong> Wanted Title</div>
  <div class="meta">2016-05-01</div>
</a></div>
<div class="item"><a href="/v/BBB222" class="box">
  <div class="cover"><img loading="lazy" src="https://cdn.example.com/bbb.jpg"></div>
  <div class="video-title"><strong>ABC-124</strong> Other Title</div>
  <div class="meta">2017-01-01</div>
</a></div>
''';

    const detailPage = '''
<h1><strong class="current-title">Wanted Title</strong></h1>
<span class="value">2016-05-01</span>
<a class="actor-female" href="/actors/x">Jane Doe</a>
<img class="video-cover" src="https://cdn.example.com/aaa_big.jpg">
''';

    const yaml = '''
id: "html_list"
name: "HTML list page"
description: "HTML list page drills into the matching detail page"
priority: 70
pattern: '([A-Za-z]{2,6})-(\\d+)'
request_urls:
  - url: "https://list.example.com/search?q={0}"
fields:
  - key: "title"
    source: 'regex:<strong class="current-title">([^<]+)</strong>'
    is_title: true
  - key: "actress"
    source: 'regex:<a class="actor-female"[^>]*>([^<]+)</a>'
    entity_type: "actress"
  - key: "cover"
    source: 'regex:<img class="video-cover" src="([^"]+)"'
    is_preview_image: true
items:
  source: 'regex:<div class="item">[\\s\\S]*?</div>\\s*</a></div>'
  title: 'regex:<div class="video-title">(?:<strong>[^<]*</strong>)?\\s*([^<]+)</div>'
  url: 'regex:<a href="([^"]+)"'
  cover: 'regex:<img[^>]+src="([^"]+)"'
  filter: '(?:^|[^A-Za-z0-9]){1}-{2}(?:[^0-9]|\$)'
detail_request:
  url_template: "https://detail.example.com{url|raw}"
  auto_drill_down_single: true
''';

    MockClient listThenDetail() => MockClient((request) async {
      if (request.url.host == 'list.example.com') {
        return http.Response(listPage, 200);
      }
      if (request.url.host == 'detail.example.com') {
        return http.Response(detailPage, 200);
      }
      return http.Response('', 404);
    });

    test('extracts one candidate per HTML block and filters by code', () async {
      final scraper = build(yaml, client: listThenDetail());
      final result = await scraper.scrape(
        const ScrapeInput(
          subject: ScrapeSubject(id: 'h1'),
          fileName: 'ABC-123.mp4',
        ),
        const ScrapeContext(),
      );

      expect(result.candidates, hasLength(1));
      expect(result.proposedTitle, 'Wanted Title');
      expect(
        result.fields.firstWhere((f) => f.key == 'actress').entityName,
        'Jane Doe',
      );
      expect(result.previewImageUrl, 'https://cdn.example.com/aaa_big.jpg');
    });

    test('does not drill down when the filter matches nothing', () async {
      final scraper = build(yaml, client: listThenDetail());
      final result = await scraper.scrape(
        const ScrapeInput(
          subject: ScrapeSubject(id: 'h2'),
          fileName: 'ZZZ-999.mp4',
        ),
        const ScrapeContext(),
      );

      expect(result.proposedTitle, isNull);
    });

    test('sends browser-like Accept-Language by default', () async {
      final seen = <String, String>{};
      final scraper = build(
        '''
id: "hdr"
name: "Header probe"
description: "probe"
pattern: 'ABC-(\\d+)'
request_urls:
  - url: "https://probe.example.com/{0}"
fields:
  - key: "title"
    source: 'regex:<title>([^<]+)</title>'
''',
        client: MockClient((request) async {
          seen.addAll(request.headers);
          return http.Response('<title>ok</title>', 200);
        }),
      );

      await scraper.scrape(
        const ScrapeInput(
          subject: ScrapeSubject(id: 'h3'),
          fileName: 'ABC-1.mp4',
        ),
        const ScrapeContext(),
      );

      expect(seen['Accept-Language'], contains('zh-CN'));
      expect(seen['User-Agent'], contains('Mozilla'));
    });
  });

  group('parse errors', () {
    test('rejects a document that is not a mapping', () {
      expect(
        () => YamlScraper.fromYamlString('- just\n- a\n- list\n'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('falls back to sane defaults when metadata is missing', () {
      final scraper = YamlScraper.fromYamlString('pattern: "X-(\\\\d+)"\n');
      expect(scraper.id, 'custom_yaml');
      expect(scraper.displayName, 'custom_yaml');
    });
  });
}
