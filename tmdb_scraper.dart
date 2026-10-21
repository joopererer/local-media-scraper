import 'dart:convert';
import 'package:http/http.dart' as http;

import 'scraper.dart';

/// Scraper for TheMovieDB (TMDB) movie and TV show metadata.
class TmdbScraper implements Scraper {
  final http.Client? _client;

  TmdbScraper({http.Client? client}) : _client = client;

  @override
  String get id => 'tmdb';

  @override
  String get displayName => 'TheMovieDB (TMDB)';

  @override
  String get description => '国际电影与剧集元数据刮削 (支持演职员、导演、类型与海报封面)';

  @override
  int get priority => 90;

  @override
  List<String> get mediaTypes => const ['video'];

  @override
  List<String> get targetSupertags => const ['电影', 'Movie', '剧集', 'Series', '电视剧']; // i18n:ignore 数据库标识符

  @override
  RegExp? get patternRegex => RegExp(
        r'themoviedb\.org/(movie|tv)/(\d+)',
        caseSensitive: false,
      );

  @override
  List<String>? get supertagToBackfill => const ['电影']; // i18n:ignore 数据库标识符

  @override
  bool canHandle(ScrapeInput input) {
    // 1. Matches URL with themoviedb.org
    final url = input.sourceUrl ?? input.resource.uri ?? '';
    if (url.isNotEmpty && patternRegex!.hasMatch(url)) return true;

    // 2. Resource has matching Supertags
    final tags = input.existingTagNames;
    if (targetSupertags.any((st) => tags.contains(st.toLowerCase()))) {
      return true;
    }

    // 3. Filename indicates a movie with a 4-digit release year (e.g. Inception.2010.1080p.mkv)
    final fn = input.fileName ?? input.resource.title ?? '';
    final movieYearMatch = RegExp(r'^(.*?)[\.\s\(\[]((?:19|20)\d{2})[\.\s\)\]]').firstMatch(fn);
    return movieYearMatch != null;
  }

  @override
  Future<ScrapeResult> scrape(ScrapeInput input, ScrapeContext ctx) async {
    final client = ctx.client ?? _client ?? http.Client();
    final apiKey = ctx.getConfig('tmdb_api_key');

    // 1. Check if URL directly points to TMDB movie or tv
    final url = input.sourceUrl ?? input.resource.uri ?? '';
    final urlMatch = patternRegex?.firstMatch(url);
    if (urlMatch != null && apiKey != null && apiKey.isNotEmpty) {
      final type = urlMatch.group(1); // 'movie' or 'tv'
      final tmdbId = urlMatch.group(2);
      final apiUrl = 'https://api.themoviedb.org/3/$type/$tmdbId?api_key=$apiKey&language=zh-CN&append_to_response=credits';

      try {
        ctx.log('TMDB: fetching $type/$tmdbId');
        final resp = await client.get(Uri.parse(apiUrl)).timeout(const Duration(seconds: 10));
        if (resp.statusCode == 200) {
          final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
          return _parseTmdbJson(data, isMovie: type == 'movie');
        }
      } catch (e) {
        ctx.log('TMDB API request failed: $e');
      }
    }

    // 2. Parse from movie title and release year pattern
    final fn = input.fileName ?? input.resource.title ?? '';
    final movieYearMatch = RegExp(r'^(.*?)[\.\s\(\[]((?:19|20)\d{2})[\.\s\)\]]').firstMatch(fn);
    if (movieYearMatch != null) {
      final cleanTitle = movieYearMatch.group(1)!.replaceAll('.', ' ').trim();
      final year = movieYearMatch.group(2)!;

      if (apiKey != null && apiKey.isNotEmpty) {
        final searchUrl = 'https://api.themoviedb.org/3/search/movie?api_key=$apiKey&query=${Uri.encodeComponent(cleanTitle)}&year=$year&language=zh-CN';
        try {
          ctx.log('TMDB: searching "$cleanTitle" ($year)');
          final resp = await client.get(Uri.parse(searchUrl)).timeout(const Duration(seconds: 10));
          if (resp.statusCode == 200) {
            final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
            final results = data['results'] as List<dynamic>?;
            if (results != null && results.isNotEmpty) {
              final first = results.first as Map<String, dynamic>;
              final movieId = first['id'];
              // Fetch full details
              final detailUrl = 'https://api.themoviedb.org/3/movie/$movieId?api_key=$apiKey&language=zh-CN&append_to_response=credits';
              final detailResp = await client.get(Uri.parse(detailUrl)).timeout(const Duration(seconds: 10));
              if (detailResp.statusCode == 200) {
                final detailData = jsonDecode(utf8.decode(detailResp.bodyBytes)) as Map<String, dynamic>;
                return _parseTmdbJson(detailData, isMovie: true);
              }
            }
          }
        } catch (e) {
          ctx.log('TMDB search failed: $e');
        }
      }

      // Offline / Fallback parsing without API key
      return ScrapeResult(
        proposedTitle: cleanTitle,
        fields: [
          ProposedField(
            key: 'release_year',
            valueText: year,
            valueNum: double.tryParse(year),
            source: 'scraper:tmdb:heuristic',
            confidence: 0.85,
          ),
        ],
        tags: const [
          ProposedTag(tagPath: ['电影'], confidence: 0.9), // i18n:ignore 数据库标识符
        ],
      );
    }

    return const ScrapeResult();
  }

