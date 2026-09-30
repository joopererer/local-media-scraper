import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/media_types.dart';
import '../../data/db/app_database.dart';
import '../../data/repositories/entity_repository.dart';
import '../../data/repositories/field_value_repository.dart';
import '../../data/repositories/resource_repository.dart';
import '../../features/browser/widgets/thumbnail_widget.dart';
import '../services/thumbnail_service.dart';
import '../../data/repositories/tag_repository.dart';
import 'bangumi_scraper.dart';
import 'douban_scraper.dart';
import 'filename_scraper.dart';
import 'jav_scraper.dart';
import 'scraper.dart';
import 'tmdb_scraper.dart';
import 'webpage_scraper.dart';
import 'yaml_scraper.dart';
import 'yaml_scraper_loader.dart';

/// Summary of all results produced by the scraper pipeline.
class ScrapePipelineResult {
  final String? updatedTitle;
  final String? previewImageUrl;
  final List<FieldValue> addedOrUpdatedFields;
  final List<String> addedTagIds;
  final List<String> backfilledSupertags;

  const ScrapePipelineResult({
    this.updatedTitle,
    this.previewImageUrl,
    this.addedOrUpdatedFields = const [],
    this.addedTagIds = const [],
    this.backfilledSupertags = const [],
  });
}

/// Registry and pipeline executor for all metadata scrapers.
class ScraperRegistry {
  final AppDatabase _db;
  final ResourceRepository _resourceRepo;
  final FieldValueRepository _fieldValueRepo;
  final EntityRepository _entityRepo;
  final TagRepository _tagRepo;
  final ThumbnailService? _thumbnailService;
  final YamlScraperLoader _yamlLoader;

  final List<Scraper> _scrapers = [];
  final Map<String, bool> _enabledStates = {};
  final Map<String, int> _customPriorities = {};
  final Map<String, dynamic> _configs = {};

  ScraperRegistry({
    required AppDatabase db,
    required ResourceRepository resourceRepo,
    required FieldValueRepository fieldValueRepo,
    required EntityRepository entityRepo,
    required TagRepository tagRepo,
    ThumbnailService? thumbnailService,
    YamlScraperLoader? yamlLoader,
    List<Scraper>? initialScrapers,
  })  : _db = db,
        _resourceRepo = resourceRepo,
        _fieldValueRepo = fieldValueRepo,
        _entityRepo = entityRepo,
        _tagRepo = tagRepo,
        _thumbnailService = thumbnailService,
        _yamlLoader = yamlLoader ?? YamlScraperLoader() {
    if (initialScrapers != null) {
      _scrapers.addAll(initialScrapers);
    } else {
      // Register Tier 1 built-in specialized scrapers
      _scrapers.add(TmdbScraper());
      _scrapers.add(DoubanScraper());
      _scrapers.add(BangumiScraper());
      _scrapers.add(JavScraper());
      // Register universal fallbacks
      _scrapers.add(FileNameScraper());
      _scrapers.add(WebPageScraper());
    }
  }

  /// Returns scrapers sorted by effective priority descending.
  List<Scraper> get scrapers {
    final list = List<Scraper>.from(_scrapers);
    list.sort((a, b) => getScraperPriority(b.id).compareTo(getScraperPriority(a.id)));
    return List.unmodifiable(list);
  }

  YamlScraperLoader get yamlLoader => _yamlLoader;

  /// Registers a custom scraper.
  void registerScraper(Scraper scraper) {
    if (!_scrapers.any((s) => s.id == scraper.id)) {
      _scrapers.add(scraper);
    }
  }

  /// Checks if a scraper is enabled.
  bool isScraperEnabled(String id) {
    return _enabledStates[id] ?? true;
  }

  /// Sets enabled state for a scraper and persists to database.
  Future<void> setScraperEnabled(String id, bool enabled) async {
    _enabledStates[id] = enabled;
    await _persistSettings();
  }

  /// Returns effective priority for a scraper (custom overridden or default).
  int getScraperPriority(String id) {
    if (_customPriorities.containsKey(id)) {
      return _customPriorities[id]!;
    }
    final scraper = _scrapers.firstWhere(
      (s) => s.id == id,
      orElse: () => _scrapers.first,
    );
    return scraper.priority;
  }

  /// Sets custom priority for a scraper and persists.
  Future<void> setScraperPriority(String id, int priority) async {
    _customPriorities[id] = priority;
    await _persistSettings();
  }

  /// Retrieves a scraper configuration value (e.g. `tmdb_api_key`, `proxy_url`).
  String? getConfig(String key) => _configs[key]?.toString();

  /// Sets and persists a scraper configuration value.
  Future<void> setConfig(String key, dynamic value) async {
    _configs[key] = value;
    await _persistConfigs();
  }

