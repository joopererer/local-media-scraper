import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart';

import '../media_type.dart';
import '../scraper.dart';

/// Configuration schema field definition for a YAML scraper.
class YamlConfigSchema {
  final String key;
  final String label;
  final String type; // 'string', 'password', 'url', 'boolean'
  final bool required;
  final String? defaultValue;
  final String? description;

  const YamlConfigSchema({
    required this.key,
    required this.label,
    this.type = 'string',
    this.required = false,
    this.defaultValue,
    this.description,
  });

  factory YamlConfigSchema.fromYaml(dynamic map) {
    if (map is! Map) {
      throw ArgumentError('Config schema field must be a map');
    }
    return YamlConfigSchema(
      key: map['key']?.toString() ?? '',
      label: map['label']?.toString() ?? map['key']?.toString() ?? '',
      type: map['type']?.toString().toLowerCase() ?? 'string',
      required: map['required'] == true,
      defaultValue:
          map['default']?.toString() ?? map['default_value']?.toString(),
      description: map['description']?.toString(),
    );
  }
}

/// Request URL definition for multi-address cascade fallback.
///
/// Entries are tried in order; the first one that returns HTTP 200 and passes
/// the optional body checks wins.
class YamlRequestUrl {
  final String url;
  final int timeoutSeconds;
  final Map<String, String> headers;

  /// Body must contain every one of these (templates rendered, case-insensitive).
  final List<String> requireBodyContains;

  /// Body must contain none of these (case-insensitive), e.g. an age-gate page.
  final List<String> rejectBodyContains;

  const YamlRequestUrl({
    required this.url,
    this.timeoutSeconds = 10,
    this.headers = const {},
    this.requireBodyContains = const [],
    this.rejectBodyContains = const [],
  });

  factory YamlRequestUrl.fromYaml(dynamic map) {
    if (map is! Map) {
      throw ArgumentError('Request URL entry must be a map');
    }
    final headers = <String, String>{};
    if (map['headers'] is Map) {
      (map['headers'] as Map).forEach((k, v) {
        headers[k.toString()] = v.toString();
      });
    }
    List<String> strList(dynamic raw) =>
        raw is Iterable ? raw.map((e) => e.toString()).toList() : const [];
    return YamlRequestUrl(
      url: map['url']?.toString() ?? '',
      timeoutSeconds: (map['timeout_seconds'] is int)
          ? map['timeout_seconds'] as int
          : 10,
      headers: headers,
      requireBodyContains: strList(map['require_body_contains']),
      rejectBodyContains: strList(map['reject_body_contains']),
    );
  }
}

/// Value mapping entry for prefix-based lookups.
class YamlValueMapEntry {
  final String value;
  final double confidence;

  const YamlValueMapEntry({required this.value, this.confidence = 0.95});

  factory YamlValueMapEntry.fromYaml(dynamic map) {
    if (map is Map) {
      return YamlValueMapEntry(
        value: map['value']?.toString() ?? '',
        confidence: (map['confidence'] is num)
            ? (map['confidence'] as num).toDouble()
            : 0.95,
      );
    }
    // Shorthand: string value defaults to confidence 0.95
    return YamlValueMapEntry(value: map.toString());
  }
}

/// Candidate parsing rule for multi-item/search scraping.
///
/// Two flavours are supported:
/// - JSON APIs: [source] is a `json:` path returning a list of objects.
/// - HTML pages: [source] is a `regex:` whose **every** match becomes one
///   candidate; inside it, `regex:` sub-sources run against that block and
///   `1`, `2`, ... read the block's capture groups.
class YamlCandidateRule {
  final String source;
  final String titleSource;
  final String? subtitleSource;
  final String? urlSource;
  final String? coverSource;

  /// Optional template rendered with the pattern match (e.g. `'\b{1}\b'`) and
  /// used as a regex to keep only candidates that really are the wanted item.
  /// Essential for HTML search pages, where the first hit is not necessarily
  /// the right one.
  final String? filter;

  const YamlCandidateRule({
    required this.source,
    required this.titleSource,
    this.subtitleSource,
    this.urlSource,
    this.coverSource,
    this.filter,
  });

