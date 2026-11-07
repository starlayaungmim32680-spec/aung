// Sky Pass (7 Nov 2026) - Ko's own profile, Phase 1.
//
// Fly's profile is not a plain "photo + name + 3 numbers" header like
// every other app. It is:
//   - [SkyBackdrop]: a live sky behind the header that follows the
//     clock of the phone (so it is right in every country):
//       dawn 05-10, day 10-16, evening 16-19, night 19-05
//     with a sun / moon, drifting clouds, twinkling stars at night and a
//     small Fly plane that crosses now and then.
//   - [ThoughtCloud]: the Sky Note (24 h thought) as a real cloud with
//     little "thinking" puffs.
//   - [FlyPassCard]: a glass boarding pass - photo, name, "Flying since"
//     (when the account was made), POSTS / FOLLOWERS / FOLLOWING, a tear
//     line, SEAT + FLIGHT code made from the uid (always the same for one
//     person) and a decorative QR.
// [saveMyTimezoneOffset] keeps users/{uid}.tzOffsetMin up to date, so
// Phase 3 can show another person's profile in THEIR sky.
// Phase 2 (7 Nov 2026): the pass has a REAL QR = my profile link
// https://<project>.firebaseapp.com/u/<uid> (AppConfig.profileLink - an
// App Link: the phone camera opens Fly on that profile;
// firebase_hosting/public/u.html for phones without Fly), and
// [showFlyPassShareSheet] shares / saves the pass as a picture, and the
// Scan button opens Fly's own QR scanner (pass_scanner_screen.dart).
//
// Weather (7 Nov 2026, Ko: "rain -> show rain, clouds -> clouds, sun ->
// sun"): on MY OWN profile the sky also shows the real weather where I
// am - [WeatherService] asks the Worker's POST /weather (Cloudflare's
// guess of my area from my internet connection, no location permission,
// MET Norway data, 30 min cache). Conditions: clear, partly, cloudy,
// rain, thunder, fog, snow. Other people's profiles never show weather
// (it would hint where they are). Dev app only: long-press the sky chip
// to cycle through every weather for testing.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import '../app_config.dart';
import 'pass_scanner_screen.dart' show PassScannerScreen;
import 'worker_auth.dart';

// ---------------------------------------------------------------------
// Sky phases
// ---------------------------------------------------------------------

enum SkyPhase { dawn, day, evening, night }

/// Which sky goes with this local time.
SkyPhase skyPhaseFor(DateTime local) {
  final int h = local.hour;
  if (h >= 5 && h < 10) return SkyPhase.dawn;
  if (h >= 10 && h < 16) return SkyPhase.day;
  if (h >= 16 && h < 19) return SkyPhase.evening;
  return SkyPhase.night;
}

/// The phone's time in another person's sky ([offsetMinutes] = their UTC
/// offset). Null offset = my own phone time.
DateTime skyTimeFor(int? offsetMinutes) {
  if (offsetMinutes == null) return DateTime.now();
  return DateTime.now().toUtc().add(Duration(minutes: offsetMinutes));
}

class _SkyLook {
  final List<Color> colors; // top -> bottom (black is added at the end)
  final String label;
  final IconData icon;
  final double cloudAlpha;
  const _SkyLook(this.colors, this.label, this.icon, this.cloudAlpha);
}

const Map<SkyPhase, _SkyLook> _looks = {
  SkyPhase.dawn: _SkyLook(
    [Color(0xFF2B1E4F), Color(0xFFC9557A), Color(0xFFFFAE7A)],
    'Morning sky',
    Icons.wb_twilight,
    0.45,
  ),
  SkyPhase.day: _SkyLook(
    [Color(0xFF1665C8), Color(0xFF3E9BEE), Color(0xFF9FD3FF)],
    'Daytime sky',
    Icons.wb_sunny_outlined,
    0.75,
  ),
  SkyPhase.evening: _SkyLook(
    [Color(0xFF241848), Color(0xFFA53A6C), Color(0xFFFF8A4C)],
    'Evening sky',
    Icons.wb_twilight,
    0.35,
  ),
  SkyPhase.night: _SkyLook(
    [Color(0xFF04060F), Color(0xFF0B1533), Color(0xFF18234E)],
    'Night sky',
    Icons.nightlight_round,
    0.10,
  ),
};

/// Top colour of the sky right now (for the AppBar above it).
Color skyTopColor(SkyPhase phase, [SkyWeather? weather]) =>
    _skyColors(phase, weather ?? SkyWeather.unknown).first;

/// The phase colours, turned grey by bad weather.
List<Color> _skyColors(SkyPhase phase, SkyWeather w) {
  final List<Color> base = _looks[phase]!.colors;
  const Map<SkyWeather, double> amount = {
    SkyWeather.partly: 0.12,
    SkyWeather.cloudy: 0.5,
    SkyWeather.rain: 0.6,
    SkyWeather.thunder: 0.7,
    SkyWeather.fog: 0.55,
    SkyWeather.snow: 0.45,
  };
  final double k = amount[w] ?? 0;
  if (k == 0) return base;
  late Color grey;
  if (phase == SkyPhase.night) {
    grey = const Color(0xFF12151C);
  } else {
    switch (w) {
      case SkyWeather.thunder:
        grey = const Color(0xFF3B414D);
        break;
      case SkyWeather.rain:
        grey = const Color(0xFF5E6775);
        break;
      case SkyWeather.fog:
        grey = const Color(0xFF9AA2AD);
        break;
      case SkyWeather.snow:
        grey = const Color(0xFFA9B3C0);
        break;
      case SkyWeather.partly:
        grey = const Color(0xFF8A97A8);
        break;
      default:
        grey = const Color(0xFF7A8391);
    }
  }
  return [for (final Color c in base) Color.lerp(c, grey, k)!];
}