  /// Loads YAML plugins from the plugins/scrapers/ directory into the registry.
  Future<void> loadYamlPlugins() async {
    final loaded = await _yamlLoader.loadScrapers();
    // Remove old YAML scrapers
    _scrapers.removeWhere((s) => s is YamlScraper);
    // Add newly loaded ones
    for (final s in loaded) {
      registerScraper(s);
    }
  }

  /// Loads scraper enabled/disabled settings and configs from database.
  Future<void> loadSettings() async {
    // 1. Scraper enabled states
    final setting = await (_db.select(_db.settings)
          ..where((tbl) => tbl.key.equals('scraper_settings')))
        .getSingleOrNull();

    if (setting != null) {
      try {
        final decoded = jsonDecode(setting.valueJson);
        if (decoded is Map<String, dynamic>) {
          for (final entry in decoded.entries) {
            if (entry.value is bool) {
              _enabledStates[entry.key] = entry.value as bool;
            }
          }
        }
      } catch (_) {}
    }

    // 2. Scraper priorities
    final prioritiesSetting = await (_db.select(_db.settings)
          ..where((tbl) => tbl.key.equals('scraper_priorities')))
        .getSingleOrNull();

    if (prioritiesSetting != null) {
      try {
        final decoded = jsonDecode(prioritiesSetting.valueJson);
        if (decoded is Map<String, dynamic>) {
          for (final entry in decoded.entries) {
            if (entry.value is num) {
              _customPriorities[entry.key] = (entry.value as num).toInt();
            }
          }
        }
      } catch (_) {}
    }

    // 3. Scraper configs (API keys, proxies)
    final configSetting = await (_db.select(_db.settings)
          ..where((tbl) => tbl.key.equals('scraper_configs')))
        .getSingleOrNull();

    if (configSetting != null) {
      try {
        final decoded = jsonDecode(configSetting.valueJson);
        if (decoded is Map<String, dynamic>) {
          _configs.addAll(decoded);
        }
      } catch (_) {}
    }

    // 4. Ensure default Supertags (e.g. JAV) are seeded with schema fields
    await _ensureDefaultSupertags();
  }

  /// Ensures that standard Supertags like JAV exist in the database with their schema fields.
  Future<void> _ensureDefaultSupertags() async {
    try {
      final javTag = await _tagRepo.findOrCreateTag('JAV');
      final existingFields = await _tagRepo.getFieldsForTag(javTag.id);

      final defaultFields = [
        ('code', '番号', 'string', null, false, 0),
        ('title', '片名', 'string', null, false, 1),
        ('studio', '片商', 'entity', 'studio', false, 2),
        ('actress', '女优', 'entity', 'actress', true, 3),
        ('year', '发行年份', 'number', null, false, 4),
      ];

      for (final (key, label, valueType, entityType, multi, sortOrder) in defaultFields) {
        final existingField = existingFields.where((f) => f.key == key).firstOrNull;
        if (existingField == null) {
          await _tagRepo.createTagField(
            tagId: javTag.id,
            key: key,
            label: label,
            valueType: valueType,
            entityType: entityType,
            multi: multi,
            sortOrder: sortOrder,
          );
        } else if (existingField.label != label) {
          await _tagRepo.updateTagField(
            id: existingField.id,
            label: label,
          );
        }
      }
    } catch (e) {
      // Non-blocking initialization error
      debugPrint('ScraperRegistry: error ensuring default supertags: $e');
    }
  }

  Future<void> _persistSettings() async {
    final jsonStr = jsonEncode(_enabledStates);
    await _db.into(_db.settings).insertOnConflictUpdate(
      SettingsCompanion.insert(
        key: 'scraper_settings',
        valueJson: jsonStr,
      ),
    );

    final prioritiesJsonStr = jsonEncode(_customPriorities);
    await _db.into(_db.settings).insertOnConflictUpdate(
      SettingsCompanion.insert(
        key: 'scraper_priorities',
        valueJson: prioritiesJsonStr,
      ),
    );
  }

  Future<void> _persistConfigs() async {
    final jsonStr = jsonEncode(_configs);
    await _db.into(_db.settings).insertOnConflictUpdate(
      SettingsCompanion.insert(
        key: 'scraper_configs',
        valueJson: jsonStr,
      ),
    );
  }

