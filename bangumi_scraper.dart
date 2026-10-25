import 'dart:convert';
import 'package:http/http.dart' as http;

import 'scraper.dart';

/// Scraper for Bangumi (番组计划, bgm.tv) anime, manga, and game metadata.
class BangumiScraper implements Scraper {
  final http.Client? _client;

  BangumiScraper({http.Client? client}) : _client = client;

  @override
  String get id => 'bangumi';

  @override
  String get displayName => 'Bangumi 番组计划';

  @override
  String get description => '二次元动画、漫画与轻小说元数据刮削 (提取日文原名、中文名、制作公司与声优)';

  @override
  int get priority => 85;

  @override
  List<String> get mediaTypes => const [];

  @override
  List<String> get targetSupertags => const ['番剧', 'Anime', '动画', '漫画', 'Manga', 'ACG']; // i18n:ignore 数据库标识符

  @override
  RegExp? get patternRegex => RegExp(
        r'(?:bgm\.tv|bangumi\.tv)/subject/(\d+)',
        caseSensitive: false,
      );

  @override
  List<String>? get supertagToBackfill => const ['番剧']; // i18n:ignore 数据库标识符

  @override
  bool canHandle(ScrapeInput input) {
    // 1. Matches Bangumi URL
    final url = input.sourceUrl ?? input.subject.uri ?? '';
    if (url.isNotEmpty && patternRegex!.hasMatch(url)) return true;

    // 2. Resource has matching Supertags
    final tags = input.existingTagNames;
    if (targetSupertags.any((st) => tags.contains(st.toLowerCase()))) {
      return true;
    }

    // 3. Filename indicates anime episode pattern (e.g. [Nekomoe] Frieren - 01 [1080p].mp4)
    final fn = input.fileName ?? input.subject.title ?? '';
    return fn.toLowerCase().contains('bangumi') ||
        RegExp(r'\[(?:bangumi|bgm)[:\-](\d+)\]', caseSensitive: false).hasMatch(fn) ||
        RegExp(r'\[[a-zA-Z0-9_\u4e00-\u9fa5]+\]\s*([^-\[]+)\s*-\s*\d{1,3}', caseSensitive: false).hasMatch(fn);
  }

  @override
  Future<ScrapeResult> scrape(ScrapeInput input, ScrapeContext ctx) async {
    final client = ctx.client ?? _client ?? http.Client();
    final url = input.sourceUrl ?? input.subject.uri ?? '';

    String? subjectId;
    final urlMatch = patternRegex?.firstMatch(url);
    if (urlMatch != null) {
      subjectId = urlMatch.group(1);
    } else {
      final fn = input.fileName ?? input.subject.title ?? '';
      final bgmMatch = RegExp(r'\[(?:bangumi|bgm)[:\-](\d+)\]', caseSensitive: false).firstMatch(fn);
      if (bgmMatch != null) {
        subjectId = bgmMatch.group(1);
      }
    }

    if (subjectId != null) {
      // Use Bangumi public v0 API
      final apiUrl = 'https://api.bgm.tv/v0/subjects/$subjectId';
      try {
        ctx.log('Bangumi: fetching API for subject $subjectId');
        final resp = await client.get(
          Uri.parse(apiUrl),
          headers: {
            'User-Agent': 'FileOrganizer/2.0 (desktop app)',
            'Accept': 'application/json',
          },
        ).timeout(const Duration(seconds: 10));

        if (resp.statusCode == 200) {
          final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
          return parseBangumiJson(data);
        }
      } catch (e) {
        ctx.log('Bangumi API request failed: $e');
      }
    }

    // Parse from anime filename pattern (e.g. "[Sub] Bocchi the Rock! - 01 [1080p]")
    final fn = input.fileName ?? input.subject.title ?? '';
    final episodeMatch = RegExp(r'\[[^\]]+\]\s*([^-\[]+)\s*-\s*(\d{1,3})', caseSensitive: false).firstMatch(fn);
    if (episodeMatch != null) {
      final animeTitle = episodeMatch.group(1)!.trim();
      final epNum = episodeMatch.group(2)!.trim();

      return ScrapeResult(
        proposedTitle: '$animeTitle 第$epNum话',
        fields: [
          ProposedField(
            key: 'anime_title',
            valueText: animeTitle,
            entityName: animeTitle,
            entityType: 'work',
            source: 'scraper:bangumi:heuristic',
            confidence: 0.90,
          ),
          ProposedField(
            key: 'episode',
            valueText: epNum,
            valueNum: double.tryParse(epNum),
            source: 'scraper:bangumi:heuristic',
            confidence: 0.95,
          ),
        ],
        tags: const [
          ProposedTag(tagPath: ['ACG', '番剧'], confidence: 0.95), // i18n:ignore 数据库标识符
        ],
      );
    }

    return const ScrapeResult();
  }

  ScrapeResult parseBangumiJson(Map<String, dynamic> data) {
    final name = data['name'] as String?; // Japanese original
    final nameCn = data['name_cn'] as String?; // Chinese localized
    final summary = data['summary'] as String?;
    final date = data['date'] as String?;
    final score = (data['rating'] as Map<String, dynamic>?)?['score'] as num?;
    final images = data['images'] as Map<String, dynamic>?;
    final String? coverUrl = (images?['large'] as String?) ?? (images?['common'] as String?);

    final fields = <ProposedField>[];

    final effectiveTitle = (nameCn != null && nameCn.isNotEmpty) ? nameCn : name;

    if (name != null && name.isNotEmpty) {
      fields.add(ProposedField(
        key: 'japanese_title',
        valueText: name,
        source: 'scraper:bangumi',
        confidence: 1.0,
      ));
    }

    if (date != null && date.isNotEmpty) {
      fields.add(ProposedField(
        key: 'air_date',
        valueText: date,
        source: 'scraper:bangumi',
        confidence: 0.95,
      ));
    }

    if (score != null && score > 0) {
      fields.add(ProposedField(
        key: 'bangumi_rating',
        valueNum: score.toDouble(),
        valueText: score.toStringAsFixed(1),
        source: 'scraper:bangumi',
        confidence: 0.95,
      ));
    }

    if (summary != null && summary.trim().isNotEmpty) {
      fields.add(ProposedField(
        key: 'summary',
        valueText: summary.trim(),
        source: 'scraper:bangumi',
        confidence: 0.90,
      ));
    }

    // Tags
    final tags = <ProposedTag>[
      const ProposedTag(tagPath: ['ACG', '番剧'], confidence: 0.95), // i18n:ignore 数据库标识符
    ];
    final tagList = data['tags'] as List<dynamic>? ?? const [];
    for (final t in tagList.take(5)) {
      final tname = t['name'] as String?;
      if (tname != null && tname.isNotEmpty) {
        tags.add(ProposedTag(tagPath: ['ACG', tname], confidence: 0.85));
      }
    }

    return ScrapeResult(
      proposedTitle: effectiveTitle,
      previewImageUrl: coverUrl,
      fields: fields,
      tags: tags,
    );
  }
}