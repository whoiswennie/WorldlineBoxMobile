// Keep compatibility with the Flutter material widgets used by the app.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'chat.dart';
import 'computers.dart';
import 'computer_connections.dart';
import 'app_brand.dart';
import 'mobile_api.dart';
import 'pairing.dart';
import 'profile.dart';

void main() => runApp(const WorldlineBoxMobile());

class WorldlineBoxMobile extends StatefulWidget {
  const WorldlineBoxMobile({super.key});

  @override
  State<WorldlineBoxMobile> createState() => _WorldlineBoxMobileState();
}

class _WorldlineBoxMobileState extends State<WorldlineBoxMobile> {
  final _store = ProfileStore();
  late final _connections = ComputerConnections(_store);
  final _navigator = GlobalKey<NavigatorState>();
  HostDirectory _hosts = HostDirectory({}, null);
  MobileApi? _pairedConnection;
  bool _loading = true;
  String? _error;
  int _generation = 0;
  Map<String, dynamic>? _notification;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _hosts = await _store.read();
      if (mounted) _connections.watch(_hosts);
    } catch (_) {
      _error = '无法读取已保存的电脑，请重新配对。';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _activate(
    HostDirectory next, {
    MobileApi? connection,
    Map<String, dynamic>? notification,
  }) async {
    if (!mounted) {
      await connection?.close();
      return;
    }
    _connections.watch(next);
    // Detach the old host's event handlers, media and SSH tunnel before mounting the next.
    setState(() => _loading = true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      await connection?.close();
      return;
    }
    setState(() {
      _hosts = next;
      _pairedConnection = connection;
      _notification = notification;
      _generation++;
      _error = null;
      _loading = false;
    });
  }

  Future<void> _save(HostProfile profile, MobileApi connection) async =>
      _activate(await _store.pair(profile), connection: connection);

  Future<void> _forget() async {
    final current = _hosts.active;
    if (current != null) await _activate(await _store.forget(current));
  }

  Future<void> _switchFromNotification(Map<String, dynamic> tap) async {
    final hosts = await _store.read();
    final id = tap['host'];
    if (id is! String || !hosts.profiles.containsKey(id)) return;
    _navigator.currentState?.popUntil((r) => r.isFirst);
    await _activate(await _store.select(id), notification: tap);
  }

  Future<void> _manage(bool activeOnline) async {
    final hosts = await _store.read();
    final nav = _navigator.currentState;
    if (nav == null) return;
    final result = await nav.push<String>(
      MaterialPageRoute(
        builder: (_) => ComputersPage(
          hosts: hosts,
          store: _store,
          online: _connections.online,
          activeOnline: activeOnline,
        ),
      ),
    );
    if (!mounted) return;
    if (result == '+') {
      final refreshed = await _store.read();
      if (!mounted || !nav.mounted) return;
      await nav.push<void>(
        MaterialPageRoute(
          builder: (page) => PairingPage(
            known: refreshed.profiles,
            onSave: (p, api) async {
              await _save(p, api);
              if (page.mounted) Navigator.pop(page);
            },
          ),
        ),
      );
    } else if (result != null && result != hosts.active) {
      await _activate(await _store.select(result));
    } else {
      final refreshed = await _store.read();
      final previous = _hosts.current;
      final next = refreshed.current;
      if (next?.fingerprint != previous?.fingerprint ||
          next?.remoteHost != previous?.remoteHost) {
        await _activate(refreshed);
      } else if (mounted) {
        _connections.watch(refreshed);
        setState(() => _hosts = refreshed);
      }
    }
  }

  @override
  void dispose() {
    _connections.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profile = _hosts.current;
    return MaterialApp(
      navigatorKey: _navigator,
      debugShowCheckedModeBanner: false,
      title: appName,
      navigatorObservers: [workspaceRoutes],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff6959a3),
          surface: const Color(0xfff7f7fa),
        ),
        scaffoldBackgroundColor: brandPaper,
        appBarTheme: const AppBarTheme(
          backgroundColor: brandPaper,
          surfaceTintColor: Colors.transparent,
          foregroundColor: Color(0xff252634),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: _loading
          ? const BrandLaunch()
          : profile == null
          ? PairingPage(onSave: _save, initialError: _error)
          : CompanionWorkspace(
              key: ValueKey('${profile.fingerprint}/$_generation'),
              profile: profile,
              manageHosts: _manage,
              initialNotification: _notification,
              switchFromNotification: _switchFromNotification,
              initialConnection: _pairedConnection,
              onForget: _forget,
              replacePairing: _save,
              saveProfile: _store.update,
            ),
    );
  }
}
