import 'dart:convert';
import 'package:http/http.dart' as http;
import 'scraper.dart';

/// Scrapes metadata (title, description, image, site_name, keywords) from a webpage URL.
class WebPageScraper implements Scraper {
  final http.Client _client;

  WebPageScraper({http.Client? client}) : _client = client ?? http.Client();

  @override
  String get id => 'web_page';

  @override
  String get displayName => '网页信息抓取器';

  @override
  String get description => '从网页 URL 抓取 OpenGraph 元数据、标题、简介与封面预览';

  @override
  int get priority => 10;

  @override
  List<String> get mediaTypes => const [];

  @override
  List<String> get targetSupertags => const [];

  @override
  RegExp? get patternRegex => null;

  @override
  List<String>? get supertagToBackfill => null;

  @override
  bool canHandle(ScrapeInput input) {
    final targetUrl = _getTargetUrl(input);
    if (targetUrl == null || targetUrl.isEmpty) return false;
    try {
      final uri = Uri.parse(targetUrl);
      return uri.scheme == 'http' || uri.scheme == 'https';
    } catch (_) {
      return false;
    }
  }

  @override
  Future<ScrapeResult> scrape(ScrapeInput input, ScrapeContext ctx) async {
    final targetUrl = _getTargetUrl(input);
    if (targetUrl == null) return const ScrapeResult();

    try {
      final uri = Uri.parse(targetUrl);
      ctx.log('WebPageScraper: fetching $targetUrl');

      final response = await _client.get(
        uri,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        ctx.log('WebPageScraper: HTTP error ${response.statusCode}');
        return const ScrapeResult();
      }

      // Try decoding body using utf-8 with fallback
      String html;
      try {
        html = utf8.decode(response.bodyBytes);
      } catch (_) {
        html = response.body;
      }

      return parseHtmlMetadata(html, baseUrl: uri);
    } catch (e) {
      ctx.log('WebPageScraper failed: $e');
      return const ScrapeResult();
    }
  }

  /// Parses OpenGraph, standard meta tags, and title from HTML string.
  ScrapeResult parseHtmlMetadata(String html, {Uri? baseUrl}) {
    String? ogTitle;
    String? titleTag;
    String? ogDescription;
    String? metaDescription;
    String? ogImage;
    String? ogSiteName;
    String? author;
    String? keywords;

    // 1. <title> tag
    final titleRegex = RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true);
    final titleMatch = titleRegex.firstMatch(html);
    if (titleMatch != null) {
      titleTag = _decodeHtmlEntities(titleMatch.group(1)!.trim());
    }

    // 2. Meta tags
    final metaRegex = RegExp(r'<meta\s+([^>]+)>', caseSensitive: false);
    for (final match in metaRegex.allMatches(html)) {
      final attrs = match.group(1)!;

      final property = _extractAttribute(attrs, 'property') ?? _extractAttribute(attrs, 'name');
      final content = _extractAttribute(attrs, 'content');

      if (property == null || content == null) continue;
      final propLower = property.toLowerCase();
      final val = _decodeHtmlEntities(content.trim());

      if (propLower == 'og:title') {
        ogTitle = val;
      } else if (propLower == 'og:description') {
        ogDescription = val;
      } else if (propLower == 'description') {
        metaDescription = val;
      } else if (propLower == 'og:image') {
        ogImage = val;
      } else if (propLower == 'og:site_name') {
        ogSiteName = val;
      } else if (propLower == 'author') {
        author = val;
      } else if (propLower == 'keywords') {
        keywords = val;
      }
    }

    // Combine results
    final proposedTitle = ogTitle ?? titleTag;
    final description = ogDescription ?? metaDescription;

    // Resolve relative og:image URL if needed
    if (ogImage != null && baseUrl != null && !ogImage.startsWith('http')) {
      try {
        ogImage = baseUrl.resolve(ogImage).toString();
      } catch (_) {}
    }

    final fields = <ProposedField>[];
    if (description != null && description.isNotEmpty) {
      fields.add(
        ProposedField(
          key: 'description',
          valueText: description,
          confidence: 0.85,
          source: 'scraper:web_page',
        ),
      );
    }

    if (ogSiteName != null && ogSiteName.isNotEmpty) {
      fields.add(
        ProposedField(
          key: 'site_name',
          valueText: ogSiteName,
          confidence: 0.9,
          source: 'scraper:web_page',
        ),
      );
    }

    if (author != null && author.isNotEmpty) {
      fields.add(
        ProposedField(
          key: 'author',
          entityName: author,
          entityType: 'author',
          confidence: 0.85,
          source: 'scraper:web_page',
        ),
      );
    }

    final tags = <ProposedTag>[];
    if (keywords != null && keywords.isNotEmpty) {
      final subKeywords = keywords.split(RegExp(r'[,;、]+')).where((s) => s.trim().isNotEmpty);
      for (final kw in subKeywords) {
        final trimmed = kw.trim();
        if (trimmed.length >= 2 && trimmed.length <= 30) {
          tags.add(ProposedTag(tagPath: [trimmed], confidence: 0.7));
        }
      }
    }

    return ScrapeResult(
      proposedTitle: proposedTitle,
      previewImageUrl: ogImage,
      fields: fields,
      tags: tags,
    );
  }

  String? _getTargetUrl(ScrapeInput input) {
    if (input.sourceUrl != null && input.sourceUrl!.isNotEmpty) {
      return input.sourceUrl;
    }
    if (input.resource.uri != null && input.resource.uri!.isNotEmpty) {
      return input.resource.uri;
    }
    return null;
  }

  String? _extractAttribute(String tagAttrs, String attrName) {
    final pattern = RegExp('$attrName\\s*=\\s*(["\'])(.*?)\\1', caseSensitive: false);
    final match = pattern.firstMatch(tagAttrs);
    return match?.group(2);
  }

  String _decodeHtmlEntities(String text) {
    return text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ');
  }
}
