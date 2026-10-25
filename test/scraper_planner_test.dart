// Copyright 2026 Jiawei LI
// Licensed under the Apache License, Version 2.0.

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scraper_core/scraper_core.dart';
import 'package:test/test.dart';

/// A scraper whose behaviour is fully controlled by the test.
class _StubScraper implements Scraper {
  @override
  final String id;
  @override
  final String displayName;
  @override
  final String description;
  @override
  final int priority;
  @override
  final List<String> mediaTypes;
  @override
  final List<String> targetSupertags;
  @override
  final RegExp? patternRegex;
  @override
  final List<String>? supertagToBackfill;

  final ScrapeResult result;
  final bool throwOnScrape;

  _StubScraper({
    required this.id,
    this.priority = 50,
    this.mediaTypes = const [],
    this.targetSupertags = const [],
    this.patternRegex,
    this.supertagToBackfill,
    this.result = const ScrapeResult(),
    this.throwOnScrape = false,
  }) : displayName = id,
       description = id;

  @override
  bool canHandle(ScrapeInput input) => true;

  @override
  Future<ScrapeResult> scrape(ScrapeInput input, ScrapeContext ctx) async {
    if (throwOnScrape) throw StateError('boom');
    return result;
  }
}

void main() {
  group('ScraperSettings', () {
    test('honours disabled ids and priority overrides', () {
      const settings = ScraperSettings(
        disabledIds: {'off'},
        priorityOverrides: {'a': 99},
      );
      final a = _StubScraper(id: 'a', priority: 10);
      final b = _StubScraper(id: 'b', priority: 50);

      expect(settings.isEnabled('off'), isFalse);
      expect(settings.isEnabled('a'), isTrue);
      expect(settings.priorityOf(a), 99);
      expect(settings.priorityOf(b), 50);
    });
  });

  group('ScraperPlanner', () {
    test('orders runs by effective priority, descending', () async {
      final planner = ScraperPlanner(
        scrapers: [
          _StubScraper(
            id: 'low',
            priority: 10,
            result: const ScrapeResult(proposedTitle: 'low'),
          ),
          _StubScraper(
            id: 'high',
            priority: 90,
            result: const ScrapeResult(proposedTitle: 'high'),
          ),
        ],
      );

      final plan = await planner.plan(
        const ScrapeInput(subject: ScrapeSubject(id: 'x')),
      );

      expect(plan.runs.map((r) => r.scraper.id), ['high', 'low']);
      // The highest-priority non-empty result wins the title.
      expect(plan.proposedTitle, 'high');
    });

    test('skips disabled scrapers', () async {
      final planner = ScraperPlanner(
        scrapers: [
          _StubScraper(
            id: 'on',
            result: const ScrapeResult(proposedTitle: 'on'),
          ),
          _StubScraper(
            id: 'off',
            result: const ScrapeResult(proposedTitle: 'off'),
          ),
        ],
        settings: const ScraperSettings(disabledIds: {'off'}),
      );

      final plan = await planner.plan(
        const ScrapeInput(subject: ScrapeSubject(id: 'x')),
      );

      expect(plan.runs.map((r) => r.scraper.id), ['on']);
      expect(plan.proposedTitle, 'on');
    });

    test('backfills a supertag once and feeds it into tier 2', () async {
      final planner = ScraperPlanner(
        scrapers: [
          _StubScraper(
            id: 'matcher',
            priority: 90,
            patternRegex: RegExp(r'ABC-\d+'),
            supertagToBackfill: const ['影视', '电影'],
          ),
          _StubScraper(
            id: 'movie',
            targetSupertags: const ['电影'],
            result: const ScrapeResult(proposedTitle: 'm'),
          ),
        ],
      );

      final plan = await planner.plan(
        const ScrapeInput(
          subject: ScrapeSubject(id: 'x'),
          fileName: 'ABC-1.mp4',
        ),
      );

      expect(plan.backfill.map((b) => b.label), ['影视 / 电影']);
      // Tier 2 sees the virtual backfilled tag, so the movie scraper still ran.
      expect(plan.runs.map((r) => r.scraper.id), contains('movie'));
    });

    test(
      'does not backfill when the subject already carries the supertag',
      () async {
        final planner = ScraperPlanner(
          scrapers: [
            _StubScraper(
              id: 'matcher',
              patternRegex: RegExp(r'ABC-\d+'),
              supertagToBackfill: const ['电影'],
            ),
          ],
        );

        final plan = await planner.plan(
          const ScrapeInput(
            subject: ScrapeSubject(id: 'x'),
            fileName: 'ABC-1.mp4',
            existingTags: [ExistingTag('电影')],
          ),
        );

        expect(plan.backfill, isEmpty);
      },
    );

    test('can skip supertag backfill for inspect-only callers', () async {
      final planner = ScraperPlanner(
        scrapers: [
          _StubScraper(
            id: 'matcher',
            patternRegex: RegExp(r'ABC-\d+'),
            supertagToBackfill: const ['电影'],
          ),
        ],
      );

      final plan = await planner.plan(
        const ScrapeInput(
          subject: ScrapeSubject(id: 'x'),
          fileName: 'ABC-1.mp4',
        ),
        backfillSupertags: false,
      );

      expect(plan.backfill, isEmpty);
    });

    test('isolates a throwing scraper from the rest', () async {
      final planner = ScraperPlanner(
        scrapers: [
          _StubScraper(id: 'bad', priority: 90, throwOnScrape: true),
          _StubScraper(
            id: 'good',
            priority: 10,
            result: const ScrapeResult(proposedTitle: 'good'),
          ),
        ],
      );

      final plan = await planner.plan(
        const ScrapeInput(subject: ScrapeSubject(id: 'x')),
      );

      expect(plan.runs.map((r) => r.scraper.id), ['good']);
      expect(plan.proposedTitle, 'good');
    });

    test(
      'media-type gate blocks a video-only scraper from tier-1 backfill on an image',
      () async {
        // Note: the gate applies to tier-1 feature dispatch only; tier-2 relies on
        // each scraper's own canHandle, matching the original app behaviour.
        final planner = ScraperPlanner(
          scrapers: [
            _StubScraper(
              id: 'videoOnly',
              mediaTypes: const ['video'],
              patternRegex: RegExp(r'ABC-\d+'),
              supertagToBackfill: const ['电影'],
            ),
          ],
        );

        final plan = await planner.plan(
          const ScrapeInput(
            subject: ScrapeSubject(
              id: 'x',
              uri: 'cover.jpg',
              mediaType: 'image',
            ),
            fileName: 'ABC-1.jpg',
          ),
        );

        expect(plan.backfill, isEmpty);
      },
    );

    test('media-type gate infers the kind from the file name', () async {
      final planner = ScraperPlanner(
        scrapers: [
          _StubScraper(
            id: 'videoOnly',
            mediaTypes: const ['video'],
            patternRegex: RegExp(r'ABC-\d+'),
            supertagToBackfill: const ['电影'],
          ),
        ],
      );

      final plan = await planner.plan(
        const ScrapeInput(
          subject: ScrapeSubject(id: 'x'),
          fileName: 'movie.mkv',
          sourceUrl: 'ABC-1',
        ),
      );

      expect(plan.backfill.map((b) => b.label), ['电影']);
    });
  });

  group('built-in registry wiring', () {
    test(
      'a YAML plugin loaded from a string works through the planner',
      () async {
        final yaml = '''
id: "bili"
name: "Bilibili"
description: "BV lookup"
priority: 80
target_supertags: ["Bilibili"]
pattern: 'BV([a-zA-Z0-9]{10})'
supertag_to_backfill: ["Bilibili"]
request:
  url_template: "https://api.example.com/view?bvid=BV{1}"
fields:
  - key: "title"
    source: "json:data.title"
    is_title: true
  - key: "cover"
    source: "json:data.pic"
    is_preview_image: true
''';
        final client = MockClient(
          (_) async => http.Response(
            '{"data":{"title":"A Video","pic":"https://img.example.com/p.jpg"}}',
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        );

        final planner = ScraperPlanner(
          scrapers: [YamlScraper.fromYamlString(yaml, client: client)],
        );

        final plan = await planner.plan(
          const ScrapeInput(
            subject: ScrapeSubject(id: 'x'),
            fileName: 'BV1xx411c7mD.mp4',
          ),
        );

        expect(plan.backfill.map((b) => b.label), ['Bilibili']);
        expect(plan.proposedTitle, 'A Video');
        expect(plan.previewImageUrl, 'https://img.example.com/p.jpg');
      },
    );
  });
}
