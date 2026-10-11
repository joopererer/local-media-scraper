import 'package:path/path.dart' as p;
import 'scraper.dart';

/// Scrapes metadata (code, year, episode, tags, studio, clean title) from filename patterns.
class FileNameScraper implements Scraper {
  @override
  String get id => 'filename';

  @override
  String get displayName => '文件名正则识别器';

  @override
  String get description => '从文件名中自动识别番号、年份、集数、括号标签及制作社';

  @override
  int get priority => 20;

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
    final name = input.fileName ?? input.resource.title;
    return name != null && name.trim().isNotEmpty;
  }

  @override
  Future<ScrapeResult> scrape(ScrapeInput input, ScrapeContext ctx) async {
    final rawName = input.fileName ?? input.resource.title ?? '';
    final stem = p.basenameWithoutExtension(rawName).trim();
    if (stem.isEmpty) {
      return const ScrapeResult();
    }

    final fields = <ProposedField>[];
    final tags = <ProposedTag>[];

    var workingTitle = stem;

    // 1. Extract bracketed tags & potential studio prefix: [Studio] or [Tag1, Tag2] or 【标签】
    final bracketRegex = RegExp(r'\[(.*?)\]|【(.*?)】');
    final bracketMatches = bracketRegex.allMatches(stem).toList();

    for (int i = 0; i < bracketMatches.length; i++) {
      final match = bracketMatches[i];
      final content = (match.group(1) ?? match.group(2) ?? '').trim();
      if (content.isEmpty) continue;

      // If it's the very first token at the beginning of filename, consider it Studio/Author
      if (i == 0 && match.start == 0 && !content.contains(',') && !content.contains('、')) {
        fields.add(
          ProposedField(
            key: 'studio',
            entityName: content,
            entityType: 'studio',
            confidence: 0.75,
            source: 'scraper:filename',
          ),
        );
      } else {
        // Split multiple tags inside brackets: [tag1, tag2] or [tag1/tag2]
        final subTags = content.split(RegExp(r'[,/、\s]+')).where((s) => s.isNotEmpty);
        for (final t in subTags) {
          // Avoid treating pure resolution like 1080p, 4k or video codec x264 as user tag
          if (_isTechnicalTag(t)) {
            fields.add(
              ProposedField(
                key: 'resolution',
                valueText: t,
                confidence: 0.9,
                source: 'scraper:filename',
              ),
            );
          } else {
            tags.add(
              ProposedTag(
                tagPath: [t],
                confidence: 0.8,
              ),
            );
          }
        }
      }
    }

    // Remove bracket matches from working title
    workingTitle = workingTitle.replaceAll(bracketRegex, ' ').trim();

    // 2. Extract番号 / Product Code (e.g. ABC-123, FC2-PPV-123456)
    final codeRegex = RegExp(r'\b([A-Za-z]{2,8}-\d{2,6})\b', caseSensitive: false);
    final codeMatch = codeRegex.firstMatch(workingTitle);
    if (codeMatch != null) {
      final code = codeMatch.group(1)!.toUpperCase();
      fields.add(
        ProposedField(
          key: 'code',
          valueText: code,
          confidence: 0.9,
          source: 'scraper:filename',
        ),
      );
      // Remove code from working title to obtain clean name
      workingTitle = workingTitle.replaceFirst(codeMatch.group(0)!, ' ').trim();
    }

    // 3. Extract Season / Episode (e.g. S01E05, EP03)
    final epRegex = RegExp(r'\b(S\d{1,2}E\d{1,2}|EP\d{1,4})\b', caseSensitive: false);
    final epMatch = epRegex.firstMatch(workingTitle);
    if (epMatch != null) {
      final ep = epMatch.group(1)!.toUpperCase();
      fields.add(
        ProposedField(
          key: 'episode',
          valueText: ep,
          confidence: 0.95,
          source: 'scraper:filename',
        ),
      );
      workingTitle = workingTitle.replaceFirst(epMatch.group(0)!, ' ').trim();
    }

    // 4. Extract Year: (2023) or 2023
    final yearRegex = RegExp(r'[\(\[\{]?(19\d{2}|20\d{2})[\)\]\}]?');
    final yearMatch = yearRegex.firstMatch(workingTitle);
    if (yearMatch != null) {
      final yearStr = yearMatch.group(1)!;
      final yearNum = double.tryParse(yearStr);
      if (yearNum != null) {
        fields.add(
          ProposedField(
            key: 'year',
            valueText: yearStr,
            valueNum: yearNum,
            confidence: 0.85,
            source: 'scraper:filename',
          ),
        );
      }
      workingTitle = workingTitle.replaceFirst(yearMatch.group(0)!, ' ').trim();
    }

    // 5. Clean up remaining title
    // Replace underscores/dots with spaces and collapse multiple spaces
    var cleanTitle = workingTitle
        .replaceAll(RegExp(r'[._]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // If cleaned title became empty or too short, keep stem
    if (cleanTitle.isEmpty || cleanTitle.length < 2) {
      cleanTitle = stem;
    }

    return ScrapeResult(
      fields: fields,
      tags: tags,
      proposedTitle: cleanTitle != stem ? cleanTitle : null,
    );
  }

  bool _isTechnicalTag(String token) {
    final lower = token.toLowerCase();
    const technical = {
      '1080p', '720p', '4k', '2k', '2160p', '480p',
      'x264', 'x265', 'h264', 'hevc', 'av1', 'aac',
      'mp4', 'mkv', 'flac', 'bdrip', 'web-dl', 'webrip',
    };
    return technical.contains(lower);
  }
}
