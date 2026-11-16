part of 'chat.dart';

class _IdentityDialog extends StatefulWidget {
  const _IdentityDialog({required this.name, required this.bio});
  final String name;
  final String bio;
  @override
  State<_IdentityDialog> createState() => _IdentityDialogState();
}

class _IdentityDialogState extends State<_IdentityDialog> {
  late final _name = TextEditingController(text: widget.name);
  late final _bio = TextEditingController(text: widget.bio);

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('我的资料'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            maxLength: 80,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: '伙伴怎么称呼你'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _bio,
            maxLength: 800,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(labelText: '个人介绍'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _name.text.trim().isEmpty
            ? null
            : () =>
                  Navigator.pop(context, (_name.text.trim(), _bio.text.trim())),
        child: const Text('保存'),
      ),
    ],
  );
}

const _portraitIds = {
  'claude',
  'deepseek-flash',
  'deepseek-sister',
  'doro',
  'gemini',
  'gpt',
  'grok',
  'guga',
  'gugugaga',
  'huan-black',
  'huan-white',
  'kimi',
  'minimax',
  'phoebe',
  'phrolova',
  'qwen',
};

class CompanionAvatar extends StatelessWidget {
  const CompanionAvatar({
    super.key,
    required this.id,
    required this.name,
    this.size = 42,
    this.fullResolution = false,
  });
  final String id;
  final String name;
  final double size;
  final bool fullResolution;

  @override
  Widget build(BuildContext context) {
    final fallback = Center(
      child: Text(
        name.characters.firstOrNull ?? '·',
        style: TextStyle(color: _accent, fontSize: size * .38),
      ),
    );
    final portraitId = id == 'builtin-dafeiyu' ? 'deepseek-sister' : id;
    return SizedBox.square(
      dimension: size,
      child: ClipOval(
        child: ColoredBox(
          color: const Color(0xffeae4f4),
          child: _portraitIds.contains(portraitId)
              ? Image.asset(
                  'assets/portraits/$portraitId.png',
                  fit: BoxFit.cover,
                  cacheWidth: fullResolution ? null : 160,
                  filterQuality: fullResolution
                      ? FilterQuality.high
                      : FilterQuality.low,
                  errorBuilder: (_, _, _) => fallback,
                )
              : fallback,
        ),
      ),
    );
  }
}

String _presenceLabel(String? presence) => switch (presence) {
  'working' => '正在执行',
  'replying' => '正在回复',
  'needs-attention' => '等待你的回复',
  'waiting' => '排队中',
  _ => '伙伴',
};

String _progressLabel(String? phase) => switch (phase) {
  'memory-starting' => '正在唤醒伙伴记忆',
  'memory-verifying' => '正在校验内置记忆引擎',
  'memory-indexing' => '正在同步记忆索引',
  'recalling-memory' => '正在检索记忆',
  'preparing-context' => '准备上下文',
  'compacting-context' => '正在整理长对话',
  'waiting-runtime' => '等待运行环境',
  'waiting-model' => '等待模型响应',
  'using-tool' => '正在使用工具',
  'generating' => '正在生成回复',
  'retrying' => '正在恢复连接',
  'reconciling' => '正在核实先前操作',
  'waiting-answer' => '等待你的回复',
  _ => '等待处理',
};

class AnswerDialog extends StatefulWidget {
  const AnswerDialog(this.question, {super.key});
  final String question;
  @override
  State<AnswerDialog> createState() => _AnswerDialogState();
}

class _AnswerDialogState extends State<AnswerDialog> {
  final _text = TextEditingController();
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('伙伴在等你回复'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.question),
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            autofocus: true,
            minLines: 1,
            maxLines: 6,
            maxLength: 12000,
            decoration: const InputDecoration(hintText: '输入回答'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _text.text.trim()),
        child: const Text('回答'),
      ),
    ],
  );
}

class _TopicBar extends StatefulWidget {
  const _TopicBar({
    super.key,
    required this.room,
    required this.api,
    required this.runtime,
    required this.members,
    required this.onChanged,
    required this.onNotice,
    required this.onRouting,
    this.inCall = false,
  });

  final String room;
  final MobileApi? api;
  final Json runtime;
  final List<Json> members;
  final Future<void> Function(Json) onChanged;
  final ValueChanged<String> onNotice;
  final ValueChanged<bool> onRouting;
  final bool inCall;