  ScrapeResult _parseTmdbJson(Map<String, dynamic> data, {required bool isMovie}) {
    final title = (data['title'] ?? data['name'] ?? data['original_title'] ?? data['original_name'])?.toString();
    final overview = data['overview'] as String?;
    final releaseDate = (data['release_date'] ?? data['first_air_date'])?.toString();
    final voteAverage = (data['vote_average'] as num?)?.toDouble();
    final posterPath = data['poster_path'] as String?;
    final posterUrl = posterPath != null ? 'https://image.tmdb.org/t/p/w500$posterPath' : null;

    final fields = <ProposedField>[];

    if (overview != null && overview.trim().isNotEmpty) {
      fields.add(ProposedField(
        key: 'overview',
        valueText: overview.trim(),
        source: 'scraper:tmdb',
        confidence: 0.95,
      ));
    }

    if (releaseDate != null && releaseDate.isNotEmpty) {
      final yearStr = releaseDate.split('-').first;
      if (yearStr.length == 4) {
        fields.add(ProposedField(
          key: 'year',
          valueText: yearStr,
          valueNum: double.tryParse(yearStr),
          source: 'scraper:tmdb',
          confidence: 0.95,
        ));
      }
    }

    if (voteAverage != null && voteAverage > 0) {
      fields.add(ProposedField(
        key: 'tmdb_rating',
        valueNum: voteAverage,
        valueText: voteAverage.toStringAsFixed(1),
        source: 'scraper:tmdb',
        confidence: 0.95,
      ));
    }

    // Credits: Director & Cast
    final credits = data['credits'] as Map<String, dynamic>?;
    if (credits != null) {
      final crew = credits['crew'] as List<dynamic>? ?? const [];
      final director = crew.firstWhere(
        (c) => c['job'] == 'Director',
        orElse: () => null,
      );
      if (director != null && director['name'] != null) {
        final directorName = director['name'].toString();
        fields.add(ProposedField(
          key: 'director',
          valueText: directorName,
          entityName: directorName,
          entityType: 'director',
          source: 'scraper:tmdb',
          confidence: 0.95,
        ));
      }

      final cast = credits['cast'] as List<dynamic>? ?? const [];
      for (final actor in cast.take(4)) {
        if (actor['name'] != null) {
          final actorName = actor['name'].toString();
          fields.add(ProposedField(
            key: 'cast',
            valueText: actorName,
            entityName: actorName,
            entityType: 'actor',
            source: 'scraper:tmdb',
            confidence: 0.90,
          ));
        }
      }
    }

    // Genres as tags
    final tags = <ProposedTag>[
      ProposedTag(tagPath: isMovie ? ['电影'] : ['剧集'], confidence: 0.95), // i18n:ignore 数据库标识符
    ];
    final genres = data['genres'] as List<dynamic>? ?? const [];
    for (final g in genres) {
      final name = g['name'] as String?;
      if (name != null && name.isNotEmpty) {
        tags.add(ProposedTag(
          tagPath: isMovie ? ['电影', name] : ['剧集', name], // i18n:ignore 数据库标识符
          confidence: 0.90,
        ));
      }
    }

    return ScrapeResult(
      proposedTitle: title?.toString(),
      previewImageUrl: posterUrl,
      fields: fields,
      tags: tags,
    );
  }
}