// ---------------------------------------------------------------------
// Weather (my own profile only)
// ---------------------------------------------------------------------

enum SkyWeather { clear, partly, cloudy, rain, thunder, fog, snow, unknown }

class SkyWeatherInfo {
  final SkyWeather condition;
  final int? tempC;
  const SkyWeatherInfo(this.condition, this.tempC);
}

SkyWeather _weatherFromName(Object? name) {
  for (final SkyWeather w in SkyWeather.values) {
    if (w.name == name) return w;
  }
  return SkyWeather.unknown;
}

/// Asks the Worker for the weather where I am, at most every 30 min.
class WeatherService {
  WeatherService._();

  static final ValueNotifier<SkyWeatherInfo?> current =
      ValueNotifier<SkyWeatherInfo?>(null);
  static const Duration _maxAge = Duration(minutes: 30);
  static DateTime? _fetchedAt;
  static bool _busy = false;
  static bool _testing = false;

  static Future<void> refresh() async {
    if (_busy || _testing) return;
    final DateTime? at = _fetchedAt;
    if (at != null && DateTime.now().difference(at) < _maxAge) return;
    _busy = true;
    try {
      final http.Response res = await http
          .post(
            Uri.parse('${AppConfig.workerUrl}/weather'),
            headers: {
              ...await workerAuthHeaders(),
              'Content-Type': 'application/json',
            },
            body: '{}',
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return;
      final Object? body = jsonDecode(res.body);
      if (body is! Map) return;
      final Object? t = body['tempC'];
      _fetchedAt = DateTime.now();
      if (_testing) return;
      current.value = SkyWeatherInfo(
        _weatherFromName(body['condition']),
        t is num ? t.round() : null,
      );
    } catch (_) {
      // Offline / not signed in: keep the plain time-of-day sky.
    } finally {
      _busy = false;
    }
  }

  /// Dev app only: shows the next weather (long-press the sky chip).
  static void debugCycle() {
    if (!AppConfig.isDev) return;
    _testing = true;
    final SkyWeather now = current.value?.condition ?? SkyWeather.unknown;
    final List<SkyWeather> all =
        SkyWeather.values.where((w) => w != SkyWeather.unknown).toList();
    final int i = all.indexOf(now);
    current.value =
        SkyWeatherInfo(all[(i + 1) % all.length], current.value?.tempC ?? 28);
  }
}

// ---------------------------------------------------------------------
// Time zone
// ---------------------------------------------------------------------

/// Saves my UTC offset (minutes) on my users doc when it changed - e.g.
/// after travelling or a summer-time switch. [current] = the doc's data
/// if the caller already read it (saves one read).
Future<void> saveMyTimezoneOffset(
  String uid, {
  Map<String, dynamic>? current,
}) async {
  try {
    final int offset = DateTime.now().timeZoneOffset.inMinutes;
    if (current != null && current['tzOffsetMin'] == offset) return;
    await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .set({'tzOffsetMin': offset}, SetOptions(merge: true));
  } catch (_) {
    // Offline: next app start tries again.
  }
}

// ---------------------------------------------------------------------
// The sky
// ---------------------------------------------------------------------

/// Animated sky that fills its parent (put it in a Positioned.fill).
class SkyBackdrop extends StatefulWidget {
  /// UTC offset of the sky's owner; null = this phone's own clock.
  final int? offsetMinutes;

  /// Real weather to draw (null / unknown = just the time-of-day sky).
  final SkyWeather? weather;
  const SkyBackdrop({super.key, this.offsetMinutes, this.weather});

