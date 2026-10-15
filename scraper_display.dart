import '../../l10n/app_localizations.dart';
import 'scraper.dart';

/// Phase 26 B5: builtin scraper display names resolve via ARB by scraper id;
/// YAML/third-party plugins keep the author's own [Scraper.displayName].
String displayScraperName(AppLocalizations l10n, Scraper scraper) {
  switch (scraper.id) {
    case 'bangumi':
      return l10n.scraper_nameBangumi;
    case 'douban':
      return l10n.scraper_nameDouban;
    case 'filename':
      return l10n.scraper_nameFilename;
    case 'jav':
      return l10n.scraper_nameJav;
    case 'webpage':
      return l10n.scraper_nameWebpage;
    case 'tmdb':
      return l10n.scraper_nameTmdb;
    default:
      return scraper.displayName;
  }
}

/// Phase 26 B5: builtin scraper descriptions via ARB (same id rule).
String displayScraperDescription(AppLocalizations l10n, Scraper scraper) {
  switch (scraper.id) {
    case 'bangumi':
      return l10n.scraper_descBangumi;
    case 'douban':
      return l10n.scraper_descDouban;
    case 'filename':
      return l10n.scraper_descFilename;
    case 'jav':
      return l10n.scraper_descJav;
    case 'webpage':
      return l10n.scraper_descWebpage;
    case 'tmdb':
      return l10n.scraper_descTmdb;
    default:
      return scraper.description;
  }
}
