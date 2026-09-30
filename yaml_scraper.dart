import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart';

import 'scraper.dart';

/// A field rule defined in YAML scraper specification.
class YamlFieldRule {
  final String key;
  final String source;
  final String? fallback;
  final String? prefix;
  final String? suffix;
  final String? entityType;
  final String valueType; // 'string' or 'number'
  final bool isTitle;
  final bool isPreviewImage;
  final double confidence;

  const YamlFieldRule({
    required this.key,
    required this.source,
    this.fallback,
    this.prefix,
    this.suffix,
    this.entityType,
    this.valueType = 'string',
    this.isTitle = false,
    this.isPreviewImage = false,
    this.confidence = 0.85,
  });

  factory YamlFieldRule.fromYaml(dynamic map) {
    if (map is! Map) {
      throw ArgumentError('Field rule must be a map');
    }
    final key = map['key']?.toString() ?? '';
    final valType = map['value_type']?.toString().toLowerCase() ??
        (key == 'rating' || key == 'year' ? 'number' : 'string');
    return YamlFieldRule(
      key: key,
      source: map['source']?.toString() ?? '',
      fallback: map['fallback']?.toString(),
      prefix: map['prefix']?.toString(),
      suffix: map['suffix']?.toString(),
      entityType: map['entity_type']?.toString(),
      valueType: valType,
      isTitle: map['is_title'] == true || key == 'title',
      isPreviewImage: map['is_preview_image'] == true ||
          key == 'cover' ||
          key == 'poster',
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
  final List<String> _mediaTypes;
  final List<String> _targetSupertags;
  final RegExp? _patternRegex;
  final List<String>? _supertagToBackfill;
  final String? _urlTemplate;
  final Map<String, String> _headers;
  final int _timeoutSeconds;
  final int _priority;
  final List<YamlFieldRule> _fields;
  final List<String> _tags;
  final http.Client? _client;

  YamlScraper({
    required String id,
    required String displayName,
    required String description,
    int priority = 60,
    List<String> mediaTypes = const [],
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
        _priority = priority,
        _mediaTypes = mediaTypes,
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

    final mediaTypes = <String>[];
    final mediaRaw = doc['media_types'] ?? doc['target_media_types'];
    if (mediaRaw is Iterable) {
      for (final item in mediaRaw) {
        mediaTypes.add(item.toString().toLowerCase().trim());
      }
    }

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

    final priority = (doc['priority'] is num) ? (doc['priority'] as num).toInt() : 60;

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
      priority: priority,
      mediaTypes: mediaTypes,
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
  int get priority => _priority;

  @override
  List<String> get targetSupertags => _targetSupertags;

  @override
  RegExp? get patternRegex => _patternRegex;

  @override
  List<String>? get supertagToBackfill => _supertagToBackfill;

  List<String> get mediaTypes => List.unmodifiable(_mediaTypes);

  @override
  bool canHandle(ScrapeInput input) {
    // 0. Check media type restriction if specified
    if (_mediaTypes.isNotEmpty) {
      final resType = input.resource.mediaType?.toLowerCase();
      if (resType != null && resType.isNotEmpty && !_mediaTypes.contains(resType)) {
        return false;
      }
    }

    // 1. Check Supertags
    final existingTags = input.existingTagNames;
    if (_targetSupertags.isNotEmpty && _targetSupertags.any((st) => existingTags.contains(st.toLowerCase()))) {
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
        final fullMatch = match.group(0);
        if (fullMatch != null) {
          requestUrl = requestUrl.replaceAll('{0}', Uri.encodeComponent(fullMatch));
        }
        for (int i = 1; i <= match.groupCount; i++) {
          final val = match.group(i) ?? '';
          requestUrl = requestUrl.replaceAll('{$i}', Uri.encodeComponent(val));
        }
      }
      requestUrl = requestUrl.replaceAll('{input}', Uri.encodeComponent(targetStr));

      // Replace {config:key} placeholders from ScrapeContext
      requestUrl = requestUrl.replaceAllMapped(RegExp(r'\{config:([a-zA-Z0-9_]+)\}'), (m) {
        final cfgKey = m.group(1)!;
        final cfgVal = ctx.getConfig(cfgKey);
        return cfgVal != null && cfgVal.isNotEmpty ? Uri.encodeComponent(cfgVal) : '';
      });

      // Guard: if any placeholder like {1}, {2} remains unreplaced, abort request
      if (RegExp(r'\{[0-9a-zA-Z_]+\}').hasMatch(requestUrl)) {
        ctx.log('YamlScraper($_id): 匹配未命中或占位符未替换完毕 ($requestUrl)，跳过网络请求');
      } else {
        try {
          ctx.log('YamlScraper($_id): GET $requestUrl');
          final effectiveHeaders = <String, String>{
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Cookie': 'existmag=all; age=verified; over18=1',
          };
          _headers.forEach((k, v) {
            // Support {config:key} in headers
            effectiveHeaders[k] = v.replaceAllMapped(RegExp(r'\{config:([a-zA-Z0-9_]+)\}'), (m) {
              return ctx.getConfig(m.group(1)!) ?? '';
            });
          });

          final resp = await client.get(
            Uri.parse(requestUrl),
            headers: effectiveHeaders,
          ).timeout(Duration(seconds: _timeoutSeconds));

          if (resp.statusCode == 200) {
            responseBody = utf8.decode(resp.bodyBytes, allowMalformed: true);
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
    }

    // 3. Extract fields
    final extractedFields = <ProposedField>[];
    String? proposedTitle;
    String? previewImageUrl;

    for (final rule in _fields) {
      dynamic val = _resolveSource(
        rule.source,
        rawText: responseBody ?? targetStr,
        jsonData: jsonRoot,
        match: match,
      );

      // Fallback if primary source produced null or empty string
      if ((val == null || val.toString().trim().isEmpty) && rule.fallback != null) {
        val = _resolveSource(
          rule.fallback!,
          rawText: responseBody ?? targetStr,
          jsonData: jsonRoot,
          match: match,
        );
      }

      if (val != null && val.toString().trim().isNotEmpty) {
        var valStr = val.toString().trim();
        if (rule.prefix != null && !valStr.startsWith(rule.prefix!)) {
          valStr = '${rule.prefix}$valStr';
        }
        if (rule.suffix != null && !valStr.endsWith(rule.suffix!)) {
          valStr = '$valStr${rule.suffix}';
        }

        if (rule.isTitle) {
          proposedTitle = valStr;
        }
        if (rule.isPreviewImage) {
          previewImageUrl = valStr;
        }

        double? valNum;
        if (rule.valueType == 'number') {
          valNum = double.tryParse(valStr);
        }

        extractedFields.add(ProposedField(
          key: rule.key,
          valueText: valStr,
          valueNum: valNum,
          entityName: rule.entityType != null ? valStr : null,
          entityType: rule.entityType,
          confidence: rule.confidence,
          source: 'scraper:$_id',
        ));
      }
    }

    // 4. Extract tags with multi-level path support & wildcard iteration
    final extractedTags = <ProposedTag>[];
    for (final tagDef in _tags) {
      if (tagDef.startsWith('json:')) {
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
                final parts = s.split('/').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
                if (parts.isNotEmpty) {
                  extractedTags.add(ProposedTag(tagPath: parts, confidence: 0.85));
                }
              }
            }
          } else {
            final s = val.toString().trim();
            if (s.isNotEmpty) {
              final parts = s.split('/').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
              if (parts.isNotEmpty) {
                extractedTags.add(ProposedTag(tagPath: parts, confidence: 0.85));
              }
            }
          }
        }
      } else if (tagDef.startsWith('regex:')) {
        // Multi-match support for regex tags
        final patternStr = tagDef.substring(6);
        try {
          final r = RegExp(patternStr, caseSensitive: false);
          final matches = r.allMatches(responseBody ?? targetStr);
          for (final m in matches) {
            final s = (m.groupCount >= 1 ? m.group(1) : m.group(0))?.trim();
            if (s != null && s.isNotEmpty) {
              final parts = s.split('/').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
              if (parts.isNotEmpty) {
                extractedTags.add(ProposedTag(tagPath: parts, confidence: 0.85));
              }
            }
          }
        } catch (_) {}
      } else {
        // Static or parameterized tag path e.g. "JAV / 女优 / {actress}"
        String resolvedTag = tagDef;
        for (final field in extractedFields) {
          if (field.valueText != null) {
            resolvedTag = resolvedTag.replaceAll('{${field.key}}', field.valueText!);
          }
        }
        // If placeholder still unresolved (e.g. {actress} without actress found), ignore
        if (!RegExp(r'\{[a-zA-Z0-9_]+\}').hasMatch(resolvedTag)) {
          final parts = resolvedTag.split('/').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
          if (parts.isNotEmpty) {
            extractedTags.add(ProposedTag(tagPath: parts, confidence: 0.9));
          }
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
      return _navigateJson(jsonData, path);
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

  /// Recursively traverses JSON structures supporting wildcards ('*') and array indices ('items[0]').
  dynamic _navigateJson(dynamic root, List<String> parts) {
    if (parts.isEmpty) return root;
    final head = parts.first;
    final tail = parts.sublist(1);

    if (root == null) return null;

    if (root is List) {
      if (head == '*') {
        final list = <dynamic>[];
        for (final item in root) {
          final res = _navigateJson(item, tail);
          if (res != null) {
            if (res is List) {
              list.addAll(res);
            } else {
              list.add(res);
            }
          }
        }
        return list.isNotEmpty ? list : null;
      }
      final index = int.tryParse(head);
      if (index != null && index >= 0 && index < root.length) {
        return _navigateJson(root[index], tail);
      }
      return null;
    }

    if (root is Map) {
      // Check for array index notation e.g. "items[0]"
      final arrayMatch = RegExp(r'^([a-zA-Z0-9_]+)\[(\d+)\]$').firstMatch(head);
      if (arrayMatch != null) {
        final key = arrayMatch.group(1)!;
        final idx = int.parse(arrayMatch.group(2)!);
        final listVal = root[key];
        if (listVal is List && idx >= 0 && idx < listVal.length) {
          return _navigateJson(listVal[idx], tail);
        }
        return null;
      }

      if (root.containsKey(head)) {
        return _navigateJson(root[head], tail);
      }
    }

    return null;
  }
}
