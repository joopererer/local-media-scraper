// Copyright 2026 Jiawei LI
// Licensed under the Apache License, Version 2.0.

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:scraper_core/scraper_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scraper_loader_test');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<File> writePlugin(String name, String id) async {
    final file = File(p.join(tmp.path, name));
    await file.writeAsString('id: "$id"\nname: "$id"\npattern: "X-(\\\\d+)"\n');
    return file;
  }

  test('loads every .yaml/.yml file and ignores everything else', () async {
    await writePlugin('a.yaml', 'a');
    await writePlugin('b.yml', 'b');
    await File(p.join(tmp.path, 'notes.txt')).writeAsString('nope');

    final loader = YamlScraperLoader(pluginsDirectory: tmp);
    final scrapers = await loader.loadScrapers();

    expect(scrapers.map((s) => s.id).toSet(), {'a', 'b'});
    expect(loader.loadedScrapers, hasLength(2));
  });

  test('keeps loading other files when one is broken', () async {
    await writePlugin('good.yaml', 'good');
    await File(
      p.join(tmp.path, 'broken.yaml'),
    ).writeAsString(':\n  - [unbalanced');

    final logs = <String>[];
    final loader = YamlScraperLoader(pluginsDirectory: tmp, onLog: logs.add);
    final scrapers = await loader.loadScrapers();

    expect(scrapers.map((s) => s.id), ['good']);
    expect(logs.any((l) => l.contains('broken.yaml')), isTrue);
  });

  test(
    'creates the directory on demand and runs the builtin sync hook',
    () async {
      final nested = Directory(p.join(tmp.path, 'plugins', 'scrapers'));
      var synced = 0;
      final loader = YamlScraperLoader(
        pluginsDirectory: nested,
        builtinSync: () async {
          synced++;
          return const [];
        },
      );

      await loader.loadScrapers();

      expect(await nested.exists(), isTrue);
      expect(synced, 1);
    },
  );

  test('reload picks up newly added plugins', () async {
    final loader = YamlScraperLoader(pluginsDirectory: tmp);
    await loader.loadScrapers();
    expect(loader.loadedScrapers, isEmpty);

    await writePlugin('late.yaml', 'late');
    await loader.reload();

    expect(loader.loadedScrapers.map((s) => s.id), ['late']);
  });

  test('watch emits a reloaded list after the directory changes', () async {
    final loader = YamlScraperLoader(pluginsDirectory: tmp);
    final emissions = <List<YamlScraper>>[];
    final sub = loader
        .watch(debounce: const Duration(milliseconds: 50))
        .listen(emissions.add);

    // Give the watcher a moment to attach before touching the directory.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await writePlugin('watched.yaml', 'watched');
    await Future<void>.delayed(const Duration(milliseconds: 800));

    await sub.cancel();
    expect(emissions, isNotEmpty);
    expect(emissions.last.map((s) => s.id), contains('watched'));
  });
}
