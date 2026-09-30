import 'dart:convert';
import 'package:http/http.dart' as http;

import 'scraper.dart';

/// Scraper for adult video (JAV) metadata, identifying standard designation codes
/// (e.g. SSIS-001, IPX-123, FC2-PPV-1234567), studios/makers, and actresses.
class JavScraper implements Scraper {
  final http.Client? _client;

  JavScraper({http.Client? client}) : _client = client;

  @override
  String get id => 'jav';

  @override
  String get displayName => '番号刮削 (JAV)';

  @override
  String get description => '识别番号编码(如 SSIS-001, IPX-123)、片商厂牌、女优与发行信息';

  @override
  int get priority => 80;

  @override
  List<String> get targetSupertags => const ['JAV', 'AV', 'Adult'];

  @override
  RegExp? get patternRegex => RegExp(
        r'\b([a-zA-Z]{2,6})[-_]?(\d{2,5})\b|(fc2[-_]?ppv[-_]?\d{5,8})',
        caseSensitive: false,
      );

  @override
  List<String>? get supertagToBackfill => const ['JAV'];

  /// Known Japanese adult video studios / labels mapped from prefix.
  static const Map<String, String> _knownStudios = {
    'SSIS': 'S1 NO.1 STYLE',
    'SSNI': 'S1 NO.1 STYLE',
    'SNIS': 'S1 NO.1 STYLE',
    'OFJE': 'S1 NO.1 STYLE',
    'TEK': 'S1 NO.1 STYLE',
    'IPX': 'IdeaPocket',
    'IPZ': 'IdeaPocket',
    'IPTD': 'IdeaPocket',
    'STAR': 'SOD Create',
    'SDDE': 'SOD Create',
    'MIDE': 'MOODYZ',
    'MIGD': 'MOODYZ',
    'MIAD': 'MOODYZ',
    'MIMK': 'MOODYZ',
    'PRED': 'PRESTIGE',
    'ABP': 'PRESTIGE',
    'WANZ': 'WANZ FACTORY',
    'ATID': 'Attackers',
    'SHKD': 'Attackers',
    'DASD': 'DAS!',
    'EBOD': 'E-BODY',
    'JUFE': 'Fitch',
    'CAWD': 'Kawaii*',
    'KAWD': 'Kawaii*',
    'FSDSS': 'FALENO',
    'MIDV': 'MOODYZ',
    'JUL': 'Madonna',
    'JUY': 'Madonna',
    'DANDY': 'Dandy',
  };

  @override
  bool canHandle(ScrapeInput input) {
    // 1. Check existing supertags
    final tags = input.existingTagNames;
    if (targetSupertags.any((st) => tags.contains(st.toLowerCase()))) {
      return true;
    }

    // 2. Check sourceUrl or resource.uri
    final url = input.sourceUrl ?? input.resource.uri ?? '';
    if (url.isNotEmpty &&
        (url.contains('javbus') ||
            url.contains('javdb') ||
            url.contains('dmm.co.jp') ||
            patternRegex!.hasMatch(url))) {
      return true;
    }

    // 3. Check filename or title for designation code
    final fn = input.fileName ?? input.resource.title ?? '';
    return patternRegex!.hasMatch(fn);
  }

