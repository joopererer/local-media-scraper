import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'yaml_scraper.dart';

/// Copies/refreshes built-in plugins before a scan.
///
/// Returns the file names that have a newer built-in version but were modified
/// by the user (they are kept as-is and surfaced in the settings UI).
typedef BuiltinPluginSync = Future<List<String>> Function();

/// Manages discovery, loading, and hot-reloading of YAML scrapers.
///
/// The loader only knows about a directory on disk. Embedded/bundled plugins are
/// supplied by the caller through [BuiltinPluginSync], so this class carries no
/// dependency on any UI framework.
class YamlScraperLoader {
  final Directory pluginsDirectory;
  final http.Client? _client;
  final void Function(String message)? _log;
  final BuiltinPluginSync? _syncBuiltins;

  List<YamlScraper> _loadedScrapers = [];

  YamlScraperLoader({
    Directory? pluginsDirectory,
    http.Client? client,
    void Function(String message)? onLog,
    BuiltinPluginSync? builtinSync,
  }) : pluginsDirectory = pluginsDirectory ?? Directory(p.join('plugins', 'scrapers')),
       _client = client,
       _log = onLog,
       _syncBuiltins = builtinSync;

  List<YamlScraper> get loadedScrapers => List.unmodifiable(_loadedScrapers);

  /// Ensures the directory exists, then delegates to [BuiltinPluginSync] (if any).
  Future<List<String>> ensureDirectoryAndSamples() async {
    try {
      if (!await pluginsDirectory.exists()) {
        await pluginsDirectory.create(recursive: true);
      }
      final sync = _syncBuiltins;
      if (sync == null) return const [];
      return await sync();
    } catch (e) {
      _log?.call('YamlScraperLoader: unable to sync builtin samples: $e');
      return const [];
    }
  }

  /// Scans the directory and loads all `.yaml` / `.yml` scrapers.
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
            _log?.call(
              'YamlScraperLoader: loaded plugin "${scraper.displayName}" (${scraper.id}) from ${entity.path}',
            );
          } catch (e) {
            _log?.call('YamlScraperLoader: error loading ${entity.path}: $e');
          }
        }
      }
    } catch (e) {
      _log?.call('YamlScraperLoader: failed to scan directory: $e');
    }

    _loadedScrapers = list;
    return list;
  }

  /// Reloads all scrapers from disk.
  Future<List<YamlScraper>> reload() async {
    return loadScrapers();
  }

  /// Emits the reloaded scraper list whenever the plugin directory changes.
  ///
  /// Edits are debounced so a single editor save does not trigger several scans.
  /// The subscription starts on first listen and stops when the stream is
  /// cancelled.
  Stream<List<YamlScraper>> watch({
    Duration debounce = const Duration(milliseconds: 400),
  }) {
    late StreamController<List<YamlScraper>> controller;
    StreamSubscription<FileSystemEvent>? subscription;
    Timer? timer;

    Future<void> emit() async {
      if (controller.isClosed) return;
      final list = await reload();
      if (!controller.isClosed) controller.add(list);
    }

    controller = StreamController<List<YamlScraper>>.broadcast(
      onListen: () async {
        try {
          if (!await pluginsDirectory.exists()) {
            await pluginsDirectory.create(recursive: true);
          }
          subscription = pluginsDirectory.watch(recursive: false).listen(
            (_) {
              timer?.cancel();
              timer = Timer(debounce, emit);
            },
            onError: (Object e) => _log?.call('YamlScraperLoader: watch error: $e'),
          );
        } catch (e) {
          _log?.call('YamlScraperLoader: cannot watch plugin directory: $e');
        }
      },
      onCancel: () async {
        timer?.cancel();
        timer = null;
        await subscription?.cancel();
        subscription = null;
      },
    );

    return controller.stream;
  }
}
