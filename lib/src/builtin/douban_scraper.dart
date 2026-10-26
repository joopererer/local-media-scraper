import 'dart:convert';

import 'package:http/http.dart' as http;

import '../media_type.dart';
import '../scraper.dart';

/// Scraper for Douban (豆瓣) Movie, TV, Book, and Music metadata.
///
/// Two entry points:
/// - subject id known (URL or an explicit `[douban:1234567]` tag) -> fetch that
///   subject directly;
/// - otherwise search by the file/title name, then fetch the winner.
///
/// Details come from Douban's mobile "rexxar" JSON API rather than the HTML
/// page: the desktop pages answer HTTP 200 with a JS anti-bot shell, so regex
/// extraction silently returns nothing. The HTML parser stays as a fallback.
class DoubanScraper implements Scraper {
  final http.Client? _client;

  DoubanScraper({http.Client? client}) : _client = client;

  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// Extensions that should be looked up as books rather than films.
  static const Set<String> _ebookExtensions = {
    'pdf',
    'epub',
    'mobi',
    'azw3',
    'azw',
    'djvu',
    'fb2',
    'cbz',
    'cbr',
    'txt',
    'md',
  };

  @override
  String get id => 'douban';

  @override
  String get displayName => '豆瓣 (Douban)';

  @override
  String get description => '中文影视与图书元数据刮削 (提取译名、演职员/作者、豆瓣评分与海报)';

  @override
  int get priority => 85;

  @override
  List<String> get mediaTypes => const [];

  @override
  List<String> get targetSupertags => const [
    '电影',
    'Movie',
    '影视',
    '图书',
    '书籍',
    'Book',
  ]; // i18n:ignore 数据库标识符

  @override
  RegExp? get patternRegex =>
      RegExp(r'douban\.com/(?:subject|movie|book)/(\d+)', caseSensitive: false);

  @override
  List<String>? get supertagToBackfill => const ['电影']; // i18n:ignore 数据库标识符

  @override
  bool canHandle(ScrapeInput input) {
    // 1. Points straight at a Douban subject
    final url = input.sourceUrl ?? input.subject.uri ?? '';
    if (url.isNotEmpty && patternRegex!.hasMatch(url)) return true;

    // 2. Carries a Douban supertag
    final tags = input.existingTagNames;
    if (targetSupertags.any((st) => tags.contains(st.toLowerCase()))) {
      return true;
    }

    // 3. Explicit id tag in the file name, or the name says douban
    final fn = input.fileName ?? input.subject.title ?? '';
    if (fn.toLowerCase().contains('douban')) return true;
    if (RegExp(
      r'\[(?:douban|db)[:\-](\d+)\]',
      caseSensitive: false,
    ).hasMatch(fn)) {
      return true;
    }

    // 4. Searchable by name: an ebook extension goes to book search, a video
    //    file with a usable name goes to film search.
    final query = searchQuery(input);
    if (!isSearchableName(query)) return false;
    if (isEbook(input)) return true;
    if ((input.subject.mediaType ?? MediaKind.video) != MediaKind.video) {
      return false;
    }
    return looksLikeFilm(input.fileName ?? input.subject.title ?? query);
  }

  /// Filters out camera dumps and placeholder names that would otherwise
  /// trigger a pointless network round-trip for every file in a library.
  static bool isSearchableName(String query) {
    final q = query.trim();
    if (q.length < 2) return false;
    if (RegExp(
      r'^(?:img|dsc|dscn|pic|photo|scan|shot|screenshot|video|untitled|'
      r'new|clip|mov|rec|gopr|dji)[\s_\-]*\d*$',
      caseSensitive: false,
    ).hasMatch(q)) {
      return false;
    }
    // Needs at least one word of 2+ letters or any CJK character.
    return RegExp(r'[A-Za-z]{2,}|[\u3400-\u9fff]').hasMatch(q);
  }

  /// True when the subject should be looked up as a book.
  bool isEbook(ScrapeInput input) {
    final mediaType = input.subject.mediaType?.toLowerCase();
    if (mediaType == MediaKind.document) return true;
    for (final path in [
      input.fileName ?? '',
      input.subject.uri ?? '',
      input.subject.title ?? '',
    ]) {
      if (path.isEmpty) continue;
      if (MediaKind.fromExtension(path) != MediaKind.document) continue;
      final ext = path.split('.').last.toLowerCase();
      if (_ebookExtensions.contains(ext)) return true;
    }
    return false;
  }

