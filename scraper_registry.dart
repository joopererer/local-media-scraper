import 'dart:async';
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
import '../plugins/scraper_plugin_loader.dart';
import '../services/thumbnail_service.dart';
import '../../data/repositories/tag_repository.dart';
import 'bangumi_scraper.dart';
import 'douban_scraper.dart';
import 'filename_scraper.dart';
import 'scraper.dart';
import 'scraper_planner.dart';
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
  YamlScraperLoader _yamlLoader;

  final List<Scraper> _scrapers = [];
  final Map<String, bool> _enabledStates = {};
  final Map<String, int> _customPriorities = {};
  final Map<String, dynamic> _configs = {};
  final Map<String, Map<String, double>> _customConfidences = {};
  StreamSubscription<List<YamlScraper>>? _pluginWatch;

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

  /// 替换 YAML 加载器（provider 在用户目录就绪后调用）。
  void setYamlLoader(YamlScraperLoader loader) {
    _yamlLoader = loader;
  }

  /// Registers a custom or overridden scraper.
  void registerScraper(Scraper scraper) {
    final idx = _scrapers.indexWhere((s) => s.id == scraper.id);
    if (idx >= 0) {
      _scrapers[idx] = scraper;
    } else {
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

  /// Returns an unmodifiable view of all stored configs.
  Map<String, dynamic> get allConfigs => Map.unmodifiable(_configs);

  /// Sets and persists a scraper configuration value.
  Future<void> setConfig(String key, dynamic value) async {
    _configs[key] = value;
    await _persistConfigs();
  }

  /// Returns effective confidence for a specific field of a scraper.
  double getEffectiveConfidence(String scraperId, String fieldKey, double defaultConfidence) {
    return _customConfidences[scraperId]?[fieldKey] ?? defaultConfidence;
  }

  /// Sets custom confidence override for a specific field of a scraper.
  Future<void> setFieldConfidence(String scraperId, String fieldKey, double confidence) async {
    _customConfidences.putIfAbsent(scraperId, () => {})[fieldKey] = confidence;
    await _persistConfidences();
  }

  /// Resets confidence overrides for a scraper back to its default.
  Future<void> resetFieldConfidences(String scraperId) async {
    _customConfidences.remove(scraperId);
    await _persistConfidences();
  }

  /// Cleans up orphan configurations and confidences belonging to scrapers that are no longer installed.
  Future<int> cleanOrphanConfigs() async {
    int removedCount = 0;
    final validScraperIds = _scrapers.map((s) => s.id).toSet();

    // 1. Clean orphan confidences
    final orphanConfScrapers = _customConfidences.keys.where((id) => !validScraperIds.contains(id)).toList();
    for (final id in orphanConfScrapers) {
      _customConfidences.remove(id);
      removedCount++;
    }
    if (orphanConfScrapers.isNotEmpty) {
      await _persistConfidences();
    }

    // 2. Collect all active config keys declared by active scrapers (via YamlScraper.configSchema)
    final activeConfigKeys = <String>{'tmdb_api_key', 'proxy_url'};
    for (final s in _scrapers) {
      if (s is YamlScraper) {
        for (final cs in s.configSchema) {
          activeConfigKeys.add(cs.key);
        }
      }
    }

    // Clean orphan config keys
    final orphanConfigKeys = _configs.keys.where((k) => !activeConfigKeys.contains(k)).toList();
    for (final k in orphanConfigKeys) {
      _configs.remove(k);
      removedCount++;
    }
    if (orphanConfigKeys.isNotEmpty) {
      await _persistConfigs();
    }

    return removedCount;
  }

  /// Loads YAML plugins from the plugins/scrapers/ directory into the registry.
  Future<void> loadYamlPlugins() async {
    _applyLoadedYamlPlugins(await _yamlLoader.loadScrapers());
  }

  /// Re-scans the plugin directory automatically whenever it changes.
  ///
  /// Safe to call more than once; only one subscription is kept.
  void watchYamlPlugins({Duration debounce = const Duration(milliseconds: 400)}) {
    if (_pluginWatch != null) return;
    _pluginWatch = _yamlLoader.watch(debounce: debounce).listen(_applyLoadedYamlPlugins);
  }

  Future<void> dispose() async {
    await _pluginWatch?.cancel();
    _pluginWatch = null;
  }

  void _applyLoadedYamlPlugins(List<YamlScraper> loaded) {
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

    // 4. Scraper custom confidences
    final confidenceSetting = await (_db.select(_db.settings)
          ..where((tbl) => tbl.key.equals('scraper_confidences')))
        .getSingleOrNull();

    if (confidenceSetting != null) {
      try {
        final decoded = jsonDecode(confidenceSetting.valueJson);
        if (decoded is Map<String, dynamic>) {
          for (final entry in decoded.entries) {
            if (entry.value is Map) {
              final fieldMap = <String, double>{};
              (entry.value as Map).forEach((k, v) {
                if (v is num) {
                  fieldMap[k.toString()] = v.toDouble();
                }
              });
              _customConfidences[entry.key] = fieldMap;
            }
          }
        }
      } catch (_) {}
    }

    // 5. Ensure default Supertags (e.g. JAV) are seeded with schema fields
    await _ensureDefaultSupertags();
  }

  /// Ensures that standard Supertags (电影, 番剧) exist in the database with their schema fields.
  Future<void> _ensureDefaultSupertags() async {
    try {
      final defaultSupertags = <String, List<(String, String, String, String?, bool, int)>>{
        '电影': [
          ('title', '片名', 'string', null, false, 0),
          ('director', '导演', 'entity', 'director', false, 1),
          ('actor', '主要演员', 'entity', 'person', true, 2),
          ('year', '发行年份', 'number', null, false, 3),
          ('rating', '豆瓣/TMDB评分', 'number', null, false, 4),
          ('summary', '剧情简介', 'string', null, false, 5),
        ],
        '番剧': [
          ('title', '中文译名', 'string', null, false, 0),
          ('original_title', '日文原名', 'string', null, false, 1),
          ('year', '放送年份', 'number', null, false, 2),
          ('rating', '评分', 'number', null, false, 3),
          ('summary', '简介', 'string', null, false, 4),
        ],
      };

      for (final entry in defaultSupertags.entries) {
        final tagName = entry.key;
        final fields = entry.value;

        final tag = await _tagRepo.findOrCreateTag(tagName);
        final existingFields = await _tagRepo.getFieldsForTag(tag.id);

        for (final (key, label, valueType, entityType, multi, sortOrder) in fields) {
          final existingField = existingFields.where((f) => f.key == key).firstOrNull;
          if (existingField == null) {
            // Avoid adding a duplicate actor-like field when the tag already
            // has an 'actress' (legacy) or 'actor' field for the same role.
            if (key == 'actor' &&
                existingFields.any(
                  (f) => f.key == 'actress' || f.key == 'actor',
                )) {
              continue;
            }
            await _tagRepo.createTagField(
              tagId: tag.id,
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

  Future<void> _persistConfidences() async {
    final jsonStr = jsonEncode(_customConfidences);
    await _db.into(_db.settings).insertOnConflictUpdate(
      SettingsCompanion.insert(
        key: 'scraper_confidences',
        valueJson: jsonStr,
      ),
    );
  }

  /// Executes the scraper pipeline: dispatch via [ScraperPlanner] (no writes),
  /// then applies the plan - backfilled supertags, fields, tags, title, media
  /// type and cover image - to the database.
  Future<ScrapePipelineResult> executePipeline(
    ScrapeInput input, {
    ScrapeContext? ctx,
  }) async {
    final effectiveCtx = ctx ?? ScrapeContext(config: _configs);
    final plan = await _planner().plan(input, ctx: effectiveCtx);
    final subject = input.subject;

    final addedFields = <FieldValue>[];
    final addedTagIds = <String>[];
    final backfilledSupertags = <String>[];

    // --- Tier 1: persist the supertags the planner decided to backfill ---
    for (final request in plan.backfill) {
      final tagId = await _findOrCreateTagPath(request.tagPath, libraryId: subject.scopeId);
      if (tagId == null) continue;
      await _tagRepo.attachTagToResource(
        subject.id,
        tagId,
        source: 'scraper:backfill:${request.scraperId}',
      );
      addedTagIds.add(tagId);
      backfilledSupertags.add(request.label);
    }

    // --- Tier 2: apply proposed fields and tags in priority order ---
    for (final run in plan.runs) {
      final scraperId = run.scraper.id;

      for (final pf in run.result.fields) {
        String? resolvedEntityId;
        if (pf.entityName != null && pf.entityName!.trim().isNotEmpty) {
          final entity = await _entityRepo.findOrCreateEntity(
            pf.entityType ?? 'other',
            pf.entityName!.trim(),
          );
          resolvedEntityId = entity.id;
        }

        final effectiveConfidence = getEffectiveConfidence(scraperId, pf.key, pf.confidence);
        final saved = await _fieldValueRepo.setAutomatedFieldValue(
          resourceId: subject.id,
          key: pf.key,
          valueText: pf.valueText,
          valueNum: pf.valueNum,
          entityId: resolvedEntityId,
          source: pf.source,
          confidence: effectiveConfidence,
        );
        addedFields.add(saved);
      }

      for (final pt in run.result.tags) {
        if (pt.tagPath.isEmpty) continue;
        final tagId = await _findOrCreateTagPath(pt.tagPath, libraryId: subject.scopeId);
        if (tagId != null) {
          await _tagRepo.attachTagToResource(
            subject.id,
            tagId,
            source: 'scraper:$scraperId',
          );
          addedTagIds.add(tagId);
        }
      }
    }

    final bestTitle = plan.proposedTitle;
    final bestPreviewImage = plan.previewImageUrl;

    // Update resource title if we obtained a valid proposed title
    if (bestTitle != null && bestTitle.trim().isNotEmpty) {
      final curTitle = subject.title;
      // Only auto-update title if current title is default/empty or resembles raw filename
      if (curTitle == null ||
          curTitle.isEmpty ||
          curTitle == 'untitled' ||
          curTitle == input.fileName) {
        await _resourceRepo.updateResource(
          ResourcesCompanion(
            id: Value(subject.id),
            title: Value(bestTitle),
            updatedAt: Value(DateTime.now().toUtc().millisecondsSinceEpoch),
          ),
        );
      }
    }

    // If resource has mediaType == 'other' or null, refine it if a known file extension is present
    if (subject.mediaType == null || subject.mediaType == 'other') {
      final checkPath = subject.uri ?? input.fileName;
      if (checkPath != null && checkPath.isNotEmpty) {
        final uri = Uri.tryParse(checkPath);
        final pathToCheck = uri != null && uri.path.isNotEmpty ? uri.path : checkPath;
        if (p.extension(pathToCheck).isNotEmpty) {
          final refinedType = await MediaTypes.detectMediaType(pathToCheck);
          final refinedMime = MediaTypes.detectMime(pathToCheck);
          if (refinedType != 'other') {
            await _resourceRepo.updateResource(
              ResourcesCompanion(
                id: Value(subject.id),
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
                subject.id,
                response.bodyBytes,
              );
              ThumbnailWidget.invalidateCache(subject.id);
              debugPrint('ScraperRegistry: saved remote cover as thumbnail for ${subject.id}');

              // Bump resource updatedAt so listeners re-render with new thumbnail
              await _resourceRepo.updateResource(
                ResourcesCompanion(
                  id: Value(subject.id),
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

  /// Planner built from the current registry state (no database access).
  ScraperPlanner _planner() => ScraperPlanner(
        scrapers: _scrapers,
        settings: ScraperSettings(
          disabledIds: {
            for (final entry in _enabledStates.entries)
              if (!entry.value) entry.key,
          },
          priorityOverrides: Map<String, int>.from(_customPriorities),
        ),
      );

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
      subject: _subjectOf(item.resource),
      fileName: fileName,
      sourceUrl: sourceUrl,
      existingTags: [for (final t in item.tags) ExistingTag(t.name)],
      existingFields: _existingFieldsOf(existingFieldsMap),
    );

    return executePipeline(input, ctx: ctx);
  }

  /// Inspects candidate scrape results without immediately mutating the resource.
  /// Used by UI verification dialogs.
  Future<({ScrapeInput input, List<({Scraper scraper, ScrapeResult result})> results})> inspectResourceScrape(
    String resourceId, {
    ScrapeContext? ctx,
  }) async {
    final item = await _resourceRepo.getResourceWithLocations(resourceId);
    if (item == null) {
      throw ArgumentError('Resource not found: $resourceId');
    }

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
      subject: _subjectOf(item.resource),
      fileName: fileName,
      sourceUrl: sourceUrl,
      existingTags: [for (final t in item.tags) ExistingTag(t.name)],
      existingFields: _existingFieldsOf(existingFieldsMap),
    );

    final effectiveCtx = ctx ?? ScrapeContext(config: _configs);
    final plan = await _planner().plan(input, ctx: effectiveCtx, backfillSupertags: false);

    return (
      input: input,
      results: [for (final run in plan.runs) (scraper: run.scraper, result: run.result)],
    );
  }

  /// Applies user-verified fields, tags, and title from a resolved ScrapeResult.
  Future<ScrapePipelineResult> applyResolvedScrapeResult({
    required String resourceId,
    required ScrapeInput input,
    required Scraper scraper,
    required List<ProposedField> selectedFields,
    required List<ProposedTag> selectedTags,
    String? title,
    String? previewImageUrl,
    List<String> backfillSupertags = const [],
  }) async {
    final addedFields = <FieldValue>[];
    final addedTagIds = <String>[];

    // 1. Backfill Supertags
    for (final st in backfillSupertags) {
      final tag = await _tagRepo.findOrCreateTag(st, libraryId: input.subject.scopeId);
      await _tagRepo.attachTagToResource(resourceId, tag.id, source: 'manual_verify:${scraper.id}');
      addedTagIds.add(tag.id);
    }

    // 2. Save selected fields
    for (final pf in selectedFields) {
      String? resolvedEntityId;
      if (pf.entityName != null && pf.entityName!.trim().isNotEmpty) {
        final entity = await _entityRepo.findOrCreateEntity(
          pf.entityType ?? 'other',
          pf.entityName!.trim(),
        );
        resolvedEntityId = entity.id;
      }

      final FieldValue saved;
      if (pf.source == 'user') {
        // User manually customized this value in verification dialog -> source='user', confidence=1.0, locked=true
        saved = await _fieldValueRepo.setUserFieldValue(
          resourceId: resourceId,
          key: pf.key,
          valueText: pf.valueText,
          valueNum: pf.valueNum,
          entityId: resolvedEntityId,
        );
      } else {
        // Unmodified automated value -> source='scraper:xxx', confidence=effectiveConfidence, locked=false
        final effectiveConfidence = getEffectiveConfidence(scraper.id, pf.key, pf.confidence);
        saved = await _fieldValueRepo.setAutomatedFieldValue(
          resourceId: resourceId,
          key: pf.key,
          valueText: pf.valueText,
          valueNum: pf.valueNum,
          entityId: resolvedEntityId,
          source: pf.source,
          confidence: effectiveConfidence,
        );
      }
      addedFields.add(saved);
    }

    // 3. Save selected tags
    for (final pt in selectedTags) {
      if (pt.tagPath.isEmpty) continue;
      final tagId = await _findOrCreateTagPath(pt.tagPath, libraryId: input.subject.scopeId);
      if (tagId != null) {
        await _tagRepo.attachTagToResource(
          resourceId,
          tagId,
          source: 'manual_verify:${scraper.id}',
        );
        addedTagIds.add(tagId);
      }
    }

    // 4. Update title
    if (title != null && title.trim().isNotEmpty) {
      await _resourceRepo.updateResource(
        ResourcesCompanion(
          id: Value(resourceId),
          title: Value(title.trim()),
          updatedAt: Value(DateTime.now().toUtc().millisecondsSinceEpoch),
        ),
      );
    }

    // 5. Update cover image if provided
    if (previewImageUrl != null && previewImageUrl.startsWith('http')) {
      try {
        final client = http.Client();
        try {
          final imgUri = Uri.parse(previewImageUrl);
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
                resourceId,
                response.bodyBytes,
              );
              ThumbnailWidget.invalidateCache(resourceId);
            }
          }
        } finally {
          client.close();
        }
      } catch (_) {}
    }

    return ScrapePipelineResult(
      updatedTitle: title,
      previewImageUrl: previewImageUrl,
      addedOrUpdatedFields: addedFields,
      addedTagIds: addedTagIds,
      backfilledSupertags: backfillSupertags,
    );
  }

  /// Maps a drift row onto the app-agnostic subject the scraping layer expects.
  ScrapeSubject _subjectOf(Resource resource) => ScrapeSubject(
        id: resource.id,
        title: resource.title,
        uri: resource.uri,
        mediaType: resource.mediaType,
        scopeId: resource.libraryId,
      );

  /// Maps drift field rows onto the plain values scrapers can see.
  Map<String, List<ExistingField>> _existingFieldsOf(Map<String, List<FieldValue>> rows) => {
        for (final entry in rows.entries)
          entry.key: [
            for (final f in entry.value)
              ExistingField(f.key, valueText: f.valueText, valueNum: f.valueNum),
          ],
      };

  Future<String?> _findOrCreateTagPath(List<String> path, {String? libraryId}) async {
    String? currentParentId;
    for (final seg in path) {
      final trimmed = seg.trim();
      if (trimmed.isEmpty) continue;

      final tag = await _tagRepo.findOrCreateTag(
        trimmed,
        parentId: currentParentId,
        libraryId: libraryId,
      );
      currentParentId = tag.id;
    }
    return currentParentId;
  }

  /// Cleans up any incorrectly tagged JAV supertags/tags on non-video resources (e.g. images).
}

/// Provider for [ScraperRegistry].
///
/// 默认插件目录：应用数据目录 `plugins/scrapers`（见 [createScraperLoader]），
/// 不再依赖当前工作目录。构造时触发一次内置同步（含哈希升级规则），
/// 之后监听目录变化自动热重载。
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

  // Asynchronously sync builtins, then load settings and yaml plugins
  createScraperLoader().then((loader) {
    registry.setYamlLoader(loader);
    registry.loadSettings().then((_) async {
      await registry.loadYamlPlugins();
      registry.watchYamlPlugins();
    });
  });

  ref.onDispose(() {
    registry.dispose();
  });

  return registry;
});
