import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'mobile_api.dart';

String _digest(List<Object?> parts) =>
    sha256.convert(utf8.encode(jsonEncode(parts))).toString();

String attachmentCacheKey(Json message, Json attachment) => _digest([
  message['conversationId'],
  message['id'],
  attachment['id'],
  attachment['size'],
  attachment['sha256'],
]);

class CachedOriginal {
  CachedOriginal(this.file, this.message, this.attachment, this.used);
  final File file;
  final Json message;
  final Json attachment;
  DateTime used;
}

class AttachmentCache {
  AttachmentCache(String fingerprint, String token, {this.base})
    : _identity = _digest([fingerprint, token]);
  final Directory? base;
  final String _identity;
  final entries = <String, CachedOriginal>{};
  late final Future<Directory> _root = _directory();
  late final Future<void> ready = _restore();
  final _pending = <String, Future<CachedOriginal>>{};
  int _generation = 0;
  final _inUse = <String>{};
  void pin(String key) => _inUse.add(key);
  void unpin(String key) => _inUse.remove(key);

  Future<Directory> _directory() async {
    final temp = base ?? await getTemporaryDirectory();
    return Directory('${temp.path}/attachment-previews/$_identity');
  }

  Future<void> _restore() async {
    final root = await _root;
    if (!await root.exists()) return;
    await for (final folder in root.list(followLinks: false)) {
      if (folder is! Directory) continue;
      final key = folder.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (key.startsWith('transfer-')) {
        if ((await folder.stat()).modified.isBefore(
          DateTime.now().subtract(const Duration(days: 1)),
        )) {
          await _remove(folder);
        }
        continue;
      }
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(key)) continue;
      try {
        final meta = object(
          jsonDecode(await File('${folder.path}/metadata.json').readAsString()),
        );
        final message = object(meta['message']),
            attachment = object(meta['attachment']);
        final file = File('${folder.path}/original');
        final stat = await file.stat();
        if (attachmentCacheKey(message, attachment) == key &&
            stat.type == FileSystemEntityType.file &&
            stat.size == attachment['size']) {
          entries[key] = CachedOriginal(
            file,
            message,
            attachment,
            stat.modified,
          );
          continue;
        }
      } on FormatException {
        // Ignore incomplete or invalid metadata.
      } on IOException {
        // Android may evict individual cache files.
      }
      await _remove(folder);
    }
    await _trim();
  }

  static Future<void> _remove(Directory folder) async {
    try {
      await folder.delete(recursive: true);
    } on FileSystemException {
      /* Already evicted or in use. */
    }
  }

  Future<void> _trim() async {
    // Keep the newest original, including a single file larger than the budget.
    final newest = entries.entries.toList()
      ..sort((a, b) => b.value.used.compareTo(a.value.used));
    var total = 0;
    for (var i = 0; i < newest.length; i++) {
      final item = newest[i];
      total += item.value.attachment['size'] as int;
      if (i > 0 &&
          !_inUse.contains(item.key) &&
          !_pending.containsKey(item.key) &&
          (i >= 256 || total > 512 * 1024 * 1024)) {
        entries.remove(item.key);
        await _remove(item.value.file.parent);
      }
    }
  }

  Future<CachedOriginal> obtain(
    Json message,
    Json attachment,
    Future<void> Function(File) fetch,
  ) async {
    await ready;
    final key = attachmentCacheKey(message, attachment);
    final underway = _pending[key];
    if (underway != null) return underway;
    final work = _obtain(key, message, attachment, fetch);
    _pending[key] = work;
    try {
      return await work;
    } finally {
      _pending.remove(key);
    }
  }

  Future<CachedOriginal> _obtain(
    String key,
    Json message,
    Json attachment,
    Future<void> Function(File) fetch,
  ) async {
    final generation = _generation;
    final cached = entries[key];
    final size = attachment['size'] as int;
    if (cached != null) {
      final stat = await cached.file.stat();
      if (stat.type == FileSystemEntityType.file && stat.size == size) {
        cached.used = DateTime.now();
        await cached.file.setLastModified(cached.used);
        return cached;
      }
      entries.remove(key);
      await _remove(cached.file.parent);
    }
    final root = await _root;
    await root.create(recursive: true);
    final staging = await root.createTemp('transfer-');
    try {
      final file = await File('${staging.path}/original').create();
      await fetch(file);
      if (await file.length() != size) throw const MobileException('附件大小校验失败。');
      if (attachment['sha256'] case final String expected) {
        final actual = await sha256.bind(file.openRead()).first;
        if (actual.toString() != expected.toLowerCase()) {
          throw const MobileException('附件内容校验失败。');
        }
      }
      final record = <String, dynamic>{
        for (final field in [
          'conversationId',
          'id',
          'senderId',
          'senderName',
          'createdAt',
          'sequence',
          'status',
        ])
          if (message.containsKey(field)) field: message[field],
        'content': String.fromCharCodes(
          (message['displayContent'] ?? message['content'] ?? '')
              .toString()
              .runes
              .take(900),
        ),
      };
      await File('${staging.path}/metadata.json').writeAsString(
        jsonEncode({'message': record, 'attachment': attachment}),
        flush: true,
      );
      if (generation != _generation) throw const MobileException('附件传输已取消。');
      final folder = await staging.rename('${root.path}/$key');
      if (generation != _generation) throw const MobileException('附件传输已取消。');
      final result = entries[key] = CachedOriginal(
        File('${folder.path}/original'),
        record,
        attachment,
        DateTime.now(),
      );
      await _trim();
      return result;
    } finally {
      await _remove(staging);
    }
  }

  Iterable<Json> offlineMessages(String? room) {
    final messages = <String, Json>{};
    for (final entry in entries.values.where(
      (item) => item.message['conversationId'] == room,
    )) {
      final message = messages.putIfAbsent(
        entry.message['id'] as String,
        () => {...entry.message, 'attachments': <Json>[]},
      );
      (message['attachments'] as List<Json>).add(entry.attachment);
    }
    return messages.values;
  }

  Future<void> clear() async {
    await ready;
    _generation++;
    await Future.wait(
      _pending.values.map(
        (work) => work.then<void>((_) {}, onError: (Object _) {}),
      ),
    );
    final root = await _root;
    if (await root.exists()) await root.delete(recursive: true);
    entries.clear();
  }
}
