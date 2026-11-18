part of 'chat.dart';

extension _WorkspaceView on _CompanionWorkspaceState {
  Widget _workspace(BuildContext context) {
    final room = _room;
    final rooms = objects(_directory['conversations']);
    final current = rooms.where((item) => item['id'] == room).firstOrNull;
    final title = current?['title'] as String? ?? '伙伴';
    return PopScope(
      canPop: room == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && room != null) _selectRoom(null);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: room == null
              ? null
              : IconButton(
                  tooltip: '返回伙伴',
                  onPressed: () => _selectRoom(null),
                  icon: const Icon(Icons.arrow_back),
                ),
          titleSpacing: room == null ? 20 : 0,
          title: room == null
              ? const BrandTitle()
              : Row(
                  children: [
                    CompanionAvatar(
                      id: _roomAvatar(current),
                      name: title,
                      size: 34,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
          actions: [
            if (room != null && current?['kind'] == 'direct')
              IconButton(
                tooltip: '桌宠视频通话',
                onPressed: _online
                    ? () => _openPetCall(room, title, _roomAvatar(current))
                    : null,
                icon: const Icon(Icons.videocam_outlined),
              ),
            if (room == null) ...[
              if (_api case final MobileApi api)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xffe7f2eb),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.circle,
                        size: 7,
                        color: Color(0xff357953),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        api.route.local ? '局域网直连' : '远程连接',
                        style: const TextStyle(
                          color: Color(0xff356648),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              PopupMenuButton<String>(
                tooltip: '我的电脑',
                icon: const Icon(Icons.more_horiz_rounded),
                onSelected: (choice) {
                  switch (choice) {
                    case 'scan':
                      _scanAddress();
                    case 'forget':
                      _forget();
                    case 'identity':
                      _editIdentity();
                    case 'cache':
                      _confirmClearCache();
                    case 'notifications':
                      _nativeAlert('settings');
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(enabled: false, child: Text('我的电脑')),
                  const PopupMenuItem(value: 'scan', child: Text('扫码更新地址')),
                  PopupMenuItem(
                    value: 'identity',
                    enabled: _online,
                    child: const Text('我的资料'),
                  ),
                  const PopupMenuItem(
                    value: 'notifications',
                    child: Text('系统通知设置'),
                  ),
                  const PopupMenuItem(value: 'cache', child: Text('清理本地缓存')),
                  const PopupMenuItem(value: 'forget', child: Text('取消配对')),
                ],
              ),
            ],
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              if (!_online)
                Material(
                  color: const Color(0xfff0e9f9),
                  child: ListTile(
                    dense: true,
                    leading: Icon(
                      _connecting ? Icons.sync : Icons.cloud_off_outlined,
                    ),
                    title: Text(_connecting ? '正在连接我的电脑' : '等待电脑上线'),
                    subtitle: Text(_error ?? '电脑上线后将自动重连。'),
                    trailing: IconButton(
                      tooltip: '扫码更新地址',
                      icon: const Icon(Icons.qr_code_scanner),
                      onPressed: _scanAddress,
                    ),
                  ),
                ),
              Expanded(
                child: room == null
                    ? _directoryView(rooms)
                    : _chatView(room, title, _roomAvatar(current), current),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _stickers() async {
    final api = _api;
    final room = _room;
    if (api == null || room == null) return;
    try {
      final packs = objects((await api.stickers(room))['packs']);
      if (!mounted || room != _room) return;
      final pack = await showModalBottomSheet<Json>(
        context: context,
        builder: (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: packs
                .map(
                  (item) => ListTile(
                    leading: const Icon(Icons.emoji_emotions_outlined),
                    title: Text(item['name'] as String),
                    onTap: () => Navigator.pop(context, item),
                  ),
                )
                .toList(),
          ),
        ),
      );
      if (pack == null || !mounted || room != _room) return;
      final items = objects(
        (await api.stickers(room, packId: pack['id'] as String))['stickers'],
      );
      if (!mounted || room != _room) return;
      final sticker = await showModalBottomSheet<Json>(
        context: context,
        builder: (context) => SafeArea(
          child: ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              return ListTile(
                title: Text(item['name'] as String),
                onTap: () => Navigator.pop(context, item),
              );
            },
          ),
        ),
      );
      if (sticker == null || !mounted || room != _room) return;
      final files = _attachments.putIfAbsent(room, () => []);
      if (files.length >= 16) {
        _show('每条消息最多 16 个附件。');
        return;
      }
      if (!files.any((file) => file['id'] == sticker['id'])) {
        _update(() => files.add(sticker));
      }
    } catch (error) {
      _show(connectionError(error));
    }
  }

  Future<void> _answer(Json message, Json question) async {
    final answer = await showDialog<String>(
      context: context,
      builder: (_) => AnswerDialog(question['text'] as String),
    );
    if (answer == null || answer.isEmpty) return;
    await _action('execution.answer', {
      'messageId': message['id'],
      'questionId': question['id'],
      'text': answer,
    });
  }

  Future<void> _forget() async {
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('取消配对'),
        content: const Text('移除这台手机上保存的电脑和访问凭据。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('取消配对'),
          ),
        ],
      ),
    );
    if (agreed != true || !mounted) return;
    try {
      _editingAddress = true;
      _connectionVersion++;
      await widget.onForget();
      await _nativeAlert('reset');
      await _cache.clear();
    } catch (error) {
      _editingAddress = false;
      _show(connectionError(error));
    }
  }

  String _roomAvatar(Json? room) {
    if (room?['kind'] != 'direct') return '';
    return (room?['memberIds'] as List?)
            ?.whereType<String>()
            .where((id) => id != 'user')
            .firstOrNull ??
        '';
  }

  Widget _directoryView(List<Json> rooms) {
    final query = _search.text.trim().toLowerCase();
    final people = objects(
      _directory['companions'],
    ).where((person) => person['enabled'] != false).toList();
    final items = (_contacts ? people : rooms)
        .where(
          (item) => ((item['title'] ?? item['name']) as String)
              .toLowerCase()
              .contains(query),
        )
        .toList();

    final count = _inbox.unread.values.fold(0, (sum, n) => sum + n);
    Widget tab(String text, bool contacts) {
      final selected = _contacts == contacts;
      return InkWell(
        onTap: () => _update(() => _contacts = contacts),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 9, 7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    text,
                    style: TextStyle(
                      fontSize: selected ? 24 : 18,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? brandInk : const Color(0xff746d80),
                    ),
                  ),
                  if (!contacts && count > 0) ...[
                    const SizedBox(width: 5),
                    _unreadBadge(count),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Container(
                height: 3,
                width: 22,
                decoration: BoxDecoration(
                  color: selected ? brandAccent : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 7, 16, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              tab('消息', false),
              const SizedBox(width: 14),
              tab('联系人', true),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: TextField(
            controller: _search,
            onChanged: (_) => _update(() {}),
            decoration: InputDecoration(
              hintText: '搜索伙伴或会话',
              isDense: true,
              hintStyle: const TextStyle(
                color: Color(0xff80798b),
                fontSize: 14,
              ),
              prefixIcon: const Icon(Icons.search_rounded, size: 21),
              filled: true,
              fillColor: const Color(0xffeeecf3),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除搜索',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => _update(_search.clear),
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(15),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(
          child: Material(
            color: Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            clipBehavior: Clip.antiAlias,
            child: items.isEmpty
                ? Center(
                    child: Text(
                      query.isNotEmpty
                          ? '没有找到匹配的结果'
                          : _online
                          ? '从联系人打开一位伙伴'
                          : '连接电脑后查看伙伴',
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const Divider(
                        height: 1,
                        indent: 82,
                        endIndent: 18,
                        color: Color(0xffefedf2),
                      ),
                      itemBuilder: (_, index) {
                        final item = items[index];
                        final name = (item['title'] ?? item['name']) as String;
                        final id = item['id'] as String;
                        final activity = object(item['activity']);
                        final unread = _contacts ? 0 : _inbox.unread[id] ?? 0;
                        final preview = _contacts
                            ? _presenceLabel(item['presence'] as String?)
                            : activity['preview'] as String?;
                        final time = _contacts
                            ? null
                            : _messageTime(activity['updatedAt'] as String?);
                        return InkWell(
                          onTap: _contacts
                              ? () => _openCompanion(item)
                              : () => _selectRoom(id),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 14,
                            ),
                            child: Row(
                              children: [
                                CompanionAvatar(
                                  id: _contacts ? id : _roomAvatar(item),
                                  name: name,
                                  size: 47,
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 16,
                                                fontWeight: unread > 0
                                                    ? FontWeight.w700
                                                    : FontWeight.w600,
                                                color: brandInk,
                                              ),
                                            ),
                                          ),
                                          if (item['pinned'] == true)
                                            const Padding(
                                              padding: EdgeInsets.only(
                                                right: 4,
                                              ),
                                              child: Icon(
                                                Icons.push_pin_outlined,
                                                size: 13,
                                              ),
                                            ),
                                          if (time != null)
                                            Text(
                                              time,
                                              style: const TextStyle(
                                                fontSize: 11,
                                                color: Color(0xff817a8a),
                                              ),
                                            ),
                                        ],
                                      ),
                                      if (preview != null || unread > 0) ...[
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                preview ?? '',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 13,
                                                  color: Color(0xff716b7c),
                                                ),
                                              ),
                                            ),
                                            if (unread > 0)
                                              _unreadBadge(unread),
                                          ],
                                        ),
                                      ],
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
          ),
        ),
      ],
    );
  }

  Widget _unreadBadge(int count) => Badge(
    backgroundColor: const Color(0xffb93653),
    textColor: Colors.white,
    label: Text(count > 99 ? '99+' : '$count'),
  );

  String? _messageTime(String? stamp) {
    final date = DateTime.tryParse(stamp ?? '')?.toLocal();
    if (date == null) return null;
    final now = DateTime.now();
    if (DateUtils.isSameDay(date, now)) {
      return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    }
    if (DateUtils.isSameDay(date, DateTime(now.year, now.month, now.day - 1))) {
      return '昨天';
    }
    return '${date.month}/${date.day}';
  }

  Widget _chatView(String room, String title, String avatarId, Json? current) {
    final messages = _messages;
    final files = _attachments[room] ?? [];
    final queued = objects(_runtime['queued']);
    final enabled =
        _online && _snapshot.isNotEmpty && !_sending && !_roomUploading;
    final canSend =
        !_sending &&
        !_roomUploading &&
        !_changingTopic &&
        (!_online || _snapshot.isNotEmpty);
    final pending = _outbox.entries
        .where((entry) => entry.value['conversationId'] == room)
        .toList();
    return Column(
      children: [
        Expanded(
          child: messages.isEmpty && pending.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CompanionAvatar(id: avatarId, name: title, size: 60),
                      const SizedBox(height: 14),
                      Text(
                        _snapshot.isEmpty && _online ? '正在读取会话…' : title,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      if (_snapshot.isNotEmpty) const Text('发条消息开始交流'),
                    ],
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(14, 18, 14, 12),
                  itemCount: messages.length + pending.length,
                  itemBuilder: (context, index) => index < messages.length
                      ? _message(messages[index])
                      : _pendingBubble(pending[index - messages.length]),
                ),
        ),
        if (messages.isNotEmpty || pending.isNotEmpty)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _jumpToLatest,
              icon: const Icon(Icons.vertical_align_bottom, size: 16),
              label: const Text('回到最新'),
            ),
          ),
        if (queued.isNotEmpty)
          SizedBox(
            height: 40,
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              scrollDirection: Axis.horizontal,
              children: queued
                  .map(
                    (item) => Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ActionChip(
                        avatar: const Icon(Icons.schedule, size: 16),
                        label: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 180),
                          child: Text(
                            (item['content'] as String?)?.trim().isNotEmpty ==
                                    true
                                ? item['content'] as String
                                : '附件消息',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        onPressed: _online
                            ? () => _queuedActions(room, item)
                            : null,
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        _TopicBar(
          key: ValueKey(room),
          room: room,
          api: _api,
          runtime: _runtime,
          members: objects(_directory['companions'])
              .where(
                (item) =>
                    (current?['memberIds'] as List?)?.contains(item['id']) ==
                    true,
              )
              .toList(),
          onNotice: _show,
          onRouting: (busy) => _update(() => _changingTopic = busy),
          onChanged: (topic) async {
            if (_room != room) return;
            if (topic.isNotEmpty) {
              _update(
                () => _snapshot = {
                  ..._snapshot,
                  'chatRuntime': {..._runtime, 'topic': topic},
                },
              );
            }
            await _refresh();
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 5, 10, 8),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: const Color(0xffe6e2ee)),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_quotes[room] case final Json quote)
                  _quotePreview(
                    quote['senderName'] as String? ?? '伙伴',
                    quote['content'] as String? ?? '',
                    clear: () => _update(() => _quotes.remove(room)),
                  ),
                if (files.isNotEmpty)
                  SizedBox(
                    height: 43,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      children: files
                          .map(
                            (file) => Padding(
                              padding: const EdgeInsets.only(right: 5),
                              child: InputChip(
                                avatar: const Icon(Icons.attach_file, size: 16),
                                label: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 160,
                                  ),
                                  child: Text(
                                    file['name'] as String,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                onDeleted: _sending
                                    ? null
                                    : () { _update(() => files.remove(file)); _scheduleCache(); }
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                if (_roomUploading) ...[
                  if (_uploads[_uploadId] case final Json upload)
                    ListTile(
                      dense: true,
                      title: Text(
                        upload['name'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${_uploadWaiting ? "等待网络，恢复后继续" : "上传中"} · ${((_uploadProgress ?? 0) * 100).floor()}%',
                      ),
                      trailing: IconButton(
                        tooltip: '取消上传',
                        onPressed: _cancelUpload,
                        icon: const Icon(Icons.close),
                      ),
                    ),
                  LinearProgressIndicator(value: _uploadProgress),
                ],
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: '表情',
                      onPressed: enabled ? _stickers : null,
                      icon: const Icon(Icons.emoji_emotions_outlined),
                    ),
                    IconButton(
                      tooltip: '添加附件',
                      onPressed: enabled ? _pickFiles : null,
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _composer,
                        focusNode: _composerFocus,
                        minLines: 1,
                        maxLines: 5,
                        maxLength: 64000,
                        decoration: const InputDecoration(
                          hintText: '发消息给伙伴…',
                          counterText: '',
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 13),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: _recordingRoom == room ? '结束录音并转文字' : '录音转文字',
                      isSelected: _recordingRoom == room,
                      onPressed:
                          _dictating || (!_online && _recordingRoom != room)
                          ? null
                          : () => _dictate(room),
                      icon: const Icon(Icons.mic_none_outlined),
                      selectedIcon: const Icon(Icons.stop_circle_outlined),
                    ),
                    if (objects(_runtime['running']).isNotEmpty)
                      IconButton(
                        tooltip: '引导正在执行的伙伴',
                        onPressed: enabled
                            ? () => _send(delivery: 'steer')
                            : null,
                        icon: const Icon(Icons.bolt_outlined),
                      ),
                    IconButton.filled(
                      tooltip: '发送',
                      onPressed: canSend ? _send : null,
                      icon: const Icon(Icons.arrow_upward),
                    ),
                    const SizedBox(width: 5),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _pendingBubble(MapEntry<String, Json> entry) {
    final error = entry.value['error'] as String?;
    return Card(
      child: ListTile(
        leading: Icon(error == null ? Icons.schedule : Icons.error_outline),
        title: Text(entry.value['content'] as String? ?? ''),
        subtitle: Text(error ?? (_online ? '正在发送' : '等待网络恢复，稍后自动发送')),
        trailing: error == null
            ? null
            : PopupMenuButton<bool>(
                onSelected: (retry) => _managePending(entry.key, retry: retry),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: true, child: Text('重试')),
                  PopupMenuItem(value: false, child: Text('移除')),
                ],
              ),
      ),
    );
  }

  Future<void> _queuedActions(String room, Json item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.bolt),
              title: const Text('引导当前回复'),
              onTap: () => Navigator.pop(context, 'message.guide'),
            ),
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: const Text('从队列移除'),
              onTap: () => Navigator.pop(context, 'message.dequeue'),
            ),
          ],
        ),
      ),
    );
    if (action != null) {
      await _action(action, {
        'conversationId': room,
        'messageId': item['messageId'],
      });
    }
  }

  Widget _quotePreview(String name, String text, {VoidCallback? clear}) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(9, 3, 6, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 2,
              height: 25,
              color: _accent.withValues(alpha: .55),
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                    ),
                  ),
                  Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
            if (clear != null)
              IconButton(
                tooltip: '移除引用',
                onPressed: clear,
                icon: const Icon(Icons.close, size: 17),
              ),
          ],
        ),
      );

  Widget _message(Json message) {
    final own = message['senderId'] == 'user';
    final id = message['id'] as String;
    final sender = message['senderName'] as String? ?? (own ? '你' : '伙伴');
    final active = ['queued', 'running'].contains(message['status']);
    final content =
        (active ? _streaming[id] ?? message['content'] : message['content'])
            as String? ??
        '';
    final execution = object(message['execution']);
    final progress = _liveProgress[id] ?? object(message['progress']);
    final activity = object(progress['activity']);
    final question = object(execution['question']);
    final steps = objects(execution['steps']);
    final attachments = objects(message['attachments']);
    final date = DateTime.tryParse(
      message['createdAt'] as String? ?? '',
    )?.toLocal();
    final time = date == null
        ? ''
        : '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        textDirection: own ? TextDirection.rtl : TextDirection.ltr,
        children: [
          CompanionAvatar(
            id: message['senderId'] as String,
            name: sender,
            size: 32,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: own
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                Text(
                  '$sender  $time',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xff656477),
                  ),
                ),
                const SizedBox(height: 5),
                if (object(message['quote']) case final Json quote
                    when quote.isNotEmpty)
                  _quotePreview(
                    quote['senderName'] as String? ?? '伙伴',
                    quote['excerpt'] as String? ?? '',
                  ),
                if (content.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: own ? const Color(0xffeeeaf8) : Colors.white,
                      border: Border.all(color: const Color(0xffe7e3ee)),
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(own ? 16 : 5),
                        topRight: Radius.circular(own ? 5 : 16),
                        bottomLeft: const Radius.circular(16),
                        bottomRight: const Radius.circular(16),
                      ),
                    ),
                    child: own
                        ? SelectableText(content)
                        : MarkdownBody(
                            data: content,
                            selectable: true,
                            fitContent: true,
                            imageBuilder: (_, _, _) => const Text('[图片链接]'),
                          ),
                  ),
                ...attachments.map((file) => _fileCard(message, file)),
                if (!own &&
                    message['status'] == 'sent' &&
                    content.trim().isNotEmpty)
                  Wrap(
                    children: [
                      IconButton(
                        tooltip: '复制',
                        visualDensity: VisualDensity.compact,
                        iconSize: 17,
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: content));
                          if (mounted) _show('已复制');
                        },
                        icon: const Icon(Icons.copy_outlined),
                      ),
                      IconButton(
                        tooltip: _readingMessage == id ? '停止朗读' : '朗读',
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        onPressed: _online
                            ? () => _readMessage(
                                message['conversationId'] as String,
                                id,
                              )
                            : null,
                        icon: Icon(
                          _readingMessage == id
                              ? Icons.stop_outlined
                              : Icons.volume_up_outlined,
                        ),
                      ),
                      IconButton(
                        tooltip: '引用',
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        onPressed: () {
                          final room = _room;
                          if (room == null) return;
                          _update(() => _quotes[room] = message);
                          _composerFocus.requestFocus();
                        },
                        icon: const Icon(Icons.format_quote_outlined),
                      ),
                    ],
                  ),
                if (message['error'] case final String error)
                  Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (active ||
                    message['status'] == 'failed' ||
                    message['status'] == 'cancelled')
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 4,
                    children: [
                      if (active)
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      Text(
                        active
                            ? _progressLabel(progress['phase'] as String?)
                            : message['status'] == 'failed'
                            ? '执行失败'
                            : '已停止',
                        style: const TextStyle(
                          color: Color(0xff656477),
                          fontSize: 12,
                        ),
                      ),
                      if (active && activity['summary'] is String)
                        Text(
                          activity['summary'] as String,
                          style: const TextStyle(fontSize: 12),
                        ),
                      if (active && !own)
                        TextButton(
                          onPressed: _online
                              ? () => _action('reply.cancel', {'messageId': id})
                              : null,
                          child: const Text('停止'),
                        ),
                      if (!active &&
                          (execution['continuation'] != null ||
                              object(execution['interruption'])['state'] ==
                                  'ready'))
                        TextButton(
                          onPressed: _online
                              ? () => _action('execution.continue', {
                                  'messageId': id,
                                  'requestId': _uuid.v4(),
                                })
                              : null,
                          child: const Text('继续执行'),
                        ),
                    ],
                  ),
                if (active && question.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: _online
                        ? () => _answer(message, question)
                        : null,
                    icon: const Icon(Icons.help_outline, size: 16),
                    label: const Text('回答伙伴的问题'),
                  ),
                if (steps.isNotEmpty)
                  ExpansionTile(
                    dense: true,
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: EdgeInsets.zero,
                    title: Text(
                      '执行过程 · ${steps.length} 步',
                      style: const TextStyle(fontSize: 12),
                    ),
                    children: steps
                        .map(
                          (step) => ListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              (step['summary'] ??
                                      step['toolName'] ??
                                      step['type'])
                                  as String,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        )
                        .toList(),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fileCard(Json message, Json file) {
    final key = '${message['id']}/${file['id']}';
    final image =
        (file['mimeType'] as String? ?? '').startsWith('image/') &&
        (file['size'] as int? ?? 0) <= 4 * 1024 * 1024;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (image && _online && _imageCache.containsKey(key))
            FutureBuilder<Uint8List>(
              future: _imageCache.putIfAbsent(key, () {
                if (_imageCache.length >= 24) {
                  _imageCache.remove(_imageCache.keys.first);
                }
                return _loadImage(message, file);
              }),
              builder: (context, snapshot) {
                final bytes = snapshot.data;
                if (bytes == null) return const SizedBox.shrink();
                return ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(
                    bytes,
                    width: 175,
                    height: 140,
                    fit: BoxFit.contain,
                    cacheWidth: 520,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                );
              },
            ),
          OutlinedButton.icon(
            onPressed: _downloading.contains(key)
                ? () => _update(() => _cancelledDownloads.add(key))
                : _online && (file['storage'] != 'external' || _api!.downloadsOriginal) ? () => _download(message, file) : null,
            icon: Icon(
              _downloading.contains(key)
                  ? Icons.cancel_outlined
                  : Icons.download_outlined,
              size: 18,
            ),
            label: Text(
              _downloading.contains(key) ? '取消下载 · ${file['name']}' : file['name'] as String? ?? '附件',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (image &&
              _online &&
              !_imageCache.containsKey(key) &&
              file['storage'] != 'external')
            TextButton.icon(
              icon: const Icon(Icons.image_outlined, size: 17),
              label: const Text('预览图片'),
              onPressed: () => _update(() {
                if (_imageCache.length >= 12) {
                  _imageCache.remove(_imageCache.keys.first);
                }
                _imageCache[key] = _loadImage(message, file);
              }),
            ),
        ],
      ),
    );
  }
}
