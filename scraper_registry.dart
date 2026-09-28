import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/media_types.dart';
import '../../data/db/app_database.dart';
import '../../data/repositories/entity_repository.dart';
import '../../data/repositories/field_value_repository.dart';
import '../../data/repositories/resource_repository.dart';
import '../../data/repositories/tag_repository.dart';
import 'filename_scraper.dart';
import 'scraper.dart';
import 'webpage_scraper.dart';

/// Summary of all results produced by the scraper pipeline.
class ScrapePipelineResult {
  final String? updatedTitle;
  final String? previewImageUrl;
  final List<FieldValue> addedOrUpdatedFields;
  final List<String> addedTagIds;

  const ScrapePipelineResult({
    this.updatedTitle,
    this.previewImageUrl,
    this.addedOrUpdatedFields = const [],
    this.addedTagIds = const [],
  });
}

/// Registry and pipeline executor for all metadata scrapers.
class ScraperRegistry {
  final AppDatabase _db;
  final ResourceRepository _resourceRepo;
  final FieldValueRepository _fieldValueRepo;
  final EntityRepository _entityRepo;
  final TagRepository _tagRepo;

  final List<Scraper> _scrapers = [];
  final Map<String, bool> _enabledStates = {};

  ScraperRegistry({
    required AppDatabase db,
    required ResourceRepository resourceRepo,
    required FieldValueRepository fieldValueRepo,
    required EntityRepository entityRepo,
    required TagRepository tagRepo,
    List<Scraper>? initialScrapers,
  })  : _db = db,
        _resourceRepo = resourceRepo,
        _fieldValueRepo = fieldValueRepo,
        _entityRepo = entityRepo,
        _tagRepo = tagRepo {
    if (initialScrapers != null) {
      _scrapers.addAll(initialScrapers);
    } else {
      // Register built-in scrapers
      _scrapers.add(FileNameScraper());
      _scrapers.add(WebPageScraper());
    }
  }

  List<Scraper> get scrapers => List.unmodifiable(_scrapers);

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

  /// Loads scraper enabled/disabled settings from database.
  Future<void> loadSettings() async {
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
  }

  Future<void> _persistSettings() async {
    final jsonStr = jsonEncode(_enabledStates);
    await _db.into(_db.settings).insertOnConflictUpdate(
      SettingsCompanion.insert(
        key: 'scraper_settings',
        valueJson: jsonStr,
      ),
    );
  }

  /// Executes all enabled scrapers that can handle the input.
  Future<ScrapePipelineResult> executePipeline(
    ScrapeInput input, {
    ScrapeContext ctx = const ScrapeContext(),
  }) async {
    final addedFields = <FieldValue>[];
    final addedTagIds = <String>[];
    String? bestTitle;
    String? bestPreviewImage;

    for (final scraper in _scrapers) {
      if (!isScraperEnabled(scraper.id)) continue;
      if (!scraper.canHandle(input)) continue;

      try {
        ctx.log('Running scraper: ${scraper.displayName}');
        final result = await scraper.scrape(input, ctx);
        if (result.isEmpty) continue;

        if (result.proposedTitle != null && bestTitle == null) {
          bestTitle = result.proposedTitle;
        }

        if (result.previewImageUrl != null && bestPreviewImage == null) {
          bestPreviewImage = result.previewImageUrl;
        }

        // Apply proposed fields respecting priority rules
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
        ctx.log('Scraper ${scraper.id} failed: $e');
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

    return ScrapePipelineResult(
      updatedTitle: bestTitle,
      previewImageUrl: bestPreviewImage,
      addedOrUpdatedFields: addedFields,
      addedTagIds: addedTagIds,
    );
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

  return ScraperRegistry(
    db: db,
    resourceRepo: resourceRepo,
    fieldValueRepo: fieldValueRepo,
    entityRepo: entityRepo,
    tagRepo: tagRepo,
  );
});