  factory YamlCandidateRule.fromYaml(dynamic map) {
    if (map is! Map) {
      throw ArgumentError('Items candidate rule must be a map');
    }
    return YamlCandidateRule(
      source: map['source']?.toString() ?? '',
      titleSource: map['title']?.toString() ?? 'title',
      subtitleSource: map['subtitle']?.toString(),
      urlSource: map['url']?.toString(),
      coverSource: map['cover']?.toString() ?? map['cover_url']?.toString(),
      filter: map['filter']?.toString(),
    );
  }
}

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
  final double? confidenceKnown; // For prefix_map: confidence when key is found
  final double?
  confidenceUnknown; // For prefix_map: confidence when key not found

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
    this.confidenceKnown,
    this.confidenceUnknown,
  });

  factory YamlFieldRule.fromYaml(dynamic map) {
    if (map is! Map) {
      throw ArgumentError('Field rule must be a map');
    }
    final key = map['key']?.toString() ?? '';
    final valType =
        map['value_type']?.toString().toLowerCase() ??
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
      isPreviewImage:
          map['is_preview_image'] == true || key == 'cover' || key == 'poster',
      confidence: (map['confidence'] is num)
          ? (map['confidence'] as num).toDouble()
          : 0.85,
      confidenceKnown: (map['confidence_known'] is num)
          ? (map['confidence_known'] as num).toDouble()
          : null,
      confidenceUnknown: (map['confidence_unknown'] is num)
          ? (map['confidence_unknown'] as num).toDouble()
          : null,
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
  final List<YamlRequestUrl> _requestUrls; // Multi-address cascade
  final Map<String, String> _headers;
  final int _timeoutSeconds;
  final int _priority;
  final List<YamlFieldRule> _fields;
  final List<String> _tags;
  final List<YamlConfigSchema> _configSchema;
  final YamlCandidateRule? _candidateRule;
  final String? _detailUrlTemplate;
  final bool _autoDrillDownSingle;
  final http.Client? _client;
  final Map<String, Map<String, YamlValueMapEntry>>
  _valueMaps; // Prefix mapping tables

  /// Matches values that already carry a URI scheme (`https:`, `data:`) or are
  /// protocol-relative (`//host/path`), i.e. do not need a base URL prefix.
  static final RegExp _absoluteUriPattern = RegExp(
    r'^(?:[a-zA-Z][a-zA-Z0-9+.\-]*:|//)',
  );

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
    List<YamlRequestUrl> requestUrls = const [],
    Map<String, String> headers = const {},
    int timeoutSeconds = 10,
    List<YamlFieldRule> fields = const [],
    List<String> tags = const [],
    List<YamlConfigSchema> configSchema = const [],
    YamlCandidateRule? candidateRule,
    String? detailUrlTemplate,
    bool autoDrillDownSingle = true,
    http.Client? client,
    Map<String, Map<String, YamlValueMapEntry>> valueMaps = const {},
  }) : _id = id,
       _displayName = displayName,
       _description = description,
       _priority = priority,
       _mediaTypes = mediaTypes,
       _targetSupertags = targetSupertags,
       _patternRegex = patternRegex,
       _supertagToBackfill = supertagToBackfill,
       _urlTemplate = urlTemplate,
       _requestUrls = requestUrls,
       _headers = headers,
       _timeoutSeconds = timeoutSeconds,
       _fields = fields,
       _tags = tags,
       _configSchema = configSchema,
       _candidateRule = candidateRule,
       _detailUrlTemplate = detailUrlTemplate,
       _autoDrillDownSingle = autoDrillDownSingle,
       _client = client,
       _valueMaps = valueMaps;

  factory YamlScraper.fromYamlString(
    String yamlContent, {
    http.Client? client,
  }) {
    final doc = loadYaml(yamlContent);
    if (doc is! Map) {
      throw ArgumentError('YAML content must be a key-value mapping.');
    }

    final id = doc['id']?.toString() ?? 'custom_yaml';
    final name =
        doc['name']?.toString() ?? doc['displayName']?.toString() ?? id;
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
    final requestUrls = <YamlRequestUrl>[];
    final headers = <String, String>{};
    int timeout = 10;

    // Parse multi-address cascade (request_urls) or legacy single request
    if (doc['request_urls'] is Iterable) {
      for (final item in doc['request_urls'] as Iterable) {
        if (item is Map) {
          requestUrls.add(YamlRequestUrl.fromYaml(item));
        }
      }
    } else if (doc['request'] is Map) {
      final req = doc['request'] as Map;
      urlTemplate = req['url_template']?.toString();
      timeout = (req['timeout_seconds'] is int)
          ? req['timeout_seconds'] as int
          : 10;
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

    final priority = (doc['priority'] is num)
        ? (doc['priority'] as num).toInt()
        : 60;

    final configSchemaList = <YamlConfigSchema>[];
    final configSchemaRaw = doc['config_schema'] ?? doc['config'];
    if (configSchemaRaw is Iterable) {
      for (final cs in configSchemaRaw) {
        if (cs is Map) {
          configSchemaList.add(YamlConfigSchema.fromYaml(cs));
        }
      }
    }

    YamlCandidateRule? candidateRule;
    if (doc['items'] is Map) {
      candidateRule = YamlCandidateRule.fromYaml(doc['items'] as Map);
    }

    String? detailUrlTemplate;
    bool autoDrillDownSingle = true;
    if (doc['detail_request'] is Map) {
      final dr = doc['detail_request'] as Map;
      detailUrlTemplate = dr['url_template']?.toString();
      if (dr['auto_drill_down_single'] is bool) {
        autoDrillDownSingle = dr['auto_drill_down_single'] as bool;
      }
    }

    final tagRules = <String>[];
    final tagsRaw = doc['tags'];
    if (tagsRaw is Iterable) {
      for (final t in tagsRaw) {
        tagRules.add(t.toString());
      }
    }

    // Parse value_maps for prefix-based lookups
    final valueMaps = <String, Map<String, YamlValueMapEntry>>{};
    if (doc['value_maps'] is Map) {
      (doc['value_maps'] as Map).forEach((mapName, entries) {
        if (entries is Map) {
          final innerMap = <String, YamlValueMapEntry>{};
          entries.forEach((key, value) {
            innerMap[key.toString().toUpperCase()] = YamlValueMapEntry.fromYaml(
              value,
            );
          });
          valueMaps[mapName.toString()] = innerMap;
        }
      });
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
      requestUrls: requestUrls,
      headers: headers,
      timeoutSeconds: timeout,
      fields: fieldRules,
      tags: tagRules,
      configSchema: configSchemaList,
      candidateRule: candidateRule,
      detailUrlTemplate: detailUrlTemplate,
      autoDrillDownSingle: autoDrillDownSingle,
      valueMaps: valueMaps,
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

  @override
  List<String> get mediaTypes => List.unmodifiable(_mediaTypes);

  List<YamlConfigSchema> get configSchema => List.unmodifiable(_configSchema);

  List<YamlFieldRule> get fieldRules => List.unmodifiable(_fields);

  YamlCandidateRule? get candidateRule => _candidateRule;

  String? get detailUrlTemplate => _detailUrlTemplate;

  bool get autoDrillDownSingle => _autoDrillDownSingle;

  /// Evaluates micro-templates supporting fallback chains (`{1 ?? 2 ?? input}`),
  /// conditionals (`{if {1}}...{else}...{/if}`), and variable replacements (`{config:key}`, `{1}`, `{input}`).
  static String renderTemplate(
    String template, {
    Match? match,
    String? targetStr,
    String? Function(String key)? getConfig,
    Map<String, String>? extraVariables,
  }) {
    String res = template;

    // Helper to evaluate a variable identifier (e.g. "1", "code", "config:key", "input")
    String? evalVar(String rawVar) {
      final v = rawVar.trim();
      if (v.isEmpty) return null;
      if (v.startsWith('config:')) {
        final cfgKey = v.substring(7);
        final val = getConfig?.call(cfgKey);
        return (val != null && val.isNotEmpty) ? val : null;
      }
      if (v == 'input') {
        return (targetStr != null && targetStr.isNotEmpty) ? targetStr : null;
      }
      if (v == '0' && match != null) {
        final g = match.group(0);
        return (g != null && g.isNotEmpty) ? g : null;
      }
      final idx = int.tryParse(v);
      if (idx != null && match != null && idx <= match.groupCount) {
        final g = match.group(idx);
        return (g != null && g.isNotEmpty) ? g : null;
      }
      if (extraVariables != null && extraVariables.containsKey(v)) {
        final val = extraVariables[v];
        return (val != null && val.isNotEmpty) ? val : null;
      }
      return null;
    }

    // 1. Process Conditionals: {if {var}}...{else}...{/if} or {if var}...{else}...{/if}
    final ifRegex = RegExp(
      r'\{if\s+\{?([0-9a-zA-Z_:]+)\}?\}([\s\S]*?)(?:\{else\}([\s\S]*?))?\{/if\}',
      caseSensitive: false,
    );
    res = res.replaceAllMapped(ifRegex, (m) {
      final varName = m.group(1)!;
      final ifBranch = m.group(2) ?? '';
      final elseBranch = m.group(3) ?? '';
      final val = evalVar(varName);
      return (val != null && val.isNotEmpty) ? ifBranch : elseBranch;
    });

    // 2. Process Fallbacks: {var1 ?? var2 ?? var3}
    final fallbackRegex = RegExp(
      r'\{([0-9a-zA-Z_:]+(?:\s*\?\?\s*[0-9a-zA-Z_:]+)+)\}',
    );
    res = res.replaceAllMapped(fallbackRegex, (m) {
      final expr = m.group(1)!;
      final tokens = expr.split('??').map((t) => t.trim());
      for (final t in tokens) {
        final val = evalVar(t);
        if (val != null && val.isNotEmpty) {
          return Uri.encodeComponent(val);
        }
      }
      return '';
    });

    // 3. Process Standard Placeholders: {0}, {1}..{n}, {input}, {config:key}, {extra}
    if (match != null) {
      final fullMatch = match.group(0);
      if (fullMatch != null) {
        res = res.replaceAll('{0}', Uri.encodeComponent(fullMatch));
      }
      for (int i = 1; i <= match.groupCount; i++) {
        final val = match.group(i) ?? '';
        res = res.replaceAll('{$i}', Uri.encodeComponent(val));
      }
    }

    if (targetStr != null) {
      res = res.replaceAll('{input}', Uri.encodeComponent(targetStr));
    }

    if (extraVariables != null) {
      // `{name|raw}` inserts the value untouched. Needed when the value is a
      // path (e.g. a detail-page href like `/v/5Ey9p`) rather than a query
      // parameter: URL-encoding a leading slash breaks the request.
      extraVariables.forEach((k, v) {
        res = res.replaceAll('{$k|raw}', v);
      });
      extraVariables.forEach((k, v) {
        res = res.replaceAll('{$k}', Uri.encodeComponent(v));
      });
    }

    res = res.replaceAllMapped(RegExp(r'\{config:([a-zA-Z0-9_]+)\}'), (m) {
      final cfgKey = m.group(1)!;
      final cfgVal = getConfig?.call(cfgKey);
      if (cfgVal == null || cfgVal.isEmpty) return '';
      // If config value is a complete URL (e.g. base_url or proxy), don't URL-encode slashes/colons
      if (cfgVal.startsWith('http://') || cfgVal.startsWith('https://')) {
        return cfgVal;
      }
      return Uri.encodeComponent(cfgVal);
    });

    return res;
  }

  @override
  bool canHandle(ScrapeInput input) {
    // 0. Check media type restriction if specified
    if (_mediaTypes.isNotEmpty) {
      var resType = input.subject.mediaType?.toLowerCase();
      if (resType == null || resType.isEmpty || resType == MediaKind.other) {
        final checkPath = input.subject.uri ?? input.fileName ?? '';
        if (checkPath.isNotEmpty) {
          resType = MediaKind.fromExtension(checkPath);
        }
      }
      if (resType != null &&
          resType.isNotEmpty &&
          resType != MediaKind.other &&
          !_mediaTypes.contains(resType)) {
        return false;
      }
      if (_mediaTypes.length == 1 &&
          _mediaTypes.first == MediaKind.video &&
          resType != MediaKind.video) {
        return false;
      }
    }

    // 1. Check Supertags
    final existingTags = input.existingTagNames;
    if (_targetSupertags.isNotEmpty &&
        _targetSupertags.any((st) => existingTags.contains(st.toLowerCase()))) {
      return true;
    }

    // 2. Check pattern regex against sourceUrl, uri, or fileName
    final pattern = _patternRegex;
    if (pattern != null) {
      final url = input.sourceUrl ?? input.subject.uri ?? '';
      if (url.isNotEmpty && pattern.hasMatch(url)) return true;

      final fn = input.fileName ?? input.subject.title ?? '';
      if (fn.isNotEmpty && pattern.hasMatch(fn)) return true;
    }

    return false;
  }

  @override
  Future<ScrapeResult> scrape(ScrapeInput input, ScrapeContext ctx) async {
    final client = ctx.client ?? _client ?? http.Client();
    final url = input.sourceUrl ?? input.subject.uri ?? '';
    final fn = input.fileName ?? input.subject.title ?? '';
    final targetStr = url.isNotEmpty ? url : fn;

    // 1. Extract matches from pattern
    Match? match;
    final pattern = _patternRegex;
    if (pattern != null) {
      match = pattern.firstMatch(targetStr);
    }

    String? responseBody;
    dynamic jsonRoot;

    // 2. Perform HTTP request (single template, or cascade list with fallback)
    // Helper for making HTTP GET request. Headers/timeout are per-call so each
    // cascade entry keeps its own settings.
    Future<({String? body, dynamic json})> fetchUrl(
      String reqUrl, {
      Map<String, String>? extraHeaders,
      int? timeoutSeconds,
    }) async {
      try {
        ctx.log('YamlScraper($_id): GET $reqUrl');
        final effectiveHeaders = <String, String>{
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          // Some sites (e.g. JavBus) answer a full 200 with an age-gate page
          // unless the request looks like a browser; Accept-Language is what
          // they check, so it is part of the defaults rather than per-plugin.
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
          'Cookie': 'existmag=all; age=verified; over18=1',
        };

        final headerSource = extraHeaders ?? _headers;
        headerSource.forEach((k, v) {
          effectiveHeaders[k] = renderTemplate(
            v,
            match: match,
            targetStr: targetStr,
            getConfig: ctx.getConfig,
          );
        });

        final resp = await client
            .get(Uri.parse(reqUrl), headers: effectiveHeaders)
            .timeout(Duration(seconds: timeoutSeconds ?? _timeoutSeconds));

        if (resp.statusCode == 200) {
          final b = utf8.decode(resp.bodyBytes, allowMalformed: true);
          dynamic j;
          try {
            j = jsonDecode(b);
          } catch (_) {}
          return (body: b, json: j);
        } else {
          ctx.log('YamlScraper($_id): HTTP ${resp.statusCode}');
        }
      } catch (e) {
        ctx.log('YamlScraper($_id) request failed: $e');
      }
      return (body: null, json: null);
    }

    // Try cascade URL list first (new multi-address feature)
    if (_requestUrls.isNotEmpty) {
      for (final reqUrlDef in _requestUrls) {
        final requestUrl = renderTemplate(
          reqUrlDef.url,
          match: match,
          targetStr: targetStr,
          getConfig: ctx.getConfig,
        );

        // Guard: if any unreplaced placeholder remains, skip this URL
        if (!RegExp(r'\{[0-9a-zA-Z_]+\}').hasMatch(requestUrl)) {
          final res = await fetchUrl(
            requestUrl,
            extraHeaders: reqUrlDef.headers,
            timeoutSeconds: reqUrlDef.timeoutSeconds,
          );
          final body = res.body;
          if (body != null) {
            final rejection = _bodyGuardRejection(body, reqUrlDef);
            if (rejection != null) {
              // Age gates usually answer 200, so a body check is the only way to
              // tell them apart from a real detail page.
              ctx.log(
                'YamlScraper($_id): $requestUrl 正文校验未通过（$rejection），尝试下一个地址',
              ); // i18n:ignore 日志
              continue;
            }
            responseBody = body;
            jsonRoot = res.json;
            break; // Success, stop cascade
          }
        } else {
          ctx.log(
            'YamlScraper($_id): unreplaced placeholders in cascade URL, skipping',
          );
        }
      }
    }

    // Fallback to legacy single request_url if no cascade list or cascade failed
    final legacyTemplate = _urlTemplate;
    if (responseBody == null && legacyTemplate != null) {
      final requestUrl = renderTemplate(
        legacyTemplate,
        match: match,
        targetStr: targetStr,
        getConfig: ctx.getConfig,
      );

      // Guard: if any unreplaced placeholder remains, abort request
      if (RegExp(r'\{[0-9a-zA-Z_]+\}').hasMatch(requestUrl)) {
        ctx.log(
          'YamlScraper($_id): 匹配未命中或占位符未替换完毕 ($requestUrl)，跳过网络请求',
        ); // i18n:ignore 日志
      } else {
        final res = await fetchUrl(requestUrl);
        responseBody = res.body;
        jsonRoot = res.json;
      }
    }

    // 3. Extract Candidates if items rule is defined
    final extractedCandidates = <ScrapeCandidate>[];
    final candRule = _candidateRule;
    if (candRule != null && (responseBody != null || jsonRoot != null)) {
      List<dynamic> rawItems = const [];
      final htmlBlocks = <String>[];

      if (responseBody != null && _isRegexSource(candRule.source)) {
        // HTML list page: every match of the block regex is one candidate.
        final blockPattern = RegExp(
          candRule.source.substring(6),
          caseSensitive: false,
        );
        for (final m in blockPattern.allMatches(responseBody)) {
          final block = m.group(0) ?? '';
          if (block.isEmpty) continue;
          htmlBlocks.add(block);
          rawItems = [
            ...rawItems,
            {
              for (var g = 0; g <= m.groupCount; g++)
                if (m.group(g) != null) g.toString(): m.group(g),
            },
          ];
        }
      } else {
        final resolved = _resolveSource(
          candRule.source,
          rawText: responseBody ?? '',
          jsonData: jsonRoot,
          match: match,
        );
        if (resolved is List) rawItems = resolved;
      }

      // Optional filter: keep only the candidate(s) matching the rendered template.
      final filterTemplate = candRule.filter;
      if (filterTemplate != null && filterTemplate.trim().isNotEmpty) {
        final filterPattern = renderTemplate(
          filterTemplate,
          match: match,
          targetStr: targetStr,
          getConfig: ctx.getConfig,
        );
        if (!RegExp(r'\{[0-9a-zA-Z_]+\}').hasMatch(filterPattern)) {
          try {
            final filterRegex = RegExp(filterPattern, caseSensitive: false);
            final keptItems = <dynamic>[];
            final keptBlocks = <String>[];
            for (var i = 0; i < rawItems.length; i++) {
              final haystack = i < htmlBlocks.length
                  ? htmlBlocks[i]
                  : rawItems[i].toString();
              if (filterRegex.hasMatch(haystack)) {
                keptItems.add(rawItems[i]);
                if (i < htmlBlocks.length) keptBlocks.add(htmlBlocks[i]);
              }
            }
            if (keptItems.isNotEmpty) {
              rawItems = keptItems;
              htmlBlocks
                ..clear()
                ..addAll(keptBlocks);
            }
          } catch (e) {
            ctx.log(
              'YamlScraper($_id): items.filter 正则无效: $e',
            ); // i18n:ignore 日志
          }
        }
      }

      for (var i = 0; i < rawItems.length; i++) {
        final item = rawItems[i];
        final blockText = i < htmlBlocks.length ? htmlBlocks[i] : '';
        // HTML blocks use `regex:` sub-sources or `1`, `2`, ... group refs;
        // JSON items use `json:` paths or plain keys.
        final isHtml = blockText.isNotEmpty;
        Match? blockMatch;
        if (isHtml) {
          blockMatch = RegExp(
            candRule.source.substring(6),
            caseSensitive: false,
          ).firstMatch(blockText);
        }

        String? resolve(dynamic subSource) {
          if (subSource == null) return null;
          final src = subSource.toString();
          if (!isHtml) {
            return _resolveSource(src, rawText: '', jsonData: item)?.toString();
          }
          if (src.startsWith('regex:')) {
            return _resolveSource(src, rawText: blockText)?.toString();
          }
          return _resolveSource(
            src,
            rawText: blockText,
            match: blockMatch,
          )?.toString();
        }

        if (item is Map) {
          final t = resolve(candRule.titleSource);
          if (t != null && t.trim().isNotEmpty) {
            extractedCandidates.add(
              ScrapeCandidate(
                title: t.trim(),
                subtitle: resolve(candRule.subtitleSource)?.trim(),
                url: resolve(candRule.urlSource)?.trim(),
                coverUrl: resolve(candRule.coverSource)?.trim(),
                extra: Map<String, dynamic>.from(item),
              ),
            );
          }
        }
      }

      // Check for two-stage auto drill-down:
      // If exactly 1 candidate returned and detail_request is configured with auto_drill_down_single == true
      final detailUrlTmpl = _detailUrlTemplate;
      if (extractedCandidates.length == 1 &&
          _autoDrillDownSingle &&
          detailUrlTmpl != null) {
        final singleCand = extractedCandidates.first;
        final extraVars = <String, String>{
          'url': singleCand.url ?? '',
          'title': singleCand.title,
          if (singleCand.subtitle != null) 'subtitle': singleCand.subtitle!,
        };
        singleCand.extra.forEach((k, v) {
          if (v != null) extraVars[k] = v.toString();
        });

        final detailUrl = renderTemplate(
          detailUrlTmpl,
          match: match,
          targetStr: targetStr,
          getConfig: ctx.getConfig,
          extraVariables: extraVars,
        );

        if (!RegExp(r'\{[0-9a-zA-Z_]+\}').hasMatch(detailUrl)) {
          ctx.log(
            'YamlScraper($_id): 命中唯一候选结果，自动执行二级深挖 -> $detailUrl',
          ); // i18n:ignore 日志
          final detailRes = await fetchUrl(detailUrl);
          if (detailRes.body != null) {
            responseBody = detailRes.body;
            jsonRoot = detailRes.json;
          }
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
      if ((val == null || val.toString().trim().isEmpty) &&
          rule.fallback != null) {
        val = _resolveSource(
          rule.fallback!,
          rawText: responseBody ?? targetStr,
          jsonData: jsonRoot,
          match: match,
        );
      }

      if (val != null && val.toString().trim().isNotEmpty) {
        var valStr = val is Map && val.containsKey('value')
            ? val['value'].toString().trim()
            : val.toString().trim();

        if (valStr.isEmpty) continue;

        // `prefix` acts as a base URL for relative references (e.g. a cover path
        // like `/pics/cover/x.jpg`): it is skipped for values that are already
        // absolute so a scraper can hit both relative and absolute markup.
        if (rule.prefix != null &&
            !valStr.startsWith(rule.prefix!) &&
            !_absoluteUriPattern.hasMatch(valStr)) {
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

        // Use confidence from prefix_map result if available, otherwise use rule's confidence
        double effectiveConfidence = rule.confidence;
        if (val is Map && val.containsKey('confidence')) {
          effectiveConfidence = val['confidence'] is num
              ? (val['confidence'] as num).toDouble()
              : rule.confidence;
        } else if (rule.source.startsWith('value_map:') ||
            rule.source.startsWith('prefix_map:')) {
          // Use confidence_known or confidence_unknown based on whether we found mapping
          if (val is Map && val['value'] != null) {
            // Check if it's a mapped value or fallback
            final isExactOnly = rule.source.startsWith('value_map:');
            final mapName = rule.source.substring(isExactOnly ? 10 : 11);
            final key = (match?.group(1) ?? '').toUpperCase();
            final isKnown =
                _valueMaps.containsKey(mapName) &&
                _valueMaps[mapName]!.containsKey(key);
            if (isKnown && rule.confidenceKnown != null) {
              effectiveConfidence = rule.confidenceKnown!;
            } else if (!isKnown && rule.confidenceUnknown != null) {
              effectiveConfidence = rule.confidenceUnknown!;
            }
          }
        }

        extractedFields.add(
          ProposedField(
            key: rule.key,
            valueText: valStr,
            valueNum: valNum,
            entityName: rule.entityType != null ? valStr : null,
            entityType: rule.entityType,
            confidence: effectiveConfidence,
            source: 'scraper:$_id',
          ),
        );
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
                final parts = s
                    .split('/')
                    .map((p) => p.trim())
                    .where((p) => p.isNotEmpty)
                    .toList();
                if (parts.isNotEmpty) {
                  extractedTags.add(
                    ProposedTag(tagPath: parts, confidence: 0.85),
                  );
                }
              }
            }
          } else {
            final s = val.toString().trim();
            if (s.isNotEmpty) {
              final parts = s
                  .split('/')
                  .map((p) => p.trim())
                  .where((p) => p.isNotEmpty)
                  .toList();
              if (parts.isNotEmpty) {
                extractedTags.add(
                  ProposedTag(tagPath: parts, confidence: 0.85),
                );
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
              final parts = s
                  .split('/')
                  .map((p) => p.trim())
                  .where((p) => p.isNotEmpty)
                  .toList();
              if (parts.isNotEmpty) {
                extractedTags.add(
                  ProposedTag(tagPath: parts, confidence: 0.85),
                );
              }
            }
          }
        } catch (_) {}
      } else {
        // Static or parameterized tag path e.g. "影视 / 演员 / {actress}"
        String resolvedTag = tagDef;
        for (final field in extractedFields) {
          if (field.valueText != null) {
            resolvedTag = resolvedTag.replaceAll(
              '{${field.key}}',
              field.valueText!,
            );
          }
        }
        // If placeholder still unresolved (e.g. {actress} without actress found), ignore
        if (!RegExp(r'\{[a-zA-Z0-9_]+\}').hasMatch(resolvedTag)) {
          final parts = resolvedTag
              .split('/')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
          if (parts.isNotEmpty) {
            extractedTags.add(
              ProposedTag(
                tagPath: parts,
                confidence: 0.9,
                rawTemplate: tagDef.contains('{') ? tagDef : null,
              ),
            );
          }
        }
      }
    }

    return ScrapeResult(
      proposedTitle: proposedTitle,
      previewImageUrl: previewImageUrl,
      fields: extractedFields,
      tags: extractedTags,
      candidates: extractedCandidates,
    );
  }

  /// Returns a human-readable reason when [body] fails the cascade entry's
  /// `require_body_contains` / `reject_body_contains` guard, or null when it passes.
  static String? _bodyGuardRejection(String body, YamlRequestUrl def) {
    final lower = body.toLowerCase();
    for (final marker in def.requireBodyContains) {
      if (!lower.contains(marker.toLowerCase())) {
        return 'require_body_contains: $marker';
      }
    }
    for (final marker in def.rejectBodyContains) {
      if (lower.contains(marker.toLowerCase())) {
        return 'reject_body_contains: $marker';
      }
    }
    return null;
  }

  static bool _isRegexSource(String source) => source.startsWith('regex:');

  /// Resolves value from json, regex, static definition, or prefix mapping table.
  /// Returns either a plain value or a map with 'value' and 'confidence' keys for mapped lookups.
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
    } else if (source.startsWith('value_map:') ||
        source.startsWith('prefix_map:')) {
      // Resolve value using value_maps table
      // value_map: exact match only (no fallback)
      // prefix_map: exact match with fallback to prefix itself
      final isExactOnly = source.startsWith('value_map:');
      final mapName = source.substring(isExactOnly ? 10 : 11);
      if (!_valueMaps.containsKey(mapName)) return null;

      // Extract lookup key from match group 1 (first captured group from pattern)
      if (match == null || match.groupCount < 1) return null;
      final key = match.group(1)?.toUpperCase() ?? '';
      if (key.isEmpty) return null;

      final valueMap = _valueMaps[mapName]!;
      if (valueMap.containsKey(key)) {
        final entry = valueMap[key]!;
        return {'value': entry.value, 'confidence': entry.confidence};
      }

      // value_map: no match -> return null
      // prefix_map: no match -> return prefix itself as fallback
      if (isExactOnly) {
        return null;
      } else {
        return {'value': key, 'confidence': 0.7};
      }
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
