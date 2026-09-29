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
  List<String> get targetSupertags => const ['番号', 'JAV', 'AV', 'Adult'];

  @override
  RegExp? get patternRegex => RegExp(
        r'\b([a-zA-Z]{2,6})[-_]?(\d{2,5})\b|(fc2[-_]?ppv[-_]?\d{5,8})',
        caseSensitive: false,
      );

  @override
  List<String>? get supertagToBackfill => const ['番号', 'JAV'];

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
        key: 'jav_code',
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

    final tags = <ProposedTag>[
      const ProposedTag(tagPath: ['番号'], confidence: 1.0),
      const ProposedTag(tagPath: ['番号', 'JAV'], confidence: 0.95),
      ProposedTag(tagPath: ['片商', studio], confidence: 0.9),
    ];

    // If an online URL is provided or web scraping is enabled
    if (url.contains('javbus.com') || url.contains('javdb.com')) {
      try {
        final resp = await client.get(
          Uri.parse(url),
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          },
        ).timeout(const Duration(seconds: 10));

        if (resp.statusCode == 200) {
          final parsed = parseJavHtml(resp.body, code: code);
          return ScrapeResult(
            proposedTitle: parsed.proposedTitle ?? '$code [${parsed.fields.where((f) => f.key == 'actress').map((f) => f.valueText).join(' ')}]',
            previewImageUrl: parsed.previewImageUrl,
            fields: [...fields, ...parsed.fields],
            tags: [...tags, ...parsed.tags],
          );
        }
      } catch (e) {
        ctx.log('Jav online scrape error: $e');
      }
    }

    // Try to extract potential actress name from filename if enclosed in brackets
    // e.g. "SSIS-001 [三上悠亜].mp4" or "SSIS-001 三上悠亚"
    final actressMatch = RegExp(r'[\[\(\s]([^\x00-\x7F]{2,8})[\]\)\s\.]').firstMatch(fn);
    if (actressMatch != null) {
      final potentialActress = actressMatch.group(1)!.trim();
      // Filter out non-names like 1080p, 高清, 中文字幕
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
          tagPath: ['女优', potentialActress],
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
    final coverMatch = RegExp(r'<a class="bigImage" href="([^"]+)"').firstMatch(html);
    if (coverMatch != null) {
      coverUrl = coverMatch.group(1);
    }

    final fields = <ProposedField>[];
    final tags = <ProposedTag>[];

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
        tagPath: ['女优', actress],
        confidence: 0.95,
      ));
    }

    // Release date
    final dateMatch = RegExp(r'<span class="header">发行时间:<\/span>\s*([0-9\-]{8,10})').firstMatch(html);
    if (dateMatch != null) {
      fields.add(ProposedField(
        key: 'release_date',
        valueText: dateMatch.group(1)!.trim(),
        source: 'scraper:jav',
        confidence: 0.95,
      ));
    }

    return ScrapeResult(
      proposedTitle: title ?? code,
      previewImageUrl: coverUrl,
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
