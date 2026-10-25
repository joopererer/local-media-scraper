# Contributing

## Ground rules

1. **The scraping layer stays app-agnostic.** No database, no UI, no
   application-specific types. If you need to persist something, return it and
   let the host do it.
2. **YAML semantics are a contract.** Plugins in the wild depend on the exact
   meaning of extraction sources, template rendering and fallback rules. Any
   behaviour change there is a **MAJOR** version bump and must come with updated
   tests in `test/yaml_scraper_test.dart`.
3. **No secrets and no site-specific plugins** in this repository. API keys are
   passed via `ScrapeContext.config`; site rules live in the host app or the
   user's plugin directory.

## Released tags are immutable

A pushed `v*` tag is never moved and never deleted. Downstream projects pin to a
tag, so moving one would silently change what everyone builds. Fixes always ship
as the next revision (`v0.1.1`, `v0.1.2`, …). Do not depend on a branch.

## Before you open a PR

```bash
dart pub get
dart analyze
dart format --output=none --set-exit-if-changed .
dart test
```

All four must pass. New behaviour needs a test; bug fixes need a regression test.

## Release checklist

1. Update `CHANGELOG.md` and bump `version` in `pubspec.yaml`.
2. `dart pub publish --dry-run` (structure/sanity check only; this is not a
   pub.dev package).
3. Tag `vX.Y.Z` and push the tag. Never reuse or move it.
4. Bump the `ref:` in each host project and record the new resolution.

