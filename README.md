# local-media-scraper

App-agnostic **metadata scraping engine** for media libraries: a small Dart
contract, a set of built-in site scrapers, and a declarative YAML plugin format
with hot reload.

Everything here is independent of any application. The engine takes a plain
value object describing the thing to scrape and returns plain values. No
database, no UI, no app-specific concepts — persistence and presentation are the
host application's job.

> Extracted from the File Organizer project
> (https://github.com/joopererer/file_organizer, Apache-2.0). Git history is
> preserved for traceability. See `NOTICE`.

## License

Apache-2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

## What it does

- **Contract** (`Scraper`): feed it a `ScrapeInput`, get back a `ScrapeResult`
  made of `ProposedField`s, `ProposedTag`s, an optional proposed title and a
  preview image.
- **Built-in scrapers**: file name, web page OpenGraph, TMDB, Douban, Bangumi.
- **YAML plugins** (`YamlScraper`): describe a site with a `.yaml` file — request
  templates, cascade fallbacks with body guards, `json:` / `regex:` / `match:` /
  `static:` / `value_map:` / `prefix_map:` extraction, candidate lists with
  single-result auto drill-down. See [`docs/YAML_SCRAPERS.md`](docs/YAML_SCRAPERS.md).
- **Plugin runtime** (`YamlScraperLoader`): discovers `*.yaml` / `*.yml` in a
  directory, reloads on demand, and can `watch()` the directory for edits.
- **Planner** (`ScraperPlanner`): decides which scrapers run in which order,
  backfills supertags on a feature-pattern match, and merges the winner's title
  and cover. It never writes anything.

## Using it from another project

```yaml
dependencies:
  scraper_core:
    git:
      url: https://github.com/joopererer/local-media-scraper.git
      ref: v0.1.0
```

Pin to a **tag**, not a branch. Released tags are immutable.

```dart
import 'package:scraper_core/scraper_core.dart';

final planner = ScraperPlanner(scrapers: [
  TmdbScraper(),
  DoubanScraper(),
  BangumiScraper(),
  FileNameScraper(),
  WebPageScraper(),
  ...await YamlScraperLoader(pluginsDirectory: pluginsDir).loadScrapers(),
]);

final plan = await planner.plan(
  ScrapeInput(
    subject: ScrapeSubject(id: 'r1', title: 'Some Movie', uri: posterUri),
    fileName: 'Some.Movie.2019.mkv',
  ),
  ctx: ScrapeContext(config: {'tmdb_api_key': myKey}),
);

for (final run in plan.runs) {
  // run.scraper.id, run.result.fields, run.result.tags ...
}
```

The engine only reads `ScrapeContext.config`; it never stores or persists
secrets. Your app owns settings, keys and credential storage.

## Plugins without code

```yaml
id: "bilibili"
name: "Bilibili"
priority: 75
pattern: 'bilibili\.com/video/(BV[a-zA-Z0-9]{10})|\b(BV[a-zA-Z0-9]{10})\b'
supertag_to_backfill: ["Bilibili"]
request:
  url_template: "https://api.bilibili.com/x/web-interface/view?bvid={1}"
fields:
  - key: "title"
    source: "json:data.title"
    is_title: true
  - key: "author"
    source: "json:data.owner.name"
    entity_type: "author"
  - key: "cover"
    source: "json:data.pic"
    is_preview_image: true
tags:
  - "json:data.tname"
  - "Bilibili"
```

Drop it in your plugin directory and call `reload()`, or listen to `watch()`.

## Command line

Run the engine against a file name or URL without writing any code:

```bash
dart run scraper_core:scraper_cli --file "Some.Show.S01E03.mkv" --builtin filename
dart run scraper_core:scraper_cli --url "https://movie.douban.com/subject/1889243/" --builtin douban
dart run scraper_core:scraper_cli --file "TEST-1.mp4" --plugins ./my_plugins --verbose
```

The result is printed as JSON. Handy for iterating on a YAML plugin.

## Building and testing

```bash
dart pub get
dart analyze
dart format --output=none --set-exit-if-changed .
dart test
```

## Versioning

Semantic versioning. A change that alters **YAML semantics** — the meaning of
`match:N`, template/fallback behaviour, `value_map:` vs `prefix_map:`, or the
`Scraper` contract — is a **MAJOR** change, because existing plugins and hosts
would misbehave silently. New optional YAML keys and new built-in scrapers are
**MINOR**. A built-in site endpoint fix is **PATCH**.

Released `v*` tags are never moved or deleted. Fixes ship as the next revision.

### Built-in scraper ids are reserved

The host app registers scrapers by id, so a plugin using `id: douban` would
**replace** the built-in `DoubanScraper`. Never ship a YAML plugin with an id
that matches a built-in scraper (`filename`, `web_page`, `tmdb`, `douban`,
`bangumi`); give user plugins their own ids (e.g. `douban_mirror`).

## Disclaimer

Scrapers send requests to third-party sites. Comply with each site's terms of
service and your local laws. Scraped metadata copyright belongs to its owners;
this library is a personal cataloguing tool only.

## Repository layout

```
lib/scraper_core.dart   public API (barrel)
lib/src/scraper.dart    contract + value objects
lib/src/builtin/        built-in scrapers
lib/src/yaml/           YAML rule engine
lib/src/planner/        side-effect-free dispatch
lib/src/plugin/         plugin loader + watcher
bin/scraper_cli.dart    command-line runner
docs/                   YAML plugin reference
test/                   unit tests and behaviour pinning
```


