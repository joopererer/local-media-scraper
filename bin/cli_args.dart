// Copyright 2026 Jiawei LI
// Licensed under the Apache License, Version 2.0.

import 'dart:io';

/// Parsed command-line options for `scraper_cli`.
class CliOptions {
  final String? fileName;
  final String? url;
  final List<String> pluginFiles;
  final List<String> pluginDirs;
  final Set<String>? builtin;
  final Map<String, dynamic> config;
  final bool verbose;

  CliOptions({
    this.fileName,
    this.url,
    required this.pluginFiles,
    required this.pluginDirs,
    this.builtin,
    required this.config,
    required this.verbose,
  });
}

/// Parses [args]; returns null when `--help` was requested.
CliOptions? parseCliArgs(List<String> args) {
  String? fileName;
  String? url;
  final pluginFiles = <String>[];
  final pluginDirs = <String>[];
  Set<String>? builtin;
  final config = <String, dynamic>{};
  var verbose = false;

  for (var i = 0; i < args.length; i++) {
    String nextValue() {
      if (i + 1 >= args.length) _fail('${args[i]} needs a value');
      return args[++i];
    }

    switch (args[i]) {
      case '--help':
      case '-h':
        return null;
      case '--file':
        fileName = nextValue();
      case '--url':
        url = nextValue();
      case '--plugin':
        pluginFiles.add(nextValue());
      case '--plugins':
        pluginDirs.add(nextValue());
      case '--builtin':
        builtin = nextValue().split(',').map((s) => s.trim()).toSet();
      case '--config':
        final pair = nextValue();
        final eq = pair.indexOf('=');
        if (eq <= 0) _fail('--config expects key=value');
        config[pair.substring(0, eq)] = pair.substring(eq + 1);
      case '--verbose':
        verbose = true;
      default:
        _fail('unknown argument ${args[i]}');
    }
  }

  if (fileName == null && url == null) _fail('--file or --url is required');

  return CliOptions(
    fileName: fileName,
    url: url,
    pluginFiles: pluginFiles,
    pluginDirs: pluginDirs,
    builtin: builtin,
    config: config,
    verbose: verbose,
  );
}

Never _fail(String message) {
  stderr.writeln('error: $message');
  exit(2);
}
