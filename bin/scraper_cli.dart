// Copyright 2026 Jiawei LI
// Licensed under the Apache License, Version 2.0.

/// Command-line runner for the scraping engine.
library;

import 'dart:convert';
import 'dart:io';

import 'package:scraper_core/scraper_core.dart';

import 'cli_args.dart';
import 'cli_json.dart';

const _usage = '''
scraper_cli - run the scraping engine without a UI

  dart run scraper_core:scraper_cli --file <name> [options]
  dart run scraper_core:scraper_cli --url <url>  [options]

Options:
  --plugins <dir>   Directory with .yaml/.yml plugins (repeatable)
  --plugin <file>   A single plugin file (repeatable)
  --builtin <ids>   Enable only these built-ins (comma separated):
                    filename,web_page,tmdb,douban,bangumi
  --config <k=v>    Scraper config value (repeatable)
  --verbose         Print scraper logs to stderr
  --help            Show this help

Exit code: 1 means nothing matched, 2 means bad input.
''';

Future<void> main(List<String> args) async {
  final opts = parseCliArgs(args);
  if (opts == null) {
    stdout.writeln(_usage);
    return;
  }
  exitCode = await _run(opts);
}

Future<int> _run(CliOptions opts) async {
  final onLog = opts.verbose ? (String m) => stderr.writeln(m) : null;
  final scrapers = <Scraper>[];

  final enabled = opts.builtin;
  bool wants(String id) => enabled == null || enabled.contains(id);
  if (wants('tmdb')) scrapers.add(TmdbScraper());
  if (wants('douban')) scrapers.add(DoubanScraper());
  if (wants('bangumi')) scrapers.add(BangumiScraper());
  if (wants('filename')) scrapers.add(FileNameScraper());
  if (wants('web_page')) scrapers.add(WebPageScraper());

  for (final path in opts.pluginFiles) {
    final file = File(path);
    if (!await file.exists()) {
      stderr.writeln('error: plugin not found: $path');
      return 2;
    }
    try {
      scrapers.add(YamlScraper.fromYamlString(await file.readAsString()));
    } catch (e) {
      stderr.writeln('error: cannot parse $path: $e');
      return 2;
    }
  }

  for (final dir in opts.pluginDirs) {
    final loader = YamlScraperLoader(
      pluginsDirectory: Directory(dir),
      onLog: onLog,
    );
    scrapers.addAll(await loader.loadScrapers());
  }

  if (scrapers.isEmpty) {
    stderr.writeln('error: no scrapers available (see --builtin / --plugin)');
    return 2;
  }

  final input = ScrapeInput(
    subject: ScrapeSubject(
      id: 'cli',
      title: opts.url ?? opts.fileName,
      uri: opts.url,
    ),
    fileName: opts.fileName,
    sourceUrl: opts.url,
  );

  final plan = await ScraperPlanner(scrapers: scrapers).plan(
    input,
    ctx: ScrapeContext(config: opts.config, onLog: onLog),
  );

  stdout.writeln(const JsonEncoder.withIndent('  ').convert(planToJson(plan)));
  return plan.isEmpty ? 1 : 0;
}