  /// Executes two-tier scraper pipeline:
  /// 1. Feature pattern match & automatic supertag backfilling.
  /// 2. Supertag-targeted and universal scraper routing.
  /// 3. Strict priority protection (Section 5.4).
  Future<ScrapePipelineResult> executePipeline(
    ScrapeInput input, {
    ScrapeContext? ctx,
  }) async {
    final effectiveCtx = ctx ?? ScrapeContext(config: _configs);
    final addedFields = <FieldValue>[];
    final addedTagIds = <String>[];
    final backfilledSupertags = <String>[];
    String? bestTitle;
    String? bestPreviewImage;

    // Mutated working copy of tags to allow two-tier dispatch chaining
    final workingExistingTags = List<Tag>.from(input.existingTags);
    ScrapeInput currentInput = input;

    // --- Tier 1: Feature Rule Pre-Dispatch & Supertag Backfilling ---
    final targetStr = '${input.fileName ?? ''} ${input.sourceUrl ?? ''} ${input.resource.title ?? ''}'.trim();
    final orderedScrapers = scrapers; // already sorted by priority descending
    for (final scraper in orderedScrapers) {
      if (!isScraperEnabled(scraper.id)) continue;
      if (scraper.patternRegex != null && scraper.patternRegex!.hasMatch(targetStr)) {
        final stBackfill = scraper.supertagToBackfill;
        if (stBackfill != null && stBackfill.isNotEmpty) {
          final tagPathStr = stBackfill.join(' / ');
          final alreadyHas = workingExistingTags.any((t) =>
              stBackfill.any((st) => t.name.toLowerCase() == st.toLowerCase()));
          if (!alreadyHas) {
            final tagId = await _findOrCreateTagPath(stBackfill);
            if (tagId != null) {
              await _tagRepo.attachTagToResource(
                input.resource.id,
                tagId,
                source: 'scraper:backfill:${scraper.id}',
              );
              addedTagIds.add(tagId);
              backfilledSupertags.add(tagPathStr);
              effectiveCtx.log('Two-tier pre-dispatch: backfilled supertag "$tagPathStr" via ${scraper.displayName}');

              // Query newly attached tag to update working tags
              final attachedTag = await (_db.select(_db.tags)..where((t) => t.id.equals(tagId))).getSingleOrNull();
              if (attachedTag != null) {
                workingExistingTags.add(attachedTag);
              }
            }
          }
        }
      }
    }

    // Refresh input with newly backfilled tags
    currentInput = ScrapeInput(
      resource: input.resource,
      fileName: input.fileName,
      sourceUrl: input.sourceUrl,
      referrerUrl: input.referrerUrl,
      existingFields: input.existingFields,
      existingTags: workingExistingTags,
    );

    // --- Tier 2: Supertag Targeted & Specific Scrapers Dispatch ---
    for (final scraper in orderedScrapers) {
      if (!isScraperEnabled(scraper.id)) continue;
      if (!scraper.canHandle(currentInput)) continue;

      try {
        effectiveCtx.log('Executing scraper: ${scraper.displayName}');
        final result = await scraper.scrape(currentInput, effectiveCtx);
        if (result.isEmpty) continue;

        if (result.proposedTitle != null && bestTitle == null) {
          bestTitle = result.proposedTitle;
        }

        if (result.previewImageUrl != null && bestPreviewImage == null) {
          bestPreviewImage = result.previewImageUrl;
        }

        // Apply proposed fields respecting priority rules (Section 5.4)
        for (final pf in result.fields) {
          String? resolvedEntityId;
          if (pf.entityName != null && pf.entityName!.trim().isNotEmpty) {
            final entity = await _entityRepo.findOrCreateEntity(
              pf.entityType ?? 'other',
              pf.entityName!.trim(),
            );
            resolvedEntityId = entity.id;
          }

          final saved = await _fieldValueRepo.setAutomatedFieldValue(
            resourceId: input.resource.id,
            key: pf.key,
            valueText: pf.valueText,
            valueNum: pf.valueNum,
            entityId: resolvedEntityId,
            source: pf.source,
            confidence: pf.confidence,
          );
          addedFields.add(saved);
        }

        // Apply proposed tags
        for (final pt in result.tags) {
          if (pt.tagPath.isEmpty) continue;
          final tagId = await _findOrCreateTagPath(pt.tagPath);
          if (tagId != null) {
            await _tagRepo.attachTagToResource(
              input.resource.id,
              tagId,
              source: 'scraper:${scraper.id}',
            );
            addedTagIds.add(tagId);
          }
        }
      } catch (e) {
        effectiveCtx.log('Scraper ${scraper.id} failed: $e');
      }
    }

    // Update resource title if we obtained a valid proposed title
    if (bestTitle != null && bestTitle.trim().isNotEmpty) {
      final curTitle = input.resource.title;
      // Only auto-update title if current title is default/empty or resembles raw filename
      if (curTitle == null ||
          curTitle.isEmpty ||
          curTitle == 'untitled' ||
          curTitle == input.fileName) {
        await _resourceRepo.updateResource(
          ResourcesCompanion(
            id: Value(input.resource.id),
            title: Value(bestTitle),
            updatedAt: Value(DateTime.now().toUtc().millisecondsSinceEpoch),
          ),
        );
      }
    }

    // If resource has mediaType == 'other' or null, refine it if a known file extension is present
    if (input.resource.mediaType == null || input.resource.mediaType == 'other') {
      final checkPath = input.resource.uri ?? input.fileName;
      if (checkPath != null && checkPath.isNotEmpty) {
        final uri = Uri.tryParse(checkPath);
        final pathToCheck = uri != null && uri.path.isNotEmpty ? uri.path : checkPath;
        if (p.extension(pathToCheck).isNotEmpty) {
          final refinedType = MediaTypes.detectMediaType(pathToCheck);
          final refinedMime = MediaTypes.detectMime(pathToCheck);
          if (refinedType != 'other') {
            await _resourceRepo.updateResource(
              ResourcesCompanion(
                id: Value(input.resource.id),
                mediaType: Value(refinedType),
                mime: Value(refinedMime),
                updatedAt: Value(DateTime.now().toUtc().millisecondsSinceEpoch),
              ),
            );
          }
        }
      }
    }

    // Download remote cover image and save as thumbnail
    if (bestPreviewImage != null && bestPreviewImage.startsWith('http')) {
      try {
        final client = http.Client();
        try {
          final imgUri = Uri.parse(bestPreviewImage);
          final response = await client.get(
            imgUri,
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
              'Referer': '${imgUri.scheme}://${imgUri.host}/',
            },
          ).timeout(const Duration(seconds: 15));

          if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
            final thumbService = _thumbnailService;
            if (thumbService != null) {
              await thumbService.saveRemoteCoverAsThumbnail(
                input.resource.id,
                response.bodyBytes,
              );
              ThumbnailWidget.invalidateCache(input.resource.id);
              debugPrint('ScraperRegistry: saved remote cover as thumbnail for ${input.resource.id}');

              // Bump resource updatedAt so listeners re-render with new thumbnail
              await _resourceRepo.updateResource(
                ResourcesCompanion(
                  id: Value(input.resource.id),
                  updatedAt: Value(DateTime.now().toUtc().millisecondsSinceEpoch),
                ),
              );
            }
          } else {
            debugPrint('ScraperRegistry: cover download returned status ${response.statusCode}');
          }
        } finally {
          client.close();
        }
      } catch (e) {
        debugPrint('ScraperRegistry: failed to download cover image: $e');
      }
    }

    return ScrapePipelineResult(
      updatedTitle: bestTitle,
      previewImageUrl: bestPreviewImage,
      addedOrUpdatedFields: addedFields,
      addedTagIds: addedTagIds,
      backfilledSupertags: backfilledSupertags,
    );
  }

  /// Convenience method to run scraper pipeline on an existing resource by its ID.
  Future<ScrapePipelineResult> scrapeResource(
    String resourceId, {
    ScrapeContext? ctx,
  }) async {
    final item = await _resourceRepo.getResourceWithLocations(resourceId);
    if (item == null) return const ScrapePipelineResult();

    final existingFieldsMap = <String, List<FieldValue>>{};
    for (final f in item.fieldValues) {
      existingFieldsMap.putIfAbsent(f.key, () => []).add(f);
    }

    final primaryLoc = item.primaryLocation;
    final fileName = primaryLoc != null
        ? p.basename(primaryLoc.path)
        : (item.resource.title ?? '');
    final sourceUrl = existingFieldsMap['source_url']?.firstOrNull?.valueText ??
        item.resource.uri;

    final input = ScrapeInput(
      resource: item.resource,
      fileName: fileName,
      sourceUrl: sourceUrl,
      existingFields: existingFieldsMap,
      existingTags: item.tags,
    );

    return executePipeline(input, ctx: ctx);
  }

  Future<String?> _findOrCreateTagPath(List<String> path) async {
    String? currentParentId;
    for (final seg in path) {
      final trimmed = seg.trim();
      if (trimmed.isEmpty) continue;

      final tag = await _tagRepo.findOrCreateTag(trimmed, parentId: currentParentId);
      currentParentId = tag.id;
    }
    return currentParentId;
  }
}

/// Provider for [ScraperRegistry].
final scraperRegistryProvider = Provider<ScraperRegistry>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final resourceRepo = ref.watch(resourceRepositoryProvider);
  final fieldValueRepo = ref.watch(fieldValueRepositoryProvider);
  final entityRepo = ref.watch(entityRepositoryProvider);
  final tagRepo = ref.watch(tagRepositoryProvider);
  final thumbService = ref.watch(thumbnailServiceProvider);

  final registry = ScraperRegistry(
    db: db,
    resourceRepo: resourceRepo,
    fieldValueRepo: fieldValueRepo,
    entityRepo: entityRepo,
    tagRepo: tagRepo,
    thumbnailService: thumbService,
  );

  // Asynchronously load settings and yaml plugins
  registry.loadSettings().then((_) => registry.loadYamlPlugins());

  return registry;
});
