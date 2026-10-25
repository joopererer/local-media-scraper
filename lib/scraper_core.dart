// Copyright 2026 Jiawei LI
// Licensed under the Apache License, Version 2.0.

/// App-agnostic metadata scraping engine.
///
/// - [Scraper] is the contract: give it a [ScrapeInput] and it returns a
///   [ScrapeResult] built from plain values only.
/// - Built-in scrapers cover the common cases (file name, web page, TMDB,
///   Douban, Bangumi).
/// - [YamlScraper] interprets declarative `.yaml` rules, so new sites can be
///   added without code.
/// - [YamlScraperLoader] discovers those files in a directory and can watch it.
/// - [ScraperPlanner] decides what runs in which order and never writes
///   anything, leaving persistence to the host application.
library;

export 'src/builtin/bangumi_scraper.dart';
export 'src/builtin/douban_scraper.dart';
export 'src/builtin/filename_scraper.dart';
export 'src/builtin/tmdb_scraper.dart';
export 'src/builtin/webpage_scraper.dart';
export 'src/media_type.dart';
export 'src/planner/scraper_planner.dart';
export 'src/plugin/yaml_scraper_loader.dart';
export 'src/scraper.dart';
export 'src/yaml/yaml_scraper.dart'
    show
        YamlCandidateRule,
        YamlConfigSchema,
        YamlFieldRule,
        YamlRequestUrl,
        YamlScraper,
        YamlValueMapEntry;
