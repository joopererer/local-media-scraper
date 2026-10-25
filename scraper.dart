import 'package:http/http.dart' as http;

/// The thing being scraped, expressed without any application/database types.
///
/// Scrapers only ever read these fields, so this type keeps the scraping layer
/// free of drift rows (and reusable outside this app).
class ScrapeSubject {
  final String id;
  final String? title;
  final String? uri;
  final String? mediaType;

  /// Opaque scope id (today: the library id) used by callers when writing tags.
  /// Scrapers never interpret it.
  final String? scopeId;

  const ScrapeSubject({
    required this.id,
    this.title,
    this.uri,
    this.mediaType,
    this.scopeId,
  });
}

/// A tag already attached to the subject (scrapers only match on the name).
class ExistingTag {
  final String name;

  const ExistingTag(this.name);
}

/// A field value already stored on the subject.
///
/// Bundled scrapers do not read this, but it is part of the contract so a
/// third-party scraper can avoid proposing a value that already exists.
class ExistingField {
  final String key;
  final String? valueText;
  final double? valueNum;

  const ExistingField(this.key, {this.valueText, this.valueNum});
}

/// Input provided to a [Scraper].
class ScrapeInput {
  final ScrapeSubject subject;
  final String? fileName;
  final String? sourceUrl;
  final String? referrerUrl;
  final List<ExistingTag> existingTags;
  final Map<String, List<ExistingField>> existingFields;

  const ScrapeInput({
    required this.subject,
    this.fileName,
    this.sourceUrl,
    this.referrerUrl,
    this.existingTags = const [],
    this.existingFields = const {},
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

  ProposedField copyWith({
    String? key,
    String? valueText,
    double? valueNum,
    String? entityName,
    String? entityType,
    double? confidence,
    String? source,
  }) {
    return ProposedField(
      key: key ?? this.key,
      valueText: valueText ?? this.valueText,
      valueNum: valueNum ?? this.valueNum,
      entityName: entityName ?? this.entityName,
      entityType: entityType ?? this.entityType,
      confidence: confidence ?? this.confidence,
      source: source ?? this.source,
    );
  }
}

class ProposedTag {
  /// Path of tags (e.g. `['Anime', 'Fanart']` or `['Wallpaper']`).
  final List<String> tagPath;
  final double confidence;

  /// Optional un-interpolated template rule (e.g. `'JAV / 片商 / {studio}'`).
  final String? rawTemplate;

  const ProposedTag({
    required this.tagPath,
    this.confidence = 0.8,
    this.rawTemplate,
  });

  ProposedTag copyWith({
    List<String>? tagPath,
    double? confidence,
    String? rawTemplate,
  }) {
    return ProposedTag(
      tagPath: tagPath ?? this.tagPath,
      confidence: confidence ?? this.confidence,
      rawTemplate: rawTemplate ?? this.rawTemplate,
    );
  }
}

/// A candidate item discovered during scraping (e.g. search results).
class ScrapeCandidate {
  final String title;
  final String? subtitle;
  final String? url;
  final String? coverUrl;
  final Map<String, dynamic> extra;

  const ScrapeCandidate({
    required this.title,
    this.subtitle,
    this.url,
    this.coverUrl,
    this.extra = const {},
  });
}

/// Aggregated result returned by a [Scraper].
class ScrapeResult {
  final List<ProposedField> fields;
  final List<ProposedTag> tags;
  final String? proposedTitle;
  final String? previewImageUrl;
  final List<ScrapeCandidate> candidates;

  const ScrapeResult({
    this.fields = const [],
    this.tags = const [],
    this.proposedTitle,
    this.previewImageUrl,
    this.candidates = const [],
  });

  bool get isEmpty =>
      fields.isEmpty &&
      tags.isEmpty &&
      proposedTitle == null &&
      previewImageUrl == null &&
      candidates.isEmpty;
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

  /// Allowed media types (e.g. `['video']`, `['image']`).
  /// An empty list means universal / all media types are permitted.
  List<String> get mediaTypes => const [];

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
