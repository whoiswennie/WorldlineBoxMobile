part of 'chat.dart';

const _filesChannel = MethodChannel('worldlinebox/mobile-files');

String _attachmentName(Json file) {
  final name = (file['originalName'] ?? file['name'] ?? '附件').toString().trim();
  final match = RegExp(
    r'^([a-f0-9]{32,})(?:\.([a-z0-9]+))?$',
    caseSensitive: false,
  ).firstMatch(name);
  if (match == null) return name.isEmpty ? '附件' : name;
  final mime = (file['mimeType'] ?? '').toString();
  final ext =
      match.group(2) ??
      const {
        'image/png': 'png',
        'image/jpeg': 'jpg',
        'image/webp': 'webp',
        'application/pdf': 'pdf',
      }[mime];
  return '${mime.startsWith('image/') ? '图片' : '附件'}-${match.group(1)!.substring(0, 8)}${ext == null ? '' : '.$ext'}';
}

String _attachmentKind(Json file) {
  final mime = (file['mimeType'] ?? '').toString().toLowerCase();
  final ext = _attachmentName(file).toLowerCase().split('.').last;
  if (mime == 'application/pdf' || ext == 'pdf') return 'PDF';
  if (mime.startsWith('image/') ||
      const {'png', 'jpeg', 'jpg', 'gif', 'webp', 'bmp'}.contains(ext)) {
    return '图片';
  }
  if (mime.startsWith('text/') ||
      const {
        'txt',
        'md',
        'csv',
        'tsv',
        'json',
        'yaml',
        'yml',
        'xml',
        'log',
        'js',
        'ts',
        'py',
        'css',
        'html',
        'dart',
        'toml',
        'ini',
      }.contains(ext)) {
    return '文本';
  }
  return '文件';
}

String _fileSize(int size) => size < 1024
    ? '$size B'
    : size < 1024 * 1024
    ? '${(size / 1024).toStringAsFixed(1)} KB'
    : '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';

Future<String?> _saveAttachment(Json args) async {
  final saved = await _filesChannel.invokeMethod<Object?>('quickSave', args);
  return saved is String
      ? '已保存到 $saved'
      : saved == true
      ? '附件已保存到所选位置'
      : null;
}

class _AttachmentPreview extends StatefulWidget {
  const _AttachmentPreview({required this.file, required this.args});
  final File file;
  final Json args;

  @override
  State<_AttachmentPreview> createState() => _AttachmentPreviewState();
}

class _AttachmentPreviewState extends State<_AttachmentPreview> {
  late final kind = _attachmentKind(widget.args);
  Future<String>? text;
  Future<Map<dynamic, dynamic>?>? pdf;
  int page = 0;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    if (kind == '文本') text = _readText();
    if (kind == 'PDF') pdf = _render(0);
  }

  Future<String> _readText() async {
    final input = await widget.file.open();
    try {
      const limit = 256 * 1024;
      final bytes = await input.read(limit);
      final content = utf8.decode(bytes, allowMalformed: true);
      return await input.length() > limit ? '$content\n…（预览前 256 KB）' : content;
    } finally {
      await input.close();
    }
  }

  Future<Map<dynamic, dynamic>?> _render(int index) =>
      _filesChannel.invokeMapMethod('pdfPage', {...widget.args, 'page': index});

  void _changePage(int next) => setState(() {
    page = next;
    pdf = _render(next);
  });

  Future<void> _save() async {
    setState(() => saving = true);
    try {
      final message = await _saveAttachment(widget.args);
      if (mounted && message != null) _notice(message);
    } on PlatformException catch (e) {
      if (mounted) _notice(e.message ?? '保存失败。');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  void _notice(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _open() async {
    try {
      await _filesChannel.invokeMethod('open', widget.args);
      if (mounted) Navigator.pop(context, true);
    } on PlatformException catch (e) {
      if (mounted) _notice(e.message ?? '无法打开文件。');
    }
  }

  Widget _zoom(Widget child) =>
      InteractiveViewer(minScale: 1, maxScale: 6, child: Center(child: child));
  Widget _fallback(String message) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message),
        TextButton(onPressed: _open, child: const Text('用其他应用打开')),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          widget.args['name'],
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: '保存到手机',
            onPressed: saving ? null : _save,
            icon: const Icon(Icons.download_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: switch (kind) {
          '图片' => _zoom(
            Image.file(
              widget.file,
              cacheWidth: 2400,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => _fallback('手机无法解码这张图片。'),
            ),
          ),
          '文本' => FutureBuilder<String>(
            future: text,
            builder: (_, snapshot) => snapshot.hasError
                ? _fallback('无法读取文本。')
                : snapshot.hasData
                ? SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(snapshot.data!),
                  )
                : const Center(child: CircularProgressIndicator()),
          ),
          'PDF' => FutureBuilder<Map<dynamic, dynamic>?>(
            future: pdf,
            builder: (_, snapshot) {
              if (snapshot.hasError) return _fallback('无法预览此 PDF。');
              if (snapshot.connectionState != ConnectionState.done ||
                  snapshot.data == null) {
                return const Center(child: CircularProgressIndicator());
              }
              final count = snapshot.data!['count'] as int;
              return Column(
                children: [
                  Expanded(
                    child: KeyedSubtree(
                      key: ValueKey(page),
                      child: _zoom(
                        Image.memory(
                          snapshot.data!['bytes'],
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: '上一页',
                        onPressed: page == 0
                            ? null
                            : () => _changePage(page - 1),
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Text('${page + 1} / $count'),
                      IconButton(
                        tooltip: '下一页',
                        onPressed: page + 1 == count
                            ? null
                            : () => _changePage(page + 1),
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
          _ => _fallback('请选择手机上的应用来查看此文件。'),
        },
      ),
    ),
  );
}
