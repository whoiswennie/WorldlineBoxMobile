part of 'chat.dart';

extension _WorkspaceAlerts on _CompanionWorkspaceState {
  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  String? get _visibleRoom => !_foreground
      ? null
      : _activeCallRoom ?? (_observedRoute?.isCurrent == true ? _room : null);

  Future<void> _nativeAlert(String method, [dynamic value]) async {
    try {
      await messageChannel.invokeMethod<void>(method, value);
    } on PlatformException {
      // A blocked notification channel must never interrupt the chat connection.
    } on MissingPluginException {
      return;
    }
  }

  void _markVisible() {
    if (!mounted) return;
    final id = _visibleRoom;
    if (id == null || !_inbox.unread.containsKey(id)) return;
    _update(() => _inbox.unread.remove(id));
    unawaited(_nativeAlert('clear', '${_profile.fingerprint}/$id'));
    unawaited(_saveCache());
  }

  Future<void> _takeChat() async {
    try {
      final tap = await messageChannel.invokeMapMethod<String, dynamic>('take');
      if (!mounted) return;
      if (tap != null && tap['host'] == _profile.fingerprint) {
        _pendingChat = tap;
      } else if (tap != null) {
        await _cacheReady;
        if (!mounted) return;
        await _saveCache(requireDisk: true);
        if (mounted) await widget.switchFromNotification(tap);
        return;
      }
      _openPendingChat();
      _markVisible();
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  void _openPendingChat() {
    final room = _pendingChat?['room'];
    if (!mounted ||
        !_foreground ||
        room is! String ||
        !_directory.containsKey('conversations')) {
      return;
    }
    if (!objects(
      _directory['conversations'],
    ).any((item) => item['id'] == room)) {
      return;
    }
    _pendingChat = null;
    Navigator.of(context).popUntil((route) => route.isFirst);
    _selectRoom(room);
  }

  void _presentMessage(String id, Json message, int? pushAfter) {
    if (!_inbox.unread.containsKey(id) || _visibleRoom == id) return;
    final room = objects(
      _directory['conversations'],
    ).where((r) => r['id'] == id).firstOrNull;
    if (room == null) return;
    final sender = message['sender'] as String? ?? room['title'] as String;
    final title = room['kind'] == 'group'
        ? '${room['title']} · $sender'
        : sender;
    final preview = (message['preview'] as String)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .characters
        .take(140)
        .toString();
    if (!_foreground) {
      if (pushAfter != null && (message['sequence'] as int) > pushAfter) {
        unawaited(
          _nativeAlert('message', {
            'host': _profile.fingerprint,
            'room': id,
            'title': title,
            'preview': preview,
            'count': _inbox.unread[id],
          }),
        );
      }
    } else if (_room != null ||
        _contacts ||
        _observedRoute?.isCurrent != true) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            '$title\n$preview',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          action: SnackBarAction(
            label: '查看',
            onPressed: () {
              _pendingChat = {'room': id};
              _openPendingChat();
            },
          ),
        ),
      );
    }
  }
}
