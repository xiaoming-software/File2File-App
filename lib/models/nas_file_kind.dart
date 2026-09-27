/// File/folder kind for NAS icons — mirrors Desktop `classifyNasName`.
enum NasFileKind {
  folder,
  image,
  video,
  audio,
  pdf,
  archive,
  doc,
  text,
  code,
  file,
}

const _imageExt = {
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
  'svg',
};

const _videoExt = {'mp4', 'mov', 'avi', 'mkv', 'webm', 'm4v'};

const _audioExt = {'mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg', 'wma'};

const _officeExt = {
  'doc',
  'docx',
  'xls',
  'xlsx',
  'ppt',
  'pptx',
  'pdf',
  'csv',
  'odt',
  'ods',
  'odp',
};

const _textExt = {
  'txt',
  'log',
  'md',
  'ini',
  'conf',
  'cfg',
  'properties',
  'env',
};

const _codeExt = {
  'js',
  'ts',
  'tsx',
  'jsx',
  'json',
  'html',
  'htm',
  'css',
  'scss',
  'less',
  'rs',
  'go',
  'py',
  'java',
  'c',
  'cc',
  'cpp',
  'cxx',
  'h',
  'hpp',
  'sh',
  'bash',
  'zsh',
  'vue',
  'xml',
  'yml',
  'yaml',
  'toml',
  'sql',
  'kt',
  'kts',
  'swift',
  'rb',
  'php',
  'lua',
  'm',
  'mm',
};

const _archiveExt = {'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz'};

/// Last `.`-segment lowercased — same as Desktop `classifyNasName`.
String fileExtension(String name) {
  final s = name.trim();
  if (s.isEmpty) return '';
  return s.split('.').last.toLowerCase();
}

NasFileKind classifyNasName(String name, {bool isDir = false}) {
  if (isDir) return NasFileKind.folder;
  final ext = fileExtension(name);
  if (_imageExt.contains(ext)) return NasFileKind.image;
  if (_videoExt.contains(ext)) return NasFileKind.video;
  if (_audioExt.contains(ext)) return NasFileKind.audio;
  if (ext == 'pdf') return NasFileKind.pdf;
  if (_archiveExt.contains(ext)) return NasFileKind.archive;
  if (_officeExt.contains(ext)) return NasFileKind.doc;
  if (_textExt.contains(ext)) return NasFileKind.text;
  if (_codeExt.contains(ext)) return NasFileKind.code;
  return NasFileKind.file;
}

extension NasFileKindMeta on NasFileKind {
  String get label => switch (this) {
        NasFileKind.folder => '文件夹',
        NasFileKind.image => '图像',
        NasFileKind.video => '影片',
        NasFileKind.audio => '音频',
        NasFileKind.pdf => 'PDF 文稿',
        NasFileKind.archive => '压缩包',
        NasFileKind.doc => '文稿',
        NasFileKind.text => '文本',
        NasFileKind.code => '代码',
        NasFileKind.file => '文稿',
      };
}
