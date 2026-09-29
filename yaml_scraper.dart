import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart';

import 'scraper.dart';

/// A field rule defined in YAML scraper specification.
class YamlFieldRule {
  final String key;
  final String source;
  final String? entityType;
  final bool isTitle;
  final bool isPreviewImage;
  final double confidence;

  const YamlFieldRule({
    required this.key,
    required this.source,
    this.entityType,
    this.isTitle = false,
    this.isPreviewImage = false,
    this.confidence = 0.85,
  });

  factory YamlFieldRule.fromYaml(dynamic map) {
    if (map is! Map) {
      throw ArgumentError('Field rule must be a map');
    }
    return YamlFieldRule(
      key: map['key']?.toString() ?? '',
      source: map['source']?.toString() ?? '',
      entityType: map['entity_type']?.toString(),
      isTitle: map['is_title'] == true || map['key'] == 'title',
      isPreviewImage: map['is_preview_image'] == true ||
          map['key'] == 'cover' ||
          map['key'] == 'poster',
      confidence: (map['confidence'] is num)
          ? (map['confidence'] as num).toDouble()
          : 0.85,
    );
  }
}

/// A declarative scraper defined via YAML configuration.
class YamlScraper implements Scraper {
  final String _id;
  final String _displayName;
  final String _description;
  final List<String> _targetSupertags;
  final RegExp? _patternRegex;
  final List<String>? _supertagToBackfill;
  final String? _urlTemplate;
  final Map<String, String> _headers;
  final int _timeoutSeconds;
  final List<YamlFieldRule> _fields;
  final List<String> _tags;
  final http.Client? _client;

  YamlScraper({
    required String id,
    required String displayName,
    required String description,
    List<String> targetSupertags = const [],
    RegExp? patternRegex,
    List<String>? supertagToBackfill,
    String? urlTemplate,
    Map<String, String> headers = const {},
    int timeoutSeconds = 10,
    List<YamlFieldRule> fields = const [],
    List<String> tags = const [],
    http.Client? client,
  })  : _id = id,
        _displayName = displayName,
        _description = description,
        _targetSupertags = targetSupertags,
        _patternRegex = patternRegex,
        _supertagToBackfill = supertagToBackfill,
        _urlTemplate = urlTemplate,
        _headers = headers,
        _timeoutSeconds = timeoutSeconds,
        _fields = fields,
        _tags = tags,
        _client = client;

  factory YamlScraper.fromYamlString(String yamlContent, {http.Client? client}) {
    final doc = loadYaml(yamlContent);
    if (doc is! Map) {
      throw ArgumentError('YAML content must be a key-value mapping.');
    }

    final id = doc['id']?.toString() ?? 'custom_yaml';
    final name = doc['name']?.toString() ?? doc['displayName']?.toString() ?? id;
    final desc = doc['description']?.toString() ?? 'Declarative YAML scraper';

    final targetSt = <String>[];
    final targetRaw = doc['target_supertags'];
    if (targetRaw is Iterable) {
      for (final item in targetRaw) {
        targetSt.add(item.toString());
      }
    }

    RegExp? pattern;
    if (doc['pattern'] != null) {
      pattern = RegExp(doc['pattern'].toString(), caseSensitive: false);
    }

    List<String>? backfill;
    final backfillRaw = doc['supertag_to_backfill'];
    if (backfillRaw is Iterable) {
      backfill = backfillRaw.map((e) => e.toString()).toList();
    }

    String? urlTemplate;
    Map<String, String> headers = {};
    int timeout = 10;

    if (doc['request'] is Map) {
      final req = doc['request'] as Map;
      urlTemplate = req['url_template']?.toString();
      timeout = (req['timeout_seconds'] is int) ? req['timeout_seconds'] as int : 10;
      if (req['headers'] is Map) {
        (req['headers'] as Map).forEach((k, v) {
          headers[k.toString()] = v.toString();
        });
      }
    }

    final fieldRules = <YamlFieldRule>[];
    final fieldsRaw = doc['fields'];
    if (fieldsRaw is Iterable) {
      for (final f in fieldsRaw) {
        if (f is Map) {
          fieldRules.add(YamlFieldRule.fromYaml(f));
        }
      }
    }

    final tagRules = <String>[];
    final tagsRaw = doc['tags'];
    if (tagsRaw is Iterable) {
      for (final t in tagsRaw) {
        tagRules.add(t.toString());
      }
    }

    return YamlScraper(
      id: id,
      displayName: name,
      description: desc,
      targetSupertags: targetSt,
      patternRegex: pattern,
      supertagToBackfill: backfill,
      urlTemplate: urlTemplate,
      headers: headers,
      timeoutSeconds: timeout,
      fields: fieldRules,
      tags: tagRules,
      client: client,
    );
  }

  @override
  String get id => _id;

  @override
  String get displayName => _displayName;

  @override
  String get description => _description;

  @override
  List<String> get targetSupertags => _targetSupertags;

  @override
  RegExp? get patternRegex => _patternRegex;

  @override
  List<String>? get supertagToBackfill => _supertagToBackfill;

