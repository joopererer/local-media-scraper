# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres
to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-10-25

### Added

- Initial extraction from File Organizer.
- `Scraper` contract with plain value objects (`ScrapeSubject`, `ExistingTag`,
  `ExistingField`, `ScrapeInput`, `ScrapeResult`, `ProposedField`,
  `ProposedTag`, `ScrapeCandidate`, `ScrapeContext`).
- Built-in scrapers: file name, web page OpenGraph, TMDB, Douban, Bangumi.
- Declarative YAML plugin engine (`YamlScraper`) with request templates,
  multi-address cascade with body guards, `json:`/`regex:`/`match:`/`static:`/
  `value_map:`/`prefix_map:` extraction, candidate lists and single-result auto
  drill-down.
- Plugin loader (`YamlScraperLoader`) with on-demand reload and a directory
  `watch()` stream.
- `ScraperPlanner`: side-effect-free two-tier dispatch with supertag backfill,
  priority protection and result merging.
- `scraper_cli` command-line runner for trying plugins without a UI.

