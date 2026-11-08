// Day Scene (8 Nov 2026) - the background of Home's Flight Path story bar.
// Ko: "nature - mountains, cities, flower gardens, birds... a different one
// every day, it must not repeat every week, it must fit every country (no
// religious buildings that don't belong there), and national days per
// country - all of it at once, for the whole world".
//
// How it works:
//   - The SKY is the same live sky as the Sky Pass profile (SkyBackdrop:
//     the phone's time of day + the real weather, without its plane).
//   - The LANDSCAPE in front of it is put together from the date (and the
//     country) as a seed: terrain (mountains, hills, sea, lake, forest,
//     fields, city, dunes, snowfield), trees (pine, round, palm, cactus,
//     bare), flowers, and moving life (birds, butterflies, fireflies at
//     night, hot-air balloons, kites). Hundreds of combinations - the same
//     for everyone in a country on one day, different the next day, not a
//     7-day loop.
//   - Only NATURE and plain buildings - no temples, churches, mosques or
//     any religious / cultural symbol, so it suits every country.
//   - The CLIMATE comes from the Worker's /weather answer (SkyWeatherInfo
//     .country / .zone / .south): palms in the tropics, snow and bare trees
//     in a northern (or southern) winter, dunes and cacti in desert
//     countries, snowfields near the poles.
//   - NATIONAL DAYS: [kNationalDays] (fixed-date independence / national /
//     republic days of ~100 countries, happy days only - no solemn or
//     contested ones) + New Year for everyone -> fireworks and "Happy ...!".
//   - 8 Nov (Ko's first look): nights were too dark, the land too small
//     and the sea had no light -> moonlit blue night colours, the land
//     takes ~45% of the bar with bigger trees / buildings, and a moon
//     (or sun) path shimmers on the sea and the lake.
//   - Dev app only: long-press the story bar = the next day's scene
//     (every 5th press previews a national day).
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../app_config.dart';
import 'sky_pass.dart';