  /// Best-effort search phrase: file stem without tags, year, episode or
  /// release-group noise.
  static String searchQuery(ScrapeInput input) {
    var raw = input.fileName ?? input.subject.title ?? '';
    if (raw.trim().isEmpty && input.subject.uri != null) {
      raw = input.subject.uri!;
    }
    var s = raw.replaceAll(RegExp(r'\.[a-zA-Z0-9]{2,5}$'), '');
    final stem = s.trim();
    s = s.replaceAll(RegExp(r'\[[^\]]*\]|【[^】]*】'), ' ');
    s = s.replaceAll(RegExp(r'\([^)]*\)'), ' ');
    s = s.replaceAll(
      RegExp(
        r'\b(?:1080p|720p|2160p|480p|4k|8k|x264|x265|h264|h265|hevc|avc|aac|'
        r'bluray|blu-ray|bdrip|brrip|webrip|web-dl|hdrip|dvdrip|remux|hdr|'
        r'10bit|8bit|proper|repack|extended|internal)\b',
        caseSensitive: false,
      ),
      ' ',
    );
    s = s.replaceAll(RegExp(r'\b(?:19|20)\d{2}\b'), ' ');
    s = s.replaceAll(RegExp(r'[\s._\-]+'), ' ').trim();
    // "1917.mkv" / "2012.mkv": the whole name is a year, so keep the stem.
    if (s.isEmpty) return stem;
    return s;
  }

  /// Films are widely named like `Title.2010.1080p`, so a release year is a
  /// strong signal; anime episodes (`[Group] Show - 01`) go to Bangumi instead.
  static bool looksLikeFilm(String rawName) {
    final stem = rawName.replaceAll(RegExp(r'\.[a-zA-Z0-9]{2,5}$'), '').trim();
    if (RegExp(r'\[\s*\d{1,4}\s*\]\s*$').hasMatch(rawName)) return false;
    if (RegExp(
      r'[-_ ]\s*\d{1,4}(\s*\[|\s*$)',
      caseSensitive: false,
    ).hasMatch(stem)) {
      return false;
    }
    return RegExp(r'(?:19|20)\d{2}').hasMatch(stem) ||
        RegExp(r'[\u3400-\u9fff]').hasMatch(stem);
  }

  @override
  Future<ScrapeResult> scrape(ScrapeInput input, ScrapeContext ctx) async {
    final client = ctx.client ?? _client ?? http.Client();
    final url = input.sourceUrl ?? input.subject.uri ?? '';

    String? subjectId;
    String? searchKind; // movie | tv | book
    final urlMatch = patternRegex?.firstMatch(url);
    if (urlMatch != null) {
      subjectId = urlMatch.group(1);
      if (url.contains('/book/')) searchKind = 'book';
      if (url.contains('/tv/')) searchKind = 'tv';
    } else {
      final fn = input.fileName ?? input.subject.title ?? '';
      final idMatch = RegExp(
        r'\[(?:douban|db)[:\-](\d+)\]',
        caseSensitive: false,
      ).firstMatch(fn);
      if (idMatch != null) subjectId = idMatch.group(1);
    }

    final wantBook = searchKind == 'book' || isEbook(input);

    // 1. No id yet: search by name and take the best hit.
    if (subjectId == null) {
      final query = searchQuery(input);
      if (query.isEmpty) return const ScrapeResult();
      final hit = await _search(client, query, book: wantBook, ctx: ctx);
      if (hit == null) {
        ctx.log('Douban: no search hit for "$query"');
        return const ScrapeResult();
      }
      subjectId = hit.id;
      searchKind = hit.kind;
      ctx.log(
        'Douban: search "$query" -> ${hit.kind}/${hit.id} (${hit.title})',
      );
    }

    // 2. Fetch the subject itself (rexxar JSON first).
    final kind = searchKind ?? (wantBook ? 'book' : 'movie');
    final fromJson = await _fetchRexxar(client, kind, subjectId, ctx);
    if (fromJson != null) return fromJson;

    // `/movie/<tv-id>` answers 301 to `/tv/<id>` and http follows it, so this
    // also covers a subject whose type we guessed wrong.
    final otherKind = kind == 'book'
        ? null
        : (kind == 'movie' ? 'tv' : 'movie');
    if (otherKind != null) {
      final retry = await _fetchRexxar(client, otherKind, subjectId, ctx);
      if (retry != null) return retry;
    }

    // 3. Last resort: the desktop page (may be an anti-bot shell).
    final html = await _fetchText(
      client,
      'https://${kind == 'book' ? 'book' : 'movie'}.douban.com/subject/$subjectId/',
      ctx,
    );
    if (html != null && html.contains('v:itemreviewed')) {
      return parseDoubanHtml(html, subjectId: subjectId);
    }

    return ScrapeResult(
      fields: [
        ProposedField(
          key: 'douban_id',
          valueText: subjectId,
          source: 'scraper:douban',
          confidence: 1.0,
        ),
      ],
    );
  }

