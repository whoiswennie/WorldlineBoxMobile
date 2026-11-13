part of 'chat.dart';

extension _OpenPetCall on _CompanionWorkspaceState {
  Future<void> _openPetCall(String room, String title, String companion) async {
    final api = _api;
    if (api == null) return;
    try {
      final result = await showDialog<Json>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _PetDial(
          title: title,
          companion: companion,
          connect: () => api.request('call.open', {'conversationId': room}),
        ),
      );
      if (result == null) return;
      final meeting = result['conversationId'] as String;
      if (!mounted || room != _room) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => _PetCall(
            api: () => _api,
            room: meeting,
            runtime: object(object(result['snapshot'])['chatRuntime']),
            title: title,
            companion: companion,
          ),
        ),
      );
    } catch (error) {
      _show(connectionError(error));
    }
  }
}

const _wallpapers = {'lake': '湖畔蓝调', 'rain': '雨中花房', 'study': '秋日书房'};
const _petRingtone = MethodChannel('worldlinebox/pet-ringtone');

class _PetDial extends StatefulWidget {
  const _PetDial({
    required this.title,
    required this.companion,
    required this.connect,
  });

  final String title;
  final String companion;
  final Future<Json> Function() connect;

  @override
  State<_PetDial> createState() => _PetDialState();
}

class _PetDialState extends State<_PetDial> with WidgetsBindingObserver {
  Timer? _timeout;
  bool _connecting = false;
  bool _muted = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _play();
    _timeout = Timer(const Duration(seconds: 60), () {
      if (mounted && !_connecting) Navigator.of(context).pop();
    });
  }

  void _play() {
    if (_muted || _connecting) return;
    unawaited(
      _petRingtone
          .invokeMethod<void>(
            'play',
            widget.companion == 'builtin-dafeiyu' ? 'dafeiyu' : 'common',
          )
          .catchError((Object _) {}),
    );
  }

  void _stop() => unawaited(
    _petRingtone.invokeMethod<void>('stop').catchError((Object _) {}),
  );

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _play();
    } else {
      _stop();
    }
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    _timeout?.cancel();
    _stop();
    try {
      final result = await widget.connect();
      if (mounted) Navigator.of(context).pop(result);
    } catch (error) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = connectionError(error);
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timeout?.cancel();
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CompanionAvatar(
          id: widget.companion,
          name: widget.title,
          size: 98,
          fullResolution: true,
        ),
        const SizedBox(height: 14),
        Text(_error ?? (_connecting ? '正在接通…' : '等待你接通')),
      ],
    ),
    actions: [
      IconButton(
        tooltip: _muted ? '开启铃声' : '静音铃声',
        icon: Icon(
          _muted ? Icons.volume_off_outlined : Icons.volume_up_outlined,
        ),
        onPressed: _connecting
            ? null
            : () {
                setState(() => _muted = !_muted);
                if (_muted) {
                  _stop();
                } else {
                  _play();
                }
              },
      ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton.icon(
        onPressed: _connecting ? null : _connect,
        icon: const Icon(Icons.call),
        label: const Text('接通'),
      ),
    ],
  );
}

class _PetCall extends StatefulWidget {
  const _PetCall({
    required this.api,
    required this.room,
    required this.runtime,
    required this.title,
    required this.companion,
  });
  final MobileApi? Function() api;
  final String room;
  final Json runtime;
  final String title;
  final String companion;

  @override
  State<_PetCall> createState() => _PetCallState();
}