  @override
  State<SkyBackdrop> createState() => _SkyBackdropState();
}

class _SkyBackdropState extends State<SkyBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 48),
  )..repeat();
  late SkyPhase _phase = skyPhaseFor(skyTimeFor(widget.offsetMinutes));
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    // Re-check once a minute so the sky changes while the profile is open.
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      final SkyPhase p = skyPhaseFor(skyTimeFor(widget.offsetMinutes));
      if (p != _phase && mounted) setState(() => _phase = p);
    });
  }

  @override
  void didUpdateWidget(covariant SkyBackdrop old) {
    super.didUpdateWidget(old);
    _phase = skyPhaseFor(skyTimeFor(widget.offsetMinutes));
  }

  @override
  void dispose() {
    _clock?.cancel();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final SkyWeather w = widget.weather ?? SkyWeather.unknown;
    return RepaintBoundary(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 900),
        child: CustomPaint(
          key: ValueKey('${_phase.name}-${w.name}'),
          painter: _SkyPainter(_phase, w, _anim),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _SkyPainter extends CustomPainter {
  final SkyPhase phase;
  final SkyWeather weather;
  final Animation<double> t;
  _SkyPainter(this.phase, this.weather, this.t) : super(repaint: t);

  // One loop of the animation = 48 s; "seconds" turns it into time.
  static const double _loopSeconds = 48;

  static final List<Offset> _stars = () {
    final math.Random r = math.Random(7);
    return List.generate(
        46, (_) => Offset(r.nextDouble(), r.nextDouble() * 0.75));
  }();

  // x, y start (0..1), length / size, speed
  static final List<List<double>> _drops = () {
    final math.Random r = math.Random(11);
    return List.generate(
      90,
      (_) => [
        r.nextDouble(),
        r.nextDouble(),
        10 + r.nextDouble() * 10,
        0.9 + r.nextDouble() * 0.6,
      ],
    );
  }();

  static final List<List<double>> _flakes = () {
    final math.Random r = math.Random(23);
    return List.generate(
      55,
      (_) => [
        r.nextDouble(),
        r.nextDouble(),
        1.4 + r.nextDouble() * 2.2,
        0.08 + r.nextDouble() * 0.1,
      ],
    );
  }();

  bool get _stormy =>
      weather == SkyWeather.cloudy ||
      weather == SkyWeather.rain ||
      weather == SkyWeather.thunder;

  bool get _showSunOrMoon =>
      weather == SkyWeather.clear ||
      weather == SkyWeather.partly ||
      weather == SkyWeather.unknown;

  @override
  void paint(Canvas canvas, Size size) {
    final _SkyLook look = _looks[phase]!;
    final Rect rect = Offset.zero & size;
    final double v = t.value;
    final double seconds = v * _loopSeconds;

    // Gradient that melts into the black page at the bottom.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          rect.topCenter,
          rect.bottomCenter,
          [..._skyColors(phase, weather), Colors.black],
          [0, 0.45, 0.82, 1],
        ),
    );

    // Stars (night: bright, dawn: a few fading ones) - only a clear sky.
    if (_showSunOrMoon && (phase == SkyPhase.night || phase == SkyPhase.dawn)) {
      final double base = phase == SkyPhase.night ? 0.9 : 0.25;
      for (int i = 0; i < _stars.length; i++) {
        if (phase == SkyPhase.dawn && i.isOdd) continue;
        if (weather == SkyWeather.partly && i % 3 == 0) continue;
        final double tw =
            0.55 + 0.45 * math.sin(2 * math.pi * (v * (2 + i % 3) + i * 0.37));
        final Offset p =
            Offset(_stars[i].dx * size.width, _stars[i].dy * size.height * 0.8);
        canvas.drawCircle(
          p,
          i % 7 == 0 ? 1.6 : 1.0,
          Paint()..color = Colors.white.withValues(alpha: base * tw),
        );
      }
    }

    if (_showSunOrMoon) _paintSunOrMoon(canvas, size);

    _paintClouds(canvas, size, v, look);

    if (weather == SkyWeather.fog) _paintFog(canvas, size, v);
    if (weather == SkyWeather.rain || weather == SkyWeather.thunder) {
      _paintRain(canvas, size, seconds);
    }
    if (weather == SkyWeather.snow) _paintSnow(canvas, size, seconds);
    if (weather != SkyWeather.thunder && weather != SkyWeather.fog) {
      _paintPlane(canvas, size, v);
    }
    if (weather == SkyWeather.thunder) _paintLightning(canvas, size, seconds);
  }

  void _paintSunOrMoon(Canvas canvas, Size size) {
    late Offset c;
    late double r;
    late Color color;
    switch (phase) {
      case SkyPhase.dawn:
        c = Offset(size.width * 0.18, size.height * 0.42);
        r = 26;
        color = const Color(0xFFFFD08A);
        break;
      case SkyPhase.day:
        c = Offset(size.width * 0.84, size.height * 0.12);
        r = 24;
        color = const Color(0xFFFFF3B0);
        break;
      case SkyPhase.evening:
        c = Offset(size.width * 0.82, size.height * 0.44);
        r = 30;
        color = const Color(0xFFFF7A45);
        break;
      case SkyPhase.night:
        c = Offset(size.width * 0.84, size.height * 0.13);
        r = 18;
        color = const Color(0xFFF2F0E6);
        break;
    }
    // Glow
    canvas.drawCircle(
      c,
      r * 2.6,
      Paint()
        ..shader = ui.Gradient.radial(c, r * 2.6, [
          color.withValues(alpha: phase == SkyPhase.night ? 0.18 : 0.45),
          color.withValues(alpha: 0),
        ]),
    );
    canvas.drawCircle(c, r, Paint()..color = color);
    if (phase == SkyPhase.night) {
      // Crescent: cover part of the moon with the sky colour.
      canvas.drawCircle(c + Offset(r * 0.55, -r * 0.25), r * 0.92,
          Paint()..color = _skyColors(SkyPhase.night, weather).first);
    }
    // Partly cloudy: one cloud over the sun / moon.
    if (weather == SkyWeather.partly) {
      _cloud(
        canvas,
        c + Offset(-r * 0.4, r * 0.7),
        r / 18,
        Paint()
          ..color = Colors.white
              .withValues(alpha: phase == SkyPhase.night ? 0.35 : 0.92)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
    }
  }

  void _paintClouds(Canvas canvas, Size size, double v, _SkyLook look) {
    // startX, y, scale, speed
    const List<List<double>> all = [
      [0.05, 0.16, 1.0, 1],
      [0.55, 0.32, 0.7, 2],
      [0.85, 0.08, 0.55, 1],
      [0.30, 0.05, 1.3, 1],
      [0.70, 0.22, 1.1, 2],
      [0.15, 0.36, 0.9, 1],
      [0.45, 0.14, 1.4, 1],
    ];
    late int count;
    late Color color;
    late double alpha;
    late double grow;
    final bool night = phase == SkyPhase.night;
    switch (weather) {
      case SkyWeather.partly:
        count = 5;
        color = Colors.white;
        alpha = night ? 0.22 : math.max(look.cloudAlpha, 0.7);
        grow = 1;
        break;
      case SkyWeather.cloudy:
      case SkyWeather.rain:
      case SkyWeather.thunder:
        count = 7;
        color = night
            ? const Color(0xFF39404F)
            : (weather == SkyWeather.cloudy
                ? const Color(0xFFC9D0DA)
                : const Color(0xFF8E97A5));
        alpha = 0.9;
        grow = 1.35;
        break;
      case SkyWeather.snow:
        count = 6;
        color = const Color(0xFFE4E9F0);
        alpha = night ? 0.3 : 0.85;
        grow = 1.25;
        break;
      case SkyWeather.fog:
        count = 3;
        color = Colors.white;
        alpha = 0.25;
        grow = 1;
        break;
      default:
        count = 3;
        color = Colors.white;
        alpha = look.cloudAlpha;
        grow = 1;
    }
    final Paint p = Paint()
      ..color = color.withValues(alpha: alpha)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, _stormy ? 8 : 6);
    for (int i = 0; i < count; i++) {
      final List<double> c = all[i];
      final double span = size.width + 200;
      final double x = ((c[0] + v * c[3]) % 1.0) * span - 100;
      _cloud(canvas, Offset(x, c[1] * size.height), c[2] * grow, p);
    }
  }

  void _cloud(Canvas canvas, Offset o, double s, Paint p) {
    canvas.drawOval(
        Rect.fromCenter(center: o, width: 90 * s, height: 26 * s), p);
    canvas.drawCircle(o + Offset(-16 * s, -10 * s), 16 * s, p);
    canvas.drawCircle(o + Offset(10 * s, -14 * s), 20 * s, p);
  }

  void _paintRain(Canvas canvas, Size size, double seconds) {
    final bool heavy = weather == SkyWeather.thunder;
    final Paint p = Paint()
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: heavy ? 0.55 : 0.45);
    const double slant = 0.18; // a little wind
    final int n = heavy ? _drops.length : 65;
    for (int i = 0; i < n; i++) {
      final List<double> d = _drops[i];
      // ~1.1 screen heights per second
      final double y =
          ((d[1] + seconds * 1.1 * d[3]) % 1.0) * (size.height + 40) - 20;
      final double x = (d[0] * (size.width + 40) - 20) + y * slant;
      final double len = d[2] * (heavy ? 1.3 : 1);
      canvas.drawLine(Offset(x, y), Offset(x - len * slant, y - len), p);
    }
  }

  void _paintSnow(Canvas canvas, Size size, double seconds) {
    final Paint p = Paint()..color = Colors.white.withValues(alpha: 0.9);
    for (int i = 0; i < _flakes.length; i++) {
      final List<double> f = _flakes[i];
      final double y =
          ((f[1] + seconds * f[3]) % 1.0) * (size.height + 20) - 10;
      final double x =
          f[0] * size.width + 10 * math.sin(seconds * 0.9 + i * 1.7);
      canvas.drawCircle(Offset(x, y), f[2], p);
    }
  }

  void _paintFog(Canvas canvas, Size size, double v) {
    for (int i = 0; i < 4; i++) {
      final double y = size.height * (0.18 + i * 0.17);
      final double dx =
          math.sin(2 * math.pi * (v + i * 0.27)) * size.width * 0.08;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(size.width / 2 + dx, y),
            width: size.width * 1.4,
            height: 46,
          ),
          const Radius.circular(23),
        ),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.18)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
      );
    }
  }

  // Two quick flashes every 8 seconds, with a bolt on the first one.
  void _paintLightning(Canvas canvas, Size size, double seconds) {
    final double f = seconds % 8.0;
    double flash = 0;
    if (f < 0.12) {
      flash = 1 - f / 0.12;
    } else if (f > 0.25 && f < 0.35) {
      flash = 0.6 * (1 - (f - 0.25) / 0.1);
    }
    if (flash <= 0) return;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.white.withValues(alpha: 0.28 * flash),
    );
    if (f < 0.12) {
      // Which bolt: changes every flash.
      final int k = (seconds / 8).floor();
      final double x0 = size.width * (0.25 + 0.5 * ((k * 37) % 10) / 10);
      final double y1 = size.height * 0.62;
      final Path bolt = Path()
        ..moveTo(x0, size.height * 0.10)
        ..lineTo(x0 - 14, size.height * 0.30)
        ..lineTo(x0 + 4, size.height * 0.30)
        ..lineTo(x0 - 18, y1)
        ..lineTo(x0 + 16, size.height * 0.24)
        ..lineTo(x0 - 2, size.height * 0.24)
        ..lineTo(x0 + 12, size.height * 0.10)
        ..close();
      canvas.drawPath(
        bolt,
        Paint()
          ..color = const Color(0xFFFFF6C8).withValues(alpha: flash)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
      );
    }
  }

  // A small Fly plane crosses during the first third of every loop.
  void _paintPlane(Canvas canvas, Size size, double v) {
    const double window = 0.34;
    if (v > window) return;
    final double k = v / window; // 0..1 across the screen
    final double x = -30 + k * (size.width + 60);
    final double y = size.height * (0.30 - 0.12 * k);
    final Color ink = phase == SkyPhase.day
        ? Colors.white
        : Colors.white.withValues(alpha: 0.85);

    // Contrail
    canvas.drawLine(
      Offset(x - 90, y + 14),
      Offset(x - 8, y + 2),
      Paint()
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..shader = ui.Gradient.linear(
          Offset(x - 90, y + 14),
          Offset(x - 8, y + 2),
          [ink.withValues(alpha: 0), ink.withValues(alpha: 0.6)],
        ),
    );

    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(Icons.flight.codePoint),
        style: TextStyle(
          fontSize: 18,
          fontFamily: Icons.flight.fontFamily,
          package: Icons.flight.fontPackage,
          color: ink,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(x, y);
    canvas.rotate(math.pi / 2 - 0.14); // nose to the right, climbing
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SkyPainter old) =>
      old.phase != phase || old.weather != weather;
}