// ---------------------------------------------------------------------
// National days (month, day, name) - fixed dates only, celebrations only.
// ---------------------------------------------------------------------
const Map<String, List<List<Object>>> kNationalDays = {
  'MM': [
    [1, 4, 'Independence Day'],
    [2, 12, 'Union Day']
  ],
  'MY': [
    [8, 31, 'Merdeka Day'],
    [9, 16, 'Malaysia Day']
  ],
  'TH': [
    [12, 5, 'National Day']
  ],
  'SG': [
    [8, 9, 'National Day']
  ],
  'ID': [
    [8, 17, 'Independence Day']
  ],
  'PH': [
    [6, 12, 'Independence Day']
  ],
  'VN': [
    [9, 2, 'National Day']
  ],
  'KH': [
    [11, 9, 'Independence Day']
  ],
  'LA': [
    [12, 2, 'National Day']
  ],
  'BN': [
    [2, 23, 'National Day']
  ],
  'TL': [
    [11, 28, 'Independence Day']
  ],
  'IN': [
    [1, 26, 'Republic Day'],
    [8, 15, 'Independence Day']
  ],
  'PK': [
    [3, 23, 'Pakistan Day'],
    [8, 14, 'Independence Day']
  ],
  'BD': [
    [3, 26, 'Independence Day'],
    [12, 16, 'Victory Day']
  ],
  'LK': [
    [2, 4, 'Independence Day']
  ],
  'BT': [
    [12, 17, 'National Day']
  ],
  'MV': [
    [7, 26, 'Independence Day']
  ],
  'CN': [
    [10, 1, 'National Day']
  ],
  'TW': [
    [10, 10, 'National Day']
  ],
  'JP': [
    [2, 11, 'National Foundation Day']
  ],
  'KR': [
    [8, 15, 'Liberation Day'],
    [10, 3, 'National Foundation Day']
  ],
  'MN': [
    [7, 11, 'Naadam Festival']
  ],
  'US': [
    [7, 4, 'Independence Day']
  ],
  'CA': [
    [7, 1, 'Canada Day']
  ],
  'MX': [
    [9, 16, 'Independence Day']
  ],
  'BR': [
    [9, 7, 'Independence Day']
  ],
  'AR': [
    [5, 25, 'May Revolution Day'],
    [7, 9, 'Independence Day']
  ],
  'CL': [
    [9, 18, 'National Day']
  ],
  'CO': [
    [7, 20, 'Independence Day']
  ],
  'PE': [
    [7, 28, 'Independence Day']
  ],
  'VE': [
    [7, 5, 'Independence Day']
  ],
  'EC': [
    [8, 10, 'Independence Day']
  ],
  'BO': [
    [8, 6, 'Independence Day']
  ],
  'PY': [
    [5, 15, 'Independence Day']
  ],
  'UY': [
    [8, 25, 'Independence Day']
  ],
  'GT': [
    [9, 15, 'Independence Day']
  ],
  'HN': [
    [9, 15, 'Independence Day']
  ],
  'SV': [
    [9, 15, 'Independence Day']
  ],
  'NI': [
    [9, 15, 'Independence Day']
  ],
  'CR': [
    [9, 15, 'Independence Day']
  ],
  'PA': [
    [11, 3, 'Independence Day']
  ],
  'DO': [
    [2, 27, 'Independence Day']
  ],
  'JM': [
    [8, 6, 'Independence Day']
  ],
  'TT': [
    [8, 31, 'Independence Day']
  ],
  'IE': [
    [3, 17, "St Patrick's Day"]
  ],
  'FR': [
    [7, 14, 'Bastille Day']
  ],
  'DE': [
    [10, 3, 'German Unity Day']
  ],
  'IT': [
    [6, 2, 'Republic Day']
  ],
  'PT': [
    [6, 10, 'Portugal Day']
  ],
  'NL': [
    [4, 27, "King's Day"]
  ],
  'BE': [
    [7, 21, 'National Day']
  ],
  'LU': [
    [6, 23, 'National Day']
  ],
  'CH': [
    [8, 1, 'Swiss National Day']
  ],
  'AT': [
    [10, 26, 'National Day']
  ],
  'PL': [
    [5, 3, 'Constitution Day'],
    [11, 11, 'Independence Day']
  ],
  'CZ': [
    [10, 28, 'Independence Day']
  ],
  'RO': [
    [12, 1, 'Great Union Day']
  ],
  'BG': [
    [3, 3, 'Liberation Day']
  ],
  'GR': [
    [3, 25, 'Independence Day']
  ],
  'TR': [
    [10, 29, 'Republic Day']
  ],
  'RU': [
    [6, 12, 'Russia Day']
  ],
  'UA': [
    [8, 24, 'Independence Day']
  ],
  'FI': [
    [12, 6, 'Independence Day']
  ],
  'SE': [
    [6, 6, 'National Day']
  ],
  'NO': [
    [5, 17, 'Constitution Day']
  ],
  'DK': [
    [6, 5, 'Constitution Day']
  ],
  'IS': [
    [6, 17, 'National Day']
  ],
  'EE': [
    [2, 24, 'Independence Day']
  ],
  'LV': [
    [11, 18, 'Independence Day']
  ],
  'LT': [
    [2, 16, 'Independence Day']
  ],
  'HR': [
    [5, 30, 'Statehood Day']
  ],
  'RS': [
    [2, 15, 'Statehood Day']
  ],
  'SI': [
    [6, 25, 'Statehood Day']
  ],
  'GE': [
    [5, 26, 'Independence Day']
  ],
  'AM': [
    [9, 21, 'Independence Day']
  ],
  'AZ': [
    [5, 28, 'Independence Day']
  ],
  'KZ': [
    [12, 16, 'Independence Day']
  ],
  'UZ': [
    [9, 1, 'Independence Day']
  ],
  'KG': [
    [8, 31, 'Independence Day']
  ],
  'TJ': [
    [9, 9, 'Independence Day']
  ],
  'TM': [
    [9, 27, 'Independence Day']
  ],
  'IQ': [
    [10, 3, 'National Day']
  ],
  'SA': [
    [2, 22, 'Founding Day'],
    [9, 23, 'Saudi National Day']
  ],
  'AE': [
    [12, 2, 'National Day']
  ],
  'QA': [
    [12, 18, 'National Day']
  ],
  'KW': [
    [2, 25, 'National Day']
  ],
  'BH': [
    [12, 16, 'National Day']
  ],
  'OM': [
    [11, 20, 'National Day']
  ],
  'JO': [
    [5, 25, 'Independence Day']
  ],
  'LB': [
    [11, 22, 'Independence Day']
  ],
  'MA': [
    [11, 18, 'Independence Day']
  ],
  'DZ': [
    [7, 5, 'Independence Day']
  ],
  'TN': [
    [3, 20, 'Independence Day']
  ],
  'NG': [
    [10, 1, 'Independence Day']
  ],
  'GH': [
    [3, 6, 'Independence Day']
  ],
  'KE': [
    [12, 12, 'Jamhuri Day']
  ],
  'TZ': [
    [12, 9, 'Independence Day']
  ],
  'UG': [
    [10, 9, 'Independence Day']
  ],
  'ZA': [
    [4, 27, 'Freedom Day']
  ],
  'ZW': [
    [4, 18, 'Independence Day']
  ],
  'SN': [
    [4, 4, 'Independence Day']
  ],
  'CI': [
    [8, 7, 'Independence Day']
  ],
  'CM': [
    [5, 20, 'National Day']
  ],
  'FJ': [
    [10, 10, 'Fiji Day']
  ],
  'PG': [
    [9, 16, 'Independence Day']
  ],
};

/// Today's celebration for [country] on [day] (local date), or null.
String? nationalDayFor(String? country, DateTime day) {
  if (day.month == 1 && day.day == 1) return 'New Year';
  final List<List<Object>>? days = kNationalDays[country];
  if (days == null) return null;
  for (final List<Object> d in days) {
    if (d[0] == day.month && d[1] == day.day) return d[2] as String;
  }
  return null;
}

// ---------------------------------------------------------------------
// The day's recipe
// ---------------------------------------------------------------------
enum Terrain {
  mountains,
  hills,
  sea,
  lake,
  forest,
  fields,
  city,
  dunes,
  snowfield
}

enum TreeKind { pine, round, palm, cactus, bare }

enum Life { birds, butterflies, fireflies, balloons, kites }

