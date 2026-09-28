import '../../data/db/app_database.dart';

/// Input provided to a [Scraper].
class ScrapeInput {
  final Resource resource;
  final String? fileName;
  final String? sourceUrl;
  final String? referrerUrl;
  final Map<String, List<FieldValue>> existingFields;

  const ScrapeInput({
    required this.resource,
    this.fileName,
    this.sourceUrl,
    this.referrerUrl,
    this.existingFields = const {},
  });
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

/// Execution context for scrapers (e.g. logging, cancellation).
class ScrapeContext {
  final void Function(String message)? onLog;

  const ScrapeContext({this.onLog});

  void log(String message) => onLog?.call(message);
}

/// Pluggable interface for metadata scrapers.
abstract class Scraper {
  String get id;
  String get displayName;
  String get description;

  /// Whether this scraper can handle the provided input.
  bool canHandle(ScrapeInput input);

  /// Performs the scrape operation.
  Future<ScrapeResult> scrape(ScrapeInput input, ScrapeContext ctx);
}
