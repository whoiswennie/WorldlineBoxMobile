import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'mobile_api.dart';

class ChatCache {
  ChatCache(this.identity, {File? file}) : _override = file;

  final String identity;
  final File? _override;
  static final _pending = <String, Future<void>>{};
  String get _queueKey => _override?.absolute.path ?? identity;
  late final Future<File> _file = _locate();

  Future<File> _locate() async {
    if (_override != null) return _override;
    final root = await getApplicationSupportDirectory();
    final key = sha256.convert(utf8.encode(identity));
    return File('${root.path}${Platform.pathSeparator}companion-$key.json');
  }

  Future<Json> read() async {
    try {
      await _pending[_queueKey];
      final file = await _file;
      if (!await file.exists() || await file.length() > 4 * 1024 * 1024) {
        return {};
      }
      return object(jsonDecode(await file.readAsString()));
    } on IOException {
      return {};
    } on FormatException {
      return {};
    } catch (_) {
      return {};
    }
  }

  Future<void> write(
    Json directory,
    Map<String, List<Json>> own, {
    Json outbox = const {},
    Json? inbox,
    Json? transfers,
  }) => _enqueue((file) async {
    final payload = jsonEncode({
      'directory': directory,
      'own': own,
      'outbox': outbox,
      'inbox': ?inbox,
      'transfers': ?transfers,
    });
    final bytes = utf8.encode(payload);
    if (bytes.length > 4 * 1024 * 1024) {
      throw const FileSystemException('Local cache is full.');
    }
    final temporary = File('${file.path}.tmp');
    try {
      await file.parent.create(recursive: true);
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  });

  Future<void> clear() => _enqueue((file) async {
    if (await file.exists()) await file.delete();
    final temporary = File('${file.path}.tmp');
    if (await temporary.exists()) await temporary.delete();
  });

  Future<void> _enqueue(Future<void> Function(File) operation) {
    final key = _queueKey;
    final work = (_pending[key] ?? Future<void>.value()).then(
      (_) async => operation(await _file),
    );
    final settled = _pending[key] = work.catchError((Object _) {});
    settled.then((_) {
      if (identical(_pending[key], settled)) _pending.remove(key);
    });
    return work;
  }
}