/// Small glass chip: "Night sky · 21:40" or "Rainy · 15:20 · 28°".
class SkyClockChip extends StatefulWidget {
  final int? offsetMinutes;
  final SkyWeatherInfo? weather;
  const SkyClockChip({super.key, this.offsetMinutes, this.weather});

  @override
  State<SkyClockChip> createState() => _SkyClockChipState();
}

class _SkyClockChipState extends State<SkyClockChip> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static (String, IconData)? _weatherLabel(SkyWeather w, SkyPhase phase) {
    switch (w) {
      case SkyWeather.clear:
        if (phase == SkyPhase.night) {
          return ('Clear night', Icons.nightlight_round);
        }
        if (phase == SkyPhase.day) return ('Sunny', Icons.wb_sunny_outlined);
        return ('Clear sky', Icons.wb_twilight);
      case SkyWeather.partly:
        return ('Partly cloudy', Icons.wb_cloudy_outlined);
      case SkyWeather.cloudy:
        return ('Cloudy', Icons.cloud_outlined);
      case SkyWeather.rain:
        return ('Rainy', Icons.umbrella_outlined);
      case SkyWeather.thunder:
        return ('Thunderstorm', Icons.thunderstorm_outlined);
      case SkyWeather.fog:
        return ('Foggy', Icons.foggy);
      case SkyWeather.snow:
        return ('Snowy', Icons.ac_unit);
      case SkyWeather.unknown:
        return null;
    }
  }

  void _showSource() {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('Weather near you, from your internet connection. '
            'Data: MET Norway.'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final DateTime now = skyTimeFor(widget.offsetMinutes);
    final SkyPhase phase = skyPhaseFor(now);
    final _SkyLook look = _looks[phase]!;
    final String hh = now.hour.toString().padLeft(2, '0');
    final String mm = now.minute.toString().padLeft(2, '0');

    final SkyWeatherInfo? w = widget.weather;
    final (String, IconData)? wl =
        w == null ? null : _weatherLabel(w.condition, phase);
    String text = '${wl?.$1 ?? look.label} · $hh:$mm';
    if (wl != null && w?.tempC != null) text += ' · ${w!.tempC}°';

    final Widget chip = AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(wl?.$2 ?? look.icon, size: 13, color: Colors.white),
          const SizedBox(width: 5),
          Text(text,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
    if (w == null && !AppConfig.isDev) return chip;
    return GestureDetector(
      onTap: wl != null ? _showSource : null,
      onLongPress: AppConfig.isDev ? WeatherService.debugCycle : null,
      child: chip,
    );
  }
}

// ---------------------------------------------------------------------
// Thought cloud (Sky Note)
// ---------------------------------------------------------------------

/// The Sky Note as a cloud. [onTap] null = someone else's profile
/// (read-only; nothing shows when there is no live note).
class ThoughtCloud extends StatefulWidget {
  final String? text;
  final DateTime? createdAt;
  final VoidCallback? onTap;
  const ThoughtCloud({
    super.key,
    required this.text,
    required this.createdAt,
    this.onTap,
  });

  @override
  State<ThoughtCloud> createState() => _ThoughtCloudState();
}

class _ThoughtCloudState extends State<ThoughtCloud>
    with SingleTickerProviderStateMixin {
  late final AnimationController _float = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _float.dispose();
    super.dispose();
  }

  bool get _live {
    final String? t = widget.text;
    final DateTime? at = widget.createdAt;
    if (t == null || t.trim().isEmpty || at == null) return false;
    return DateTime.now().difference(at) < const Duration(hours: 24);
  }

  @override
  Widget build(BuildContext context) {
    final bool live = _live;
    if (!live && widget.onTap == null) return const SizedBox.shrink();

    final Widget cloud = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          constraints: const BoxConstraints(maxWidth: 250),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: live ? 0.94 : 0.18),
            borderRadius: BorderRadius.circular(22),
            border: live
                ? null
                : Border.all(color: Colors.white.withValues(alpha: 0.5)),
            boxShadow: live
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                live ? Icons.cloud : Icons.add,
                size: 15,
                color: live ? const Color(0xFF3A8DFF) : Colors.white,
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  live ? widget.text!.trim() : 'Share a thought',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: live ? const Color(0xFF1B1B2F) : Colors.white,
                    fontSize: 13,
                    height: 1.3,
                    fontWeight: live ? FontWeight.w600 : FontWeight.w500,
                    fontStyle: live ? FontStyle.normal : FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ),
        // Thinking puffs down toward the pass.
        Padding(
          padding: const EdgeInsets.only(top: 4, right: 40),
          child: Column(
            children: [
              _puff(9, live),
              const SizedBox(height: 3),
              Padding(
                padding: const EdgeInsets.only(left: 14),
                child: _puff(5, live),
              ),
            ],
          ),
        ),
      ],
    );

    final Widget floating = AnimatedBuilder(
      animation: _float,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, 4 * (_float.value - 0.5)),
        child: child,
      ),
      child: cloud,
    );
    if (widget.onTap == null) return floating;
    return GestureDetector(onTap: widget.onTap, child: floating);
  }

  Widget _puff(double d, bool live) => Container(
        width: d,
        height: d,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: live ? 0.9 : 0.35),
        ),
      );
}

