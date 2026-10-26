# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres
to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-10-26

### Added

- **Douban**: title search. When no subject id is available the scraper now
  searches Douban by the cleaned-up file name (`movie.douban.com/j/subject_suggest`
  for films, `book.douban.com/...` for ebooks) and then reads the mobile
  "rexxar" JSON API (`m.douban.com/rexxar/api/v2/{movie,tv,book}/{id}`).
- **Douban**: ebooks. A PDF/EPUB/MOBI/AZW3… file is looked up as a book
  (author, rating, publisher-era tags) instead of a film.
- **Bangumi**: title search through the v0 search API; the anime title parsed
  from the file name (e.g. `[Nekomoe] Frieren - 01`) is looked up and the
  episode number is kept on the result. Falls back to the old file-name
  heuristic when nothing is found.

### Changed

- **Douban** no longer scrapes the desktop HTML page as its primary path. Those
  pages answer HTTP 200 with a JS anti-bot shell (`载入中 ...`), so every regex
  silently produced nothing. The HTML parser remains as a last-resort fallback.
- `canHandle` for Douban now ignores camera dumps and placeholder names
  (`IMG_1234`, `untitled`, …) so a library scan does not fire a request per file.

### Fixed

- Douban/TMDB/Bangumi **bundled YAML plugins shadowed the built-in Dart
  scrapers** because they shared the same scraper ids, which made the better
  implementations unreachable and left the visible plugin unable to build its
  request URL. The three YAML files are no longer needed and have been removed
  from the host app.

## [0.1.1] - 2026-10-26

### Added

- `items:` now accepts a `regex:` block source, so **HTML search pages** can be
  scraped without an API: every match becomes one candidate, and inside a block
  you can use `regex:` sub-sources or the block's capture groups (`1`, `2`, ...).
- `items.filter:` — a template rendered with the pattern match (e.g.
  `'(?:^|[^A-Za-z0-9]){1}-{2}(?:[^0-9]|$)'`) used as a regex to keep only the
  candidate that really is the wanted item, so `auto_drill_down_single` can fire
  on search results.
- `{name|raw}` in templates inserts a variable without URL-encoding. Needed for
  `detail_request.url_template` when `{url}` is a site-relative path.

### Changed

- Default request headers now include `Accept` and `Accept-Language`. Some sites
  (e.g. JavBus) answer an HTTP 200 age-gate page unless the request looks like a
  browser, which made plugins silently parse the gate page.

### Fixed

- `items:` with a `regex:` source could not produce candidates at all before
  (only `json:` lists were supported).

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

