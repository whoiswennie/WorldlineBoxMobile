part of 'chat.dart';

const _topicAppNames = {
  'browser': '浏览器',
  'asset-manager': '资产库',
  'cabin-world': '小屋世界',
  'music': '音乐',
  'video': '视频',
};
const _appIcons = {
  'browser': Icons.language,
  'asset-manager': Icons.inventory_2_outlined,
  'cabin-world': Icons.house_outlined,
  'music': Icons.music_note_outlined,
  'video': Icons.ondemand_video,
};

extension _TopicAppPicker on _CompanionWorkspaceState {
  Future<void> _chooseApp(String room) async {
    var busy = false;
    String? notice;
    final api = _api;
    if (api == null) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => StatefulBuilder(
        builder: (context, update) => ValueListenableBuilder<Json>(
          valueListenable: _appState,
          builder: (_, runtime, _) {
            final apps = (runtime['apps'] as List? ?? []).toSet();
            final topic = object(runtime['topic'])['id'];
            Future<void> toggle(String id, bool enable) async {
              if (busy) return;
              update(() {
                busy = true;
                notice = null;
              });
              try {
                final fields = <String, dynamic>{
                  'conversationId': room,
                  'topicId': ?topic,
                };
                late Json response;
                if (id == 'browser' && enable) {
                  final tabs = objects((await api.browserTabs(room))['tabs']);
                  if (tabs.isEmpty) {
                    throw const MobileException('请先在电脑的内置浏览器打开需要连接的网页。');
                  }
                  if (!sheet.mounted) return;
                  final tab = await showDialog<String>(
                    context: sheet,
                    builder: (dialog) => SimpleDialog(
                      title: const Text('选择电脑标签页'),
                      children: [
                        for (final tab in tabs)
                          ListTile(
                            title: Text(tab['title'] as String),
                            subtitle: Text(tab['host'] as String),
                            onTap: () =>
                                Navigator.pop(dialog, tab['id'] as String),
                          ),
                      ],
                    ),
                  );
                  if (tab == null || !sheet.mounted) return;
                  final ref = await api.browserTabs(room, tabId: tab);
                  response = await api.request('app.browser', {
                    ...fields,
                    'referenceId': ref['referenceId'],
                  });
                } else {
                  response = await api.request(
                    enable ? 'app.connect' : 'app.detach',
                    {...fields, 'appId': id},
                  );
                }
                await _refresh();
                if (id == 'video' &&
                    enable &&
                    object(response['app'])['login'] == 'guest') {
                  notice = '已连接视频。需要账号权限时，请在电脑的内置浏览器登录哔哩哔哩。手机卡片使用官方嵌入播放器。';
                }
              } catch (error) {
                notice = error.toString();
              } finally {
                if (sheet.mounted) update(() => busy = false);
              }
            }

            return SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: [
                  const ListTile(
                    title: Text('话题应用'),
                    subtitle: Text('可同时启用多个应用，选择会同步到电脑。'),
                  ),
                  for (final entry in _topicAppNames.entries)
                    SwitchListTile(
                      secondary: Icon(_appIcons[entry.key]),
                      title: Text(entry.value),
                      value: apps.contains(entry.key),
                      onChanged: busy || _api != api
                          ? null
                          : (value) => toggle(entry.key, value),
                    ),
                  if (busy) const LinearProgressIndicator(),
                  if (notice != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(notice!),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ChatMediaCard extends StatefulWidget {
  const _ChatMediaCard({
    super.key,
    required this.card,
    required this.api,
    required this.room,
    required this.message,
    required this.active,
    required this.select,
  });
  final Json card;
  final MobileApi? api;
  final String room, message;
  final bool active;
  final ValueChanged<bool> select;
  @override
  State<_ChatMediaCard> createState() => _ChatMediaCardState();
}

class _ChatMediaCardState extends State<_ChatMediaCard>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => widget.active;
  List<Json> _tracks = [];
  int _index = 0, _generation = 0;
  String? _stream, _error;
  bool get _music => widget.card['kind'] == 'music';
  String get _id => widget.card['id'] as String;
  @override
  void initState() {
    super.initState();
    if (widget.active && _music) unawaited(_loadTrack(0));
  }

  @override
  void didUpdateWidget(_ChatMediaCard old) {
    super.didUpdateWidget(old);
    updateKeepAlive();
    if (widget.active != old.active || widget.api != old.api) {
      _generation++;
      _stream = null;
      _error = null;
      if (widget.active && _music) unawaited(_loadTrack(_index));
    }
  }

  Future<void> _loadTrack(int index) async {
    final revision = ++_generation;
    final api = widget.api;
    if (api == null) return;
    setState(() {
      _stream = null;
      _error = null;
    });
    try {
      if (_tracks.isEmpty) {
        final result = await api.cardMusic(widget.room, widget.message, _id);
        if (!mounted || revision != _generation) return;
        _tracks = objects(result['tracks']);
      }
      if (_tracks.isEmpty) throw const MobileException('这个歌单暂时没有可播放的歌曲。');
      _index = index.clamp(0, _tracks.length - 1);
      final result = await api.cardMusic(
        widget.room,
        widget.message,
        _id,
        track: _tracks[_index]['id'] as String,
      );
      if (mounted && revision == _generation) {
        setState(() => _stream = object(result['stream'])['url'] as String);
      }
    } catch (error) {
      if (mounted && revision == _generation) {
        setState(() => _error = '无法播放这首歌，请检查网络或重试。');
      }
    }
  }

  Future<void> _openBilibili() async {
    try {
      final opened = await const MethodChannel('worldlinebox/bilibili')
          .invokeMethod<bool>('open', {
            'videoId': widget.card['videoId'],
            'page': widget.card['page'] ?? 1,
          });
      if (!mounted || opened == true) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未找到可打开此视频的哔哩哔哩客户端，可以继续在卡片中观看。')),
      );
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('打开哔哩哔哩失败。')));
      }
    }
  }

  void _finished() {
    if (!mounted || !widget.active || _tracks.isEmpty) return;
    final mode = widget.card['mode'];
    if (mode == 'once' && _index + 1 == _tracks.length) {
      widget.select(false);
      return;
    }
    final next = mode == 'single'
        ? _index
        : mode == 'shuffle' && _tracks.length > 1
        ? (_index + 1 + Random().nextInt(_tracks.length - 1)) % _tracks.length
        : (_index + 1) % _tracks.length;
    unawaited(_loadTrack(next));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final card = widget.card;
    final track = _tracks.isEmpty ? <String, dynamic>{} : _tracks[_index];
    final url = _music ? _stream : card['player'] as String?;
    final cover = (_music ? track['coverUrl'] : card['cover']) as String?;
    final title =
        (_music ? track['name'] : null) as String? ??
        card['title'] as String? ??
        '';
    final subtitle = _music
        ? (track['artists'] as List? ?? card['preview'] as List? ?? []).join(
            ' · ',
          )
        : card['author'] as String? ?? '';
    final player = widget.active && url != null && _error == null;
    Widget coverImage() => cover == null || !cover.startsWith('https://')
        ? Icon(_music ? Icons.music_note : Icons.movie_outlined)
        : Image.network(
            cover,
            fit: BoxFit.cover,
            width: double.infinity,
            headers: _music
                ? null
                : const {'Referer': 'https://www.bilibili.com/'},
            errorBuilder: (_, _, _) =>
                Icon(_music ? Icons.music_note : Icons.movie_outlined),
          );
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_music && !player)
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Semantics(
                label: '播放视频',
                button: true,
                child: InkWell(
                  onTap: widget.api == null ? null : () => widget.select(true),
                  child: Stack(
                    fit: StackFit.expand,
                    alignment: Alignment.center,
                    children: [
                      coverImage(),
                      const Center(
                        child: CircleAvatar(
                          backgroundColor: Colors.black54,
                          child: Icon(Icons.play_arrow, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (player)
            SizedBox(
              height: _music ? 52 : null,
              child: AspectRatio(
                aspectRatio: _music ? 5 : 16 / 9,
                child: _InlinePlayer(
                  key: ValueKey('$_generation:$url'),
                  url: url,
                  music: _music,
                  onEnded: _finished,
                  onError: () {
                    if (mounted && widget.active) {
                      setState(() => _error = '媒体暂时无法播放，请检查网络或平台播放权限。');
                    }
                  },
                ),
              ),
            ),
          ListTile(
            dense: true,
            leading: _music
                ? SizedBox.square(dimension: 42, child: coverImage())
                : null,
            title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: subtitle.isEmpty
                ? null
                : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: widget.active || _music
                ? IconButton(
                    tooltip: widget.active ? '收起播放器' : '播放音乐',
                    onPressed: widget.api == null
                        ? null
                        : () => widget.select(!widget.active),
                    icon: Icon(widget.active ? Icons.close : Icons.play_arrow),
                  )
                : null,
          ),
          if (!_music)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _openBilibili,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('用哔哩哔哩打开'),
              ),
            ),
          if (widget.active && _music && _stream == null && _error == null)
            const LinearProgressIndicator(),
          if (widget.active && _music && _tracks.length > 1)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: '上一首',
                  icon: const Icon(Icons.skip_previous),
                  onPressed: () => _loadTrack((_index - 1) % _tracks.length),
                ),
                TextButton(
                  child: Text('${_index + 1} / ${_tracks.length}'),
                  onPressed: () async {
                    final index = await showModalBottomSheet<int>(
                      context: context,
                      builder: (sheet) => SafeArea(
                        child: ListView.builder(
                          itemCount: _tracks.length,
                          itemBuilder: (_, i) => ListTile(
                            title: Text(_tracks[i]['name'] as String),
                            selected: i == _index,
                            onTap: () => Navigator.pop(sheet, i),
                          ),
                        ),
                      ),
                    );
                    if (mounted && widget.active && index != null) {
                      await _loadTrack(index);
                    }
                  },
                ),
                IconButton(
                  tooltip: '下一首',
                  icon: const Icon(Icons.skip_next),
                  onPressed: () => _loadTrack((_index + 1) % _tracks.length),
                ),
              ],
            ),
          if (_error != null)
            TextButton(
              onPressed: () {
                if (_music) {
                  unawaited(_loadTrack(_index));
                } else {
                  setState(() {
                    _generation++;
                    _error = null;
                  });
                }
              },
              child: Text('$_error 重试'),
            ),
        ],
      ),
    );
  }
}

class _InlinePlayer extends StatefulWidget {
  const _InlinePlayer({
    super.key,
    required this.url,
    required this.music,
    required this.onEnded,
    required this.onError,
  });
  final String url;
  final bool music;
  final VoidCallback onEnded, onError;
  @override
  State<_InlinePlayer> createState() => _InlinePlayerState();
}

class _InlinePlayerState extends State<_InlinePlayer> {
  MethodChannel? _channel;
  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AndroidView(
    viewType: 'worldlinebox/chat-media',
    creationParams: {'url': widget.url, 'music': widget.music},
    creationParamsCodec: const StandardMessageCodec(),
    gestureRecognizers: {
      Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
    },
    onPlatformViewCreated: (id) {
      if (!mounted) return;
      _channel = MethodChannel('worldlinebox/chat-media/$id')
        ..setMethodCallHandler((call) async {
          if (call.method == 'ended') widget.onEnded();
          if (call.method == 'error') widget.onError();
        });
    },
  );
}
