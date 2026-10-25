// Copyright 2026 Jiawei LI
// Licensed under the Apache License, Version 2.0.

import 'package:scraper_core/scraper_core.dart';

/// Serialises a [ScrapePlan] into the CLI's JSON shape.
Map<String, dynamic> planToJson(ScrapePlan plan) => {
  'backfillSupertags': [for (final b in plan.backfill) b.label],
  'proposedTitle': plan.proposedTitle,
  'previewImageUrl': plan.previewImageUrl,
  'runs': [for (final run in plan.runs) _runToJson(run)],
};

Map<String, dynamic> _runToJson(ScraperRun run) => {
  'scraper': run.scraper.id,
  'fields': [
    for (final f in run.result.fields)
      {
        'key': f.key,
        'valueText': f.valueText,
        'valueNum': f.valueNum,
        'entityName': f.entityName,
        'entityType': f.entityType,
        'confidence': f.confidence,
        'source': f.source,
      },
  ],
  'tags': [
    for (final t in run.result.tags)
      {'path': t.tagPath, 'confidence': t.confidence},
  ],
};