class DaySceneSpec {
  final int seed;
  final Terrain terrain;
  final TreeKind tree;
  final bool winter;
  final bool flowers;
  final List<Life> life;
  final String? holiday;
  const DaySceneSpec({
    required this.seed,
    required this.terrain,
    required this.tree,
    required this.winter,
    required this.flowers,
    required this.life,
    required this.holiday,
  });

  String get label =>
      '${terrain.name} · ${tree.name}${winter ? ' · winter' : ''} · '
      '${life.map((l) => l.name).join('+')}'
      '${holiday != null ? ' · $holiday' : ''}';

  static int _hash(String s) {
    int h = 0x811C9DC5;
    for (final int c in s.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0x7FFFFFFF;
    }
    return h;
  }

  static T _pick<T>(Random r, List<T> list) => list[r.nextInt(list.length)];

  factory DaySceneSpec.forDay(
    DateTime local,
    SkyWeatherInfo? geo, {
    int debugShift = 0,
  }) {
    final DateTime day = DateTime(local.year, local.month, local.day)
        .add(Duration(days: debugShift));
    final String country = geo?.country ?? '';
    final int seed = _hash('${day.year}-${day.month}-${day.day}-$country');
    final Random r = Random(seed);
    final String zone = geo?.zone ?? 'temperate';
    final bool south = geo?.south ?? false;
    final int m = day.month;
    final bool coldMonths = south ? (m >= 6 && m <= 8) : (m == 12 || m <= 2);
    final bool winter = zone == 'polar' || (zone == 'temperate' && coldMonths);

    late Terrain terrain;
    late TreeKind tree;
    switch (zone) {
      case 'tropical':
        terrain = _pick(r, const [
          Terrain.sea,
          Terrain.hills,
          Terrain.lake,
          Terrain.forest,
          Terrain.fields,
          Terrain.city,
          Terrain.mountains,
          Terrain.sea,
        ]);
        tree = _pick(r, const [TreeKind.palm, TreeKind.round, TreeKind.palm]);
        break;
      case 'arid':
        terrain = _pick(r, const [
          Terrain.dunes,
          Terrain.dunes,
          Terrain.mountains,
          Terrain.city,
          Terrain.sea,
        ]);
        tree = _pick(r, const [TreeKind.palm, TreeKind.cactus]);
        break;
      case 'polar':
        terrain = _pick(r, const [
          Terrain.snowfield,
          Terrain.mountains,
          Terrain.lake,
          Terrain.forest,
        ]);
        tree = TreeKind.pine;
        break;
      default: // temperate
        terrain = winter
            ? _pick(r, const [
                Terrain.snowfield,
                Terrain.mountains,
                Terrain.forest,
                Terrain.city,
                Terrain.lake,
                Terrain.hills,
              ])
            : _pick(r, const [
                Terrain.mountains,
                Terrain.hills,
                Terrain.sea,
                Terrain.lake,
                Terrain.forest,
                Terrain.fields,
                Terrain.city,
              ]);
        tree = winter
            ? _pick(r, const [TreeKind.pine, TreeKind.bare])
            : _pick(r, const [TreeKind.pine, TreeKind.round, TreeKind.round]);
    }

    final SkyPhase phase = skyPhaseFor(local);
    final List<Life> life = [];
    if (phase == SkyPhase.night) {
      if (!winter && zone != 'arid') life.add(Life.fireflies);
    } else {
      final List<Life> pool = [
        Life.birds,
        Life.balloons,
        Life.kites,
        if (!winter && zone != 'polar') Life.butterflies,
      ];
      life.add(_pick(r, pool));
      if (r.nextBool()) {
        final Life second = _pick(r, pool);
        if (!life.contains(second)) life.add(second);
      }
    }

    final String? holiday = debugShift != 0 && debugShift % 5 == 4
        ? 'Independence Day'
        : nationalDayFor(country, day);

    return DaySceneSpec(
      seed: seed,
      terrain: terrain,
      tree: tree,
      winter: winter,
      flowers: !winter && zone != 'polar' && r.nextInt(3) > 0,
      life: life,
      holiday: holiday,
    );
  }
}

// ---------------------------------------------------------------------
// The widget
// ---------------------------------------------------------------------

/// Dev app only: days added to today (long-press the bar's plane).
final ValueNotifier<int> daySceneDebugShift = ValueNotifier<int>(0);

/// The whole background (sky + today's landscape + life + fireworks).
class DayScene extends StatefulWidget {
  const DayScene({super.key});

  /// Dev app only: shows the next day's scene, returns its description.
  static String debugNextDay() {
    if (!AppConfig.isDev) return '';
    daySceneDebugShift.value++;
    return DaySceneSpec.forDay(
      DateTime.now(),
      WeatherService.current.value,
      debugShift: daySceneDebugShift.value,
    ).label;
  }

  @override
  State<DayScene> createState() => _DaySceneState();
}

