import 'package:http/http.dart' as http;

import 'scraper.dart';

/// Scraper for Douban (豆瓣) Movie, Book, and Music metadata.
class DoubanScraper implements Scraper {
  final http.Client? _client;

  DoubanScraper({http.Client? client}) : _client = client;

  @override
  String get id => 'douban';

  @override
  String get displayName => '豆瓣 (Douban)';

  @override
  String get description => '中文影视与图书元数据刮削 (提取译名、演职员/作者、豆瓣评分与海报)';

  @override
  int get priority => 85;

  @override
  List<String> get targetSupertags => const ['电影', 'Movie', '图书', '书籍', 'Book'];

  @override
  RegExp? get patternRegex => RegExp(
        r'douban\.com/subject/(\d+)',
        caseSensitive: false,
      );

  @override
  List<String>? get supertagToBackfill => const ['电影'];

  @override
  bool canHandle(ScrapeInput input) {
    // 1. Matches Douban URL
    final url = input.sourceUrl ?? input.resource.uri ?? '';
    if (url.isNotEmpty && patternRegex!.hasMatch(url)) return true;

    // 2. Resource has matching Supertags
    final tags = input.existingTagNames;
    if (targetSupertags.any((st) => tags.contains(st.toLowerCase()))) {
      return true;
    }

    // 3. Filename or title contains 'douban' or a douban ID tag
    final fn = input.fileName ?? input.resource.title ?? '';
    return fn.toLowerCase().contains('douban') || RegExp(r'\[(?:douban|db)[:\-](\d+)\]', caseSensitive: false).hasMatch(fn);
  }

  @override
  Future<ScrapeResult> scrape(ScrapeInput input, ScrapeContext ctx) async {
    final client = ctx.client ?? _client ?? http.Client();
    final url = input.sourceUrl ?? input.resource.uri ?? '';

    String? subjectId;
    final urlMatch = patternRegex?.firstMatch(url);
    if (urlMatch != null) {
      subjectId = urlMatch.group(1);
    } else {
      final fn = input.fileName ?? input.resource.title ?? '';
      final dbIdMatch = RegExp(r'\[(?:douban|db)[:\-](\d+)\]', caseSensitive: false).firstMatch(fn);
      if (dbIdMatch != null) {
        subjectId = dbIdMatch.group(1);
      }
    }

    if (subjectId != null) {
      final targetUrl = 'https://movie.douban.com/subject/$subjectId/';
      try {
        ctx.log('Douban: fetching subject $subjectId');
        final resp = await client.get(
          Uri.parse(targetUrl),
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          },
        ).timeout(const Duration(seconds: 10));

        if (resp.statusCode == 200) {
          return parseDoubanHtml(resp.body, subjectId: subjectId);
        }
      } catch (e) {
        ctx.log('Douban request failed: $e');
      }
    }

    // Heuristic fallback from filename
    final fn = input.fileName ?? input.resource.title ?? '';
    final clean = fn.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), '').trim();
    if (clean.isNotEmpty) {
      return ScrapeResult(
        proposedTitle: clean,
        tags: const [
          ProposedTag(tagPath: ['豆瓣'], confidence: 0.8),
        ],
      );
    }

    return const ScrapeResult();
  }

  ScrapeResult parseDoubanHtml(String html, {required String subjectId}) {
    // 1. Title
    String? title;
    final titleMatch = RegExp(r'<span property="v:itemreviewed">(.*?)</span>').firstMatch(html);
    if (titleMatch != null) {
      title = titleMatch.group(1)!.trim();
    }

    // 2. Rating
    double? rating;
    final ratingMatch = RegExp(r'<strong class="ll rating_num" property="v:average">(.*?)</strong>').firstMatch(html);
    if (ratingMatch != null) {
      rating = double.tryParse(ratingMatch.group(1)!.trim());
    }

    // 3. Director
    String? director;
    final dirMatch = RegExp(r'rel="v:directedBy">(.*?)</a>').firstMatch(html);
    if (dirMatch != null) {
      director = dirMatch.group(1)!.trim();
    }

    // 4. Summary
    String? summary;
    final summaryMatch = RegExp(r'<span property="v:summary"[^>]*>([\s\S]*?)</span>').firstMatch(html);
    if (summaryMatch != null) {
      summary = summaryMatch.group(1)!.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll('&nbsp;', ' ').trim();
    }

    // 5. Poster image
    String? posterUrl;
    final posterMatch = RegExp(r'<img src="(https://[^"]+doubanio\.com/[^"]+)" title="点击看更多海报"').firstMatch(html);
    if (posterMatch != null) {
      posterUrl = posterMatch.group(1);
    }

    // 6. Genres
    final genres = <String>[];
    final genreMatches = RegExp(r'<span property="v:genre">(.*?)</span>').allMatches(html);
    for (final m in genreMatches) {
      genres.add(m.group(1)!.trim());
    }

    final fields = <ProposedField>[
      ProposedField(
        key: 'douban_id',
        valueText: subjectId,
        source: 'scraper:douban',
        confidence: 1.0,
      ),
    ];

    if (director != null) {
      fields.add(ProposedField(
        key: 'director',
        valueText: director,
        entityName: director,
        entityType: 'director',
        source: 'scraper:douban',
        confidence: 0.95,
      ));
    }

    if (rating != null && rating > 0) {
      fields.add(ProposedField(
        key: 'douban_rating',
        valueNum: rating,
        valueText: rating.toStringAsFixed(1),
        source: 'scraper:douban',
        confidence: 0.95,
      ));
    }

    if (summary != null && summary.isNotEmpty) {
      fields.add(ProposedField(
        key: 'summary',
        valueText: summary,
        source: 'scraper:douban',
        confidence: 0.90,
      ));
    }

    final tags = <ProposedTag>[
      const ProposedTag(tagPath: ['影视'], confidence: 0.9),
    ];
    for (final g in genres) {
      tags.add(ProposedTag(tagPath: ['影视', g], confidence: 0.9));
    }

    return ScrapeResult(
      proposedTitle: title,
      previewImageUrl: posterUrl,
      fields: fields,
      tags: tags,
    );
  }
}
