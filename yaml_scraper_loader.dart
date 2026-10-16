import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../plugins/plugin_asset_source.dart';
import 'yaml_scraper.dart';

/// Manages discovery, loading, and hot-reloading of YAML scrapers.
///
/// 目录：应用数据目录 `plugins/scrapers`（见 [PluginAssetSource.userDir]），
/// 不再依赖当前工作目录。内置插件由 [syncBuiltinPlugins] 从打包资源同步
/// （首次复制 + 哈希比对的升级规则），本文件不再内嵌默认 YAML 常量。
class YamlScraperLoader {
  final Directory pluginsDirectory;
  final http.Client? _client;
  List<YamlScraper> _loadedScrapers = [];

  YamlScraperLoader({Directory? pluginsDirectory, http.Client? client})
    : pluginsDirectory = pluginsDirectory ?? Directory('plugins/scrapers'),
      _client = client;

  /// 生产构造：用户目录（应用数据目录），附带内置同步。
  /// [onBuiltinUpdateNotice] 收到"有新内置版本但用户已修改"的文件名（可为空）。
  static Future<YamlScraperLoader> inUserDir({
    http.Client? client,
    void Function(List<String>)? onBuiltinUpdateNotice,
  }) async {
    final dir = await PluginAssetSource.userDir('scrapers');
    final loader = YamlScraperLoader(pluginsDirectory: dir, client: client);
    final pending = await syncBuiltinPlugins('scrapers');
    if (pending.isNotEmpty) onBuiltinUpdateNotice?.call(pending);
    return loader;
  }

  List<YamlScraper> get loadedScrapers => List.unmodifiable(_loadedScrapers);


  /// Ensures directory exists; then syncs builtin plugins from packaged assets
  /// (first copy + hash-based upgrade, see [syncBuiltinPlugins]).
  /// Returns files that have a newer builtin version but were modified by the
  /// user (kept as-is; surfaced in plugin settings).
  ///
  /// 测试/临时目录（系统临时目录或相对路径）只建目录，不做内置同步
  /// （内置同步需要 Flutter asset 环境，单元测试中不可用）。
  Future<List<String>> ensureDirectoryAndSamples() async {
    try {
      if (!await pluginsDirectory.exists()) {
        await pluginsDirectory.create(recursive: true);
      }
      if (!p.isAbsolute(pluginsDirectory.path) ||
          p.isWithin(Directory.systemTemp.path, pluginsDirectory.path)) {
        return const [];
      }
      return syncBuiltinPlugins('scrapers');
    } catch (e) {
      debugPrint('YamlScraperLoader: unable to sync builtin samples: $e');
      return const [];
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