class _DaySceneState extends State<DayScene>
    with SingleTickerProviderStateMixin {
  late final AnimationController _life = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  )..repeat();

  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Weather + country + climate zone (at most every 30 min).
    WeatherService.refresh();
    // Dawn -> day -> evening -> night, and a new scene after midnight.
    _tick = Timer.periodic(const Duration(minutes: 5), (_) {
      WeatherService.refresh();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SkyWeatherInfo?>(
      valueListenable: WeatherService.current,
      builder: (context, geo, _) => ValueListenableBuilder<int>(
        valueListenable: daySceneDebugShift,
        builder: (context, shift, _) {
          final DateTime now = DateTime.now();
          final DaySceneSpec spec =
              DaySceneSpec.forDay(now, geo, debugShift: shift);
          final SkyPhase phase = skyPhaseFor(now);
          return Stack(
            fit: StackFit.expand,
            children: [
              SkyBackdrop(weather: geo?.condition, showPlane: false),
              RepaintBoundary(
                child: CustomPaint(
                  painter:
                      _LandscapePainter(spec, phase, geo?.condition, _life),
                ),
              ),
              if (spec.holiday != null) ...[
                RepaintBoundary(
                  child: CustomPaint(
                    painter: _FireworksPainter(spec.seed, _life),
                  ),
                ),
                Positioned(
                  right: 10,
                  top: 6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color:
                              const Color(0xFFFFD27A).withValues(alpha: 0.6)),
                    ),
                    child: Text(
                      '🎆 Happy ${spec.holiday}!',
                      style: const TextStyle(
                        color: Color(0xFFFFE3A3),
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
              // Keeps the names under the circles readable.
              const IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0.7, 1],
                      colors: [Color(0x00000000), Color(0x59000000)],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Landscape
// ---------------------------------------------------------------------
class _LandscapePainter extends CustomPainter {
  final DaySceneSpec spec;
  final SkyPhase phase;
  final SkyWeather? weather;
  final Animation<double> t;
  _LandscapePainter(this.spec, this.phase, this.weather, this.t)
      : super(repaint: t);

  bool get _night => phase == SkyPhase.night;

  // Same rule as the sky: the sun / moon only shows under a clear sky.
  bool get _sunOrMoon =>
      weather == null ||
      weather == SkyWeather.clear ||
      weather == SkyWeather.partly ||
      weather == SkyWeather.unknown;

  // Silhouette colours for the far and near layers, by time of day.
  Color get _far {
    if (spec.terrain == Terrain.dunes) {
      return const {
        SkyPhase.dawn: Color(0xFFB07A55),
        SkyPhase.day: Color(0xFFD7A66A),
        SkyPhase.evening: Color(0xFF9A5A44),
        SkyPhase.night: Color(0xFF4A4266),
      }[phase]!;
    }
    if (spec.winter || spec.terrain == Terrain.snowfield) {
      return const {
        SkyPhase.dawn: Color(0xFFC9B8D6),
        SkyPhase.day: Color(0xFFDDE7F2),
        SkyPhase.evening: Color(0xFFB79AB4),
        SkyPhase.night: Color(0xFF5A6A99),
      }[phase]!;
    }
    return const {
      SkyPhase.dawn: Color(0xFF4A2E5C),
      SkyPhase.day: Color(0xFF4F8F6C),
      SkyPhase.evening: Color(0xFF3A1F3F),
      SkyPhase.night: Color(0xFF2C3D6E),
    }[phase]!;
  }

  Color get _near {
    if (spec.terrain == Terrain.dunes) {
      return const {
        SkyPhase.dawn: Color(0xFF7A4E36),
        SkyPhase.day: Color(0xFFB07C45),
        SkyPhase.evening: Color(0xFF5E3428),
        SkyPhase.night: Color(0xFF2E2746),
      }[phase]!;
    }
    if (spec.terrain == Terrain.snowfield) {
      return const {
        SkyPhase.dawn: Color(0xFFE7DCEB),
        SkyPhase.day: Color(0xFFF2F6FB),
        SkyPhase.evening: Color(0xFFCDB6C9),
        SkyPhase.night: Color(0xFF6B78A3),
      }[phase]!;
    }
    return const {
      SkyPhase.dawn: Color(0xFF2A1A38),
      SkyPhase.day: Color(0xFF2F6B4A),
      SkyPhase.evening: Color(0xFF22122A),
      SkyPhase.night: Color(0xFF1A2650),
    }[phase]!;
  }

  Color get _water => const {
        SkyPhase.dawn: Color(0xFF7A4F7E),
        SkyPhase.day: Color(0xFF2F7FC1),
        SkyPhase.evening: Color(0xFF6A3456),
        SkyPhase.night: Color(0xFF22407E),
      }[phase]!;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width, h = size.height;
    final Random r = Random(spec.seed);
    final double v = t.value;
    final double ground = h * 0.74; // near ground line

    switch (spec.terrain) {
      case Terrain.mountains:
        _ridge(canvas, w, h, r, h * 0.26, 5 + r.nextInt(3), _far,
            snow: spec.winter || r.nextInt(3) == 0);
        _hills(canvas, w, h, r, ground - 8, 9, _near);
        break;
      case Terrain.hills:
        _hills(canvas, w, h, r, h * 0.46, 18, _far);
        _hills(canvas, w, h, r, ground - 6, 12, _near);
        break;
      case Terrain.sea:
        _hills(canvas, w, h, r, h * 0.50, 10, _far);
        _sea(canvas, w, h, r, h * 0.56, v);
        _hills(canvas, w, h, r, ground + 4, 5, _near);
        break;
      case Terrain.lake:
        _hills(canvas, w, h, r, h * 0.42, 18, _far);
        _sea(canvas, w, h, r, h * 0.58, v, lake: true);
        _hills(canvas, w, h, r, ground + 6, 4, _near);
        break;
      case Terrain.forest:
        _hills(canvas, w, h, r, h * 0.48, 12, _far);
        for (double x = -6; x < w + 10; x += 10 + r.nextDouble() * 9) {
          _tree(canvas, TreeKind.pine, Offset(x, h * 0.60 + r.nextDouble() * 8),
              18 + r.nextDouble() * 16, Color.lerp(_far, _near, 0.5)!);
        }
        _hills(canvas, w, h, r, ground, 5, _near);
        break;
      case Terrain.fields:
        _hills(canvas, w, h, r, h * 0.46, 16, _far);
        _hills(canvas, w, h, r, ground - 10, 5, _near);
        _fieldRows(canvas, w, h, ground - 8);
        break;
      case Terrain.city:
        _hills(canvas, w, h, r, h * 0.56, 8, _far);
        _city(canvas, w, h, r, ground);
        _hills(canvas, w, h, r, ground + 6, 2, _near);
        break;
      case Terrain.dunes:
        _dunes(canvas, w, h, r, h * 0.46, _far);
        _dunes(canvas, w, h, r, ground - 4, _near);
        break;
      case Terrain.snowfield:
        _ridge(canvas, w, h, r, h * 0.34, 5, _far, snow: true);
        _hills(canvas, w, h, r, ground - 6, 6, _near);
        break;
    }

    // Trees in front (not over the whole width - there is room for the
    // circles' names between them).
    final int trees = spec.terrain == Terrain.city ? 3 : 4 + r.nextInt(4);
    for (int i = 0; i < trees; i++) {
      final double x = r.nextDouble() * w;
      _tree(canvas, spec.tree, Offset(x, ground + 6), 22 + r.nextDouble() * 18,
          Color.lerp(_near, Colors.black, 0.35)!,
          snowy: spec.winter);
    }

    if (spec.flowers && !_night) {
      final List<Color> petals = [
        const Color(0xFFFF7AA2),
        const Color(0xFFFFD34E),
        const Color(0xFFFFFFFF),
        const Color(0xFFB98CFF),
      ];
      for (int i = 0; i < 38; i++) {
        final double x = r.nextDouble() * w;
        final double y = ground + 4 + r.nextDouble() * (h - ground - 4);
        final double sway = 1.2 * sin(v * 2 * pi * 3 + i);
        canvas.drawCircle(Offset(x + sway, y), 1.6 + r.nextDouble() * 1.2,
            Paint()..color = petals[i % petals.length].withValues(alpha: 0.9));
      }
    }

    for (final Life l in spec.life) {
      _life(canvas, w, h, l, v, ground);
    }
  }

  // Jagged mountain ridge with optional snow caps.
  void _ridge(Canvas c, double w, double h, Random r, double top, int peaks,
      Color color,
      {bool snow = false}) {
    final Path p = Path()..moveTo(0, h);
    final List<Offset> tops = [];
    final double step = w / peaks;
    p.lineTo(0, top + 20 + r.nextDouble() * 10);
    for (int i = 0; i < peaks; i++) {
      final double px = step * (i + 0.5) + (r.nextDouble() - 0.5) * step * 0.4;
      final double py = top + r.nextDouble() * 22;
      final double vx = step * (i + 1);
      final double vy = top + 28 + r.nextDouble() * 16;
      p.lineTo(px, py);
      tops.add(Offset(px, py));
      p.lineTo(vx, vy);
    }
    p.lineTo(w, h);
    p.close();
    c.drawPath(p, Paint()..color = color);
    if (snow) {
      final Paint white = Paint()..color = Colors.white.withValues(alpha: 0.85);
      for (final Offset o in tops) {
        c.drawPath(
          Path()
            ..moveTo(o.dx, o.dy)
            ..lineTo(o.dx - 7, o.dy + 7)
            ..lineTo(o.dx - 3, o.dy + 6)
            ..lineTo(o.dx, o.dy + 9)
            ..lineTo(o.dx + 3, o.dy + 6)
            ..lineTo(o.dx + 7, o.dy + 7)
            ..close(),
          white,
        );
      }
    }
  }

  // Soft rolling hills.
  void _hills(Canvas c, double w, double h, Random r, double base, double amp,
      Color color) {
    final double ph = r.nextDouble() * pi * 2;
    final double f = 1.5 + r.nextDouble() * 2;
    final Path p = Path()..moveTo(0, h);
    for (double x = 0; x <= w; x += 4) {
      p.lineTo(x, base - amp * sin(x / w * pi * f + ph));
    }
    p
      ..lineTo(w, h)
      ..close();
    c.drawPath(p, Paint()..color = color);
  }

  void _dunes(
      Canvas c, double w, double h, Random r, double base, Color color) {
    final double ph = r.nextDouble() * pi;
    final Path p = Path()..moveTo(0, h);
    for (double x = 0; x <= w; x += 4) {
      final double y = base -
          16 * sin(x / w * pi * 1.3 + ph).abs() -
          5 * sin(x / w * pi * 4 + ph);
      p.lineTo(x, y);
    }
    p
      ..lineTo(w, h)
      ..close();
    c.drawPath(p, Paint()..color = color);
  }

  // Sea or lake with moving light lines.
  void _sea(Canvas c, double w, double h, Random r, double top, double v,
      {bool lake = false}) {
    c.drawRect(
      Rect.fromLTRB(0, top, w, h),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_water, Color.lerp(_water, Colors.black, 0.5)!],
        ).createShader(Rect.fromLTRB(0, top, w, h)),
    );
    final Paint shine = Paint()
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: _night ? 0.35 : 0.45);
    for (int i = 0; i < 16; i++) {
      final double y = top + 4 + (i % 4) * 5.0;
      final double x =
          ((i * 53 + v * w * (lake ? 0.5 : 1.0) * (i.isEven ? 1 : -1)) % w +
                  w) %
              w;
      c.drawLine(Offset(x, y), Offset(x + 6 + (i % 3) * 4, y), shine);
    }
    _lightPath(c, w, h, top, v);
  }

  // The moon's (or the sun's) reflection: short glittering dashes under
  // where the sky draws it (sky_pass.dart: x = 84% at night / day, 82%
  // in the evening), wider and fainter towards the shore.
  void _lightPath(Canvas c, double w, double h, double top, double v) {
    if (!_sunOrMoon) return;
    final double cx = w * (phase == SkyPhase.evening ? 0.82 : 0.84);
    final Color col = const {
      SkyPhase.dawn: Color(0xFFFFD08A),
      SkyPhase.day: Color(0xFFFFFFFF),
      SkyPhase.evening: Color(0xFFFF9A5C),
      SkyPhase.night: Color(0xFFF2F0E6),
    }[phase]!;
    // Soft glow column.
    c.drawRect(
      Rect.fromLTRB(cx - 14, top, cx + 14, h),
      Paint()
        ..color = col.withValues(alpha: _night ? 0.10 : 0.08)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    final Paint dash = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.6;
    int row = 0;
    for (double y = top + 2; y < h; y += 3.2, row++) {
      final double depth = (y - top) / max(1, h - top); // 0 far .. 1 near
      final double half = 3 + depth * 13;
      for (int k = 0; k < 2; k++) {
        final double flick =
            0.5 + 0.5 * sin(v * 2 * pi * 9 + row * 1.7 + k * 2.3);
        final double off = (k == 0 ? -1 : 1) * half * 0.5 * (0.4 + flick);
        final double len = half * (0.35 + 0.5 * flick);
        dash.color = col.withValues(alpha: (0.85 - depth * 0.45) * flick);
        c.drawLine(
            Offset(cx + off - len / 2, y), Offset(cx + off + len / 2, y), dash);
      }
    }
  }

  void _fieldRows(Canvas c, double w, double h, double top) {
    final Color a =
        Color.lerp(_near, const Color(0xFFC8B04A), _night ? 0.1 : 0.45)!;
    final Color b =
        Color.lerp(_near, const Color(0xFF6FAF4A), _night ? 0.1 : 0.4)!;
    for (int i = 0; i < 6; i++) {
      final double y = top + i * 5.0;
      c.drawRect(Rect.fromLTWH(0, y, w, 5), Paint()..color = i.isEven ? a : b);
    }
  }

  void _city(Canvas c, double w, double h, Random r, double ground) {
    final Paint body = Paint()..color = Color.lerp(_far, Colors.black, 0.35)!;
    final bool lights = phase == SkyPhase.night || phase == SkyPhase.evening;
    double x = -4;
    while (x < w) {
      final double bw = 14 + r.nextDouble() * 20;
      final double bh = 26 + r.nextDouble() * 46;
      final Rect b = Rect.fromLTWH(x, ground - bh, bw, bh + 10);
      c.drawRect(b, body);
      if (r.nextInt(5) == 0) {
        c.drawLine(Offset(x + bw / 2, ground - bh),
            Offset(x + bw / 2, ground - bh - 7), body..strokeWidth = 1.2);
      }
      if (lights) {
        final Paint win = Paint()
          ..color = const Color(0xFFFFD27A).withValues(alpha: 0.85);
        for (double wy = ground - bh + 4; wy < ground - 2; wy += 5) {
          for (double wx = x + 2; wx < x + bw - 2; wx += 4) {
            if (r.nextInt(3) == 0) {
              c.drawRect(Rect.fromLTWH(wx, wy, 1.6, 2), win);
            }
          }
        }
      }
      x += bw + 1 + r.nextDouble() * 3;
    }
  }

  void _tree(Canvas c, TreeKind kind, Offset base, double size, Color color,
      {bool snowy = false}) {
    final Paint p = Paint()..color = color;
    switch (kind) {
      case TreeKind.pine:
        for (int i = 0; i < 3; i++) {
          final double y = base.dy - size * (0.35 + i * 0.25);
          final double half = size * (0.38 - i * 0.09);
          c.drawPath(
            Path()
              ..moveTo(base.dx, y - size * 0.32)
              ..lineTo(base.dx - half, y)
              ..lineTo(base.dx + half, y)
              ..close(),
            p,
          );
        }
        c.drawRect(
            Rect.fromLTWH(base.dx - 1, base.dy - size * 0.36, 2, size * 0.36),
            p);
        if (snowy) {
          c.drawCircle(Offset(base.dx, base.dy - size * 1.05), size * 0.07,
              Paint()..color = Colors.white.withValues(alpha: 0.9));
        }
        break;
      case TreeKind.round:
        c.drawRect(
            Rect.fromLTWH(base.dx - 1.2, base.dy - size * 0.5, 2.4, size * 0.5),
            p);
        c.drawCircle(Offset(base.dx, base.dy - size * 0.68), size * 0.32, p);
        c.drawCircle(
            Offset(base.dx - size * 0.2, base.dy - size * 0.55), size * 0.2, p);
        c.drawCircle(Offset(base.dx + size * 0.2, base.dy - size * 0.57),
            size * 0.22, p);
        break;
      case TreeKind.palm:
        final Path trunk = Path()
          ..moveTo(base.dx, base.dy)
          ..quadraticBezierTo(base.dx + size * 0.15, base.dy - size * 0.5,
              base.dx + size * 0.05, base.dy - size);
        c.drawPath(
            trunk,
            Paint()
              ..color = color
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.2);
        final Offset top = Offset(base.dx + size * 0.05, base.dy - size);
        for (int i = 0; i < 6; i++) {
          final double a = -pi / 2 + (i - 2.5) * 0.55;
          final Offset end = top +
              Offset(cos(a) * size * 0.5, sin(a) * size * 0.35 + size * 0.22);
          c.drawPath(
            Path()
              ..moveTo(top.dx, top.dy)
              ..quadraticBezierTo(top.dx + cos(a) * size * 0.3,
                  top.dy - size * 0.12, end.dx, end.dy),
            Paint()
              ..color = color
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.4
              ..strokeCap = StrokeCap.round,
          );
        }
        break;
      case TreeKind.cactus:
        final RRect stem = RRect.fromRectAndRadius(
            Rect.fromLTWH(base.dx - 2.5, base.dy - size, 5, size),
            const Radius.circular(2.5));
        c.drawRRect(stem, p);
        c.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromLTWH(
                    base.dx - 8, base.dy - size * 0.7, 3.5, size * 0.3),
                const Radius.circular(2)),
            p);
        c.drawRect(Rect.fromLTWH(base.dx - 8, base.dy - size * 0.42, 6, 3), p);
        c.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromLTWH(
                    base.dx + 4.5, base.dy - size * 0.8, 3.5, size * 0.35),
                const Radius.circular(2)),
            p);
        c.drawRect(Rect.fromLTWH(base.dx + 2, base.dy - size * 0.48, 6, 3), p);
        break;
      case TreeKind.bare:
        final Paint br = Paint()
          ..color = color
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round;
        final Offset top = base - Offset(0, size);
        c.drawLine(base, top, br..strokeWidth = 2.2);
        br.strokeWidth = 1.3;
        for (int i = 0; i < 4; i++) {
          final double y = base.dy - size * (0.45 + i * 0.14);
          final double dir = i.isEven ? 1 : -1;
          c.drawLine(Offset(base.dx, y),
              Offset(base.dx + dir * size * 0.3, y - size * 0.18), br);
        }
        if (snowy) {
          c.drawLine(
              top,
              top + const Offset(0, 2),
              Paint()
                ..color = Colors.white
                ..strokeWidth = 2);
        }
        break;
    }
  }

  void _life(Canvas c, double w, double h, Life l, double v, double ground) {
    switch (l) {
      case Life.birds:
        final Paint p = Paint()
          ..color =
              (_night ? Colors.white : Colors.black).withValues(alpha: 0.6)
          ..strokeWidth = 1.3
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;
        for (int i = 0; i < 5; i++) {
          final double x = ((v * 1.3 + i * 0.06) % 1.0) * (w + 60) - 30;
          final double y = h * 0.22 + (i % 3) * 6 + 3 * sin(v * 2 * pi * 2 + i);
          final double flap = 2.5 * sin(v * 2 * pi * 30 + i * 1.7);
          c.drawPath(
            Path()
              ..moveTo(x - 4, y - flap)
              ..quadraticBezierTo(x - 2, y - 1, x, y)
              ..quadraticBezierTo(x + 2, y - 1, x + 4, y - flap),
            p,
          );
        }
        break;
      case Life.butterflies:
        const List<Color> cols = [
          Color(0xFFFF7AA2),
          Color(0xFFFFD34E),
          Color(0xFF8FD3FF),
        ];
        for (int i = 0; i < 3; i++) {
          final double x =
              ((v * 0.6 + i * 0.33) % 1.0) * w + 10 * sin(v * 2 * pi * 4 + i);
          final double y = ground - 10 + 8 * sin(v * 2 * pi * 3 + i * 2);
          final double open = 0.4 + 0.6 * sin(v * 2 * pi * 40 + i).abs();
          final Paint p = Paint()..color = cols[i];
          c.drawOval(
              Rect.fromCenter(
                  center: Offset(x - 2.2 * open, y),
                  width: 4 * open,
                  height: 5),
              p);
          c.drawOval(
              Rect.fromCenter(
                  center: Offset(x + 2.2 * open, y),
                  width: 4 * open,
                  height: 5),
              p);
        }
        break;
      case Life.fireflies:
        for (int i = 0; i < 16; i++) {
          final double x = (i * 37.0 + 20 * sin(v * 2 * pi + i)) % w;
          final double y =
              ground - 6 - (i % 5) * 7 + 4 * cos(v * 2 * pi * 2 + i);
          final double glow =
              (0.5 + 0.5 * sin(v * 2 * pi * 6 + i * 1.3)).clamp(0.0, 1.0);
          c.drawCircle(
              Offset(x, y),
              4,
              Paint()
                ..color = const Color(0xFFE8FF7A).withValues(alpha: 0.25 * glow)
                ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
          c.drawCircle(Offset(x, y), 1.3,
              Paint()..color = const Color(0xFFF4FFB0).withValues(alpha: glow));
        }
        break;
      case Life.balloons:
        const List<List<Color>> stripes = [
          [Color(0xFFFF4B6E), Color(0xFFFFD34E)],
          [Color(0xFF3A8DFF), Color(0xFFFFFFFF)],
          [Color(0xFF9C4DFF), Color(0xFF35E1F2)],
        ];
        for (int i = 0; i < 3; i++) {
          final double q = (v + i / 3) % 1.0;
          final double x = w * (0.2 + 0.3 * i) + 14 * sin(q * pi * 2);
          final double y = h * 0.75 - q * h * 0.7;
          final double alpha = sin(q * pi).clamp(0.0, 1.0);
          if (alpha < 0.05) continue;
          final Rect ball =
              Rect.fromCenter(center: Offset(x, y), width: 11, height: 13);
          c.drawOval(
              ball, Paint()..color = stripes[i][0].withValues(alpha: alpha));
          c.drawRect(
              Rect.fromCenter(center: Offset(x, y), width: 3, height: 13),
              Paint()..color = stripes[i][1].withValues(alpha: alpha));
          c.drawRect(
              Rect.fromLTWH(x - 2, y + 9, 4, 3),
              Paint()
                ..color = const Color(0xFF6B4A2E).withValues(alpha: alpha));
        }
        break;
      case Life.kites:
        for (int i = 0; i < 2; i++) {
          final Offset anchor = Offset(w * (0.3 + 0.4 * i), ground + 6);
          final Offset kite = Offset(
            anchor.dx + 30 + 8 * sin(v * 2 * pi * 2 + i),
            h * 0.25 + 6 * cos(v * 2 * pi * 3 + i),
          );
          c.drawLine(
              anchor,
              kite,
              Paint()
                ..color = Colors.white.withValues(alpha: 0.35)
                ..strokeWidth = 0.8);
          c.save();
          c.translate(kite.dx, kite.dy);
          c.rotate(0.3 * sin(v * 2 * pi * 2 + i));
          c.drawPath(
            Path()
              ..moveTo(0, -7)
              ..lineTo(5, 0)
              ..lineTo(0, 8)
              ..lineTo(-5, 0)
              ..close(),
            Paint()
              ..color =
                  i == 0 ? const Color(0xFFFF4B6E) : const Color(0xFF35E1F2),
          );
          c.restore();
        }
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _LandscapePainter old) =>
      old.spec.seed != spec.seed ||
      old.spec.holiday != spec.holiday ||
      old.phase != phase ||
      old.weather != weather;
}

// ---------------------------------------------------------------------
// Fireworks (national days)
// ---------------------------------------------------------------------
class _FireworksPainter extends CustomPainter {
  final int seed;
  final Animation<double> t;
  _FireworksPainter(this.seed, this.t) : super(repaint: t);

  static const List<Color> _colors = [
    Color(0xFFFF4B6E),
    Color(0xFFFFD27A),
    Color(0xFF35E1F2),
    Color(0xFF9C4DFF),
    Color(0xFFFFFFFF),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final double v = t.value;
    // 4 bursts, each lasting 1/6 of a 4 s cycle, at different places.
    for (int b = 0; b < 4; b++) {
      final double q = ((v * 6) + b * 0.27) % 1.0; // 0..1 life of a burst
      final int n = ((v * 6) + b * 0.27).floor();
      final Random r = Random(seed + b * 977 + n * 31);
      final Offset c = Offset(
        size.width * (0.15 + 0.7 * r.nextDouble()),
        size.height * (0.15 + 0.3 * r.nextDouble()),
      );
      final Color col = _colors[r.nextInt(_colors.length)];
      final double radius = 6 + 22 * Curves.easeOut.transform(q);
      final double alpha = (1 - q).clamp(0.0, 1.0);
      for (int i = 0; i < 14; i++) {
        final double a = i * 2 * pi / 14;
        final Offset p = c + Offset(cos(a), sin(a) + 0.25 * q) * radius;
        canvas.drawCircle(
            p, 1.5, Paint()..color = col.withValues(alpha: alpha));
        canvas.drawCircle(
          p,
          3.5,
          Paint()
            ..color = col.withValues(alpha: alpha * 0.3)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FireworksPainter old) => old.seed != seed;
}