  @override
  State<_TopicBar> createState() => _TopicBarState();
}

class _TopicBarState extends State<_TopicBar> {
  String? _busy;
  String? _memberId;
  String? _newRequest;
  final _compactionRequests = <(String, String), String>{};

  Json get _topic => object(widget.runtime['topic']);

  Future<void> _run(
    String type,
    Future<Json?> Function(MobileApi) action,
  ) async {
    final api = widget.api;
    if (api == null || _busy != null) return;
    final routing = type != 'topic.compact';
    setState(() => _busy = type);
    if (routing) widget.onRouting(true);
    try {
      final response = await action(api);
      if (!mounted || response == null) return;
      await widget.onChanged(object(response['topic']));
      if (!mounted) return;
      if (type == 'topic.compact') {
        widget.onNotice(
          response['compacted'] == true ? '话题上下文已压缩' : '当前话题内容较少，无需压缩',
        );
      }
    } catch (error) {
      if (mounted) widget.onNotice(connectionError(error));
    } finally {
      if (mounted) {
        setState(() => _busy = null);
        if (routing) widget.onRouting(false);
      }
    }
  }

  Future<Json> _newTopic(MobileApi api) async {
    try {
      final response = await api.request('topic.new', {
        'conversationId': widget.room,
        'requestId': _newRequest ??= _uuid.v4(),
      });
      _newRequest = null;
      return response;
    } on MobileException catch (error) {
      if (error.status != null) _newRequest = null;
      rethrow;
    }
  }

