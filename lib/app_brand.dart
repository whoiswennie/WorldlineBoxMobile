// Match the Material widgets used throughout this app.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const appName = '世界线盒子';
const brandInk = Color(0xff30274c);
const brandPaper = Color(0xfff8f7fb);
const brandAccent = Color(0xff6954a4);
const messageChannel = MethodChannel('worldlinebox/messages');
final workspaceRoutes = RouteObserver<ModalRoute<dynamic>>();
final _version = messageChannel
    .invokeMethod<String>('version')
    .catchError((_) => null);

class BrandTitle extends StatelessWidget {
  const BrandTitle({super.key});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: Image.asset(
          'assets/worldlinebox-logo.png',
          width: 36,
          height: 36,
        ),
      ),
      const SizedBox(width: 10),
      Flexible(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              appName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 20,
                height: 1.2,
                color: brandInk,
                fontWeight: FontWeight.w700,
                letterSpacing: .5,
              ),
            ),
            FutureBuilder<String?>(
              future: _version,
              builder: (_, value) => value.data == null
                  ? const SizedBox.shrink()
                  : Text(
                      'v${value.data}',
                      style: const TextStyle(
                        fontSize: 11,
                        height: 1.25,
                        letterSpacing: .45,
                        color: Color(0xff726b80),
                      ),
                    ),
            ),
          ],
        ),
      ),
    ],
  );
}

class BrandLaunch extends StatelessWidget {
  const BrandLaunch({super.key});
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: BrandTitle()));
}
