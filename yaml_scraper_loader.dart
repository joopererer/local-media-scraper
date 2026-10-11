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

  /// Default YAML configuration for Douban.
  static const String defaultDoubanYaml = '''
id: douban
name: 豆瓣 (Douban)
description: 抓取中文影视图书元数据（评分、导演、演员、海报与简介）
priority: 85
media_types:
  - video
target_supertags:
  - 电影
  - Movie
  - 影视
pattern: 'douban\\.com/subject/(\\d+)|\\[(?:douban|db)[:\\-](\\d+)\\]'
supertag_to_backfill:
  - 电影
request:
  url_template: 'https://movie.douban.com/subject/{1}{2}/'
  timeout_seconds: 10
fields:
  - key: title
    source: 'regex:<span property="v:itemreviewed">(.*?)</span>'
    is_title: true
    confidence: 0.95
  - key: rating
    source: 'regex:<strong class="ll rating_num" property="v:average">(.*?)</strong>'
    value_type: number
    confidence: 0.9
  - key: director
    source: 'regex:<a [^>]*rel="v:directedBy"[^>]*>(.*?)</a>'
    entity_type: director
    confidence: 0.9
  - key: actress
    source: 'regex:<a [^>]*rel="v:starring"[^>]*>(.*?)</a>'
    entity_type: actress
    confidence: 0.9
  - key: year
    source: 'regex:<span class="year">\\((\\d{4})\\)</span>'
    value_type: number
    confidence: 0.9
  - key: summary
    source: 'regex:<span property="v:summary"[^>]*>([\\s\\S]*?)</span>'
    confidence: 0.85
  - key: cover
    source: 'regex:<img [^>]*src="([^"]+)"[^>]*title="点击看更多海报"'
    is_preview_image: true
    confidence: 0.95
tags:
  - 'regex:<span property="v:genre">(.*?)</span>'
  - '豆瓣'
  - '影视 / 华语电影'
  - '影视 / {year}'
  - '影视 / 导演 / {director}'
''';

  /// Default YAML configuration for Bangumi.
  static const String defaultBangumiYaml = '''
id: bangumi
name: Bangumi 番组计划
description: 提取二次元动画、漫画元数据（日文原名、中文名、制作公司与封面）
priority: 85
media_types:
  - video
target_supertags:
  - 番剧
  - Anime
  - 动画
  - ACG
pattern: '(?:bgm\\.tv|bangumi\\.tv)/subject/(\\d+)|\\[(?:bangumi|bgm)[:\\-](\\d+)\\]'
supertag_to_backfill:
  - 番剧
request:
  url_template: 'https://api.bgm.tv/v0/subjects/{1}{2}'
  timeout_seconds: 10
  headers:
    Accept: 'application/json'
fields:
  - key: title
    source: 'json:name_cn'
    fallback: 'json:name'
    is_title: true
    confidence: 0.95
  - key: original_title
    source: 'json:name'
    confidence: 0.9
  - key: summary
    source: 'json:summary'
    confidence: 0.85
  - key: rating
    source: 'json:rating.score'
    value_type: number
    confidence: 0.9
  - key: year
    source: 'regex:date":\\s*"(\\d{4})'
    value_type: number
    confidence: 0.9
  - key: cover
    source: 'json:images.large'
    is_preview_image: true
    confidence: 0.95
tags:
  - 'json:tags.*.name'
  - '番剧'
  - '番剧 / {year}'
''';

  /// Default YAML configuration for TMDB.
  static const String defaultTmdbYaml = '''
id: tmdb
name: The Movie Database (TMDB)
description: 国际影视剧集元数据刮削（支持 API Key 与海报）
priority: 90
media_types:
  - video
target_supertags:
  - 电影
  - Movie
  - 影视
pattern: 'themoviedb\\.org/movie/(\\d+)|tmdb\\.org/movie/(\\d+)'
supertag_to_backfill:
  - 电影
request:
  url_template: 'https://api.themoviedb.org/3/movie/{1}{2}?api_key={config:tmdb_api_key}&language=zh-CN'
  timeout_seconds: 10
fields:
  - key: title
    source: 'json:title'
    is_title: true
    confidence: 0.95
  - key: original_title
    source: 'json:original_title'
    confidence: 0.9
  - key: summary
    source: 'json:overview'
    confidence: 0.85
  - key: rating
    source: 'json:vote_average'
    value_type: number
    confidence: 0.9
  - key: year
    source: 'regex:^(\\d{4})'
    value_type: number
    confidence: 0.9
  - key: cover
    source: 'json:poster_path'
    prefix: 'https://image.tmdb.org/t/p/w500'
    is_preview_image: true
    confidence: 0.95
tags:
  - 'json:genres.*.name'
  - '电影'
  - '电影 / {year}'
''';

  /// Default YAML configuration for custom JAV online scraping.
  static const String defaultJavBusYaml = '''
id: javbus
name: JavBus 搜刮器
description: 根据番号抽取标题、女优、封面、制作商与发行年份
priority: 70
media_types:
  - video
target_supertags:
  - JAV
pattern: '(?<![a-zA-Z0-9])(?!(?:IMG|DSC|PIC|PHOTO|RAW|SCAN|DOC|FILE|TEST|SAMPLE|COVER|POSTER|PAGE|ITEM|THUMB|PART|DISC|MP|EP|CH|VOL)[-_])([a-zA-Z]{2,6})[-_](\\d{2,5})(?![a-zA-Z0-9])'
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
  - key: studio
    source: 'regex:<span class="header">制作商:</span>\\s*<a href="[^"]*">([^<]+)</a>'
    entity_type: studio
    confidence: 0.95
  - key: year
    source: 'regex:<span class="header">发行时间:</span>\\s*([0-9]{4})'
    value_type: number
    confidence: 0.9
tags:
  - 'JAV'
  - 'JAV / 女优 / {actress}'
  - 'JAV / 片商 / {studio}'
''';

  static const String sampleJavBusYaml = defaultJavBusYaml;

  /// Ensures directory exists and writes default examples if missing.
  Future<void> ensureDirectoryAndSamples() async {
    try {
      if (!await pluginsDirectory.exists()) {
        await pluginsDirectory.create(recursive: true);
      }
      final filesToEnsure = {
        'bilibili.yaml': defaultBilibiliYaml,
        'javbus.yaml': defaultJavBusYaml,
        'douban.yaml': defaultDoubanYaml,
        'bangumi.yaml': defaultBangumiYaml,
        'tmdb.yaml': defaultTmdbYaml,
      };

      for (final entry in filesToEnsure.entries) {
        final f = File('${pluginsDirectory.path}/${entry.key}');
        if (!await f.exists()) {
          await f.writeAsString(entry.value.trim());
        }
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