  @override
  Future<ScrapeResult> scrape(ScrapeInput input, ScrapeContext ctx) async {
    final client = ctx.client ?? _client ?? http.Client();
    final fn = input.fileName ?? input.resource.title ?? '';
    final url = input.sourceUrl ?? input.resource.uri ?? '';

    // 1. Extract designation code
    final code = extractJavCode(fn.isNotEmpty ? fn : url);
    if (code == null) {
      return const ScrapeResult();
    }

    ctx.log('JavScraper: detected code $code');

    // 2. Determine Maker / Studio
    final prefix = code.split('-').first.toUpperCase();
    final studio = _knownStudios[prefix] ?? (code.startsWith('FC2') ? 'FC2' : prefix);

    final fields = <ProposedField>[
      ProposedField(
        key: 'code',
        valueText: code,
        source: 'scraper:jav',
        confidence: 1.0,
      ),
      ProposedField(
        key: 'studio',
        valueText: studio,
        entityName: studio,
        entityType: 'studio',
        source: 'scraper:jav',
        confidence: _knownStudios.containsKey(prefix) ? 0.95 : 0.7,
      ),
    ];

    // Extract year from filename (e.g. "SSIS-001 2023" or "[2023]")
    final yearMatch = RegExp(r'(?:^|[\s\[\(])(?:20[0-2]\d|19[89]\d)(?:$|[\s\]\)])').firstMatch(fn);
    if (yearMatch != null) {
      final year = RegExp(r'\d{4}').firstMatch(yearMatch.group(0)!)!.group(0)!;
      fields.add(ProposedField(
        key: 'year',
        valueText: year,
        valueNum: double.tryParse(year),
        source: 'scraper:jav',
        confidence: 0.85,
      ));
    }

    final tags = <ProposedTag>[
      const ProposedTag(tagPath: ['JAV'], confidence: 1.0),
      ProposedTag(tagPath: ['JAV', '片商', studio], confidence: 0.9),
    ];

    // Online fetch target URL: if explicit URL was given use it; otherwise probe JavBus, then JavDB fallback
    final customBase = ctx.getConfig('javbus_base_url')?.trim();
    final javbusBase = (customBase != null && customBase.isNotEmpty)
        ? customBase.replaceAll(RegExp(r'/+$'), '')
        : 'https://www.javbus.com';

    // 1. Try JavBus
    String targetUrl = url.contains('javbus.com') ? url : '$javbusBase/$code';
    try {
      ctx.log('JavScraper: online probe JavBus $targetUrl');
      final resp = await client.get(
        Uri.parse(targetUrl),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Cookie': 'existmag=all; age=verified',
        },
      ).timeout(const Duration(seconds: 8));

      final bodyString = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (resp.statusCode == 200 && !bodyString.contains('Age Verification JavBus')) {
        final parsed = parseJavHtml(bodyString, code: code);
        final actressNames = parsed.fields
            .where((f) => f.key == 'actress')
            .map((f) => f.valueText)
            .whereType<String>()
            .join(' ');
        final composedTitle = actressNames.isNotEmpty
            ? '$code [$actressNames]'
            : (parsed.proposedTitle ?? code);

        return ScrapeResult(
          proposedTitle: composedTitle,
          previewImageUrl: parsed.previewImageUrl,
          fields: [...fields, ...parsed.fields],
          tags: [...tags, ...parsed.tags],
        );
      } else {
        ctx.log('JavScraper: JavBus returned ${resp.statusCode} or Age Verification redirect');
      }
    } catch (e) {
      ctx.log('JavScraper: JavBus probe failed ($e)');
    }

    // 2. Cascade fallback to JavDB
    try {
      final javdbSearchUrl = 'https://javdb.com/search?q=${Uri.encodeComponent(code)}&f=all';
      ctx.log('JavScraper: cascade fallback to JavDB $javdbSearchUrl');
      final dbResp = await client.get(
        Uri.parse(javdbSearchUrl),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Cookie': 'over18=1',
        },
      ).timeout(const Duration(seconds: 8));