// ---------------------------------------------------------------------
// The pass
// ---------------------------------------------------------------------

int _fnv(String s) {
  int h = 0x811C9DC5;
  for (final int c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

/// "14C" - row 1..40, seat A..F, always the same for one uid.
String flySeatFor(String uid) {
  final int h = _fnv(uid);
  return '${h % 40 + 1}${'ABCDEF'[(h >> 8) % 6]}';
}

/// "FL-7K2Q" - always the same for one uid.
String flyCodeFor(String uid) {
  const String abc = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  int h = _fnv('fly:$uid');
  final StringBuffer b = StringBuffer('FL-');
  for (int i = 0; i < 4; i++) {
    b.write(abc[h % abc.length]);
    h = h ~/ abc.length;
  }
  return b.toString();
}

const List<String> _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

class FlyPassCard extends StatelessWidget {
  final String uid;
  final String name;
  final String? photoUrl;
  final DateTime? flyingSince;
  final int posts;
  final int followers;
  final int following;
  final VoidCallback? onEdit;
  final VoidCallback? onShare;

  /// Opens the Fly Pass scanner (my own profile).
  final VoidCallback? onScan;

  /// Text in the QR (my profile link). Null = a decorative QR.
  final String? qrData;

  /// Frosted glass over the sky. Off for the shared picture
  /// (RenderRepaintBoundary.toImage can't see what is behind a blur).
  final bool blur;

  const FlyPassCard({
    super.key,
    required this.uid,
    required this.name,
    required this.photoUrl,
    required this.flyingSince,
    required this.posts,
    required this.followers,
    required this.following,
    this.onEdit,
    this.onShare,
    this.onScan,
    this.qrData,
    this.blur = true,
  });

  @override
  Widget build(BuildContext context) {
    final bool hasPhoto = photoUrl != null && photoUrl!.isNotEmpty;
    final DateTime? since = flyingSince?.toLocal();
    return ClipPath(
      clipper: _TicketClipper(notchY: 150),
      child: BackdropFilter(
        enabled: blur,
        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: blur ? 0.20 : 0.24),
                Colors.white.withValues(alpha: blur ? 0.07 : 0.10),
              ],
            ),
          ),
          child: CustomPaint(
            painter: _TicketBorderPainter(notchY: 150),
            child: Column(
              children: [
                SizedBox(
                  height: 150,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.flight_takeoff,
                                color: Colors.white, size: 15),
                            const SizedBox(width: 6),
                            // Expanded (not Spacer) so 3 buttons fit on
                            // small phones too - the label fades instead.
                            const Expanded(
                              child: Text('FLY PASS',
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow: TextOverflow.fade,
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 11.5,
                                      letterSpacing: 2.2,
                                      fontWeight: FontWeight.w800)),
                            ),
                            if (onScan != null) ...[
                              _pill(Icons.qr_code_scanner, null, onScan!),
                              const SizedBox(width: 6),
                            ],
                            if (onShare != null)
                              _pill(Icons.ios_share, 'Share', onShare!),
                            if (onShare != null && onEdit != null)
                              const SizedBox(width: 6),
                            if (onEdit != null)
                              GestureDetector(
                                onTap: onEdit,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.16),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.edit,
                                          size: 12, color: Colors.white),
                                      SizedBox(width: 4),
                                      Text('Edit',
                                          style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w700)),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(2.5),
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(colors: [
                                  Color(0xFFFF4B6E),
                                  Color(0xFF9C4DFF),
                                  Color(0xFF3A8DFF),
                                ]),
                              ),
                              child: CircleAvatar(
                                radius: 33,
                                backgroundColor: const Color(0xFF22263A),
                                backgroundImage:
                                    hasPhoto ? NetworkImage(photoUrl!) : null,
                                child: hasPhoto
                                    ? null
                                    : Text(
                                        name.isNotEmpty
                                            ? name[0].toUpperCase()
                                            : '?',
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 26,
                                            fontWeight: FontWeight.bold),
                                      ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('PASSENGER',
                                      style: TextStyle(
                                          color: Colors.white60,
                                          fontSize: 9.5,
                                          letterSpacing: 1.6,
                                          fontWeight: FontWeight.w700)),
                                  const SizedBox(height: 2),
                                  Text(name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 21,
                                          fontWeight: FontWeight.w800)),
                                  if (since != null) ...[
                                    const SizedBox(height: 3),
                                    Text(
                                      'Flying since '
                                      '${_months[since.month - 1]} ${since.year}',
                                      style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 12.5),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          _stat('POSTS', posts),
                          _stat('FOLLOWERS', followers),
                          _stat('FOLLOWING', following),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _field('SEAT', flySeatFor(uid)),
                          const SizedBox(width: 22),
                          _field('FLIGHT', flyCodeFor(uid)),
                          const Spacer(),
                          if (qrData != null)
                            // Tap = the QR big, easy to scan (Ko, 7 Nov).
                            GestureDetector(
                              onTap: () => showBigFlyQr(context, qrData!, name),
                              child: Container(
                                padding: const EdgeInsets.all(3),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: _FlyQr(data: qrData!, size: 52),
                              ),
                            )
                          else
                            SizedBox(
                              width: 46,
                              height: 46,
                              child: CustomPaint(
                                  painter: _FakeQrPainter(_fnv('qr:$uid'))),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // label null = icon only (Scan).
  Widget _pill(IconData icon, String? label, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(
              horizontal: label == null ? 7 : 10, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: label == null ? 15 : 12, color: Colors.white),
              if (label != null) ...[
                const SizedBox(width: 4),
                Text(label,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700)),
              ],
            ],
          ),
        ),
      );

  Widget _stat(String label, int value) => Expanded(
        child: Column(
          children: [
            Text(_compact(value),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 9.5,
                    letterSpacing: 1.3,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      );

  Widget _field(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 9.5,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w800,
                  fontFeatures: [ui.FontFeature.tabularFigures()])),
        ],
      );

  static String _compact(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) {
      final double k = n / 1000;
      return '${k.toStringAsFixed(k < 10 ? 1 : 0)}K';
    }
    final double m = n / 1000000;
    return '${m.toStringAsFixed(m < 10 ? 1 : 0)}M';
  }
}

