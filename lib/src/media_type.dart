// Copyright 2026 Jiawei LI
// Licensed under the Apache License, Version 2.0.

import 'package:path/path.dart' as p;

/// Media-kind constants and a pure (no-I/O) extension lookup.
///
/// The host application owns its own richer media-type detection; scrapers only
/// need to know which broad kind a subject is so `media_types` gating works.
abstract final class MediaKind {
  static const String video = 'video';
  static const String audio = 'audio';
  static const String image = 'image';
  static const String document = 'document';
  static const String archive = 'archive';
  static const String other = 'other';

  static const Map<String, String> _byExtension = {
    'mp4': video,
    'mkv': video,
    'avi': video,
    'mov': video,
    'wmv': video,
    'flv': video,
    'webm': video,
    'm4v': video,
    'ts': video,
    'rmvb': video,
    'iso': video,

    'mp3': audio,
    'flac': audio,
    'wav': audio,
    'aac': audio,
    'ogg': audio,
    'm4a': audio,
    'wma': audio,
    'ape': audio,

    'jpg': image,
    'jpeg': image,
    'png': image,
    'gif': image,
    'webp': image,
    'bmp': image,
    'svg': image,
    'tiff': image,
    'ico': image,

    'pdf': document,
    'doc': document,
    'docx': document,
    'xls': document,
    'xlsx': document,
    'ppt': document,
    'pptx': document,
    'txt': document,
    'md': document,
    'epub': document,
    'mobi': document,

    'zip': archive,
    'rar': archive,
    '7z': archive,
    'tar': archive,
    'gz': archive,
    'bz2': archive,
  };

  /// Returns the media kind for [pathOrName] based on its extension only.
  static String fromExtension(String pathOrName) {
    final ext = p.extension(pathOrName).toLowerCase().replaceAll('.', '');
    return _byExtension[ext] ?? other;
  }
}