  Future<({String id, String kind, String title})?> _search(
    http.Client client,
    String query, {
    required bool book,
    required ScrapeContext ctx,
  }) async {
    final host = book ? 'book.douban.com' : 'movie.douban.com';
    final uri = Uri.parse(
      'https://$host/j/subject_suggest',
    ).replace(queryParameters: {'q': query});
    final body = await _fetchText(client, uri.toString(), ctx);
    if (body == null) return null;

    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (decoded is! List) return null;

    final lowerQuery = query.toLowerCase();
    Map<String, dynamic>? best;
    var bestScore = -1.0;
    for (final item in decoded) {
      if (item is! Map) continue;
      final id = item['id']?.toString();
      final title = (item['title'] ?? '').toString();
      if (id == null || id.isEmpty) continue;

      var score = 0.0;
      final lowerTitle = title.toLowerCase();
      if (lowerTitle == lowerQuery) {
        score += 10;
      } else if (lowerTitle.contains(lowerQuery)) {
        score += 6;
      } else if (lowerTitle.isNotEmpty && lowerQuery.contains(lowerTitle)) {
        score += 4;
      }
      final sub = (item['sub_title'] ?? '').toString().toLowerCase();
      if (sub.isNotEmpty && (sub == lowerQuery || sub.contains(lowerQuery))) {
        score += 3;
      }
      if ((item['year']?.toString() ?? '').isNotEmpty) score += 1;
      if (score > bestScore) {
        bestScore = score;
        best = Map<String, dynamic>.from(item);
      }
    }
    if (best == null || bestScore <= 0) return null;

    final rawType = (best['type'] ?? '').toString().toLowerCase();
    return (
      id: best['id'].toString(),
      kind: switch (rawType) {
        'b' || 'book' => 'book',
        'tv' => 'tv',
        _ => 'movie',
      },
      title: (best['title'] ?? '').toString(),
    );
  }

  Future<ScrapeResult?> _fetchRexxar(
    http.Client client,
    String kind,
    String subjectId,
    ScrapeContext ctx,
  ) async {
    final body = await _fetchText(
      client,
      'https://m.douban.com/rexxar/api/v2/$kind/$subjectId',
      ctx,
      headers: {
        'Referer': 'https://m.douban.com/',
        'Accept': 'application/json',
      },
    );
    if (body == null) return null;
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final map = Map<String, dynamic>.from(decoded);
    if (map['title'] == null) return null;
    return parseRexxarJson(map, kind: kind, subjectId: subjectId);
  }

  Future<String?> _fetchText(
    http.Client client,
    String url,
    ScrapeContext ctx, {
    Map<String, String>? headers,
  }) async {
    try {
      final resp = await client
          .get(
            Uri.parse(url),
            headers: {
              'User-Agent': _userAgent,
              'Accept-Language': 'zh-CN,zh;q=0.9',
              ...?headers,
            },
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode == 200) {
        return utf8.decode(resp.bodyBytes, allowMalformed: true);
      }
      ctx.log('Douban: HTTP ${resp.statusCode} for $url');
    } catch (e) {
      ctx.log('Douban request failed ($url): $e');
    }
    return null;
  }