/// Rounded card with two half-circle notches at the tear line.
class _TicketClipper extends CustomClipper<Path> {
  final double notchY;
  _TicketClipper({required this.notchY});

  static Path ticketPath(Size size, double notchY) {
    const double r = 22; // corner
    const double n = 11; // notch radius
    final Path card = Path()
      ..addRRect(RRect.fromRectAndRadius(
          Offset.zero & size, const Radius.circular(r)));
    final Path notches = Path()
      ..addOval(Rect.fromCircle(center: Offset(0, notchY), radius: n))
      ..addOval(Rect.fromCircle(center: Offset(size.width, notchY), radius: n));
    return Path.combine(PathOperation.difference, card, notches);
  }

  @override
  Path getClip(Size size) => ticketPath(size, notchY);

  @override
  bool shouldReclip(covariant _TicketClipper old) => old.notchY != notchY;
}

class _TicketBorderPainter extends CustomPainter {
  final double notchY;
  _TicketBorderPainter({required this.notchY});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      _TicketClipper.ticketPath(size, notchY),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withValues(alpha: 0.32),
    );
    // Dashed tear line
    final Paint dash = Paint()
      ..strokeWidth = 1.4
      ..color = Colors.white.withValues(alpha: 0.38);
    for (double x = 18; x < size.width - 18; x += 10) {
      canvas.drawLine(Offset(x, notchY), Offset(x + 5, notchY), dash);
    }
  }

  @override
  bool shouldRepaint(covariant _TicketBorderPainter old) =>
      old.notchY != notchY;
}

