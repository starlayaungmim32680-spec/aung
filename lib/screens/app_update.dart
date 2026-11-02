// Force-update check (2 Nov 2026) - launch list item "force-update".
//
// Once Fly is on Google Play, people keep old versions for a long time.
// When the Worker or the Firestore rules change, an old build can break
// (e.g. builds from before `videoReady` show videos that are still
// encoding). So the app asks the Worker which builds are still OK:
//   GET <workerUrl>/app-version -> {minBuild, latestBuild, updateUrl}
// Ko sets the numbers in Cloudflare (Worker -> Settings -> Variables:
// MIN_APP_BUILD, LATEST_APP_BUILD, optional APP_UPDATE_URL) - no code
// change, no new APK. Each flavor asks its own Worker (app_config.dart).
//   - my build <  minBuild    -> [_UpdateRequiredScreen] over the whole
//                                app (also the login screen), no way past
//   - my build <  latestBuild -> a "New version" sheet, once per app run,
//                                with "Later"
//   - no internet / Worker error / 0 -> nothing (never lock people out
//                                by mistake)
// Asked when the app starts and when it comes back to the front (at most
// every 5 minutes, or every time while the update screen is showing, so
// lowering MIN_APP_BUILD unlocks it again).
// "My build" = the APK's build number (--build-number, yyDDDHHmm - see
// AI_CONTEXT §7 5b). The builds made before this file have no check.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app_config.dart';

const List<Color> _flyGradient = [
  Color(0xFFFF4B6E),
  Color(0xFF9C4DFF),
  Color(0xFF3A8DFF),
];

/// Wraps the whole app (MaterialApp.builder in main.dart).
class AppUpdateGate extends StatefulWidget {
  final Widget child;

  /// For the "New version" sheet (the gate sits above the Navigator).
  final GlobalKey<NavigatorState> navigatorKey;

  const AppUpdateGate({
    super.key,
    required this.child,
    required this.navigatorKey,
  });

  @override
  State<AppUpdateGate> createState() => _AppUpdateGateState();
}

class _AppUpdateGateState extends State<AppUpdateGate>
    with WidgetsBindingObserver {
  static const Duration _minGap = Duration(minutes: 5);

  int _myBuild = 0;
  String _myVersion = '';
  String _package = '';
  int _minBuild = 0;
  int _latestBuild = 0;
  String _updateUrl = '';
  bool _checking = false;
  bool _softShown = false;
  DateTime? _lastCheck;

  bool get _required => _myBuild > 0 && _myBuild < _minBuild;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final DateTime? last = _lastCheck;
    if (_required ||
        last == null ||
        DateTime.now().difference(last) > _minGap) {
      _check();
    }
  }

  Future<void> _check() async {
    if (_checking) return;
    _checking = true;
    try {
      if (_myBuild == 0) {
        final PackageInfo info = await PackageInfo.fromPlatform();
        _myBuild = int.tryParse(info.buildNumber) ?? 0;
        _myVersion = info.version;
        _package = info.packageName;
      }
      if (_myBuild == 0) return;
      final http.Response res = await http
          .get(Uri.parse('${AppConfig.workerUrl}/app-version'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return;
      final Object? body = jsonDecode(res.body);
      if (body is! Map) return;
      int asInt(Object? v) => v is num ? v.toInt() : 0;
      _lastCheck = DateTime.now();
      if (!mounted) return;
      setState(() {
        _minBuild = asInt(body['minBuild']);
        _latestBuild = asInt(body['latestBuild']);
        final Object? u = body['updateUrl'];
        _updateUrl = u is String ? u : '';
      });
      if (!_required && _myBuild < _latestBuild && !_softShown) {
        _softShown = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _showSoft());
      }
    } catch (_) {
      // Offline / timeout / bad answer: let the person use Fly.
    } finally {
      _checking = false;
    }
  }

  Future<void> _openStore() async {
    final List<Uri> tries = [
      if (_updateUrl.isNotEmpty) Uri.parse(_updateUrl),
      if (_package.isNotEmpty) Uri.parse('market://details?id=$_package'),
      if (_package.isNotEmpty)
        Uri.parse('https://play.google.com/store/apps/details?id=$_package'),
    ];
    for (final Uri u in tries) {
      try {
        if (await launchUrl(u, mode: LaunchMode.externalApplication)) return;
      } catch (_) {}
    }
  }

  void _showSoft() {
    final BuildContext? ctx = widget.navigatorKey.currentContext;
    if (ctx == null || !mounted) return;
    HapticFeedback.lightImpact();
    showModalBottomSheet<void>(
      context: ctx,
      backgroundColor: const Color(0xFF15121C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 18),
              const _UpdateIcon(size: 64),
              const SizedBox(height: 16),
              const Text(
                'A new version of Fly is ready',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text(
                'Update to get the newest features and fixes.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white70, fontSize: 14.5, height: 1.4),
              ),
              const SizedBox(height: 20),
              _Button(
                label: 'Update',
                filled: true,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openStore();
                },
              ),
              const SizedBox(height: 10),
              _Button(
                label: 'Later',
                onTap: () => Navigator.pop(sheetContext),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_required) return widget.child;
    return _UpdateRequiredScreen(
      version: _myVersion,
      buildNumber: _myBuild,
      onUpdate: _openStore,
    );
  }
}

/// Full screen over the whole app. Back closes the app (Android default
/// at the root) - there is nothing behind it to go back to.
class _UpdateRequiredScreen extends StatelessWidget {
  final String version;
  final int buildNumber;
  final VoidCallback onUpdate;

  const _UpdateRequiredScreen({
    required this.version,
    required this.buildNumber,
    required this.onUpdate,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _UpdateIcon(size: 90),
                const SizedBox(height: 22),
                const Text(
                  'Time to update Fly',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 25,
                      fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 10),
                const Text(
                  'This version of Fly is too old to keep working. Update to '
                  'the newest version - it only takes a moment, and your '
                  'account, videos and chats stay just as they are.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white70, fontSize: 14.5, height: 1.45),
                ),
                const SizedBox(height: 26),
                _Button(label: 'Update now', filled: true, onTap: onUpdate),
                const SizedBox(height: 18),
                Text(
                  'Your version: $version (build $buildNumber)',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UpdateIcon extends StatelessWidget {
  final double size;
  const _UpdateIcon({required this.size});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.8, end: 1),
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutBack,
      builder: (context, s, child) => Transform.scale(scale: s, child: child),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(colors: _flyGradient),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF9C4DFF).withValues(alpha: 0.45),
              blurRadius: 28,
            ),
          ],
        ),
        child: Icon(Icons.system_update_alt,
            color: Colors.white, size: size * 0.5),
      ),
    );
  }
}

class _Button extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool filled;

  const _Button({
    required this.label,
    required this.onTap,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: filled ? const LinearGradient(colors: _flyGradient) : null,
          color: filled ? null : Colors.white.withValues(alpha: 0.08),
        ),
        child: Text(label,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 15.5,
                fontWeight: FontWeight.w700)),
      ),
    );
  }
}