  @override
  bool canHandle(ScrapeInput input) {
    // 1. Check Supertags
    final existingTags = input.existingTagNames;
    if (_targetSupertags.any((st) => existingTags.contains(st.toLowerCase()))) {
      return true;
    }

    // 2. Check pattern regex against sourceUrl, uri, or fileName
    final pattern = _patternRegex;
    if (pattern != null) {
      final url = input.sourceUrl ?? input.resource.uri ?? '';
      if (url.isNotEmpty && pattern.hasMatch(url)) return true;

      final fn = input.fileName ?? input.resource.title ?? '';
      if (fn.isNotEmpty && pattern.hasMatch(fn)) return true;
    }

    return false;
  }

  @override
  Future<ScrapeResult> scrape(ScrapeInput input, ScrapeContext ctx) async {
    final client = ctx.client ?? _client ?? http.Client();
    final url = input.sourceUrl ?? input.resource.uri ?? '';
    final fn = input.fileName ?? input.resource.title ?? '';
    final targetStr = url.isNotEmpty ? url : fn;

    // 1. Extract matches from pattern
    Match? match;
    final pattern = _patternRegex;
    if (pattern != null) {
      match = pattern.firstMatch(targetStr);
    }

    String? responseBody;
    dynamic jsonRoot;

    // 2. If url_template is provided, perform HTTP request
    final tmpl = _urlTemplate;
    if (tmpl != null) {
      String requestUrl = tmpl;
      if (match != null) {
        for (int i = 1; i <= match.groupCount; i++) {
          final val = match.group(i);
          if (val != null) {
            requestUrl = requestUrl.replaceAll('{$i}', Uri.encodeComponent(val));
          }
        }
      }
      requestUrl = requestUrl.replaceAll('{input}', Uri.encodeComponent(targetStr));

      try {
        ctx.log('YamlScraper($_id): GET $requestUrl');
        final resp = await client.get(
          Uri.parse(requestUrl),
          headers: _headers.isNotEmpty
              ? _headers
              : {
                  'User-Agent':
                      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                },
        ).timeout(Duration(seconds: _timeoutSeconds));

        if (resp.statusCode == 200) {
          responseBody = resp.body;
          try {
            jsonRoot = jsonDecode(responseBody);
          } catch (_) {
            // Not JSON, keep as raw text / HTML
          }
        } else {
          ctx.log('YamlScraper($_id): HTTP ${resp.statusCode}');
        }
      } catch (e) {
        ctx.log('YamlScraper($_id) request failed: $e');
      }
    }

    // 3. Extract fields
    final extractedFields = <ProposedField>[];
    String? proposedTitle;
    String? previewImageUrl;

    for (final rule in _fields) {
      final val = _resolveSource(
        rule.source,
        rawText: responseBody ?? targetStr,
        jsonData: jsonRoot,
        match: match,
      );

      if (val != null && val.toString().trim().isNotEmpty) {
        final valStr = val.toString().trim();
        if (rule.isTitle) {
          proposedTitle = valStr;
        }
        if (rule.isPreviewImage) {
          previewImageUrl = valStr;
        }

        extractedFields.add(ProposedField(
          key: rule.key,
          valueText: valStr,
          entityName: rule.entityType != null ? valStr : null,
          entityType: rule.entityType,
          confidence: rule.confidence,
          source: 'scraper:$_id',
        ));
      }
    }

    // 4. Extract tags
    final extractedTags = <ProposedTag>[];
    for (final tagDef in _tags) {
      if (tagDef.startsWith('json:') || tagDef.startsWith('regex:')) {
        final val = _resolveSource(
          tagDef,
          rawText: responseBody ?? targetStr,
          jsonData: jsonRoot,
          match: match,
        );
        if (val != null) {
          if (val is List) {
            for (final item in val) {
              final s = item.toString().trim();
              if (s.isNotEmpty) {
                extractedTags.add(ProposedTag(tagPath: [s], confidence: 0.85));
              }
            }
          } else {
            final s = val.toString().trim();
            if (s.isNotEmpty) {
              extractedTags.add(ProposedTag(tagPath: [s], confidence: 0.85));
            }
          }
        }
      } else {
        // Static tag path e.g. "视频/Bilibili" or "视频"
        final parts = tagDef.split('/').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
        if (parts.isNotEmpty) {
          extractedTags.add(ProposedTag(tagPath: parts, confidence: 0.9));
        }
      }
    }

    return ScrapeResult(
      proposedTitle: proposedTitle,
      previewImageUrl: previewImageUrl,
      fields: extractedFields,
      tags: extractedTags,
    );
  }

  /// Resolves value from json, regex, or static definition.
  dynamic _resolveSource(
    String source, {
    required String rawText,
    dynamic jsonData,
    Match? match,
  }) {
    if (source.startsWith('json:')) {
      if (jsonData == null) return null;
      final path = source.substring(5).split('.');
      dynamic cur = jsonData;
      for (final p in path) {
        if (cur is Map && cur.containsKey(p)) {
          cur = cur[p];
        } else {
          return null;
        }
      }
      return cur;
    } else if (source.startsWith('regex:')) {
      final pattern = source.substring(6);
      final r = RegExp(pattern, caseSensitive: false);
      final m = r.firstMatch(rawText);
      if (m != null) {
        return m.groupCount >= 1 ? m.group(1) : m.group(0);
      }
      return null;
    } else if (source.startsWith('match:')) {
      final indexStr = source.substring(6);
      final idx = int.tryParse(indexStr);
      if (idx != null && match != null && match.groupCount >= idx) {
        return match.group(idx);
      }
      return null;
    } else if (source.startsWith('static:')) {
      return source.substring(7);
    }
    return null;
  }
}