  /// Builds a result from Douban's mobile JSON (shared by movie/tv/book).
  ScrapeResult parseRexxarJson(
    Map<String, dynamic> data, {
    required String kind,
    required String subjectId,
  }) {
    final title = data['title']?.toString().trim();
    final isBook = kind == 'book';

    String? cover;
    final pic = data['pic'];
    if (pic is String) {
      cover = pic;
    } else if (pic is Map) {
      cover =
          pic['large']?.toString() ??
          pic['normal']?.toString() ??
          pic['small']?.toString();
    }
    cover ??= data['cover_url']?.toString();
    if (cover != null && cover.trim().isEmpty) cover = null;

    final fields = <ProposedField>[
      ProposedField(
        key: 'douban_id',
        valueText: subjectId,
        source: 'scraper:douban',
        confidence: 1.0,
      ),
    ];

    final year = data['year']?.toString();
    if (year != null && year.isNotEmpty) {
      fields.add(
        ProposedField(
          key: 'year',
          valueText: year,
          valueNum: double.tryParse(year),
          source: 'scraper:douban',
          confidence: 0.9,
        ),
      );
    }

    final rating = (data['rating'] as Map?)?['value'];
    if (rating is num && rating > 0) {
      fields.add(
        ProposedField(
          key: 'douban_rating',
          valueNum: rating.toDouble(),
          valueText: rating.toStringAsFixed(1),
          source: 'scraper:douban',
          confidence: 0.95,
        ),
      );
    }

    void addPeople(String rawKey, String fieldKey, String entityType) {
      final list = data[rawKey];
      if (list is! List) return;
      for (final p in list.take(5)) {
        final name = p is Map ? p['name']?.toString().trim() : p?.toString();
        if (name == null || name.isEmpty) continue;
        fields.add(
          ProposedField(
            key: fieldKey,
            valueText: name,
            entityName: name,
            entityType: entityType,
            source: 'scraper:douban',
            confidence: 0.9,
          ),
        );
      }
    }

    if (isBook) {
      addPeople('author', 'author', 'person');
    } else {
      addPeople('directors', 'director', 'director');
      addPeople('actors', 'actress', 'person');
    }

    final intro = (data['intro'] ?? data['summary'])?.toString().trim();
    if (intro != null && intro.isNotEmpty) {
      fields.add(
        ProposedField(
          key: 'summary',
          valueText: intro,
          source: 'scraper:douban',
          confidence: 0.9,
        ),
      );
    }

    final originalTitle = data['original_title']?.toString().trim();
    if (originalTitle != null &&
        originalTitle.isNotEmpty &&
        originalTitle != title) {
      fields.add(
        ProposedField(
          key: 'original_title',
          valueText: originalTitle,
          source: 'scraper:douban',
          confidence: 0.9,
        ),
      );
    }

    // Genres / tags become tags under 影视 or 图书.
    final rootTag = isBook ? '图书' : '影视'; // i18n:ignore 数据库标识符
    final tags = <ProposedTag>[
      ProposedTag(tagPath: [rootTag], confidence: 0.9),
      const ProposedTag(tagPath: ['豆瓣'], confidence: 0.9), // i18n:ignore
    ];
    final genreList = data['genres'];
    if (genreList is List) {
      for (final g in genreList.take(5)) {
        final name = g?.toString().trim();
        if (name == null || name.isEmpty) continue;
        tags.add(ProposedTag(tagPath: [rootTag, name], confidence: 0.85));
      }
    }
    final tagList = data['tags'];
    if (tagList is List) {
      for (final t in tagList.take(5)) {
        final name = t is Map ? t['name']?.toString().trim() : t?.toString();
        if (name == null || name.isEmpty) continue;
        tags.add(ProposedTag(tagPath: [rootTag, name], confidence: 0.8));
      }
    }

    return ScrapeResult(
      proposedTitle: (title != null && title.isNotEmpty) ? title : null,
      previewImageUrl: cover,
      fields: fields,
      tags: tags,
    );
  }

  ScrapeResult parseDoubanHtml(String html, {required String subjectId}) {
    // 1. Title
    String? title;
    final titleMatch = RegExp(
      r'<span property="v:itemreviewed">(.*?)</span>',
    ).firstMatch(html);
    if (titleMatch != null) {
      title = titleMatch.group(1)!.trim();
    }

    // 2. Rating
    double? rating;
    final ratingMatch = RegExp(
      r'<strong class="ll rating_num" property="v:average">(.*?)</strong>',
    ).firstMatch(html);
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
    final summaryMatch = RegExp(
      r'<span property="v:summary"[^>]*>([\s\S]*?)</span>',
    ).firstMatch(html);
    if (summaryMatch != null) {
      summary = summaryMatch
          .group(1)!
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .replaceAll('&nbsp;', ' ')
          .trim();
    }

    // 5. Poster image
    String? posterUrl;
    final posterMatch = RegExp(
      r'<img src="(https://[^"]+doubanio\.com/[^"]+)" title="点击看更多海报"',
    ).firstMatch(html);
    if (posterMatch != null) {
      posterUrl = posterMatch.group(1);
    }

    // 6. Genres
    final genres = <String>[];
    final genreMatches = RegExp(
      r'<span property="v:genre">(.*?)</span>',
    ).allMatches(html);
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
      fields.add(
        ProposedField(
          key: 'director',
          valueText: director,
          entityName: director,
          entityType: 'director',
          source: 'scraper:douban',
          confidence: 0.95,
        ),
      );
    }

    if (rating != null && rating > 0) {
      fields.add(
        ProposedField(
          key: 'douban_rating',
          valueNum: rating,
          valueText: rating.toStringAsFixed(1),
          source: 'scraper:douban',
          confidence: 0.95,
        ),
      );
    }

    if (summary != null && summary.isNotEmpty) {
      fields.add(
        ProposedField(
          key: 'summary',
          valueText: summary,
          source: 'scraper:douban',
          confidence: 0.90,
        ),
      );
    }

    final tags = <ProposedTag>[
      const ProposedTag(tagPath: ['影视'], confidence: 0.9), // i18n:ignore 数据库标识符
    ];
    for (final g in genres) {
      tags.add(
        ProposedTag(tagPath: ['影视', g], confidence: 0.9),
      ); // i18n:ignore 数据库标识符
    }

    return ScrapeResult(
      proposedTitle: title,
      previewImageUrl: posterUrl,
      fields: fields,
      tags: tags,
    );
  }
}
