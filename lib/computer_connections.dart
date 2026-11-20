import 'dart:async';

import 'package:flutter/foundation.dart';

import 'mobile_api.dart';
import 'profile.dart';

/// Other paired PCs keep an authenticated presence connection. Only the selected
/// workspace consumes chat history, sends queued messages or starts playback.
class ComputerConnections {
  ComputerConnections(this.store) {
    _retry = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
  }
  final ProfileStore store;
  final online = ValueNotifier<Set<String>>({});
  final _targets = <String, HostProfile>{};
  final _connections = <String, MobileApi>{};
  final _dialing = <String>{};
  late final Timer _retry;
  bool _closed = false;
  int _next = 0;

  void watch(HostDirectory directory) {
    _targets
      ..clear()
      ..addAll(directory.profiles)
      ..remove(directory.active);
    for (final entry in _connections.entries.toList()) {
      if (_targets[entry.key]?.token != entry.value.profile.token) {
        _drop(entry.key, entry.value);
      }
    }
    _tick();
  }

  void _tick() {
    if (_closed || _targets.isEmpty) return;
    final targets = _targets.values.toList();
    final start = _next % targets.length;
    for (var i = 0; i < targets.length; i++) {
      final p = targets[(start + i) % targets.length];
      final api = _connections[p.fingerprint];
      if (api == null) {
        if (_dialing.length < 4 && _dialing.add(p.fingerprint)) {
          _next = (start + i + 1) % targets.length;
          unawaited(_connect(p));
        }
      } else {
        unawaited(_heartbeat(api));
      }
    }
  }

  Future<void> _heartbeat(MobileApi api) async {
    try {
      final next = await api.currentRemoteHost();
      if (next != null &&
          next != api.profile.remoteHost &&
          identical(_connections[api.profile.fingerprint], api)) {
        api.profile = api.profile.withRoutes(remote: next);
        await store.update(api.profile);
      }
    } catch (_) {
      _drop(api.profile.fingerprint, api);
    }
  }

  Future<void> _connect(HostProfile p) async {
    final id = p.fingerprint;
    MobileApi? candidate;
    try {
      final api = candidate = await MobileApi.connect(p);
      if (_closed || _targets[id]?.token != p.token) {
        await api.close();
        return;
      }
      _connections[id] = api;
      await store.update(api.profile);
      if (!identical(_connections[id], api)) return;
      api
          .events(null)
          .listen(
            (event) {
              if (event['type'] == 'ready' && identical(_connections[id], api)) {
                online.value = {...online.value, id};
              }
            },
            onError: (Object _) => _drop(id, api),
            onDone: () => _drop(id, api),
            cancelOnError: true,
          );
    } catch (_) {
      if (candidate != null) _drop(id, candidate);
    } finally {
      _dialing.remove(id);
    }
  }

  void _drop(String id, MobileApi api) {
    if (identical(_connections[id], api)) {
      _connections.remove(id);
      if (!_closed) online.value = {...online.value}..remove(id);
    }
    unawaited(api.close());
  }

  void dispose() {
    _closed = true;
    _retry.cancel();
    for (final api in _connections.values) {
      unawaited(api.close());
    }
    _connections.clear();
    online.dispose();
  }
}
