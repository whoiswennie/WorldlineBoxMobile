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
      _activeCallRoom = meeting;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => _PetCall(
            api: () => _api,
            room: meeting,
            initialSnapshot: object(result['snapshot']),
            stageCatalog: object(result['callStage']),
            title: title,
            companion: companion,
          ),
        ),
      );
    } catch (error) {
      _show(connectionError(error));
    } finally {
      _activeCallRoom = null;
      if (mounted) _markVisible();
    }
  }
}

const _wallpapers = {'lake': '湖畔蓝调', 'rain': '雨中花房', 'study': '秋日书房'};
const _petRingtone = MethodChannel('worldlinebox/pet-ringtone');
const _callDockInk = Color(0xff405b78);
const _callDockBorder = Color(0xffbed1e4);

enum _CallBubbleVisibility { automatic, collapsed, reviewing }

const _callBubbleAutoHideDelay = Duration(milliseconds: 1800);

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
            widget.companion == 'builtin-dafeiyu' ? 'dafeiyu' : 'phoebe',
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
    required this.initialSnapshot,
    required this.stageCatalog,
    required this.title,
    required this.companion,
  });
  final MobileApi? Function() api;
  final String room;
  final Json initialSnapshot;
  final Json stageCatalog;
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
  final _interruptedReplies = <String>{};
  final _presentedThrough = <String, (int, String)>{};
  final _callSpeech = MobileSpeech();
  Future<void>? _cueVoice;
  bool _playingCue = false;
  bool _autoCue = true;
  int _cueIndex = -1;
  int _furthestCue = -1;
  int _cueRevision = 0;
  int _topicRevision = 0;
  int? _stageId;
  Timer? _cueTimer;
  Timer? _bubbleHideTimer;
  _CallBubbleVisibility _bubbleVisibility = _CallBubbleVisibility.automatic;
  Timer? _poll;
  Timer? _eventRefresh;
  StreamSubscription<Json>? _events;
  MobileApi? _eventApi;
  int? _cursor;
  int? _publicationCursor;
  String _caption = '';
  String _background = 'lake';
  File? _custom;
  String? _error;
  bool _sending = false;
  bool _checking = false;
  bool _voice = true;
  ({String text, String? topic, String requestId})? _attempt;
  late Json _runtime = object(widget.initialSnapshot['chatRuntime']);
  bool _changingTopic = false;
  bool _interrupting = false;
  PetCallProgress? _replyProgress;
  DateTime? _replyStartedAt;
  MobileApi? _observedApi;
  _PetAssetServer? _assetServer;
  MethodChannel? _stage;
  bool _stageReady = false;
  double? _modelProgress;
  bool _modelFailed = false;
  bool _fullBody = false;
  bool _canChangeBodyShape = false;
  double _bodyShape = 0;
  Json? _activeCue;
  String? _stagePresence;

  @override
  void initState() {
    super.initState();
    _observedApi = widget.api();
    _cursor = widget.initialSnapshot['cursor'] as int?;
    _publicationCursor =
        object(widget.initialSnapshot['callDelivery'])['cursor'] as int?;
    for (final message in objects(widget.initialSnapshot['messages'])) {
      if (message['senderId'] != widget.companion ||
          !['queued', 'running'].contains(message['status'])) {
        continue;
      }
      _pending.add(message['id'] as String);
      for (final cue in objects(message['cues'])) {
        _spoken.add("${message['id']}/${cue['id']}");
      }
    }
    _watchCall(_observedApi);
    _poll = Timer.periodic(const Duration(seconds: 2), (timer) {
      final api = widget.api();
      final changed = !identical(_observedApi, api);
      if (changed) setState(() => _observedApi = api);
      if (api != null && _events == null || !identical(_eventApi, api)) {
        _watchCall(api);
      }
      unawaited(
        _refresh(
          force: changed || _publicationCursor != null && timer.tick % 5 == 0,
        ),
      );
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
                () => _replyProgress = _callProgress(
                  object(event['progress']),
                  startedAt: _replyProgress?.startedAt ?? _replyStartedAt,
                ),
              );
            } else if (active &&
                event['type'] == 'text' &&
                !_playingCue &&
                _autoCue) {
              final text = event['text'] as String?;
              if (text != null) {
                setState(() => _caption = text);
              }
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
      _canChangeBodyShape = false;
    });
    try {
      final server = await _PetAssetServer.open(
        local,
        widget.companion,
        characterName: widget.title,
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
    _headBounds = null;
    _stage?.setMethodCallHandler(null);
    _stagePresence = null;
    final stage = _stage = MethodChannel('worldlinebox/pet-stage/$id');
    stage.setMethodCallHandler((call) async {
      if (!mounted || _stage != stage) return;
      if ((call.method, call.arguments) case (
        'figure',
        [
          final double x,
          final double y,
          final double width,
          final double height,
        ],
      )) {
        final bounds = Rect.fromLTWH(x, y, width, height);
        if (_headBounds != bounds) setState(() => _headBounds = bounds);
      } else if (call.method == 'status') {
        if (call.arguments == 'body-shape') {
          setState(() => _canChangeBodyShape = true);
          _sendBodyShape();
          return;
        }
        setState(() {
          _stageReady = call.arguments == 'ready';
          _modelFailed = call.arguments == 'error';
          _modelProgress = null;
        });
        if (_stageReady) {
          if (_activeCue != null) _sendStageCue();
          _syncStagePresence();
          _sendStageFraming();
        }
      }
    });
  }

  void _sendBodyShape() {
    if (!_stageReady || !_canChangeBodyShape) return;
    unawaited(
      _stage
          ?.invokeMethod<void>('bodyShape', _bodyShape)
          .catchError((Object _) {}),
    );
  }

  Future<void> _chooseBodyShape() => showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('体型 ${(_bodyShape * 100).round()}%'),
              Slider(
                value: _bodyShape,
                onChanged: (value) {
                  setSheetState(() => _bodyShape = value);
                  _sendBodyShape();
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );

  void _sendStageFraming() {
    if (!_stageReady) return;
    unawaited(
      _stage
          ?.invokeMethod<void>('fullBody', _fullBody)
          .catchError((Object _) {}),
    );
  }

  void _sendStageCue() {
    if (!_stageReady) return;
    unawaited(
      _stage
          ?.invokeMethod<void>('cue', jsonEncode(_activeCue))
          .catchError((Object _) {}),
    );
  }

  void _syncStagePresence() {
    if (!_stageReady) return;
    final value = _activeCue != null
        ? 'speaking'
        : _sending || _pending.isNotEmpty
        ? 'waiting'
        : 'idle';
    if (value == _stagePresence) return;
    _stagePresence = value;
    unawaited(
      _stage?.invokeMethod<void>('presence', value).catchError((Object _) {}),
    );
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
    _cancelBubbleHide();
    setState(() {
      _sending = true;
      _error = null;
      _replyStartedAt = DateTime.now();
      _replyProgress = null;
      if (!_playingCue) _caption = '';
      _bubbleVisibility = _CallBubbleVisibility.automatic;
    });
    _syncStagePresence();
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
      if (!_autoCue) setState(() => _autoCue = true);
      if (_text.text.trim() == text) _text.clear();
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = connectionError(error));
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _scheduleBubbleHide();
        _syncStagePresence();
      }
    }
  }

  Future<void> _refresh({bool force = false}) async {
    final api = widget.api();
    if (_checking || api == null || (_pending.isEmpty && !force)) {
      return;
    }
    final topicRevision = _topicRevision;
    _checking = true;
    var more = false;
    try {
      final state = object(
        (await api.request('state', {
          'conversationId': widget.room,
          'after': ?_cursor,
          'callAfter': ?_publicationCursor,
          'tracked': _pending.take(20).toList(),
        }))['snapshot'],
      );
      if (!mounted || topicRevision != _topicRevision) return;
      final previousCursor = _cursor;
      _cursor = state['cursor'] as int? ?? _cursor;
      final delivery = object(state['callDelivery']);
      _publicationCursor = delivery['cursor'] as int? ?? _publicationCursor;
      more = delivery['more'] == true;
      final published = (delivery['messageIds'] as List? ?? [])
          .whereType<String>()
          .toSet();
      PetCallProgress? progress;
      for (final message in objects(state['messages'])) {
        final id = message['id'] as String;
        if (message['senderId'] != widget.companion ||
            _interruptedReplies.contains(id)) {
          continue;
        }
        final fresh =
            previousCursor != null &&
            (message['sequence'] as int) > previousCursor;
        if (!_pending.contains(id) && !published.contains(id) && !fresh) {
          continue;
        }
        final content = (message['content'] as String? ?? '').trim();
        final cues = objects(message['cues']);
        if (['queued', 'running'].contains(message['status'])) {
          _pending.add(id);
          final createdAt = message['createdAt'] as String?;
          progress = _callProgress(
            object(message['progress']),
            startedAt:
                (createdAt == null ? null : DateTime.tryParse(createdAt)) ??
                _replyStartedAt,
            queued: message['status'] == 'queued',
          );
          if (content.isNotEmpty && cues.isEmpty && !_playingCue && _autoCue) {
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
              (content.isNotEmpty ||
                  objects(message['captionPages']).isNotEmpty) &&
              _spoken.add(message['id'] as String)) {
            _enqueueCue({
              'text': content,
              'messageId': message['id'],
              'pages': message['captionPages'],
            });
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
      _scheduleBubbleHide();
      _syncStagePresence();
    } catch (error) {
      if (mounted) setState(() => _error = connectionError(error));
    } finally {
      _checking = false;
      if (mounted && (topicRevision != _topicRevision || more)) {
        unawaited(_refresh(force: true));
      }
    }
  }

  void _enqueueCue(Json cue) {
    final pages = objects(cue['pages']).toList();
    if (pages.isEmpty) {
      _cueQueue.add(cue);
    } else {
      final holds = pages.map((page) => page['holdMs'] as int).toList();
      final reading = holds.fold(0, (total, ms) => total + ms);
      final motion = objects(
        widget.stageCatalog['motions'],
      ).firstWhere((item) => item['id'] == cue['motion'], orElse: () => {});
      final motionMs = ((motion['durationSeconds'] as num? ?? 0) * 1000)
          .round();
      final minimum = max(
        motionMs,
        max(
          cue['durationMs'] as int? ?? 0,
          cue['expression'] != null
              ? 1800
              : cue['gesture'] != null
              ? 900
              : 0,
        ),
      );
      holds[holds.length - 1] += max(0, minimum - reading);
      for (var i = 0; i < pages.length; i++) {
        _cueQueue.add({
          ...cue,
          'pageText': pages[i]['text'],
          'speechPage': pages[i]['speechPage'],
          'holdMs': holds[i],
          'lastPage': i == pages.length - 1,
        });
      }
    }
    if (_autoCue && !_playingCue) unawaited(_playCue(_cueIndex + 1));
  }

  Future<void> _jumpCue(int index, {bool autoplay = false}) async {
    if (index < 0 || index >= _cueQueue.length) return;
    _cueTimer?.cancel();
    _cancelBubbleHide();
    final revision = ++_cueRevision;
    _activeCue = null;
    _cueVoice = null;
    setState(() {
      _autoCue = autoplay;
      _bubbleVisibility = _CallBubbleVisibility.automatic;
    });
    try {
      await _callSpeech.stop();
    } catch (_) {
      // Advancing a caption still works if audio has already ended.
    }
    if (mounted && revision == _cueRevision) await _playCue(index);
  }

  Future<void> _playCue(int index) async {
    if (!mounted || index < 0 || index >= _cueQueue.length) return;
    _cancelBubbleHide();
    final revision = ++_cueRevision;
    final cue = _cueQueue[index];
    final text = (cue['pageText'] ?? cue['text']) as String? ?? '';
    final messageId = cue['messageId'], segmentId = cue['id'];
    final newReply =
        _cueIndex < 0 || _cueQueue[_cueIndex]['messageId'] != messageId;
    if (messageId is String &&
        segmentId is String &&
        index >= (_presentedThrough[messageId]?.$1 ?? -1)) {
      _presentedThrough[messageId] = (index, segmentId);
    }
    final duration =
        cue['holdMs'] as int? ??
        cue['durationMs'] as int? ??
        (text.characters.length * 130).clamp(1400, 12000);
    setState(() {
      _cueIndex = index;
      _furthestCue = max(_furthestCue, index);
      _playingCue = true;
      _caption = text;
      if (newReply) _bubbleVisibility = _CallBubbleVisibility.automatic;
    });
    if (text.isNotEmpty) unawaited(_pose.forward(from: 0));
    final elapsed = Stopwatch()..start();
    final newCue = !_sameCue(_activeCue, cue);
    final pageIndex = widget.api()?.pagedSpeech == true
        ? cue['speechPage'] as int?
        : null;
    if (newCue) {
      _activeCue = cue;
      _sendStageCue();
      _syncStagePresence();
    }
    if (pageIndex != null) {
      await _playCueAudio(cue, revision, pageIndex: pageIndex);
    } else {
      if (newCue) _cueVoice = _playCueAudio(cue, revision);
      if (cue['lastPage'] != false || !_autoCue) await _cueVoice;
    }
    if (!mounted || revision != _cueRevision) return;
    _cueTimer = Timer(
      Duration(
        milliseconds: (duration - elapsed.elapsedMilliseconds).clamp(
          0,
          duration,
        ),
      ),
      () {
        if (!mounted || revision != _cueRevision) return;
        if (_autoCue && index + 1 < _cueQueue.length) {
          unawaited(_playCue(index + 1));
        } else {
          setState(() {
            _playingCue = false;
            _activeCue = null;
            _cueVoice = null;
          });
          _sendStageCue();
          _syncStagePresence();
          _scheduleBubbleHide();
        }
      },
    );
  }

  bool _sameCue(Json? current, Json next) =>
      current != null &&
      current['messageId'] == next['messageId'] &&
      current['id'] == next['id'];

  Future<void> _playCueAudio(Json cue, int revision, {int? pageIndex}) async {
    final api = widget.api();
    try {
      final message = cue['messageId'];
      if (_voice && api != null && message is String) {
        await _callSpeech.play(
          api,
          widget.room,
          message,
          part: cue['id'] as String?,
          pageIndex: pageIndex,
          stage: _stageId,
        );
      }
    } catch (error) {
      if (mounted &&
          (pageIndex == null
              ? _sameCue(_activeCue, cue)
              : revision == _cueRevision)) {
        setState(() => _error = connectionError(error));
      }
    }
  }

  void _pauseCue() {
    _cueTimer?.cancel();
    _cancelBubbleHide();
    _cueRevision++;
    unawaited(_callSpeech.stop().catchError((Object _) {}));
    setState(() {
      _playingCue = false;
      _autoCue = false;
      _activeCue = null;
      _cueVoice = null;
    });
    _sendStageCue();
    _syncStagePresence();
  }

  Future<void> _interruptReply() async {
    final api = widget.api();
    if (api == null || _interrupting) return;
    final ids = {
      ..._pending,
      ..._cueQueue
          .skip(max(0, _cueIndex))
          .map((cue) => cue['messageId'])
          .whereType<String>(),
    }.where((id) => !_interruptedReplies.contains(id)).take(80).toList();
    if (ids.isEmpty) {
      _pauseCue();
      return;
    }
    final revision = _topicRevision;
    setState(() => _interrupting = true);
    try {
      final reply = await api.request('call.interrupt', {
        'conversationId': widget.room,
        'topicId': ?object(_runtime['topic'])['id'] as String?,
        'requestId': _uuid.v4(),
        'replies': [
          for (final id in ids)
            {'messageId': id, 'throughSegmentId': ?_presentedThrough[id]?.$2},
        ],
      });
      if (!mounted || revision != _topicRevision) return;
      final interrupted =
          (reply['interruptedReplyIds'] as List?)
              ?.whereType<String>()
              .toSet() ??
          ids.toSet();
      _pending.removeAll(interrupted);
      _interruptedReplies.addAll(interrupted);
      final tail = _cueQueue
          .skip(_furthestCue + 1)
          .where((cue) => !interrupted.contains(cue['messageId']))
          .toList();
      _cueQueue
        ..removeRange(_furthestCue + 1, _cueQueue.length)
        ..addAll(tail);
      _pauseCue();
    } catch (error) {
      if (mounted && revision == _topicRevision) {
        setState(() => _error = connectionError(error));
      }
    } finally {
      if (mounted) setState(() => _interrupting = false);
    }
  }

  Future<void> _openCallHistory() async {
    final api = widget.api();
    if (api == null) return;
    final initial = api.request('state', {
      'conversationId': widget.room,
      'history': true,
    });
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .68,
        child: FutureBuilder<Json>(
          future: initial,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: Text(connectionError(snapshot.error!)));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final state = object(snapshot.data!['snapshot']);
            final messages = objects(state['messages']).toList();
            var hasMore = state['hasMore'] == true;
            var fetching = false;
            return StatefulBuilder(
              builder: (context, update) => SafeArea(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
                  children: [
                    Text(
                      '完整对话',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (hasMore && messages.isNotEmpty)
                      TextButton(
                        onPressed: fetching
                            ? null
                            : () async {
                                update(() => fetching = true);
                                try {
                                  final result = await api.request('state', {
                                    'conversationId': widget.room,
                                    'history': true,
                                    'before': messages.first['sequence'],
                                  });
                                  if (!context.mounted) return;
                                  final page = object(result['snapshot']);
                                  update(() {
                                    messages.insertAll(
                                      0,
                                      objects(page['messages']),
                                    );
                                    hasMore = page['hasMore'] == true;
                                    fetching = false;
                                  });
                                } catch (error) {
                                  if (!context.mounted) return;
                                  update(() => fetching = false);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(connectionError(error)),
                                    ),
                                  );
                                }
                              },
                        child: const Text('更早的对话'),
                      ),
                    for (final message in messages)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              message['senderId'] == 'user'
                                  ? '我'
                                  : widget.title,
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                            Text(_historyTranscript(message)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  String _historyTranscript(Json message) {
    final lines = objects(
      message['cues'],
    ).map((cue) => cue['text']).whereType<String>().join('\n');
    return lines.isNotEmpty ? lines : message['content'] as String? ?? '';
  }

  Rect? _headBounds;
  bool _composerExpanded = false;

  bool get _canHideBubble =>
      _bubbleVisibility == _CallBubbleVisibility.automatic &&
      _autoCue &&
      !_playingCue &&
      !_sending &&
      _pending.isEmpty &&
      _cueIndex >= 0 &&
      _cueIndex == _cueQueue.length - 1 &&
      _caption.isNotEmpty;

  PetCallProgress _callProgress(
    Json data, {
    DateTime? startedAt,
    bool queued = false,
  }) {
    final phase =
        data['phase'] as String? ?? (queued ? 'queued' : 'preparing-context');
    final activity = object(data['activity']);
    return PetCallProgress(
      label: data['label'] as String? ?? _progressLabel(phase),
      phase: phase,
      icon: data['icon'] as String?,
      startedAt: startedAt,
      step: activity['step'] as int?,
      summary: activity['summary'] as String?,
    );
  }

  void _cancelBubbleHide() {
    _bubbleHideTimer?.cancel();
    _bubbleHideTimer = null;
  }

  void _scheduleBubbleHide() {
    if (!_canHideBubble || _bubbleHideTimer != null) return;
    _bubbleHideTimer = Timer(_callBubbleAutoHideDelay, () {
      _bubbleHideTimer = null;
      if (mounted && _canHideBubble) {
        setState(() => _bubbleVisibility = _CallBubbleVisibility.collapsed);
      }
    });
  }

  Widget? _buildBubble() {
    if (_bubbleVisibility == _CallBubbleVisibility.collapsed) {
      return PetCallReviewButton(
        onPressed: () => setState(() {
          final autoplayInProgress =
              _autoCue && (_playingCue || _sending || _pending.isNotEmpty);
          _bubbleVisibility = autoplayInProgress
              ? _CallBubbleVisibility.automatic
              : _CallBubbleVisibility.reviewing;
        }),
      );
    }
    final text = _caption.isNotEmpty ? _caption : _error;
    final progress = _sending || _pending.isNotEmpty
        ? _replyProgress ??
              PetCallProgress(label: '正在回应…', startedAt: _replyStartedAt)
        : null;
    if (text == null && progress == null) return null;
    return PetCallBubble(
      text: text,
      progress: progress,
      index: _cueIndex,
      count: _cueQueue.length,
      autoplay: _autoCue,
      playing: _playingCue,
      onJump: (index, autoplay) =>
          unawaited(_jumpCue(index, autoplay: autoplay)),
      onPause: _pauseCue,
      onCollapse: _cueIndex >= 0
          ? () {
              _cancelBubbleHide();
              setState(
                () => _bubbleVisibility = _CallBubbleVisibility.collapsed,
              );
            }
          : null,
      notice: _caption.isNotEmpty ? _error : null,
      onHistory: _cueIndex >= 0 ? () => unawaited(_openCallHistory()) : null,
      onInterrupt: !_interrupting && (_playingCue || _pending.isNotEmpty)
          ? () => unawaited(_interruptReply())
          : null,
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    _eventRefresh?.cancel();
    _eventApi = null;
    unawaited(_events?.cancel());
    _cueTimer?.cancel();
    _cancelBubbleHide();
    _cueRevision++;
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
      resizeToAvoidBottomInset: false,
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
            maintainBottomViewPadding: true,
            child: Column(
              children: [
                ListTile(
                  title: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  subtitle: const Text(
                    '桌宠通话',
                    style: TextStyle(color: Colors.white70),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_stageReady && _canChangeBodyShape)
                        IconButton(
                          color: Colors.white,
                          tooltip: '体型',
                          icon: const Icon(Icons.tune),
                          onPressed: _chooseBodyShape,
                        ),
                      if (_stageReady)
                        IconButton(
                          color: Colors.white,
                          tooltip: _fullBody ? '半身取景' : '全身取景',
                          icon: Icon(
                            _fullBody
                                ? Icons.person_outline
                                : Icons.accessibility_new,
                          ),
                          onPressed: () {
                            setState(() => _fullBody = !_fullBody);
                            _sendStageFraming();
                          },
                        ),
                      IconButton(
                        color: Colors.white,
                        tooltip: '通话背景',
                        icon: const Icon(Icons.wallpaper),
                        onPressed: _chooseWallpaper,
                      ),
                      if (!_composerExpanded)
                        IconButton(
                          color: Colors.white,
                          tooltip: '结束通话',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.call_end),
                        ),
                    ],
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
                  child: PetCallStage(
                    figure: _buildFigure(),
                    headBounds: _stageReady ? _headBounds : null,
                    keyboardInset: max(
                      0.0,
                      MediaQuery.viewInsetsOf(context).bottom -
                          MediaQuery.viewPaddingOf(context).bottom,
                    ),
                    bubble: _buildBubble(),
                    dock: _composerExpanded
                        ? _buildComposer(context)
                        : PetCallInputButton(
                            onPressed: () =>
                                setState(() => _composerExpanded = true),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFigure() => Stack(
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
          gestureRecognizers: {
            Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
          },
          creationParams: {'url': server.url},
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: _stageCreated,
        ),
    ],
  );

  Widget _buildComposer(BuildContext context) => Align(
    alignment: Alignment.bottomCenter,
    heightFactor: 1,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 540),
      child: SingleChildScrollView(
        reverse: true,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _TopicBar(
              room: widget.room,
              api: widget.api(),
              runtime: _runtime,
              members: [
                {'id': widget.companion, 'name': widget.title},
              ],
              inCall: true,
              onRouting: (busy) => setState(() => _changingTopic = busy),
              onNotice: (text) => ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(text))),
              onChanged: (topic) async {
                if (topic.isNotEmpty) {
                  if (object(_runtime['topic'])['id'] != topic['id']) {
                    _topicRevision++;
                    _cueTimer?.cancel();
                    _cancelBubbleHide();
                    _cueRevision++;
                    unawaited(_callSpeech.stop());
                    setState(() {
                      _cueQueue.clear();
                      _interruptedReplies.clear();
                      _presentedThrough.clear();
                      _pending.clear();
                      _cueIndex = -1;
                      _furthestCue = -1;
                      _activeCue = null;
                      _cueVoice = null;
                      _playingCue = false;
                      _autoCue = true;
                      _caption = '';
                      _bubbleVisibility = _CallBubbleVisibility.automatic;
                      _replyProgress = null;
                      _replyStartedAt = null;
                    });
                    _sendStageCue();
                    _syncStagePresence();
                  }
                  setState(() => _runtime = {..._runtime, 'topic': topic});
                }
                await _refresh(force: true);
              },
            ),
            const SizedBox(height: 5),
            _buildInputBar(context),
          ],
        ),
      ),
    ),
  );

  Widget _buildInputBar(BuildContext context) => Material(
    color: const Color(0xfffbfdff),
    surfaceTintColor: Colors.transparent,
    shadowColor: const Color(0x660b2940),
    elevation: 4,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: _callDockBorder),
    ),
    child: Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(12, 2, 4, 2),
      child: IconButtonTheme(
        data: IconButtonThemeData(
          style: IconButton.styleFrom(
            foregroundColor: _callDockInk,
            minimumSize: const Size.square(40),
            visualDensity: const VisualDensity(horizontal: -1, vertical: -1),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(11),
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _text,
                autofocus: true,
                textInputAction: TextInputAction.send,
                cursorColor: const Color(0xff285b8a),
                style: const TextStyle(color: Color(0xff21364f), fontSize: 15),
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(
                  hintText: '发消息…',
                  hintMaxLines: 1,
                  hintStyle: TextStyle(color: Color(0xff61778e)),
                  isDense: true,
                  filled: false,
                  contentPadding: EdgeInsets.symmetric(vertical: 10),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
              ),
            ),
            IconButton(
              isSelected: !_voice,
              tooltip: _voice ? '静音伙伴' : '打开伙伴声音',
              onPressed: () {
                setState(() => _voice = !_voice);
                if (!_voice) unawaited(_callSpeech.stop());
              },
              icon: const Icon(Icons.volume_up_outlined, size: 20),
              selectedIcon: const Icon(Icons.volume_off_outlined, size: 20),
            ),
            IconButton(
              tooltip: '收起会面输入',
              onPressed: () {
                FocusScope.of(context).unfocus();
                setState(() => _composerExpanded = false);
              },
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 21),
            ),
            IconButton.filled(
              style: IconButton.styleFrom(
                backgroundColor: const Color(0xfffbe8ed),
                foregroundColor: const Color(0xffa33855),
              ),
              tooltip: '结束通话',
              icon: const Icon(Icons.call_end_outlined, size: 19),
              onPressed: () => Navigator.pop(context),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _text,
              builder: (_, draft, _) => IconButton.filled(
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xff285b8a),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(0xffe3ecf5),
                  disabledForegroundColor: const Color(0xff617b95),
                ),
                tooltip: '发送',
                onPressed:
                    _sending ||
                        _changingTopic ||
                        widget.api() == null ||
                        draft.text.trim().isEmpty
                    ? null
                    : _send,
                icon: const Icon(Icons.arrow_upward_rounded, size: 20),
              ),
            ),
          ],
        ),
      ),
    ),
  );
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
    required String characterName,
    required void Function(double) onProgress,
  }) async {
    final cache = await getApplicationSupportDirectory();
    final modelFolder = Directory('${cache.path}/pet-model-files');
    await modelFolder.create(recursive: true);
    final originals = <String, Future<File>>{};
    final variants = <String, File>{};
    final cacheKey = model['cacheKey'] as String? ?? 'bundled-v1';
    Future<File> extract(String path) async {
      final key = sha256.convert(utf8.encode('$cacheKey/$companion/$path'));
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
              'catalog': model['catalog'],
              'vts': model['vts'],
              'name': characterName,
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
              '<style>html,body,#stage{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}#stage{touch-action:none}#stage[data-character-hover]{cursor:pointer}canvas{display:block}</style>'
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
