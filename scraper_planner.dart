import '../../core/media_types.dart';
import 'scraper.dart';

/// Runtime settings that influence dispatch, supplied by the caller.
///
/// Kept as a plain value object so the planner never touches the database.
class ScraperSettings {
  final Set<String> disabledIds;
  final Map<String, int> priorityOverrides;

  const ScraperSettings({
    this.disabledIds = const {},
    this.priorityOverrides = const {},
  });

  bool isEnabled(String id) => !disabledIds.contains(id);

  int priorityOf(Scraper scraper) => priorityOverrides[scraper.id] ?? scraper.priority;
}

/// A supertag that tier 1 decided to backfill, with the scraper that triggered it.
class BackfillRequest {
  final List<String> tagPath;
  final String scraperId;

  const BackfillRequest({required this.tagPath, required this.scraperId});

  String get label => tagPath.join(' / ');
}

/// One scraper execution with its non-empty result.
class ScraperRun {
  final Scraper scraper;
  final ScrapeResult result;

  const ScraperRun(this.scraper, this.result);
}

/// The outcome of dispatch: what to run, what to backfill, which title/cover won.
/// Contains no side effects - persisting it is the caller's job.
class ScrapePlan {
  /// Input as seen by tier 2 (existing tags include tier-1 backfill names).
  final ScrapeInput input;
  final List<BackfillRequest> backfill;
  final List<ScraperRun> runs;
  final String? proposedTitle;
  final String? previewImageUrl;

  const ScrapePlan({
    required this.input,
    this.backfill = const [],
    this.runs = const [],
    this.proposedTitle,
    this.previewImageUrl,
  });

  bool get isEmpty => backfill.isEmpty && runs.isEmpty && proposedTitle == null;
}

/// Two-tier scraper dispatch (plan only, never writes).
///
/// 1. Feature pattern match & automatic supertag backfilling.
/// 2. Supertag-targeted and universal scraper routing.
/// 3. Strict priority protection (Section 5.4).
class ScraperPlanner {
  final List<Scraper> scrapers;
  final ScraperSettings settings;

  const ScraperPlanner({required this.scrapers, this.settings = const ScraperSettings()});

  /// Registered scrapers sorted by effective priority descending.
  List<Scraper> orderedScrapers() {
    final list = List<Scraper>.from(scrapers);
    list.sort((a, b) => settings.priorityOf(b).compareTo(settings.priorityOf(a)));
    return list;
  }

  /// Runs dispatch and scraping. [backfillSupertags] is false for inspect-only
  /// callers that must see exactly what the given tags would match.
  Future<ScrapePlan> plan(
    ScrapeInput input, {
    ScrapeContext? ctx,
    bool backfillSupertags = true,
  }) async {
    final effectiveCtx = ctx ?? const ScrapeContext();
    final ordered = orderedScrapers();
    final backfill = <BackfillRequest>[];
    final virtualTagNames = <String>{for (final t in input.existingTags) t.name};

    // --- Tier 1: feature rule pre-dispatch & supertag backfilling ---
    if (backfillSupertags) {
      final targetStr =
          '${input.fileName ?? ''} ${input.sourceUrl ?? ''} ${input.subject.title ?? ''}'.trim();

      for (final scraper in ordered) {
        if (!settings.isEnabled(scraper.id)) continue;
        if (!_passesMediaTypeGate(scraper, input)) continue;

        final regex = scraper.patternRegex;
        if (regex == null || !regex.hasMatch(targetStr)) continue;

        final stBackfill = scraper.supertagToBackfill;
        if (stBackfill == null || stBackfill.isEmpty) continue;

        final alreadyHas = virtualTagNames.any(
          (name) => stBackfill.any((st) => name.toLowerCase() == st.toLowerCase()),
        );
        if (alreadyHas) continue;

        final request = BackfillRequest(tagPath: List<String>.from(stBackfill), scraperId: scraper.id);
        backfill.add(request);
        virtualTagNames.add(stBackfill.last);
        effectiveCtx.log(
          'Two-tier pre-dispatch: backfilled supertag "${request.label}" via ${scraper.displayName}',
        );
      }
    }

    // --- Tier 2: supertag targeted & specific scrapers dispatch ---
    final tier2Input = backfill.isEmpty
        ? input
        : ScrapeInput(
            subject: input.subject,
            fileName: input.fileName,
            sourceUrl: input.sourceUrl,
            referrerUrl: input.referrerUrl,
            existingTags: [for (final name in virtualTagNames) ExistingTag(name)],
            existingFields: input.existingFields,
          );

    final runs = <ScraperRun>[];
    String? bestTitle;
    String? bestPreviewImage;

    for (final scraper in ordered) {
      if (!settings.isEnabled(scraper.id)) continue;
      if (!scraper.canHandle(tier2Input)) continue;

      try {
        effectiveCtx.log('Executing scraper: ${scraper.displayName}');
        final result = await scraper.scrape(tier2Input, effectiveCtx);
        if (result.isEmpty) continue;

        bestTitle ??= result.proposedTitle;
        bestPreviewImage ??= result.previewImageUrl;
        runs.add(ScraperRun(scraper, result));
      } catch (e) {
        effectiveCtx.log('Scraper ${scraper.id} failed: $e');
      }
    }

    return ScrapePlan(
      input: tier2Input,
      backfill: backfill,
      runs: runs,
      proposedTitle: bestTitle,
      previewImageUrl: bestPreviewImage,
    );
  }

  bool _passesMediaTypeGate(Scraper scraper, ScrapeInput input) {
    if (scraper.mediaTypes.isEmpty) return true;

    var resType = input.subject.mediaType?.toLowerCase();
    if (resType == null || resType.isEmpty || resType == MediaTypes.other) {
      final checkPath = input.subject.uri ?? input.fileName ?? '';
      if (checkPath.isNotEmpty) {
        resType = MediaTypes.detectMediaTypeFromExtension(checkPath);
      }
    }
    if (resType != null &&
        resType.isNotEmpty &&
        resType != MediaTypes.other &&
        !scraper.mediaTypes.contains(resType)) {
      return false;
    }
    if (scraper.mediaTypes.length == 1 &&
        scraper.mediaTypes.first == MediaTypes.video &&
        resType != MediaTypes.video) {
      return false;
    }
    return true;
  }
}