  Future<Json?> _pickTopic(MobileApi api) async {
    final result = await api.request('topic.list', {
      'conversationId': widget.room,
      'mode': 'all',
    });
    if (!mounted) return null;
    final current = _topic['id'] as String?;
    final selection = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => TopicPicker(
        api: api,
        room: widget.room,
        initial: result,
        current: current,
      ),
    );
    if (!mounted || selection == null || selection == current) return null;
    final currentApi = widget.api;
    if (currentApi == null) throw const MobileException('电脑离线，请连接后重试。');
    if (selection.isEmpty) return _newTopic(currentApi);
    return currentApi.request('topic.select', {
      'conversationId': widget.room,
      'topicId': selection,
    });
  }

  Future<Json> _compact(MobileApi api, String topicId, String memberId) async {
    final key = (topicId, memberId);
    try {
      final result = await api.request('topic.compact', {
        'conversationId': widget.room,
        'topicId': topicId,
        'companionId': memberId,
        'requestId': _compactionRequests.putIfAbsent(key, _uuid.v4),
      });
      _compactionRequests.remove(key);
      return result;
    } on MobileException catch (error) {
      if (error.status != null && error.status! < 500) {
        _compactionRequests.remove(key);
      }
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final member =
        widget.members.where((item) => item['id'] == _memberId).firstOrNull ??
        widget.members.firstOrNull;
    final memberId = member?['id'] as String?;
    final topicId = _topic['id'] as String?;
    final state = object(object(widget.runtime['contexts'])[memberId]);
    final phase = state['phase'] as String?;
    final pressure = object(state['pressure']);
    final used =
        (pressure['projectedTokens'] ?? pressure['pressureTokens']) as num?;
    final capacity = pressure['contextWindow'] as num?;
    final percent = used == null || capacity == null || capacity <= 0
        ? null
        : (used * 100 / capacity).round().clamp(0, 100);
    final enabled = _busy == null && widget.api != null;
    final compacting = _busy == 'topic.compact' || phase == 'compacting';
    final canCompact =
        enabled &&
        memberId != null &&
        topicId != null &&
        (phase == null || phase == 'idle') &&
        objects(widget.runtime['running']).isEmpty;
    final foreground = widget.inCall ? _callDockInk : _accent;
    final style = TextButton.styleFrom(
      foregroundColor: foreground,
      disabledForegroundColor: widget.inCall ? const Color(0xff73879b) : null,
      textStyle: widget.inCall
          ? const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)
          : null,
      padding: EdgeInsets.symmetric(horizontal: widget.inCall ? 6 : 8),
      minimumSize: const Size(36, 42),
      tapTargetSize: widget.inCall ? MaterialTapTargetSize.shrinkWrap : null,
    );
    return Container(
      margin: widget.inCall
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(10, 3, 10, 0),
      padding: EdgeInsets.symmetric(horizontal: widget.inCall ? 5 : 3),
      decoration: BoxDecoration(
        color: widget.inCall
            ? const Color(0xfaf1f7fc)
            : const Color(0xfff0ebf8),
        borderRadius: BorderRadius.circular(12),
        border: widget.inCall ? Border.all(color: _callDockBorder) : null,
      ),
      child: Row(
        children: [
          TextButton.icon(
            style: style,
            onPressed: enabled ? () => _run('topic.new', _newTopic) : null,
            icon: const Icon(Icons.add, size: 18),
            label: Text(_busy == 'topic.new' ? '新建中…' : '新话题'),
          ),
          Expanded(
            child: TextButton(
              style: style,
              onPressed: enabled
                  ? () => _run('topic.select', _pickTopic)
                  : null,
              child: Row(
                children: [
                  const Icon(Icons.history, size: 17),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      _topic['title'] as String? ?? '选择话题',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(Icons.keyboard_arrow_down, size: 16),
                ],
              ),
            ),
          ),
          if (widget.members.length > 1)
            PopupMenuButton<String>(
              tooltip: '选择要压缩的伙伴',
              enabled: enabled,
              iconColor: foreground,
              icon: const Icon(Icons.people_outline, size: 18),
              onSelected: (id) => setState(() => _memberId = id),
              itemBuilder: (_) => [
                for (final person in widget.members)
                  CheckedPopupMenuItem(
                    value: person['id'] as String,
                    checked: person['id'] == memberId,
                    child: Text(person['name'] as String? ?? '伙伴'),
                  ),
              ],
            ),
          TextButton.icon(
            style: style,
            onPressed: canCompact
                ? () => _run(
                    'topic.compact',
                    (api) => _compact(api, topicId, memberId),
                  )
                : null,
            icon: compacting
                ? const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome_outlined, size: 16),
            label: Text(compacting ? '压缩中…' : '压缩'),
          ),
          if (percent != null)
            Tooltip(
              message: '当前话题上下文占用',
              child: Padding(
                padding: const EdgeInsets.only(right: 5),
                child: Text(
                  '$percent%',
                  style: TextStyle(color: foreground, fontSize: 12),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class TopicPicker extends StatefulWidget {
  const TopicPicker({
    super.key,
    required this.api,
    required this.room,
    required this.initial,
    this.current,
  });
  final MobileApi api;
  final String room;
  final Json initial;
  final String? current;
  @override
  State<TopicPicker> createState() => _TopicPickerState();
}

class _TopicPickerState extends State<TopicPicker> {
  late final List<Json> _topics = objects(widget.initial['topics']);
  late String? _next = widget.initial['nextTopicCursor'] as String?;
  bool _busy = false;
  String? _error;

  Future<void> _more() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.api.request('topic.list', {
        'conversationId': widget.room,
        'mode': 'all',
        'before': _next,
      });
      if (mounted) {
        setState(() {
          _topics.addAll(objects(result['topics']));
          _next = result['nextTopicCursor'] as String?;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = connectionError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .64,
      child: Column(
        children: [
          ListTile(
            title: const Text(
              '话题',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            trailing: TextButton.icon(
              onPressed: () => Navigator.pop(context, ''),
              icon: const Icon(Icons.add),
              label: const Text('新话题'),
            ),
          ),
          if (widget.initial['topicListStale'] == true)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('当前显示电脑已同步的话题。'),
            ),
          Expanded(
            child: ListView(
              children: [
                ..._topics.map(
                  (topic) => ListTile(
                    title: Text(topic['title'] as String? ?? '话题'),
                    selected: topic['id'] == widget.current,
                    leading: Icon(
                      topic['id'] == widget.current
                          ? Icons.check
                          : Icons.chat_bubble_outline,
                    ),
                    onTap: () => Navigator.pop(context, topic['id'] as String),
                  ),
                ),
                if (_error != null) Center(child: Text(_error!)),
                if (_next != null)
                  TextButton(
                    onPressed: _busy ? null : _more,
                    child: Text(_busy ? '正在读取…' : '更多话题'),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
