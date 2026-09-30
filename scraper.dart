import 'package:http/http.dart' as http;

import '../../data/db/app_database.dart';

/// Input provided to a [Scraper].
class ScrapeInput {
  final Resource resource;
  final String? fileName;
  final String? sourceUrl;
  final String? referrerUrl;
  final Map<String, List<FieldValue>> existingFields;
  final List<Tag> existingTags;

  const ScrapeInput({
    required this.resource,
    this.fileName,
    this.sourceUrl,
    this.referrerUrl,
    this.existingFields = const {},
    this.existingTags = const [],
  });

  Set<String> get existingTagNames =>
      existingTags.map((t) => t.name.toLowerCase()).toSet();
}

/// A field proposed by a scraper.
class ProposedField {
  final String key;
  final String? valueText;
  final double? valueNum;
  final String? entityName;
  final String? entityType;
  final double confidence;
  final String source;

  const ProposedField({
    required this.key,
    this.valueText,
    this.valueNum,
    this.entityName,
    this.entityType,
    this.confidence = 0.8,
    required this.source,
  });
}

/// A tag proposed by a scraper.
class ProposedTag {
  /// Path of tags (e.g. `['Anime', 'Fanart']` or `['Wallpaper']`).
  final List<String> tagPath;
  final double confidence;

  const ProposedTag({
    required this.tagPath,
    this.confidence = 0.8,
  });
}

/// Aggregated result returned by a [Scraper].
class ScrapeResult {
  final List<ProposedField> fields;
  final List<ProposedTag> tags;
  final String? proposedTitle;
  final String? previewImageUrl;

  const ScrapeResult({
    this.fields = const [],
    this.tags = const [],
    this.proposedTitle,
    this.previewImageUrl,
  });

  bool get isEmpty =>
      fields.isEmpty && tags.isEmpty && proposedTitle == null && previewImageUrl == null;
}

/// Execution context for scrapers (e.g. logging, API keys, proxy, http client).
class ScrapeContext {
  final void Function(String message)? onLog;
  final Map<String, dynamic> config;
  final http.Client? client;

  const ScrapeContext({
    this.onLog,
    this.config = const {},
    this.client,
  });

  void log(String message) => onLog?.call(message);

  String? getConfig(String key) => config[key]?.toString();
}

/// Pluggable interface for metadata scrapers.
abstract class Scraper {
  String get id;
  String get displayName;
  String get description;

  /// Execution priority (higher executes earlier).
  /// Built-in specialized scrapers default to 80-90, universal fallbacks to 10-20.
  int get priority => 50;

  /// Target supertags that this scraper specializes in (e.g. `['电影', 'Movie']`, `['番剧', 'Anime']`).
  /// An empty list means universal / not constrained to specific supertags.
  List<String> get targetSupertags => const [];

  /// Optional regular expression pattern to detect if an input matches this scraper's domain
  /// (e.g. `r'([A-Z]{3,5}-\d{3,5})'` or `r'(BV[a-zA-Z0-9]{10})'` or `r'douban\.com'`).
  RegExp? get patternRegex => null;

  /// If this scraper matches by [patternRegex], optionally backfill this supertag/tag
  /// to the resource (e.g. `['影视', '电影']` or `['番号', 'AV']`).
  List<String>? get supertagToBackfill => null;

  /// Whether this scraper can handle the provided input.
  bool canHandle(ScrapeInput input);

  /// Performs the scrape operation.
  Future<ScrapeResult> scrape(ScrapeInput input, ScrapeContext ctx);
}
