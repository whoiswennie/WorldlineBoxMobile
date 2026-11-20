// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'mobile_api.dart';
import 'profile.dart';
import 'websocket_ssh.dart';

class ComputersPage extends StatefulWidget {
  const ComputersPage({
    super.key,
    required this.hosts,
    required this.store,
    required this.online,
    required this.activeOnline,
  });
  final ValueListenable<Set<String>> online;
  final bool activeOnline;
  final HostDirectory hosts;
  final ProfileStore store;
  @override
  State<ComputersPage> createState() => _ComputersPageState();
}

class _ComputersPageState extends State<ComputersPage> {
  late HostDirectory hosts = widget.hosts;
  bool busy = false;
  String? status;

  Future<void> clean() async {
    setState(() {
      busy = true;
      status = '正在检查已配对电脑…';
    });
    final changes = <HostProfile, HostProfile?>{};
    var unknown = 0;
    final profiles = hosts.profiles.values.toList();
    Future<void> check(HostProfile p) async {
      MobileApi? api;
      try {
        api = await MobileApi.connect(p);
        if (api.profile.remoteHost != p.remoteHost) {
          changes[p] = api.profile;
        } else if (api.route.local &&
            p.remoteHost != null &&
            await api.currentRemoteHost() == null &&
            await WebSocketSsh.expiredTemporaryAddress(p.remoteHost!)) {
          changes[p] = api.profile.withRoutes(clearRemote: true);
        }
      } catch (_) {
        if (await MobileApi.confirmedRemoved(p)) {
          changes[p] = null;
        } else if (p.remoteHost != null &&
            await WebSocketSsh.expiredTemporaryAddress(p.remoteHost!)) {
          changes[p] = p.withRoutes(clearRemote: true);
        } else {
          unknown++;
        }
      } finally {
        await api?.close();
      }
    }

    try {
      for (var i = 0; i < profiles.length; i += 4) {
        await Future.wait(profiles.skip(i).take(4).map(check));
        if (!mounted) return;
      }
      final next = await widget.store.clean(changes);
      if (mounted) {
        setState(() {
          hosts = next;
          final kept = unknown == 0 ? '' : '另有 $unknown 台暂时无法确认，已保留配对。';
          status = '已清理或更新 ${changes.length} 条记录。$kept';
        });
      }
    } catch (_) {
      if (mounted) setState(() => status = '连接记录暂时无法保存，请重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('我的电脑')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final p in hosts.profiles.values)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.computer_outlined),
                  title: Text(p.displayName),
                  subtitle: ValueListenableBuilder<Set<String>>(
                    valueListenable: widget.online,
                    builder: (_, live, _) => Text(
                      [
                        (live.contains(p.fingerprint) ||
                                hosts.active == p.fingerprint &&
                                    widget.activeOnline)
                            ? '在线'
                            : '未连接',
                        if (p.localRoutes.isNotEmpty) p.localRoutes.first.host,
                        if (p.remoteHost != null) '远程连接',
                        p.discoveryName.substring(4, 12),
                      ].join(' · '),
                    ),
                  ),
                  trailing: hosts.active == p.fingerprint
                      ? const Icon(
                          Icons.check_circle_outline,
                          semanticLabel: '当前电脑',
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: busy
                      ? null
                      : () => Navigator.pop(context, p.fingerprint),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: busy ? null : () => Navigator.pop(context, '+'),
              icon: const Icon(Icons.add),
              label: const Text('添加电脑'),
            ),
            TextButton.icon(
              onPressed: busy ? null : clean,
              icon: const Icon(Icons.cleaning_services_outlined),
              label: const Text('清理失效连接'),
            ),
            if (busy) const LinearProgressIndicator(),
            if (status != null)
              Padding(padding: const EdgeInsets.all(12), child: Text(status!)),
          ],
        ),
      ),
    ),
  );
}
