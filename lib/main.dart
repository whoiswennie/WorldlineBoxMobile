// Keep compatibility with the Flutter material widgets used by the app.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'chat.dart';
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
  HostProfile? _profile;
  MobileApi? _pairedConnection;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _profile = await _store.read();
    } catch (_) {
      _error = '无法读取已保存的电脑，请重新配对。';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save(HostProfile profile, MobileApi connection) async {
    await _store.save(profile);
    if (mounted) {
      setState(() {
        _profile = profile;
        _pairedConnection = connection;
        _error = null;
      });
    } else {
      await connection.close();
    }
  }

  Future<void> _forget() async {
    await _store.forget();
    if (mounted) {
      setState(() {
        _profile = null;
        _pairedConnection = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    return MaterialApp(
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
              profile: profile,
              initialConnection: _pairedConnection,
              onForget: _forget,
              saveProfile: _store.save,
            ),
    );
  }
}