      if (dbResp.statusCode == 200) {
        final dbBodyString = utf8.decode(dbResp.bodyBytes, allowMalformed: true);
        final parsed = parseJavDbSearchHtml(dbBodyString, code: code);
        if (parsed != null) {
          ctx.log('JavScraper: successfully parsed metadata from JavDB');
          final actressNames = parsed.fields
              .where((f) => f.key == 'actress')
              .map((f) => f.valueText)
              .whereType<String>()
              .join(' ');
          final composedTitle = actressNames.isNotEmpty
              ? '$code [$actressNames]'
              : (parsed.proposedTitle ?? code);

          return ScrapeResult(
            proposedTitle: composedTitle,
            previewImageUrl: parsed.previewImageUrl,
            fields: [...fields, ...parsed.fields],
            tags: [...tags, ...parsed.tags],
          );
        }
      }
    } catch (e) {
      ctx.log('JavScraper: JavDB probe failed ($e)');
    }

    // 3. Fallback to local filename actress pattern
    final actressMatch = RegExp(r'[\[\(\s]([^\x00-\x7F]{2,8})[\]\)\s\.]').firstMatch(fn);
    if (actressMatch != null) {
      final potentialActress = actressMatch.group(1)!.trim();
      if (!['高清', '中文字幕', '字幕', '无码', '破解'].contains(potentialActress)) {
        fields.add(ProposedField(
          key: 'actress',
          valueText: potentialActress,
          entityName: potentialActress,
          entityType: 'actress',
          source: 'scraper:jav',
          confidence: 0.8,
        ));
        tags.add(ProposedTag(
          tagPath: ['JAV', '女优', potentialActress],
          confidence: 0.8,
        ));
      }
    }

    return ScrapeResult(
      proposedTitle: code,
      fields: fields,
      tags: tags,
    );
  }

  /// Parses JAV web page HTML (e.g. JavBus or compatible mirrors)
  ScrapeResult parseJavHtml(String html, {required String code}) {
    String? title;
    final titleMatch = RegExp(r'<title>(.*?)<\/title>', caseSensitive: false).firstMatch(html);
    if (titleMatch != null) {
      title = titleMatch.group(1)!.replaceAll('- JavBus', '').trim();
    }

    String? coverUrl;
    final coverMatch = RegExp(r'<a class="bigImage" href="([^"]+)"').firstMatch(html) ??
        RegExp(r'<meta property="og:image" content="([^"]+)"', caseSensitive: false).firstMatch(html) ??
        RegExp(r'<img[^>]*class="[^"]*cover[^"]*"[^>]*src="([^"]+)"').firstMatch(html) ??
        RegExp(r'<img[^>]*src="([^"]*cover[^"]*)"').firstMatch(html);
    if (coverMatch != null) {
      coverUrl = coverMatch.group(1);
      if (coverUrl != null) {
        if (coverUrl.startsWith('//')) {
          coverUrl = 'https:$coverUrl';
        } else if (coverUrl.startsWith('/')) {
          coverUrl = 'https://www.javbus.com$coverUrl';
        }
      }
    }

    final fields = <ProposedField>[];
    final tags = <ProposedTag>[];

    if (title != null && title.isNotEmpty) {
      fields.add(ProposedField(
        key: 'title',
        valueText: title,
        source: 'scraper:jav',
        confidence: 0.95,
      ));
    }

    // Actresses
    final actressMatches = RegExp(r'<span class="genre"><a href="[^"]*star[^"]*">([^<]+)<\/a><\/span>').allMatches(html);
    for (final m in actressMatches) {
      final actress = m.group(1)!.trim();
      fields.add(ProposedField(
        key: 'actress',
        valueText: actress,
        entityName: actress,
        entityType: 'actress',
        source: 'scraper:jav',
        confidence: 0.95,
      ));
      tags.add(ProposedTag(
        tagPath: ['JAV', '女优', actress],
        confidence: 0.95,
      ));
    }

    // Release year (discard full release_date, only keep year)
    final dateMatch = RegExp(r'<span class="header">发行时间:<\/span>\s*([0-9\-]{8,10})').firstMatch(html);
    if (dateMatch != null) {
      final releaseDate = dateMatch.group(1)!.trim();
      final yearStr = releaseDate.split('-').first;
      if (yearStr.length == 4) {
        fields.add(ProposedField(
          key: 'year',
          valueText: yearStr,
          valueNum: double.tryParse(yearStr),
          source: 'scraper:jav',
          confidence: 0.95,
        ));
      }
    }

    return ScrapeResult(
      proposedTitle: title ?? code,
      previewImageUrl: coverUrl,
      fields: fields,
      tags: tags,
    );
  }

  /// Parses JavDB search results HTML and extracts matching item
  ScrapeResult? parseJavDbSearchHtml(String html, {required String code}) {
    final cleanCode = code.toUpperCase();

    // Check if whole HTML contains code
    if (!html.toUpperCase().contains(cleanCode)) return null;

    // Extract title (containing code)
    final titleMatch = RegExp(r'class="video-title"[^>]*>(.*?)<\/div>', dotAll: true).firstMatch(html) ??
        RegExp(r'title="([^"]*' + RegExp.escape(code) + r'[^"]*)"', caseSensitive: false).firstMatch(html) ??
        RegExp(r'title="([^"]+)"').firstMatch(html);

    String title = titleMatch != null
        ? titleMatch.group(1)!.replaceAll(RegExp(r'<[^>]*>'), '').trim()
        : '';

    // Extract cover image
    final imgMatch = RegExp(r'<img[^>]*src="([^"]*jdbstatic[^"]*covers[^"]*)"').firstMatch(html) ??
        RegExp(r'<img[^>]*src="([^"]+)"').firstMatch(html);
    final cover = imgMatch?.group(1);

      final fields = <ProposedField>[];
      final tags = <ProposedTag>[];

      if (title.isNotEmpty) {
        fields.add(ProposedField(
          key: 'title',
          valueText: title,
          source: 'scraper:jav:javdb',
          confidence: 0.9,
        ));
      }

      // Extract actress: last token from title
      final parts = title.split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        final lastToken = parts.last.trim();
        if (RegExp(r'^[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff]{2,8}$').hasMatch(lastToken)) {
          fields.add(ProposedField(
            key: 'actress',
            valueText: lastToken,
            entityName: lastToken,
            entityType: 'actress',
            source: 'scraper:jav:javdb',
            confidence: 0.9,
          ));
          tags.add(ProposedTag(
            tagPath: ['JAV', '女优', lastToken],
            confidence: 0.9,
          ));
        }
      }

      // Extract year if present in html
      final dateMatch = RegExp(r'(\d{4}-\d{2}-\d{2})').firstMatch(html);
      if (dateMatch != null) {
        final releaseDate = dateMatch.group(1)!;
        final yearStr = releaseDate.split('-').first;
        fields.add(ProposedField(
          key: 'year',
          valueText: yearStr,
          valueNum: double.tryParse(yearStr),
          source: 'scraper:jav:javdb',
          confidence: 0.9,
        ));
      }

      return ScrapeResult(
        proposedTitle: title.isNotEmpty ? '$code $title' : code,
        previewImageUrl: cover,
        fields: fields,
        tags: tags,
      );
  }

  /// Extracts and formats designation code to standard uppercase with hyphen: e.g. `SSIS-001`.
  static String? extractJavCode(String text) {
    // 1. FC2 PPV
    final fc2Match = RegExp(r'fc2[-_]?ppv[-_]?(\d{5,8})', caseSensitive: false).firstMatch(text);
    if (fc2Match != null) {
      return 'FC2-PPV-${fc2Match.group(1)}';
    }

    // 2. Standard Letter-Digits code
    final stdMatch = RegExp(r'\b([a-zA-Z]{2,6})[-_]?(\d{2,5})\b').firstMatch(text);
    if (stdMatch != null) {
      final letters = stdMatch.group(1)!.toUpperCase();
      final digits = stdMatch.group(2)!;
      // Filter out common false positives like "MP4-1080", "PART-01", "DISC-1"
      if (['MP', 'PART', 'DISC', 'EP', 'CH', 'VOL'].contains(letters)) {
        return null;
      }
      return '$letters-$digits';
    }

    return null;
  }
}
