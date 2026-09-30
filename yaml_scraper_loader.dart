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
priority: 75
media_types:
  - video
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

  /// Example YAML configuration for custom JAV online scraping via mirror or API.
  static const String sampleJavBusYaml = '''
id: javbus_custom
name: JavBus 自定义搜刮器 (示例)
description: 声明式 JavBus 插件示例，支持从网页抽取标题、女优、封面与发行日期
priority: 70
media_types:
  - video
target_supertags:
  - JAV
pattern: '(?<![a-zA-Z0-9])([a-zA-Z]{2,6})[-_](\\d{2,5})(?![a-zA-Z0-9])'
supertag_to_backfill:
  - JAV
request:
  url_template: 'https://www.javbus.com/{1}-{2}'
  timeout_seconds: 10
fields:
  - key: code
    source: 'match:0'
    confidence: 1.0
  - key: title
    source: 'regex:<title>(.*?)</title>'
    is_title: true
    confidence: 0.9
  - key: cover
    source: 'regex:<a class="bigImage" href="([^"]+)"'
    is_preview_image: true
    confidence: 0.95
  - key: actress
    source: 'regex:<span class="genre"><a href="[^"]*star[^"]*">([^<]+)</a></span>'
    entity_type: actress
    confidence: 0.95
  - key: year
    source: 'regex:<span class="header">发行时间:</span>\\s*([0-9]{4})'
    confidence: 0.9
tags:
  - 'JAV'
  - 'JAV / 女优 / {actress}'
''';

  /// Ensures directory exists and writes default examples if missing.
  Future<void> ensureDirectoryAndSamples() async {
    try {
      if (!await pluginsDirectory.exists()) {
        await pluginsDirectory.create(recursive: true);
      }
      final sampleBili = File('${pluginsDirectory.path}/bilibili.yaml');
      if (!await sampleBili.exists()) {
        await sampleBili.writeAsString(defaultBilibiliYaml.trim());
      }
      final sampleJav = File('${pluginsDirectory.path}/javbus_sample.yaml');
      if (!await sampleJav.exists()) {
        await sampleJav.writeAsString(sampleJavBusYaml.trim());
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