/// Looks like a QR code (decoration only - Phase 2 makes a real one).
class _FakeQrPainter extends CustomPainter {
  final int seed;
  _FakeQrPainter(this.seed);

  @override
  void paint(Canvas canvas, Size size) {
    const int n = 13;
    final double c = size.width / n;
    final Paint on = Paint()..color = Colors.white.withValues(alpha: 0.92);
    final math.Random r = math.Random(seed);

    bool inFinder(int x, int y) =>
        (x < 4 && y < 4) || (x >= n - 4 && y < 4) || (x < 4 && y >= n - 4);

    for (int y = 0; y < n; y++) {
      for (int x = 0; x < n; x++) {
        if (inFinder(x, y)) continue;
        if (r.nextBool()) {
          canvas.drawRect(Rect.fromLTWH(x * c, y * c, c, c), on);
        }
      }
    }
    void finder(double ox, double oy) {
      final Paint ring = Paint()
        ..color = on.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = c * 0.8;
      canvas.drawRect(
          Rect.fromLTWH(ox + c * 0.4, oy + c * 0.4, c * 2.6, c * 2.6), ring);
      canvas.drawRect(Rect.fromLTWH(ox + c * 1.2, oy + c * 1.2, c, c), on);
    }

    finder(0, 0);
    finder(size.width - c * 3.4, 0);
    finder(0, size.height - c * 3.4);
  }

  @override
  bool shouldRepaint(covariant _FakeQrPainter old) => old.seed != seed;
}

// ---------------------------------------------------------------------
// The whole header
// ---------------------------------------------------------------------

/// Sky + clock chip + thought cloud + pass, for the top of a profile.
/// [showWeather] = my own profile: the sky also shows my real weather.
class SkyPassHeader extends StatefulWidget {
  final int? offsetMinutes;
  final bool showWeather;
  final Widget thought;
  final Widget pass;
  const SkyPassHeader({
    super.key,
    this.offsetMinutes,
    this.showWeather = false,
    required this.thought,
    required this.pass,
  });

  @override
  State<SkyPassHeader> createState() => _SkyPassHeaderState();
}

