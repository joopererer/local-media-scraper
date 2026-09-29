import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'yaml_scraper.dart';

/// Manages discovery, loading, and hot-reloading of YAML scrapers from `plugins/scrapers/`.
class YamlScraperLoader {
  final Directory pluginsDirectory;
  final http.Client? _client;
  List<YamlScraper> _loadedScrapers = [];

  YamlScraperLoader({
    Directory? pluginsDirectory,
    http.Client? client,
  })  : pluginsDirectory = pluginsDirectory ?? Directory('plugins/scrapers'),
        _client = client;

  List<YamlScraper> get loadedScrapers => List.unmodifiable(_loadedScrapers);

  /// Default example YAML configuration for Bilibili videos.
  static const String defaultBilibiliYaml = '''
id: bilibili
name: Bilibili 视频刮削器
description: 根据 BV 号自动抓取 B 站视频标题、UP 主、封面与分区标签
target_supertags:
  - 视频
  - Bilibili
pattern: 'bilibili\\.com/video/(BV[a-zA-Z0-9]{10})|\\b(BV[a-zA-Z0-9]{10})\\b'
supertag_to_backfill:
  - 视频
  - Bilibili
request:
  url_template: 'https://api.bilibili.com/x/web-interface/view?bvid={1}'
  timeout_seconds: 10
fields:
  - key: bvid
    source: 'match:1'
    confidence: 1.0
  - key: title
    source: 'json:data.title'
    is_title: true
    confidence: 0.95
  - key: author
    source: 'json:data.owner.name'
    entity_type: author
    confidence: 0.9
  - key: cover
    source: 'json:data.pic'
    is_preview_image: true
    confidence: 0.9
  - key: summary
    source: 'json:data.desc'
    confidence: 0.85
tags:
  - 'json:data.tname'
  - '视频'
  - 'Bilibili'
''';

  /// Ensures directory exists and writes default example if empty.
  Future<void> ensureDirectoryAndSamples() async {
    try {
      if (!await pluginsDirectory.exists()) {
        await pluginsDirectory.create(recursive: true);
      }
      final sampleFile = File('${pluginsDirectory.path}/bilibili.yaml');
      if (!await sampleFile.exists()) {
        await sampleFile.writeAsString(defaultBilibiliYaml.trim());
      }
    } catch (e) {
      debugPrint('YamlScraperLoader: unable to create default sample: $e');
    }
  }

  /// Scans directory and loads all `.yaml` and `.yml` scrapers.
  Future<List<YamlScraper>> loadScrapers() async {
    final list = <YamlScraper>[];
    try {
      if (!await pluginsDirectory.exists()) {
        await ensureDirectoryAndSamples();
      }

      final entities = pluginsDirectory.listSync(followLinks: false);
      for (final entity in entities) {
        if (entity is File &&
            (entity.path.endsWith('.yaml') || entity.path.endsWith('.yml'))) {
          try {
            final content = await entity.readAsString();
            final scraper = YamlScraper.fromYamlString(content, client: _client);
            list.add(scraper);
            debugPrint('YamlScraperLoader: loaded plugin "${scraper.displayName}" (${scraper.id}) from ${entity.path}');
          } catch (e) {
            debugPrint('YamlScraperLoader: error loading ${entity.path}: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('YamlScraperLoader: failed to scan directory: $e');
    }

    _loadedScrapers = list;
    return list;
  }

  /// Reloads all scrapers from disk.
  Future<List<YamlScraper>> reload() async {
    return loadScrapers();
  }
}
