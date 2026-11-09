// Fly Looks (9 Nov 2026) - the colour filters for videos and photos.
// Ko: "add lots of effects, TikTok-like, as good as you can".
//
// A "look" is saved on the post / story as the plain `filterType` string,
// exactly like before - playback (feed, story viewer, upload preview,
// photo effects) rebuilds it with a ColorFilter.matrix, nothing is baked
// into the video file. Two changes:
//   1. Many more looks ([kFlyFilters], 23 incl. the 5 old ones whose ids
//      and matrices stay EXACTLY the same, so old posts look unchanged).
//   2. The camera's Beauty can be saved with it: `"<id>|b<0-100>"`, e.g.
//      `golden|b40`. [videoFilterMatrix] understands both forms. Old app
//      versions only know the 5 old ids and fall back to "no filter" for
//      anything else (they use `?? none`), so nothing breaks there.
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

class FlyFilter {
  final String id;
  final String name;
  final List<double> matrix;
  const FlyFilter(this.id, this.name, this.matrix);
}

// ---------------------------------------------------------------------
// Matrix helpers (4x5 row-major, offsets in 0..255 like ColorFilter.matrix)
// ---------------------------------------------------------------------
const List<double> _identity = <double>[
  1, 0, 0, 0, 0, //
  0, 1, 0, 0, 0, //
  0, 0, 1, 0, 0, //
  0, 0, 0, 1, 0, //
];

/// The matrix that applies [first], then [then].
List<double> composeMatrices(List<double> then, List<double> first) {
  final List<double> out = List<double>.filled(20, 0);
  for (int r = 0; r < 4; r++) {
    for (int c = 0; c < 5; c++) {
      double v = 0;
      for (int k = 0; k < 4; k++) {
        v += then[r * 5 + k] * first[k * 5 + c];
      }
      if (c == 4) v += then[r * 5 + 4];
      out[r * 5 + c] = v;
    }
  }
  return out;
}