class _SkyPassHeaderState extends State<SkyPassHeader>
    with WidgetsBindingObserver {
  Timer? _weatherTimer;

  @override
  void initState() {
    super.initState();
    if (widget.showWeather) {
      WidgetsBinding.instance.addObserver(this);
      WeatherService.refresh();
      // refresh() itself asks the Worker at most every 30 min.
      _weatherTimer = Timer.periodic(
          const Duration(minutes: 10), (_) => WeatherService.refresh());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) WeatherService.refresh();
  }

  @override
  void dispose() {
    _weatherTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Widget _build(SkyWeatherInfo? w) {
    return Stack(
      children: [
        Positioned.fill(
          child: SkyBackdrop(
            offsetMinutes: widget.offsetMinutes,
            weather: w?.condition,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 26),
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SkyClockChip(
                  offsetMinutes: widget.offsetMinutes,
                  weather: w,
                ),
              ),
              const SizedBox(height: 26),
              widget.thought,
              const SizedBox(height: 6),
              widget.pass,
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.showWeather) return _build(null);
    return ValueListenableBuilder<SkyWeatherInfo?>(
      valueListenable: WeatherService.current,
      builder: (context, w, _) => _build(w),
    );
  }
}

// ---------------------------------------------------------------------
// Share my pass (Phase 2)
// ---------------------------------------------------------------------

/// Bottom sheet: a picture of my pass on my sky (real QR = my profile
/// link) with Share and Save.
Future<void> showFlyPassShareSheet(
  BuildContext context, {
  required String uid,
  required String name,
  required String? photoUrl,
  required DateTime? flyingSince,
  required int posts,
  required int followers,
  required int following,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF15121C),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _FlyPassShareSheet(
      pass: FlyPassCard(
        uid: uid,
        name: name,
        photoUrl: photoUrl,
        flyingSince: flyingSince,
        posts: posts,
        followers: followers,
        following: following,
        qrData: AppConfig.profileLink(uid),
        blur: false,
      ),
      link: AppConfig.profileLink(uid),
    ),
  );
}

class _FlyPassShareSheet extends StatefulWidget {
  final FlyPassCard pass;
  final String link;
  const _FlyPassShareSheet({required this.pass, required this.link});

  @override
  State<_FlyPassShareSheet> createState() => _FlyPassShareSheetState();
}

class _FlyPassShareSheetState extends State<_FlyPassShareSheet> {
  final GlobalKey _shot = GlobalKey();
  bool _busy = false;

  Future<Uint8List?> _picture() async {
    final RenderObject? ro = _shot.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary) return null;
    final ui.Image image = await ro.toImage(pixelRatio: 3);
    final ByteData? data =
        await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data?.buffer.asUint8List();
  }

  void _toast(String text) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final Uint8List? png = await _picture();
      if (png == null) throw Exception('no picture');
      final Directory dir = await getTemporaryDirectory();
      final File file = File(
          '${dir.path}/fly_pass_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(png);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/png')],
        text: 'Fly with me! ${widget.link}',
      );
    } catch (_) {
      _toast("Couldn't share your pass - please try again");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final Uint8List? png = await _picture();
      if (png == null) throw Exception('no picture');
      if (!await Gal.hasAccess()) {
        if (!await Gal.requestAccess()) {
          _toast('Gallery access is needed to save your pass');
          return;
        }
      }
      await Gal.putImageBytes(png,
          album: 'Fly',
          name: 'fly_pass_${DateTime.now().millisecondsSinceEpoch}');
      _toast('Your Fly Pass was saved to your gallery');
    } catch (_) {
      _toast("Couldn't save your pass - please try again");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final double maxH = MediaQuery.of(context).size.height * 0.62;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
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
            const SizedBox(height: 14),
            const Text('Share your Fly Pass',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text('Friends scan the code to open your profile on Fly.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60, fontSize: 13)),
            const SizedBox(height: 14),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxH),
              child: FittedBox(
                child: RepaintBoundary(
                  key: _shot,
                  child: _ShareCard(pass: widget.pass),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _SheetButton(
                    icon: Icons.download_rounded,
                    label: 'Save',
                    onTap: _busy ? null : _save,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _SheetButton(
                    icon: Icons.ios_share,
                    label: 'Share',
                    filled: true,
                    busy: _busy,
                    onTap: _busy ? null : _share,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: () {
                final NavigatorState nav = Navigator.of(context);
                nav.pop();
                nav.push(MaterialPageRoute(
                    builder: (_) => const PassScannerScreen()));
              },
              icon: const Icon(Icons.qr_code_scanner,
                  color: Color(0xFF35E1F2), size: 18),
              label: const Text("Scan a friend's pass",
                  style: TextStyle(
                      color: Color(0xFF35E1F2), fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the picture looks like: my sky (with my weather) + the pass.
class _ShareCard extends StatelessWidget {
  final FlyPassCard pass;
  const _ShareCard({required this.pass});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 360,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          children: [
            Positioned.fill(
              child: SkyBackdrop(
                weather: WeatherService.current.value?.condition,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 22, 18, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.flight_takeoff, color: Colors.white, size: 20),
                      SizedBox(width: 8),
                      Text('Fly',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.5)),
                      Spacer(),
                      Text('BOARDING NOW',
                          style: TextStyle(
                              color: Colors.white70,
                              fontSize: 10.5,
                              letterSpacing: 2,
                              fontWeight: FontWeight.w800)),
                    ],
                  ),
                  const SizedBox(height: 34),
                  pass,
                  const SizedBox(height: 16),
                  const Text('Scan to fly with me on Fly',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool filled;
  final bool busy;
  const _SheetButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = false,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null && !busy ? 0.5 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: filled
                ? const LinearGradient(colors: [
                    Color(0xFFFF4B6E),
                    Color(0xFF9C4DFF),
                    Color(0xFF3A8DFF),
                  ])
                : null,
            color: filled ? null : Colors.white.withValues(alpha: 0.08),
          ),
          child: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, color: Colors.white, size: 19),
                    const SizedBox(width: 8),
                    Text(label,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700)),
                  ],
                ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Big QR (tap the small one on the pass)
// ---------------------------------------------------------------------

class _FlyQr extends StatelessWidget {
  final String data;
  final double size;
  const _FlyQr({required this.data, required this.size});

  @override
  Widget build(BuildContext context) {
    return QrImageView(
      data: data,
      size: size,
      padding: EdgeInsets.zero,
      backgroundColor: Colors.white,
      eyeStyle: const QrEyeStyle(
        eyeShape: QrEyeShape.square,
        color: Color(0xFF15121C),
      ),
      dataModuleStyle: const QrDataModuleStyle(
        dataModuleShape: QrDataModuleShape.square,
        color: Color(0xFF15121C),
      ),
    );
  }
}

/// My QR, big in the middle of the screen, so a friend can scan it
/// easily. Tap anywhere (or Back) to close.
Future<void> showBigFlyQr(BuildContext context, String data, String name) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black.withValues(alpha: 0.82),
    transitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (ctx, _, __) {
      final double side =
          (MediaQuery.of(ctx).size.width * 0.72).clamp(220.0, 340.0);
      return GestureDetector(
        onTap: () => Navigator.of(ctx).pop(),
        child: Material(
          type: MaterialType.transparency,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF9C4DFF).withValues(alpha: 0.5),
                        blurRadius: 40,
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      _FlyQr(data: data, size: side),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.flight_takeoff,
                              color: Color(0xFF9C4DFF), size: 18),
                          const SizedBox(width: 6),
                          ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: side - 30),
                            child: Text(name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Color(0xFF15121C),
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                const Text('Scan with Fly to open my profile',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                const Text('Tap anywhere to close',
                    style: TextStyle(color: Colors.white54, fontSize: 12.5)),
              ],
            ),
          ),
        ),
      );
    },
    transitionBuilder: (ctx, anim, _, child) {
      final Animation<double> curved =
          CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
      return FadeTransition(
        opacity: anim,
        child: ScaleTransition(scale: curved, child: child),
      );
    },
  );
}
