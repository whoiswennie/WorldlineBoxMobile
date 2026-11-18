import 'mobile_api.dart';

/// Kept per paired computer. Persist only counts and cursors, never reply text.
class MessageInbox {
  int? cursor;
  bool legacyInitialized = false;
  final unread = <String, int>{};
  final legacyHeads = <String, int>{};

  void restore(Json saved) {
    cursor = saved['cursor'] as int?;
    legacyInitialized = saved['legacyInitialized'] == true;
    for (final (target, source) in [
      (unread, object(saved['unread'])),
      (legacyHeads, object(saved['legacyHeads'])),
    ]) {
      for (final entry in source.entries) {
        if (entry.value is int && entry.value >= 0) {
          target[entry.key] = entry.value;
        }
      }
    }
  }

  Json toJson() => {
    'cursor': cursor,
    'unread': Map.of(unread),
    'legacyInitialized': legacyInitialized,
    'legacyHeads': Map.of(legacyHeads),
  };

  /// Returns the last new message in each unread conversation for presentation.
  Map<String, Json> apply(Json page, Set<String> rooms, String? visibleRoom) {
    final last = <String, Json>{};
    final next = page['cursor'] as int;
    if (cursor != null && next < cursor!) unread.clear();
    for (final message in objects(page['messages'])) {
      final room = message['room'] as String;
      if (!rooms.contains(room) ||
          room == visibleRoom ||
          (message['sequence'] as int) <= (cursor ?? -1)) {
        continue;
      }
      unread.update(room, (n) => n + 1, ifAbsent: () => 1);
      last[room] = message;
    }
    cursor = next;
    unread.removeWhere((id, _) => !rooms.contains(id) || id == visibleRoom);
    return last;
  }

  // Older desktops expose only a directory and paged chat history. Confirm the
  // actual sender ID before reporting a change (names can match the user's).
  Future<({Map<String, int> heads, List<Json> messages})> readLegacy(
    List<Json> rooms,
    Set<String> companions,
    Future<Json> Function(String room, int? before) history,
  ) async {
    final heads = <String, int>{};
    final messages = <Json>[];
    for (final room in rooms) {
      final id = room['id'] as String;
      final latest = object(room['activity'])['sequence'] as int? ?? 0;
      heads[id] = latest;
      final previous = legacyHeads[id] ?? 0;
      if (!legacyInitialized || latest <= previous) continue;
      int? before;
      while (true) {
        final page = await history(id, before);
        final batch = objects(page['messages']);
        for (final m in batch) {
          final seq = m['sequence'] as int;
          if (seq <= previous ||
              seq > latest ||
              m['status'] != 'sent' ||
              !companions.contains(m['senderId'])) {
            continue;
          }
          final content = (m['content'] as String? ?? '').trim();
          if (content.isEmpty && objects(m['attachments']).isEmpty) continue;
          messages.add({
            'room': id,
            'sequence': seq,
            'sender': m['senderName'],
            'preview': content.isEmpty ? '[附件]' : content,
          });
        }
        final first = batch.firstOrNull?['sequence'] as int?;
        if (page['hasMore'] != true ||
            first == null ||
            first <= previous ||
            (before != null && first >= before)) {
          break;
        }
        before = first;
      }
    }
    messages.sort(
      (a, b) => (a['sequence'] as int).compareTo(b['sequence'] as int),
    );
    return (heads: heads, messages: messages);
  }

  Map<String, Json> applyLegacy(
    Map<String, int> heads,
    List<Json> messages,
    String? visibleRoom,
  ) {
    final last = <String, Json>{};
    for (final message in messages) {
      final id = message['room'] as String;
      if (id == visibleRoom ||
          (message['sequence'] as int) <= (legacyHeads[id] ?? 0)) {
        continue;
      }
      unread.update(id, (n) => n + 1, ifAbsent: () => 1);
      last[id] = message;
    }
    legacyInitialized = true;
    legacyHeads
      ..clear()
      ..addAll(heads);
    unread.removeWhere((id, _) => !heads.containsKey(id) || id == visibleRoom);
    return last;
  }
}