List<double> _sat(double s) {
  const double lr = 0.2126, lg = 0.7152, lb = 0.0722;
  return <double>[
    lr * (1 - s) + s, lg * (1 - s), lb * (1 - s), 0, 0, //
    lr * (1 - s), lg * (1 - s) + s, lb * (1 - s), 0, 0, //
    lr * (1 - s), lg * (1 - s), lb * (1 - s) + s, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
}

List<double> _contrast(double c) {
  final double o = 128 * (1 - c);
  return <double>[
    c, 0, 0, 0, o, //
    0, c, 0, 0, o, //
    0, 0, c, 0, o, //
    0, 0, 0, 1, 0, //
  ];
}

/// Per-channel gain + offset (a colour tint).
List<double> _tint(
    {double r = 1,
    double g = 1,
    double b = 1,
    double dr = 0,
    double dg = 0,
    double db = 0}) {
  return <double>[
    r, 0, 0, 0, dr, //
    0, g, 0, 0, dg, //
    0, 0, b, 0, db, //
    0, 0, 0, 1, 0, //
  ];
}

List<double> _sepia(double amount) {
  const List<double> s = <double>[
    0.393, 0.769, 0.189, 0, 0, //
    0.349, 0.686, 0.168, 0, 0, //
    0.272, 0.534, 0.131, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
  return List<double>.generate(
      20, (i) => _identity[i] + (s[i] - _identity[i]) * amount);
}

/// Faded film: lifts the blacks, softens the whites.
List<double> _fade(double f) {
  final double k = 1 - f;
  final double o = 255 * f * 0.6;
  return <double>[
    k, 0, 0, 0, o, //
    0, k, 0, 0, o, //
    0, 0, k, 0, o, //
    0, 0, 0, 1, 0, //
  ];
}

/// Steps applied left to right.
List<double> _chain(List<List<double>> steps) {
  List<double> m = _identity;
  for (final List<double> s in steps) {
    m = composeMatrices(s, m);
  }
  return m;
}

// ---------------------------------------------------------------------
// The looks
// ---------------------------------------------------------------------
final List<FlyFilter> kFlyFilters = <FlyFilter>[
  const FlyFilter('none', 'Normal', _identity),
  FlyFilter('vivid', 'Vivid', _chain([_sat(1.45), _contrast(1.1)])),
  FlyFilter(
      'golden',
      'Golden Hour',
      _chain([
        _sepia(0.25),
        _tint(r: 1.08, b: 0.88, dr: 8, dg: 4),
        _sat(1.15),
      ])),
  // The 5 original looks - ids and numbers unchanged (old posts).
  const FlyFilter('warm', 'Warm', <double>[
    1.15, 0, 0, 0, 12, 0, 1.05, 0, 0, 6, 0, 0, 0.85, 0, 0, 0, 0, 0, 1, 0, //
  ]),
  FlyFilter(
      'sakura',
      'Sakura',
      _chain([
        _tint(dr: 18, dg: -2, db: 12),
        _contrast(0.95),
        _tint(dr: 6, dg: 6, db: 6),
      ])),
  FlyFilter(
      'peach',
      'Peach',
      _chain([
        _tint(r: 1.04, dr: 14, dg: 6, db: -6),
        _sat(1.05),
      ])),
  FlyFilter(
      'honey', 'Honey', _chain([_sepia(0.35), _sat(1.2), _tint(dr: 6, dg: 4)])),
  FlyFilter(
      'sunset',
      'Sunset',
      _chain([
        _tint(r: 1.15, g: 0.95, b: 0.92, dr: 12, dg: -6, db: 12),
        _sat(1.2),
      ])),
  FlyFilter(
      'skypass',
      'Sky Pass',
      _chain([
        _tint(r: 0.92, g: 0.95, b: 1.12, dr: 8, db: 18),
        _sat(1.1),
        _contrast(1.05),
      ])),
  const FlyFilter('cool', 'Cool', <double>[
    0.9, 0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 0, 1.2, 0, 12, 0, 0, 0, 1, 0, //
  ]),
  FlyFilter(
      'ocean',
      'Ocean',
      _chain([
        _tint(r: 0.85, g: 1.02, b: 1.15, dg: 6, db: 14),
        _sat(1.1),
      ])),
  FlyFilter(
      'polar',
      'Polar',
      _chain([
        _tint(r: 0.95, g: 1.02, b: 1.12),
        _sat(0.8),
        _tint(dr: 14, dg: 14, db: 14),
      ])),
  FlyFilter(
      'mint',
      'Mint',
      _chain([
        _tint(r: 0.92, g: 1.08, dg: 10, db: 6),
        _sat(0.95),
        _tint(dr: 6, dg: 6, db: 6),
      ])),
  FlyFilter(
      'matcha',
      'Matcha',
      _chain([
        _tint(r: 0.95, g: 1.08, b: 0.85),
        _fade(0.08),
        _sat(0.9),
      ])),
  FlyFilter(
      'neon',
      'Neon Night',
      _chain([
        _sat(1.8),
        _contrast(1.2),
        _tint(dr: 14, dg: -10, db: 20),
      ])),
  FlyFilter(
      'cyber',
      'Cyber',
      _chain([
        _tint(r: 1.1, g: 0.98, b: 1.12, dr: 10, dg: -4, db: 8),
        _sat(1.3),
        _contrast(1.15),
      ])),
  FlyFilter(
      'dreamy',
      'Dreamy',
      _chain([
        _contrast(0.85),
        _tint(dr: 28, dg: 18, db: 30),
        _sat(0.9),
      ])),
  FlyFilter(
      'film',
      'Film 98',
      _chain([
        _fade(0.1),
        _sepia(0.15),
        _sat(0.85),
        _contrast(1.05),
      ])),
  FlyFilter(
      'retro',
      'Retro',
      _chain([
        _fade(0.12),
        _tint(r: 1.02, g: 1.05, b: 0.85),
        _sat(0.8),
      ])),
  const FlyFilter('vintage', 'Vintage', <double>[
    1.05, 0.05, 0.05, 0, 12, 0, 0.95, 0.05, 0, 6, 0.05, 0.1, 0.75, 0, 0, //
    0, 0, 0, 1, 0, //
  ]),
  FlyFilter('fade', 'Fade', _chain([_fade(0.15), _sat(0.8)])),
  FlyFilter('noir', 'Noir', _chain([_sat(0), _contrast(1.4)])),
  const FlyFilter('bw', 'B&W', <double>[
    0.33, 0.59, 0.11, 0, 0, 0.33, 0.59, 0.11, 0, 0, 0.33, 0.59, 0.11, 0, 0, //
    0, 0, 0, 1, 0, //
  ]),
];

final Map<String, FlyFilter> _byId = {for (final f in kFlyFilters) f.id: f};

/// Soft, brighter skin (the camera's Beauty, 0..1) - the same numbers the
/// camera has used since Phase 1.
List<double> beautyMatrix(double intensity) {
  const List<double> beauty = <double>[
    1.08, 0.04, 0.04, 0, 18, //
    0.04, 1.08, 0.04, 0, 18, //
    0.02, 0.02, 1.05, 0, 14, //
    0, 0, 0, 1, 0, //
  ];
  final double k = intensity.clamp(0.0, 1.0);
  return List<double>.generate(
      20, (i) => _identity[i] + (beauty[i] - _identity[i]) * k);
}

/// The filter id of a saved look ("golden|b40" -> "golden").
String lookFilterId(String? look) {
  if (look == null || look.isEmpty) return 'none';
  final int bar = look.indexOf('|');
  final String id = bar == -1 ? look : look.substring(0, bar);
  return _byId.containsKey(id) ? id : 'none';
}

/// One 0..1 setting of a saved look: "golden|b40|s70" -> key 's' = 0.7.
/// Keys: b = colour beauty, s = smooth, g = glow / bright, r = rosy,
/// n = night (Fly Beauty Engine, 9 Nov 2026).
double lookParam(String? look, String key) {
  if (look == null) return 0;
  final List<String> parts = look.split('|');
  for (int i = 1; i < parts.length; i++) {
    final String p = parts[i];
    if (p.length > 1 && p[0] == key) {
      final int? v = int.tryParse(p.substring(1));
      return v == null ? 0 : v.clamp(0, 100) / 100;
    }
  }
  return 0;
}

/// The colour beauty of a saved look, 0..1 ("golden|b40" -> 0.4).
double lookBeauty(String? look) => lookParam(look, 'b');

/// The Fly Beauty Engine settings of a saved look.
class BeautySettings {
  final double smooth, glow, rosy, night;
  const BeautySettings(
      {this.smooth = 0, this.glow = 0, this.rosy = 0, this.night = 0});
  static BeautySettings of(String? look) => BeautySettings(
        smooth: lookParam(look, 's'),
        glow: lookParam(look, 'g'),
        rosy: lookParam(look, 'r'),
        night: lookParam(look, 'n'),
      );
  bool get isOff => smooth <= 0 && glow <= 0 && rosy <= 0 && night <= 0;
}

/// Builds the string saved as `filterType` (only the settings in use).
String makeLook(String filterId, double beauty,
    [BeautySettings engine = const BeautySettings()]) {
  final StringBuffer out = StringBuffer(filterId);
  void add(String key, double v) {
    final int n = (v.clamp(0.0, 1.0) * 100).round();
    if (n > 0) out.write('|$key$n');
  }

  add('b', beauty);
  add('s', engine.smooth);
  add('g', engine.glow);
  add('r', engine.rosy);
  add('n', engine.night);
  return out.toString();
}

/// Keeps a look's beauty settings but changes its filter.
String withFilter(String? look, String filterId) {
  if (look == null) return filterId;
  final int bar = look.indexOf('|');
  return bar == -1 ? filterId : filterId + look.substring(bar);
}

// ---------------------------------------------------------------------
// Fly Beauty Engine - the GPU shader (shaders/fly_beauty.frag)
// ---------------------------------------------------------------------
class FlyBeautyEngine {
  FlyBeautyEngine._();

  /// The GPU shader needs Impeller. 9 Nov 2026 test (dev app with
  /// Impeller ON): the shader ran, BUT the FullScreenVideoScreen ghost /
  /// duplicated action bar came straight back - so Impeller stays OFF
  /// everywhere and the shader is not used. FlyLook uses the Skia-safe
  /// lighten-blur version. Turn this on only if that Impeller bug is fixed.
  static const bool kUseGpuShader = false;

  static final ValueNotifier<ui.FragmentProgram?> program =
      ValueNotifier<ui.FragmentProgram?>(null);
  static bool _loading = false;

  /// False once the phone turned out not to support shader filters
  /// (no Impeller) - then only the colour part of a look is shown.
  static bool supported = true;

  static void ensureLoaded() {
    if (_loading || program.value != null || !supported) return;
    _loading = true;
    ui.FragmentProgram.fromAsset('shaders/fly_beauty.frag').then((p) {
      program.value = p;
    }).catchError((Object e) {
      debugPrint('Fly Beauty Engine: $e');
      supported = false;
    });
  }

  /// The image filter for [b] at [size] physical pixels, or null.
  static ui.ImageFilter? filterFor(BeautySettings b, Size size) {
    final ui.FragmentProgram? p = program.value;
    if (p == null || !supported || b.isOff) return null;
    try {
      final ui.FragmentShader shader = p.fragmentShader()
        ..setFloat(0, size.width)
        ..setFloat(1, size.height)
        ..setFloat(2, b.smooth)
        ..setFloat(3, b.glow)
        ..setFloat(4, b.rosy)
        ..setFloat(5, b.night);
      return ui.ImageFilter.shader(shader);
    } catch (e) {
      debugPrint('Fly Beauty Engine off: $e');
      supported = false;
      return null;
    }
  }
}

/// Night / Bright / Rosy as one colour matrix (works on every renderer).
List<double> beautyColourMatrix(BeautySettings b) {
  List<double> m = _identity;
  if (b.night > 0) {
    // Lift the shadows: brighter, a little less contrast.
    m = composeMatrices(_contrast(1 - 0.18 * b.night), m);
    m = composeMatrices(
        _tint(
            r: 1 + 0.35 * b.night,
            g: 1 + 0.35 * b.night,
            b: 1 + 0.35 * b.night,
            dr: 22 * b.night,
            dg: 22 * b.night,
            db: 22 * b.night),
        m);
  }
  if (b.glow > 0) {
    m = composeMatrices(
        _tint(dr: 10 * b.glow, dg: 8 * b.glow, db: 8 * b.glow), m);
  }
  if (b.rosy > 0) {
    m = composeMatrices(
        _tint(dr: 14 * b.rosy, dg: -2 * b.rosy, db: 3 * b.rosy), m);
  }
  return m;
}

/// Shows [child] (a video / photo / camera preview) through a saved look:
/// the colour filter + Fly Beauty. Use this everywhere a `filterType` is
/// played back.
///
/// Fly runs with Impeller OFF (AndroidManifest - the FullScreenVideoScreen
/// ghost-UI fix, see AI_CONTEXT), and the GPU shader filter
/// (ImageFilter.shader) only works on Impeller. So Fly Beauty uses a
/// renderer-independent trick (9 Nov 2026, after Ko's Off / Doll test
/// showed no smoothing):
///   - Smooth: a blurred, slightly darkened copy of the picture is laid
///     over it with BlendMode.lighten - it only wins where the picture is
///     darker than its surroundings (pores, spots, small lines), so the
///     skin gets smoother while edges / eyes stay sharp.
///   - Bright: a strongly blurred, dimmed copy with BlendMode.screen = a
///     soft glow.
///   - Night / Rosy (+ bright tint): one colour matrix.
/// [FlyBeautyEngine.kUseGpuShader] switches to the shader version once
/// Impeller can be turned back on.
class FlyLook extends StatelessWidget {
  final String? look;
  final Widget child;
  const FlyLook({super.key, required this.look, required this.child});

  @override
  Widget build(BuildContext context) {
    final String? l = look;
    if (l == null || l.isEmpty || l == 'none') return child;
    final BeautySettings b = BeautySettings.of(l);
    List<double>? matrix;
    if (lookFilterId(l) != 'none' || lookBeauty(l) > 0) {
      matrix = videoFilterMatrix(l);
    }
    if (!b.isOff) {
      matrix = composeMatrices(beautyColourMatrix(b), matrix ?? _identity);
    }
    final Widget colour = matrix == null
        ? child
        : ColorFiltered(
            colorFilter: ColorFilter.matrix(matrix),
            child: child,
          );
    if (b.isOff) return colour;

    if (FlyBeautyEngine.kUseGpuShader && FlyBeautyEngine.supported) {
      FlyBeautyEngine.ensureLoaded();
      return ValueListenableBuilder<ui.FragmentProgram?>(
        valueListenable: FlyBeautyEngine.program,
        builder: (context, program, _) {
          if (program == null) return _skiaBeauty(colour, b);
          return LayoutBuilder(builder: (context, box) {
            if (!box.maxWidth.isFinite || !box.maxHeight.isFinite) {
              return _skiaBeauty(colour, b);
            }
            final double dpr = MediaQuery.devicePixelRatioOf(context);
            final ui.ImageFilter? f = FlyBeautyEngine.filterFor(
                b, Size(box.maxWidth * dpr, box.maxHeight * dpr));
            if (f == null) return _skiaBeauty(colour, b);
            return ImageFiltered(imageFilter: f, child: colour);
          });
        },
      );
    }
    return _skiaBeauty(colour, b);
  }

  // Lighten-blur smoothing + screen glow (works without Impeller).
  static Widget _skiaBeauty(Widget colour, BeautySettings b) {
    final double smooth = b.smooth;
    final double glow = b.glow;
    // passthrough: the picture keeps the exact size it gets without
    // beauty (a loose Stack let the camera preview shrink - black band at
    // the bottom, 9 Nov 2026).
    return Stack(
      fit: StackFit.passthrough,
      children: [
        colour,
        if (smooth > 0)
          Positioned.fill(
            child: IgnorePointer(
              child: ClipRect(
                child: BackdropFilter(
                  blendMode: BlendMode.lighten,
                  filter: ui.ImageFilter.compose(
                    outer: ColorFilter.matrix(
                        // Darker copy = it only fills small dark spots,
                        // not the edges of hair / eyes (no white halos).
                        _tint(
                            r: 0.86 + 0.1 * smooth,
                            g: 0.86 + 0.1 * smooth,
                            b: 0.86 + 0.1 * smooth)),
                    inner: ui.ImageFilter.blur(
                      sigmaX: 1 + 2.5 * smooth,
                      sigmaY: 1 + 2.5 * smooth,
                      tileMode: TileMode.clamp,
                    ),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        if (glow > 0)
          Positioned.fill(
            child: IgnorePointer(
              child: ClipRect(
                child: BackdropFilter(
                  blendMode: BlendMode.screen,
                  filter: ui.ImageFilter.compose(
                    outer: ColorFilter.matrix(
                        _tint(r: 0.13 * glow, g: 0.12 * glow, b: 0.12 * glow)),
                    inner: ui.ImageFilter.blur(
                      sigmaX: 12 + 10 * glow,
                      sigmaY: 12 + 10 * glow,
                      tileMode: TileMode.clamp,
                    ),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The colour matrix for a saved look (unknown ids = no filter).
List<double> videoFilterMatrix(String? look) {
  final List<double> base = _byId[lookFilterId(look)]!.matrix;
  final double b = lookBeauty(look);
  if (b <= 0) return base;
  return composeMatrices(base, beautyMatrix(b));
}

/// Display name of a look's filter.
String filterLabel(String? look) => _byId[lookFilterId(look)]!.name;

/// A tiny painted scene (sky, sun, hill, a face) shown through a look -
/// the thumbnails of the filter pickers.
class FilterSwatch extends StatelessWidget {
  final String look;
  final double size;
  final bool selected;
  const FilterSwatch({
    super.key,
    required this.look,
    this.size = 58,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        border: Border.all(
          color: selected ? Colors.white : Colors.white24,
          width: selected ? 2.5 : 1,
        ),
        boxShadow: selected
            ? const [BoxShadow(color: Color(0xAAFF4B6E), blurRadius: 12)]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.26),
        child: ColorFiltered(
          colorFilter: ColorFilter.matrix(videoFilterMatrix(look)),
          child: CustomPaint(painter: _SwatchPainter()),
        ),
      ),
    );
  }
}

class _SwatchPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width, h = size.height;
    final Rect r = Offset.zero & size;
    canvas.drawRect(
      r,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF6FA8E8), Color(0xFFF2C9A0)],
        ).createShader(r),
    );
    canvas.drawCircle(Offset(w * 0.78, h * 0.22), w * 0.1,
        Paint()..color = const Color(0xFFFFE08A));
    final Path hill = Path()
      ..moveTo(0, h * 0.72)
      ..quadraticBezierTo(w * 0.35, h * 0.55, w * 0.7, h * 0.7)
      ..quadraticBezierTo(w * 0.9, h * 0.76, w, h * 0.7)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(hill, Paint()..color = const Color(0xFF4F9A5C));
    // A face + shoulders.
    canvas.drawOval(
        Rect.fromCenter(
            center: Offset(w * 0.38, h * 1.0), width: w * 0.6, height: h * 0.4),
        Paint()..color = const Color(0xFFD9485F));
    canvas.drawCircle(Offset(w * 0.38, h * 0.62), w * 0.15,
        Paint()..color = const Color(0xFFE2B48F));
    canvas.drawArc(
        Rect.fromCircle(center: Offset(w * 0.38, h * 0.58), radius: w * 0.16),
        3.3,
        2.8,
        true,
        Paint()..color = const Color(0xFF2A2020));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