class _PetCallState extends State<_PetCall>
    with SingleTickerProviderStateMixin {
  late final _pose = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  );
  final _text = TextEditingController();
  final _spoken = <String>{};
  final _pending = <String>{};
  final _cueQueue = <Json>[];
  final _callSpeech = MobileSpeech();
  bool _playingCue = false;
  int? _stageId;
  Timer? _cueTimer;
  Timer? _poll;
  Timer? _eventRefresh;
  StreamSubscription<Json>? _events;
  MobileApi? _eventApi;
  int? _cursor;
  String _caption = '';
  String _background = 'lake';
  File? _custom;
  String? _error;
  bool _sending = false;
  bool _checking = false;
  bool _voice = true;
  ({String text, String? topic, String requestId})? _attempt;
  late Json _runtime = widget.runtime;
  bool _changingTopic = false;
  String? _replyProgress;
  MobileApi? _observedApi;
  _PetAssetServer? _assetServer;
  MethodChannel? _stage;
  bool _stageReady = false;
  double? _modelProgress;
  bool _modelFailed = false;

  @override
  void initState() {
    super.initState();
    _observedApi = widget.api();
    _watchCall(_observedApi);
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      final api = widget.api();
      final changed = !identical(_observedApi, api);
      if (changed) setState(() => _observedApi = api);
      if (api != null && _events == null || !identical(_eventApi, api)) {
        _watchCall(api);
      }
      unawaited(_refresh(force: changed));
    });
    unawaited(_restoreWallpaper());
    unawaited(_startStage());
  }

  void _watchCall(MobileApi? api) {
    unawaited(_events?.cancel());
    _events = null;
    _eventApi = api;
    if (api == null) return;
    void stopped() {
      if (identical(_eventApi, api)) _events = null;
    }

    _events = api
        .events(widget.room)
        .listen(
          (event) {
            if (!mounted || !identical(widget.api(), api)) return;
            final active = _pending.contains(event['messageId']);
            if (active && event['type'] == 'progress') {
              setState(
                () => _replyProgress = _progressLabel(
                  object(event['progress'])['phase'] as String?,
                ),
              );
            } else if (active && event['type'] == 'text' && _cueTimer == null) {
              final text = event['text'] as String?;
              if (text != null) setState(() => _caption = text);
            } else if (event['type'] == 'changed') {
              _eventRefresh ??= Timer(const Duration(milliseconds: 180), () {
                _eventRefresh = null;
                unawaited(_refresh(force: true));
              });
            }
          },
          onError: (Object _) => stopped(),
          onDone: stopped,
          cancelOnError: true,
        );
  }

  Future<void> _startStage() async {
    Json local = {};
    try {
      local = await _PetAssetServer.bundledModel(widget.companion);
    } on PlatformException {
      if (mounted) setState(() => _modelFailed = true);
      return;
    }
    if (!mounted || local.isEmpty) return;
    setState(() {
      _modelProgress = 0;
      _modelFailed = false;
      _stageReady = false;
    });
    try {
      final server = await _PetAssetServer.open(
        local,
        widget.companion,
        name: widget.title,
        onProgress: (progress) {
          if (mounted) setState(() => _modelProgress = progress);
        },
      );
      if (!mounted) {
        await server.close();
        return;
      }
      setState(() => _assetServer = server);
    } catch (_) {
      if (mounted) {
        setState(() {
          _modelFailed = true;
          _modelProgress = null;
        });
      }
    }
  }

  void _stageCreated(int id) {
    _stageId = id;
    _stage?.setMethodCallHandler(null);
    final stage = _stage = MethodChannel('worldlinebox/pet-stage/$id');
    stage.setMethodCallHandler((call) async {
      if (mounted && _stage == stage && call.method == 'status') {
        setState(() {
          _stageReady = call.arguments == 'ready';
          _modelFailed = call.arguments == 'error';
          _modelProgress = null;
        });
      }
    });
  }

  Future<File> _wallpaperFile(String name) async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}${Platform.pathSeparator}$name');
  }

  Future<void> _restoreWallpaper() async {
    try {
      final file = await _wallpaperFile('pet-wallpaper.txt');
      final choice = await file.readAsString();
      final custom = await _wallpaperFile('pet-wallpaper-image');
      final available = await custom.exists();
      if (!mounted) return;
      setState(() {
        if (_wallpapers.containsKey(choice) || choice == 'plain') {
          _background = choice;
        }
        if (choice == 'custom' && available) {
          _custom = custom;
          _background = choice;
        }
      });
    } on IOException {
      /* Default wallpaper is available offline. */
    }
  }

  Future<void> _chooseWallpaper() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in _wallpapers.entries)
              ListTile(
                title: Text(item.value),
                selected: _background == item.key,
                onTap: () => Navigator.pop(context, item.key),
              ),
            ListTile(
              title: const Text('纯色背景'),
              onTap: () => Navigator.pop(context, 'plain'),
            ),
            ListTile(
              leading: const Icon(Icons.add_photo_alternate_outlined),
              title: const Text('导入自己的背景'),
              onTap: () => Navigator.pop(context, 'custom'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    try {
      if (choice == 'custom') {
        final picked = await FilePicker.platform.pickFiles(
          type: FileType.image,
        );
        final path = picked?.files.single.path;
        if (path == null) return;
        final image = File(path);
        if (await image.length() > 20 * 1024 * 1024) {
          throw const MobileException('背景图片最多 20 MB。');
        }
        final target = await _wallpaperFile('pet-wallpaper-image');
        await image.copy(target.path);
        await FileImage(target).evict();
        _custom = target;
      }
      await (await _wallpaperFile(
        'pet-wallpaper.txt',
      )).writeAsString(choice, flush: true);
      if (mounted) setState(() => _background = choice);
    } catch (error) {
      if (mounted) setState(() => _error = connectionError(error));
    }
  }

  Future<void> _send() async {
    final api = widget.api(), text = _text.text.trim();
    if (api == null || text.isEmpty || _sending || _changingTopic) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final topic = object(_runtime['topic'])['id'] as String?;
    if (_attempt?.text != text || _attempt?.topic != topic) {
      _attempt = (text: text, topic: topic, requestId: _uuid.v4());
    }
    try {
      final result = await api.request('message.send', {
        'conversationId': widget.room,
        'topicId': ?topic,
        'requestId': _attempt!.requestId,
        'content': text,
      });
      if (!mounted) return;
      _attempt = null;
      _pending.addAll(
        (result['replyMessageIds'] as List? ?? []).whereType<String>(),
      );
      if (_text.text.trim() == text) _text.clear();
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = connectionError(error));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _refresh({bool force = false}) async {
    final api = widget.api();
    if (_checking || api == null || (_pending.isEmpty && !force)) return;
    _checking = true;
    try {
      final state = object(
        (await api.request('state', {
          'conversationId': widget.room,
          'after': ?_cursor,
          'tracked': _pending.take(20).toList(),
        }))['snapshot'],
      );
      if (!mounted) return;
      _cursor = state['cursor'] as int? ?? _cursor;
      String? progress;
      for (final message in objects(state['messages'])) {
        if (!_pending.contains(message['id'])) continue;
        final content = (message['content'] as String? ?? '').trim();
        final cues = objects(message['cues']);
        if (['queued', 'running'].contains(message['status'])) {
          progress = _progressLabel(
            object(message['progress'])['phase'] as String?,
          );
          if (content.isNotEmpty && cues.isEmpty && !_playingCue) {
            _caption = content;
          }
        }
        for (final cue in cues) {
          final id = "${message['id']}/${cue['id']}";
          if (_spoken.add(id)) {
            _enqueueCue({...cue, 'messageId': message['id']});
          }
        }
        if (['sent', 'failed', 'cancelled'].contains(message['status'])) {
          _pending.remove(message['id']);
          if (cues.isEmpty &&
              content.isNotEmpty &&
              _spoken.add(message['id'] as String)) {
            _enqueueCue({'text': content, 'messageId': message['id']});
          }
          if (message['status'] == 'failed') {
            setState(() => _error = message['error'] as String? ?? '伙伴回复失败。');
          }
        }
      }
      setState(() {
        _runtime = object(state['chatRuntime']);
        _replyProgress = progress;
      });
    } catch (error) {
      if (mounted) setState(() => _error = connectionError(error));
    } finally {
      _checking = false;
    }
  }

  void _enqueueCue(Json cue) {
    _cueQueue.add(cue);
    if (!_playingCue) unawaited(_playNextCue());
  }

  Future<void> _playNextCue() async {
    if (!mounted || _cueQueue.isEmpty) return;
    _playingCue = true;
    final cue = _cueQueue.removeAt(0);
    final text = cue['text'] as String? ?? '';
    final duration =
        (cue['durationMs'] as int? ??
        (text.characters.length * 220).clamp(1500, 12000));
    if (text.trim().isNotEmpty) {
      setState(() => _caption = text);
      unawaited(_pose.forward(from: 0));
    }
    unawaited(
      _stage
          ?.invokeMethod<void>(
            'cue',
            jsonEncode({...cue, 'durationMs': duration}),
          )
          .catchError((Object _) {}),
    );
    final elapsed = Stopwatch()..start();
    final api = widget.api();
    try {
      final message = cue['messageId'];
      if (_voice && api != null && message is String) {
        await _callSpeech.play(
          api,
          widget.room,
          message,
          part: cue['id'] as String?,
          stage: _stageId,
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = connectionError(error));
    }
    if (!mounted) return;
    _cueTimer = Timer(
      Duration(
        milliseconds: (duration - elapsed.elapsedMilliseconds).clamp(
          0,
          duration,
        ),
      ),
      () {
        _cueTimer = null;
        _playingCue = false;
        unawaited(_playNextCue());
      },
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    _eventRefresh?.cancel();
    _eventApi = null;
    unawaited(_events?.cancel());
    _cueTimer?.cancel();
    _stage?.setMethodCallHandler(null);
    unawaited(_assetServer?.close());
    _pose.dispose();
    _text.dispose();
    unawaited(_callSpeech.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final background = _wallpapers.containsKey(_background)
        ? AssetImage('assets/call-backgrounds/$_background.png')
              as ImageProvider
        : _background == 'custom' && _custom != null
        ? FileImage(_custom!)
        : null;
    return Scaffold(
      backgroundColor: const Color(0xff161322),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (background != null) Image(image: background, fit: BoxFit.cover),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x80111120),
                  Color(0x00111120),
                  Color(0xdd111120),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                ListTile(
                  title: Text(
                    widget.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  subtitle: const Text(
                    '桌宠通话',
                    style: TextStyle(color: Colors.white70),
                  ),
                  trailing: IconButton(
                    color: Colors.white,
                    tooltip: '通话背景',
                    icon: const Icon(Icons.wallpaper),
                    onPressed: _chooseWallpaper,
                  ),
                ),
                if (_modelProgress != null && !_stageReady)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Column(
                      children: [
                        const Text(
                          '正在准备 Live2D 形象',
                          style: TextStyle(color: Colors.white70),
                        ),
                        LinearProgressIndicator(value: _modelProgress),
                      ],
                    ),
                  ),
                if (_modelFailed)
                  TextButton(
                    onPressed: () async {
                      final server = _assetServer;
                      setState(() => _assetServer = null);
                      await server?.close();
                      if (mounted) await _startStage();
                    },
                    child: const Text('重试加载 Live2D'),
                  ),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (!_stageReady)
                        LayoutBuilder(
                          builder: (context, constraints) => Center(
                            child: AnimatedBuilder(
                              animation: _pose,
                              builder: (context, child) => Transform.scale(
                                scale: 1 + .035 * sin(_pose.value * pi),
                                child: child,
                              ),
                              child: CompanionAvatar(
                                id: widget.companion,
                                name: widget.title,
                                fullResolution: true,
                                size: min(
                                  constraints.maxWidth * .82,
                                  constraints.maxHeight * .85,
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (_assetServer case final server?)
                        AndroidView(
                          key: ValueKey(server.url),
                          viewType: 'worldlinebox/pet-stage',
                          creationParams: {'url': server.url},
                          creationParamsCodec: const StandardMessageCodec(),
                          onPlatformViewCreated: _stageCreated,
                        ),
                    ],
                  ),
                ),
                if (_caption.isNotEmpty || _error != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 150),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(22, 8, 22, 8),
                      child: Text(
                        _error ?? _caption,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                        ),
                      ),
                    ),
                  ),
                if (_replyProgress != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      _replyProgress!,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                _TopicBar(
                  room: widget.room,
                  api: widget.api(),
                  runtime: _runtime,
                  members: [
                    {'id': widget.companion, 'name': widget.title},
                  ],
                  dark: true,
                  onRouting: (busy) => setState(() => _changingTopic = busy),
                  onNotice: (text) => ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(text))),
                  onChanged: (topic) async {
                    if (topic.isNotEmpty) {
                      setState(() => _runtime = {..._runtime, 'topic': topic});
                    }
                    await _refresh(force: true);
                  },
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      IconButton(
                        color: Colors.white,
                        tooltip: _voice ? '静音伙伴' : '打开伙伴声音',
                        onPressed: () {
                          setState(() => _voice = !_voice);
                          if (!_voice) {
                            unawaited(_callSpeech.stop());
                          }
                        },
                        icon: Icon(
                          _voice
                              ? Icons.volume_up_outlined
                              : Icons.volume_off_outlined,
                        ),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _text,
                          style: const TextStyle(color: Colors.white),
                          onSubmitted: (_) => _send(),
                          decoration: const InputDecoration(
                            hintText: '发消息…',
                            hintStyle: TextStyle(color: Colors.white70),
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      IconButton(
                        color: Colors.white,
                        tooltip: '发送',
                        onPressed:
                            _sending || _changingTopic || widget.api() == null
                            ? null
                            : _send,
                        icon: const Icon(Icons.arrow_upward),
                      ),
                      IconButton.filled(
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xffa53553),
                          foregroundColor: Colors.white,
                        ),
                        tooltip: '结束通话',
                        icon: const Icon(Icons.call_end),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PetAssetServer {
  _PetAssetServer(this._server, this._nonce);
  final HttpServer _server;
  final String _nonce;
  static const _textures = MethodChannel('worldlinebox/pet-textures');
  static Future<Json> bundledModel(String companion) async {
    final catalog = await _textures.invokeMethod<String>('catalog');
    return catalog == null
        ? const {}
        : object(object(jsonDecode(catalog))[companion]);
  }

  String get url => 'http://127.0.0.1:${_server.port}/$_nonce/';
  Future<void> close() async {
    await _server.close(force: true);
  }

  static Future<_PetAssetServer> open(
    Json model,
    String companion, {
    required String name,
    required void Function(double) onProgress,
  }) async {
    final cache = await getApplicationSupportDirectory();
    final modelFolder = Directory('${cache.path}/pet-model-files');
    await modelFolder.create(recursive: true);
    final originals = <String, Future<File>>{};
    final variants = <String, File>{};
    Future<File> extract(String path) async {
      final key = sha256.convert(utf8.encode('bundled-v1/$companion/$path'));
      final file = File('${modelFolder.path}/$key');
      if (await file.exists()) return file;
      final temporary = File('${file.path}.${_uuid.v4()}.tmp');
      try {
        await _textures.invokeMethod<void>('copyBundled', {
          'asset': path,
          'path': temporary.path,
        });
        return await temporary.rename(file.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    }

    Future<File> original(String path) async {
      try {
        return await originals.putIfAbsent(path, () => extract(path));
      } catch (_) {
        originals.remove(path);
        rethrow;
      }
    }

    Future<File> texture(File source, int limit) async {
      final file = File('${source.path}.max-$limit');
      if (await file.exists()) return file;
      final temporary = File('${file.path}.${_uuid.v4()}.tmp');
      try {
        final resized = await _textures.invokeMethod<bool>('prepare', {
          'path': source.path,
          'output': temporary.path,
          'limit': limit,
        });
        if (resized != true) return source;
        return await temporary.rename(file.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    }

    Future<void> prepare(int gpuLimit) async {
      onProgress(0);
      final memoryLimit =
          await _textures.invokeMethod<int>('memoryLimit') ?? 4096;
      final limit = min(gpuLimit, memoryLimit);
      final manifestPath = model['model'] as String;
      final manifest = object(
        jsonDecode(await (await original(manifestPath)).readAsString()),
      );
      final references = object(manifest['FileReferences']);
      final folder = manifestPath.substring(
        0,
        manifestPath.lastIndexOf('/') + 1,
      );
      final assets = [
        'live2dcubismcore.min.js',
        if (references['Moc'] case final String moc) '$folder$moc',
        for (final texture
            in (references['Textures'] as List? ?? []).whereType<String>())
          '$folder$texture',
      ];
      final prepared = <String, File>{};
      for (var i = 0; i < assets.length; i++) {
        final path = assets[i];
        final source = await original(path);
        if (path.toLowerCase().endsWith('.png')) {
          prepared[path] = await texture(source, limit);
        }
        onProgress((i + 1) / assets.length);
      }
      variants
        ..clear()
        ..addAll(prepared);
    }

    Future<void>? preparation;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _PetAssetServer(server, _uuid.v4());
    server.listen((request) async {
      final response = request.response;
      try {
        final segments = request.uri.pathSegments;
        if (request.method != 'GET' ||
            request.headers.value(HttpHeaders.hostHeader) !=
                '127.0.0.1:${server.port}' ||
            segments.isEmpty ||
            segments.first != host._nonce) {
          response.statusCode = 404;
        } else {
          final name = segments.skip(1).join('/');
          if (name.isEmpty) {
            response.headers.contentType = ContentType.html;
            final start = jsonEncode({
              'model':
                  'media/${(model['model'] as String).split('/').map(Uri.encodeComponent).join('/')}',
              'manifest': model['manifest'],
              'vts': model['vts'],
              'name': name,
              'core': 'media/live2dcubismcore.min.js',
            }).replaceAll('<', r'\u003c');
            final viewer =
                (await rootBundle.loadString(
                  'assets/pet-viewer/viewer.js',
                )).replaceAll(
                  RegExp('</script', caseSensitive: false),
                  r'<\/script',
                );
            response.write(
              '<!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">'
              '<style>html,body,#stage{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}canvas{display:block}</style>'
              '<div id="stage"></div><script>$viewer</script><script>window.startPet($start)</script>',
            );
          } else if (name == 'prepare') {
            final limit = int.tryParse(
              request.uri.queryParameters['limit'] ?? '',
            );
            if (limit == null ||
                limit < 1024 ||
                limit > 16384 ||
                preparation != null) {
              response.statusCode = 400;
            } else {
              final preparing = preparation = prepare(limit);
              try {
                await preparing;
                response.statusCode = 204;
              } finally {
                preparation = null;
              }
            }
          } else if (name.startsWith('media/')) {
            final path = name.substring(6);
            final source = variants[path] ?? await original(path);
            final extension = path.split('.').last.toLowerCase();
            response.headers.contentType = switch (extension) {
              'js' => ContentType('application', 'javascript'),
              'json' => ContentType.json,
              'png' => ContentType('image', 'png'),
              _ => ContentType.binary,
            };
            response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
            response.contentLength = await source.length();
            await response.addStream(source.openRead());
          } else {
            response.statusCode = 404;
          }
        }
      } catch (_) {
        try {
          response.statusCode = 503;
        } catch (_) {}
      } finally {
        await response.close().catchError((Object _) {});
      }
    });
    return host;
  }
}
