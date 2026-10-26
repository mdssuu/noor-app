import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_settings.dart';
import 'main.dart' show Masjid, NoorColors, NotificationService;
import 'services/app_config.dart';

// ===========================================================================
//  THE LOOK
//
//  The mockup is a full bleed sky that follows the clock — navy with a
//  crescent at night, blue at breakfast, orange at noon, magenta at sunset —
//  with a mosque skyline standing in front of it and glass panels floating
//  on top. Everything in this file serves that picture; the features behind
//  the panels are the ones the app has always had.
// ===========================================================================

/// Which body is up in the sky.
enum Celestial { none, sun, moon }

/// One sky: a three stop gradient, the colour the skyline is cut from, and
/// the stars/moon/sun that belong to that hour.
@immutable
class NoorSky {
  const NoorSky({
    required this.top,
    required this.mid,
    required this.bottom,
    required this.silhouette,
    this.stars = false,
    this.celestial = Celestial.none,
  });

  final Color top;
  final Color mid;
  final Color bottom;
  final Color silhouette;
  final bool stars;
  final Celestial celestial;

  LinearGradient get gradient => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[top, mid, bottom],
        stops: const <double>[0.0, 0.52, 1.0],
      );

  /// Midnight → 04:00: real night — almost black overhead, a faint blue
  /// still hanging in the west.
  static const NoorSky night = NoorSky(
    top: Color(0xFF070A18),
    mid: Color(0xFF131A33),
    bottom: Color(0xFF2A3352),
    silhouette: Color(0xFF05060F),
    stars: true,
    celestial: Celestial.moon,
  );

  /// 04:00 → 06:00: Fajr — the last of the night lifting into violet, a warm
  /// band already glowing where the sun will come up.
  static const NoorSky dawn = NoorSky(
    top: Color(0xFF0D1430),
    mid: Color(0xFF35386B),
    bottom: Color(0xFFD89A87),
    silhouette: Color(0xFF171233),
    stars: true,
    celestial: Celestial.moon,
  );

  /// 06:00 → 11:00: the bright morning blue with haze at the horizon.
  static const NoorSky morning = NoorSky(
    top: Color(0xFF1E74BE),
    mid: Color(0xFF5AA6DD),
    bottom: Color(0xFFCFE7F5),
    silhouette: Color(0xFF1F3B54),
    celestial: Celestial.sun,
  );

  /// 11:00 → 16:00: noon — deeper blue overhead, pale and hazy at the ground.
  static const NoorSky afternoon = NoorSky(
    top: Color(0xFF1F7FC4),
    mid: Color(0xFF5FB0E0),
    bottom: Color(0xFFD9EDF7),
    silhouette: Color(0xFF24405A),
    celestial: Celestial.sun,
  );

  /// 16:00 → 19:00: Maghrib — indigo above, the sun sitting on the horizon.
  static const NoorSky evening = NoorSky(
    top: Color(0xFF2E2159),
    mid: Color(0xFF8A4C74),
    bottom: Color(0xFFF2A478),
    silhouette: Color(0xFF241436),
    celestial: Celestial.sun,
  );

  /// 19:00 → 21:00: the purple hour before true night.
  static const NoorSky dusk = NoorSky(
    top: Color(0xFF16123A),
    mid: Color(0xFF463C7C),
    bottom: Color(0xFF9E7F98),
    silhouette: Color(0xFF0F0B26),
    stars: true,
    celestial: Celestial.moon,
  );

  /// The sky the reader is actually standing under.
  static NoorSky of([DateTime? at]) {
    final int hour = (at ?? DateTime.now()).hour;
    if (hour < 4) return night;
    if (hour < 6) return dawn;
    if (hour < 11) return morning;
    if (hour < 16) return afternoon;
    if (hour < 19) return evening;
    if (hour < 21) return dusk;
    return night;
  }

  /// The hours the sky changes at — the only six instants in a day when both
  /// the gradient and everything cut from it have to be rebuilt.
  static const List<int> changeHours = <int>[4, 6, 11, 16, 19, 21];

  /// The next moment after [at] at which [of] answers differently.
  ///
  /// Strictly after: a timer armed for exactly the boundary must not arm
  /// itself again for the same instant.
  static DateTime nextChange(DateTime at) {
    for (final int hour in changeHours) {
      final DateTime boundary = DateTime(at.year, at.month, at.day, hour);
      if (boundary.isAfter(at)) return boundary;
    }
    return DateTime(at.year, at.month, at.day + 1, changeHours.first);
  }
}

// ===========================================================================
//  THE CARD MATERIAL — one material, whatever hour it is
// ===========================================================================

/// What the floating surfaces are made of.
///
/// The sky is still this app's wallpaper — navy at night, blue at breakfast,
/// magenta at sunset — but the re-skin pinned the furniture: the page reads
/// as warm daylight at 3 a.m. too, so every sky resolves to the same
/// white-card-with-warm-hairline material (see [NoorLook.from]). The sky
/// decides what is *painted*; the material decides what is *furniture*, and
/// after the re-skin the furniture no longer moves with the wallpaper.
@immutable
class NoorLook {
  const NoorLook({
    required this.base,
    required this.fill,
    required this.border,
    required this.shadowColor,
    required this.glow,
  });

  /// The app's one material, whatever hour it is: a white card floating on
  /// the cream page with a warm hairline and a soft, low shadow — the shape
  /// every card in the reference design is cut from.
  ///
  /// The sky no longer derives it: six skies once meant six materials, but
  /// the re-skin pinned the furniture so the page reads as warm daylight at
  /// 3 a.m. too. Every hour therefore resolves to this same value, which
  /// collapses the equality below — a rebuild on a sky that changed nothing
  /// is a rebuild of nothing.
  factory NoorLook.from(NoorSky sky) => const NoorLook(
        base: NoorColors.white,
        // Opaque white: the card is a card, not a pane of glass over a sky
        // that is no longer painted behind it.
        fill: NoorColors.white,
        // A warm hairline, not a cold one — the edge of paper, not of glass.
        border: Color(0x1A3A2E22),
        // The shadow is cut from the same warm ink the type is, so the card
        // lands on the cream page instead of floating above a grey haze.
        shadowColor: Color(0x1F3A2E22),
        // The faint peach wash down the top edge: the accent colour catching
        // the light, the one thing left that remembers the sky.
        glow: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0x14E39A6B), Color(0x00E39A6B)],
          stops: <double>[0, 0.55],
        ),
      );

  /// The opaque colour the material is built from — before the wash of
  /// transparency that turns it into glass.
  final Color base;

  /// The wash laid over the blurred sky. This is the colour the eye reads.
  final Color fill;

  /// The hairline that makes an edge catch light.
  final Color border;

  /// The colour a card floats on.
  final Color shadowColor;

  /// The wash of light down from the top edge.
  final Gradient glow;

  /// The shadow every card floats on: soft, low, never a hard black edge.
  List<BoxShadow> get shadow => <BoxShadow>[
        BoxShadow(color: shadowColor, blurRadius: 26, offset: const Offset(0, 12)),
      ];

  /// Value equality matters: `NoorGlassScope` uses it to decide whether a
  /// sky that did not actually change is worth rebuilding the screen for.
  @override
  bool operator ==(Object other) =>
      other is NoorLook &&
      other.base == base &&
      other.fill == fill &&
      other.border == border &&
      other.shadowColor == shadowColor &&
      other.glow == glow;

  @override
  int get hashCode => Object.hash(base, fill, border, shadowColor, glow);
}

/// Small deterministic random — the skyline has to look the same on every
/// repaint, otherwise the city would flicker.
class _Rng {
  _Rng(this.seed);

  int seed;

  double next() {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x7fffffff;
  }

  double range(double a, double b) => a + next() * (b - a);
}

/// Paints a whole screen's background: gradient, stars, moon or sun, and two
/// rows of mosque skyline silhouettes.
///
/// [paintSky] turns the *drawn* sky off while leaving everything standing on
/// it in place. That is the shape a photograph needs: the owner's wallpaper
/// supplies the colour and the light, and the skyline — the one thing that
/// makes a background read as Noor's rather than as any picture — stays in
/// front of it, with a scrim between so white type on glass has something to
/// hold against whatever was uploaded.
class SkyPainter extends CustomPainter {
  const SkyPainter(this.sky, {this.paintSky = true});

  final NoorSky sky;

  /// Whether to paint the gradient, stars and sun/moon. `false` means "a
  /// photograph is already underneath this" — the skyline still draws, the
  /// clock's own colours do not.
  final bool paintSky;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    if (paintSky) {
      canvas.drawRect(
        rect,
        Paint()..shader = sky.gradient.createShader(rect),
      );

      if (sky.stars) _stars(canvas, size);
      switch (sky.celestial) {
        case Celestial.sun:
          _sun(canvas, size);
          break;
        case Celestial.moon:
          _moon(canvas, size);
          break;
        case Celestial.none:
          break;
      }
    } else {
      // Over a photograph there is no gradient to lean on, so the veil has to
      // come from here: dark enough at the bottom for the glass cards to read
      // the same, light enough at the top that the picture is still the
      // picture.
      canvas.drawRect(
        rect,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[Color(0x2B000000), Color(0x59000000)],
          ).createShader(rect),
      );
    }

    // Far row first (paler, shorter), then the near row in front of it.
    _skylineRow(
      canvas,
      size,
      Paint()..color = sky.silhouette.withValues(alpha: 0.34),
      rng: _Rng(7),
      ground: size.height + 8,
      unitMin: 56,
      unitMax: 104,
      band: 0.07,
      spread: 0.07,
    );
    _skylineRow(
      canvas,
      size,
      Paint()..color = sky.silhouette,
      rng: _Rng(31),
      ground: size.height + 2,
      unitMin: 74,
      unitMax: 142,
      band: 0.10,
      spread: 0.10,
    );

    // A whisper of shade right at the very bottom so the floating bar reads as
    // floating. Nothing above it — the sky should stay clean.
    final Rect foot =
        Rect.fromLTWH(0, size.height * 0.80, size.width, size.height * 0.20);
    canvas.drawRect(
      foot,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Colors.transparent, Color(0x26000000)],
        ).createShader(foot),
    );
  }

  void _stars(Canvas canvas, Size size) {
    final _Rng rng = _Rng(99);
    final Paint paint = Paint();
    for (int i = 0; i < 70; i++) {
      paint.color = Colors.white.withValues(alpha: rng.range(0.25, 0.95));
      canvas.drawCircle(
        Offset(rng.range(6, size.width - 6), rng.range(6, size.height * 0.62)),
        rng.range(0.6, 1.8),
        paint,
      );
    }
  }

  /// The sun sits where it actually is — low, behind the skyline, so the
  /// buildings cut into it instead of a white ball floating in the UI.
  void _sun(Canvas canvas, Size size) {
    final Offset centre = Offset(size.width * 0.74, size.height * 0.815);
    final double r = size.shortestSide * 0.075;
    final Paint glow = Paint()
      ..shader = const RadialGradient(
        colors: <Color>[Color(0x73FFE3B8), Color(0x00FFE3B8)],
      ).createShader(Rect.fromCircle(center: centre, radius: r * 3.8));
    canvas.drawCircle(centre, r * 3.8, glow);
    canvas.drawCircle(centre, r, Paint()..color = const Color(0xFFFFF3DC));
  }

  void _moon(Canvas canvas, Size size) {
    final Offset centre = Offset(size.width * 0.90, size.height * 0.16);
    final double r = size.shortestSide * 0.040;
    final Path full = Path()..addOval(Rect.fromCircle(center: centre, radius: r));
    final Path cut = Path()
      ..addOval(Rect.fromCircle(
        center: centre + Offset(r * 0.52, -r * 0.34),
        radius: r * 0.99,
      ));
    final Paint glow = Paint()
      ..shader = RadialGradient(
        colors: <Color>[
          Colors.white.withValues(alpha: 0.30),
          Colors.white.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromCircle(center: centre, radius: r * 2.6));
    canvas.drawCircle(centre, r * 2.6, glow);
    canvas.drawPath(
      Path.combine(PathOperation.difference, full, cut),
      Paint()..color = Colors.white.withValues(alpha: 0.95),
    );
  }

  /// Walks the width laying down blocks, domed halls and minarets.
  void _skylineRow(
    Canvas canvas,
    Size size,
    Paint paint, {
    required _Rng rng,
    required double ground,
    required double unitMin,
    required double unitMax,
    required double band,
    required double spread,
  }) {
    double x = -70;
    while (x < size.width + 70) {
      final double w = rng.range(unitMin, unitMax);
      final double h = size.height * rng.range(band, band + spread);
      final int kind = (rng.next() * 4).floor();

      switch (kind) {
        case 1: // domed prayer hall
          canvas.drawRect(Rect.fromLTRB(x, ground - h, x + w, ground), paint);
          _dome(canvas, x + w / 2, ground - h, w * 0.34, paint);
          break;
        case 2: // minaret
          _minaret(canvas, x + w / 2, ground, h * 1.4, w * 0.30, paint);
          break;
        case 3: // hall flanked by two minarets
          canvas.drawRect(
              Rect.fromLTRB(x + w * 0.16, ground - h, x + w * 0.84, ground), paint);
          _dome(canvas, x + w / 2, ground - h, w * 0.26, paint);
          _minaret(canvas, x + w * 0.12, ground, h * 1.3, w * 0.18, paint);
          _minaret(canvas, x + w * 0.88, ground, h * 1.3, w * 0.18, paint);
          break;
        default: // low house with a small dome — never a bare skyscraper
          final double bh = h * 0.70;
          canvas.drawRect(Rect.fromLTRB(x, ground - bh, x + w, ground), paint);
          _dome(canvas, x + w * 0.58, ground - bh, w * 0.22, paint);
          break;
      }

      x += w + rng.range(6, 26);
    }
  }

  /// Half circle sitting on [cy], with the little finial every dome carries.
  void _dome(Canvas canvas, double cx, double cy, double r, Paint paint) {
    final Path dome = Path()
      ..moveTo(cx - r, cy)
      ..arcTo(
        Rect.fromCircle(center: Offset(cx, cy), radius: r),
        math.pi,
        math.pi,
        true,
      )
      ..close();
    canvas.drawPath(dome, paint);
    canvas.drawRect(Rect.fromLTWH(cx - 1.4, cy - r - 9, 2.8, 10), paint);
    canvas.drawCircle(Offset(cx, cy - r - 10), 2.6, paint);
  }

  /// Slender tower with a balcony and a pointed cap.
  void _minaret(
      Canvas canvas, double cx, double ground, double h, double w, Paint paint) {
    final double top = ground - h;
    canvas.drawRect(Rect.fromLTWH(cx - w / 2, top, w, ground - top), paint);
    canvas.drawRect(Rect.fromLTWH(cx - w * 0.9, top, w * 1.8, w * 0.55), paint);
    final Path cap = Path()
      ..moveTo(cx - w * 0.85, top)
      ..lineTo(cx, top - h * 0.26)
      ..lineTo(cx + w * 0.85, top)
      ..close();
    canvas.drawPath(cap, paint);
    canvas.drawCircle(Offset(cx, top - h * 0.26 - w * 0.4), w * 0.38, paint);
  }

  @override
  bool shouldRepaint(SkyPainter oldDelegate) =>
      oldDelegate.sky != sky || oldDelegate.paintSky != paintSky;
}

/// The background itself: edge to edge, behind whatever the screen puts up.
///
/// Two backgrounds, one widget. With no owner-set wallpaper it is the drawn
/// sky it has always been; with one, the photograph fills the screen and the
/// skyline is painted in front of it. It listens to [AppConfig] so a wallpaper
/// set from the panel lands on the screens that are already open — the change
/// is the whole feature, and a wallpaper that needs a restart would not be one.
class MosqueScape extends StatefulWidget {
  const MosqueScape({super.key, this.sky});

  /// Defaults to the sky for the current hour.
  final NoorSky? sky;

  @override
  State<MosqueScape> createState() => _MosqueScapeState();
}

class _MosqueScapeState extends State<MosqueScape> {
  @override
  void initState() {
    super.initState();
    AppConfig.instance.addListener(_configChanged);
  }

  @override
  void dispose() {
    AppConfig.instance.removeListener(_configChanged);
    super.dispose();
  }

  void _configChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ImageProvider? wallpaper = AppConfig.instance.wallpaperImage;

    if (wallpaper == null) {
      // The re-skin drops the drawn sky: the page is flat warm cream, the
      // cards are white, and nothing behind them changes with the clock.
      return const ColoredBox(
        color: NoorColors.cream,
        child: SizedBox.expand(),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // The owner's photograph, still fully working through remote config.
        // Its error builder falls back to the same flat cream the page is
        // painted with, so a wallpaper that fails to decode never becomes a
        // black rectangle.
        Image(
          image: wallpaper,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) => const ColoredBox(
            color: NoorColors.cream,
            child: SizedBox.expand(),
          ),
        ),
        // A *light* scrim, not the old night veil: the photo reads as a soft
        // wash behind the white cards, and any type sitting straight on the
        // page still has cream-level contrast against it.
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[Color(0xA6FAF6F0), Color(0xE6FAF6F0)],
              ),
            ),
            child: SizedBox.expand(),
          ),
        ),
      ],
    );
  }
}

/// A [Scaffold] wearing the sky: the gradient and skyline run behind the
/// status bar, the app bar and the bottom bar alike.
///
/// This widget owns both halves of the wallpaper. It picks the sky — the one
/// passed in, or the one the clock says — and hands the matching [NoorLook]
/// to everything behind it through [NoorGlassScope], then arms a timer for
/// the next hour the sky changes at. So a screen does not need to know that
/// either of them moves: at the boundary it repaints the gradient *and* the
/// cards cut from it, together, in one frame.
class NoorScaffold extends StatefulWidget {
  const NoorScaffold({
    super.key,
    this.sky,
    this.appBar,
    required this.body,
    this.bottomNavigationBar,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.bottomSheet,
    this.drawer,
    this.endDrawer,
    this.extendBody = false,
    this.resizeToAvoidBottomInset,
  });

  /// When null the sky follows the clock; when set it is frozen (the splash
  /// and the login screen paint night whatever the hour), and so is the
  /// material — no timer, nothing to repaint.
  final NoorSky? sky;
  final PreferredSizeWidget? appBar;
  final Widget body;
  final Widget? bottomNavigationBar;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final Widget? bottomSheet;
  final Widget? drawer;
  final Widget? endDrawer;
  final bool extendBody;
  final bool? resizeToAvoidBottomInset;

  @override
  State<NoorScaffold> createState() => _NoorScaffoldState();
}

class _NoorScaffoldState extends State<NoorScaffold> {
  Timer? _skyTimer;

  @override
  void initState() {
    super.initState();
    _armSkyTimer();
  }

  @override
  void didUpdateWidget(NoorScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.sky == null) != (widget.sky == null)) _armSkyTimer();
  }

  /// Schedules a rebuild for the next instant the sky changes.
  ///
  /// The timer only *wakes the screen up*: the new sky and the new material
  /// are both read from the clock inside [build], so a timer that fires a
  /// moment early or late still lands on the right pair, and one that fires
  /// with the sky unchanged simply re-arms itself for the real boundary.
  void _armSkyTimer() {
    _skyTimer?.cancel();
    if (widget.sky != null) return;

    final Duration wait = NoorSky.nextChange(DateTime.now())
        .difference(DateTime.now());
    _skyTimer = Timer(
      wait > Duration.zero ? wait : const Duration(seconds: 1),
      () {
        if (!mounted) return;
        setState(_armSkyTimer);
      },
    );
  }

  @override
  void dispose() {
    _skyTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Read here, not cached: this is the one place that must know which sky
    // is on screen, and the timer guarantees it is asked again on time.
    final NoorSky painted = widget.sky ?? NoorSky.of();

    return NoorGlassScope(
      look: NoorLook.from(painted),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Positioned.fill(
            child: IgnorePointer(child: MosqueScape(sky: painted)),
          ),
          Scaffold(
            backgroundColor: Colors.transparent,
            appBar: widget.appBar,
            body: widget.body,
            bottomNavigationBar: widget.bottomNavigationBar,
            floatingActionButton: widget.floatingActionButton,
            floatingActionButtonLocation: widget.floatingActionButtonLocation,
            bottomSheet: widget.bottomSheet,
            drawer: widget.drawer,
            endDrawer: widget.endDrawer,
            extendBody: widget.extendBody,
            resizeToAvoidBottomInset: widget.resizeToAvoidBottomInset,
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
//  BOTTOM BAR
// ===========================================================================

class NoorTab {
  const NoorTab(this.icon, this.activeIcon, this.label);

  /// Resting icon — every tab uses the same outline family so the bar reads
  /// as one set, not four collections.
  final IconData icon;

  /// The same outline glyph, so the only thing that changes when a tab lights
  /// up is the accent colour — the shape family never shifts under the eye.
  final IconData activeIcon;

  final String label;
}

/// The bar the mockup's app never had but this one needs: where you are is
/// one tap away from anywhere else.
class NoorBottomBar extends StatelessWidget {
  const NoorBottomBar({super.key, required this.index, required this.onChanged});

  static const List<NoorTab> tabs = <NoorTab>[
    NoorTab(Icons.watch_later_outlined, Icons.watch_later_outlined, 'Home'),
    NoorTab(Icons.mosque_outlined, Icons.mosque_outlined, 'Nearby'),
    NoorTab(Icons.favorite_border, Icons.favorite_border, 'Favourites'),
    NoorTab(Icons.person_outline, Icons.person_outline, 'Profile'),
  ];

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final BorderRadius r = BorderRadius.circular(24);
    final NoorLook look = NoorGlass.of(context);
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      // Shadow lives on an unclipped wrapper so it can spill past the glass.
      child: Container(
        decoration: BoxDecoration(
          borderRadius: r,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: look.shadowColor.withValues(alpha: 0.42),
              blurRadius: 30,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: r,
          // Same material as every card: the sky, blurred, under the wash of
          // this hour's panel colour. The bar floats on the gradient with it.
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(
              sigmaX: NoorGlass.blurSigma,
              sigmaY: NoorGlass.blurSigma,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: look.fill,
                borderRadius: r,
                border: Border.all(color: look.border, width: 1),
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(gradient: look.glow),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 7),
                  child: Row(
                    children: <Widget>[
                      for (int i = 0; i < tabs.length; i++)
                        Expanded(
                          child: _Destination(
                            index: i,
                            tab: tabs[i],
                            selected: i == index,
                            onTap: () => onChanged(i),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Destination extends StatelessWidget {
  const _Destination({
    required this.index,
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final NoorTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: tab.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          decoration: BoxDecoration(
            color: selected
                ? NoorColors.gold.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                selected ? tab.activeIcon : tab.icon,
                size: 22,
                color: selected
                    ? NoorColors.emeraldDeep
                    : NoorColors.muted,
              ),
              const SizedBox(height: 3),
              Text(
                tab.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.outfit(
                  fontSize: 9.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected
                      ? NoorColors.emeraldDeep
                      : NoorColors.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
//  GLASS PANELS
// ===========================================================================

/// Provides [NoorLook] to the subtree below it — the material that subtree's
/// cards are cut from.
///
/// [NoorScaffold] installs one around every screen, from the sky that screen
/// is actually painting, so the wallpaper and everything standing on it are
/// always rebuilt from the same hour. A widget that asks outside any scope
/// (a dialog, a bare test harness) falls back to the sky right now.
class NoorGlassScope extends InheritedWidget {
  const NoorGlassScope({super.key, required this.look, required super.child});

  final NoorLook look;

  static NoorLook of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NoorGlassScope>()?.look ??
      NoorLook.from(NoorSky.of());

  @override
  bool updateShouldNotify(NoorGlassScope oldWidget) => oldWidget.look != look;
}

/// Every floating surface in the app is cut from this one material — same
/// fill, same hairline — so cards, panels and buttons read as one family.
///
/// The material is not a constant: it is derived from the sky (see
/// [NoorLook.from]) and handed down by [NoorGlassScope], so it changes in the
/// same frame the background does. Only the two numbers that are *not* colour
/// — [radius] and [blurSigma] — stay fixed, because a family that changes
/// shape is not a family.
class NoorGlass {
  const NoorGlass._();

  /// The material in force for the screen this context belongs to.
  static NoorLook of(BuildContext context) => NoorGlassScope.of(context);

  /// One blur shared by every card, so the backdrop is sampled the same way
  /// everywhere and the surfaces feel machined from the same sheet.
  static const double blurSigma = 18;

  /// 24dp everywhere — one radius, one family.
  static const double radius = 24;
}

/// The mockup's floating panel: blurred glass, hairline border, room for a
/// section title above the rows.
///
/// The backdrop is sampled through a [BackdropFilter], so the panel takes its
/// colour from the sky behind it and blends into the gradient instead of
/// sitting on top of it as a solid block.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(14, 14, 14, 14),
    this.radius = NoorGlass.radius,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final BorderRadius r = BorderRadius.circular(radius);
    final NoorLook look = NoorGlass.of(context);
    return Container(
      decoration: BoxDecoration(borderRadius: r, boxShadow: look.shadow),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(
            sigmaX: NoorGlass.blurSigma,
            sigmaY: NoorGlass.blurSigma,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: look.fill,
              borderRadius: r,
              border: Border.all(color: look.border, width: 1),
            ),
            // Painted after the fill but before the content: the wash of light
            // that keeps the panel from reading as a flat cut-out.
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: look.glow),
              child: Padding(padding: padding, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
//  AVATAR — one circle, one place, no sliver of panel peeking through
// ===========================================================================

/// A photo (or its placeholder) in a perfect circle.
///
/// Every circular photo in the app — the app-bar chip, the big Profile
/// portrait, the preview inside the edit dialog — goes through this one
/// widget so they can never drift apart again.
///
/// Why it is built this way: a [Container] that owns the border *insets its
/// child by the border width* (the decoration's padding), so a photo drawn
/// that way stops a hair short of the circle on all four sides and the panel
/// behind shows through as a sliver. Here the layers are siblings instead —
/// background, photo, hairline — so nothing can shrink the picture: the photo
/// fills the circle edge to edge, and the hairline is painted *over* it.
class PerfectCircleAvatar extends StatelessWidget {
  const PerfectCircleAvatar({
    super.key,
    required this.size,
    this.image,
    this.borderWidth = 2,
    this.borderColor = NoorColors.gold,
    this.background = NoorColors.emeraldDeep,
    this.icon = Icons.person_outlined,
    this.shadow = const <BoxShadow>[],
  });

  /// Outer diameter of the circle (the hairline sits inside it).
  final double size;

  /// `FileImage` for a locally picked portrait, `NetworkImage` for the
  /// Firebase one, `null` for the placeholder icon.
  final ImageProvider? image;

  final double borderWidth;
  final Color borderColor;

  /// Painted behind the photo — also what the placeholder icon sits on.
  final Color background;
  final IconData icon;
  final List<BoxShadow> shadow;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // 1. The disc itself, sized exactly, so the photo always has a
          //    circle-shaped bed of the right colour under it.
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: background,
              boxShadow: shadow,
            ),
          ),
          // 2. The photo, clipped by its own oval to those same bounds and
          //    laid out with no decoration around it: `BoxFit.cover` crops,
          //    it never letterboxes, so there is no room for a gap.
          Positioned.fill(
            child: ClipOval(
              child: image == null
                  ? Center(
                      child: Icon(icon, size: size * 0.42, color: NoorColors.white),
                    )
                  : Image(
                      image: image!,
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (_, _, _) => Center(
                        child: Icon(icon, size: size * 0.42, color: NoorColors.white),
                      ),
                    ),
            ),
          ),
          // 3. Hairline last, on top: a ring can never push the photo back.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: borderColor, width: borderWidth),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
//  MASJID LOGO — the mark that starts a masjid row
// ===========================================================================

/// The logo plate at the head of a masjid row: a pale peach tile with an
/// apricot hairline, so the deep-apricot mosque glyph reads against it the
/// way the reference design cuts its icon chips.
///
/// The Nearby/Favourites cards and the masjid detail header cut their logo
/// from this one component. Keeping it in one place matters — the old dark
/// plate belonged to the night glass the re-skin took away, and a gold glyph
/// on a gold plate is invisible. One component, one fix, everywhere.
class MasjidLogo extends StatelessWidget {
  const MasjidLogo({super.key, this.size = 42});

  /// Edge of the square plate; the radius and the glyph scale with it.
  final double size;

  @override
  Widget build(BuildContext context) {
    // A wash of the accent, darker than the white card it sits on, so the
    // plate reads as a plate; the hairline keeps its edge at any size.
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: NoorColors.goldSoft,
        borderRadius: BorderRadius.circular(size * 0.33),
        border: Border.all(
          color: NoorColors.gold.withValues(alpha: 0.55),
          width: 1.2,
        ),
      ),
      child: Icon(
        Icons.mosque_outlined,
        size: size * 0.52,
        color: NoorColors.emeraldDeep,
      ),
    );
  }
}

// ===========================================================================
//  HERO — the mockup's "Next prayer time" head of screen
// ===========================================================================

/// City, the time of the prayer due next, and the seconds left in the big
/// type the mockup opens with.
class NextPrayerHero extends StatefulWidget {
  const NextPrayerHero({
    super.key,
    required this.latitude,
    required this.longitude,
    required this.areaName,
    this.board,
    this.onOpenQibla,
    this.onOpenTasbeeh,
    this.onOpenTracker,
    this.debugNow,
  });

  final double latitude;
  final double longitude;
  final String areaName;

  /// The three doors under the cards. Optional: the hero lays the row out
  /// either way, and a null callback simply leaves the door shut — which is
  /// all any test needs to render it.
  final VoidCallback? onOpenQibla;
  final VoidCallback? onOpenTasbeeh;
  final VoidCallback? onOpenTracker;

  /// Pins "now" for a test.
  ///
  /// The hero reads the wall clock every second, which no test can steer at
  /// the makruh boundary; production passes nothing and reads the real one.
  @visibleForTesting
  final DateTime? debugNow;

  /// The masjid whose Jamaat column this hero quotes — the same board the
  /// Today card quotes. Card B's clock runs down to the time the reader
  /// will actually stand in sujood at, while *which* prayer is on — and
  /// the moment the hero switches — stays on the official clock: Isha's
  /// Awwal moves the card at Isha's Awwal, never at a later Jamaat.
  ///
  /// `null` (nothing starred, or a board with no times on it) leaves every
  /// clock on this card calculated, exactly as before.
  final Masjid? board;

  @override
  State<NextPrayerHero> createState() => _NextPrayerHeroState();
}

class _NextPrayerHeroState extends State<NextPrayerHero> {
  Timer? _ticker;
  _HeroEntry? _next;

  /// The prayer whose time is on *right now*, on the official clock.
  _HeroEntry? _prev;

  /// The *calculated* start of [_next] — card A's End line, and the
  /// instant its big countdown reaches zero.
  DateTime? _nextCalc;

  /// The board's own Jamaat for [_next], when the masjid publishes one.
  ///
  /// Card B prints this under its big Awwal — the moment the reader will
  /// stand in sujood — while *which* prayer is next stays on the official
  /// clock: a Jamaat may move the number card B prints small, never the
  /// moment the hero switches prayers.
  DateTime? _nextJamaat;

  /// Today's makruh (Zawal) window, carried from the same recompute so
  /// card A never has to ask `AppSettings.compute` again — that call owns a
  /// single slot and a second ask would evict the day's times mid-build.
  ///
  /// Held only while the clock is *inside* it (see [_recompute]): card A
  /// announces the window during Makruh and falls silent the rest of the
  /// day — a standing note about 11:56 would read as if it were always due.
  ({DateTime start, DateTime end})? _makruh;

  /// Last night's Isha, held against the coordinates and date it was asked
  /// for — see [_beforeFajr].
  String? _beforeKey;
  DateTime? _beforeIsha;

  static const List<String> _keys = <String>[
    'fajr',
    'sunrise',
    'dhuhr',
    'asr',
    'maghrib',
    'isha',
  ];

  static const Map<String, String> _labels = <String, String>{
    'fajr': 'Fajr',
    'sunrise': 'Sunrise',
    'dhuhr': 'Dhuhr',
    'asr': 'Asr',
    'maghrib': 'Maghrib',
    'isha': 'Isha',
  };

  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_settingsChanged);
    _recompute();
    // One second: this number counts down in front of the reader.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _recompute());
  }

  void _settingsChanged() {
    // Method or madhab moved: last night's Isha is now a different answer.
    _beforeKey = null;
    _recompute();
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(NextPrayerHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A board that has just been starred (or unstarred) must not wait for the
    // next tick to move the countdown.
    if (oldWidget.board?.id != widget.board?.id) _recompute();
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_settingsChanged);
    _ticker?.cancel();
    super.dispose();
  }

  /// The five prayers a board carries. `sunrise` is not one of them and no
  /// masjid publishes it, so sunrise always stays on the calculated clock.
  static const List<String> _prayerKeys = <String>[
    'fajr',
    'dhuhr',
    'asr',
    'maghrib',
    'isha',
  ];

  /// The board's own Jamaat clock for [key], placed on [onDay]'s calendar.
  ///
  /// `--:--`, blanks and anything else unparseable read as *no board time*,
  /// so a prayer this masjid does not publish simply stays calculated.
  static DateTime? _jamaatOn(Masjid board, String key, DateTime onDay) {
    final int? minutes = NotificationService.parseClockTime(board.timeFor(key));
    if (minutes == null) return null;
    return DateTime(onDay.year, onDay.month, onDay.day, minutes ~/ 60, minutes % 60);
  }

  /// The board quoted on this card, or `null` when it publishes none of the
  /// five — a starred masjid with an empty board must not claim the credit,
  /// or its name on the subtitle, for times that are still calculated.
  Masjid? get _quotedBoard {
    final Masjid? board = widget.board;
    if (board == null) return null;
    for (final String key in _prayerKeys) {
      if (NotificationService.parseClockTime(board.timeFor(key)) != null) {
        return board;
      }
    }
    return null;
  }

  void _recompute() {
    if (!mounted) return;

    final AppSettings settings = AppSettings.instance;
    final DateTime now = widget.debugNow ?? DateTime.now();
    final LocalPrayerTimes day = settings.compute(
      latitude: settings.customLatitude ?? widget.latitude,
      longitude: settings.customLongitude ?? widget.longitude,
    );

    // The hero runs on the *official* clock: which prayer is on and which
    // is due come straight off the calculated times, so a board's later
    // Jamaat can never hold the card back — Isha's Awwal moves the hero at
    // Isha's Awwal, whether or not a masjid quotes a later Jamaat. The
    // board's own moment is fetched separately, for card B.
    final Map<String, DateTime> at = day.times;
    final Masjid? quoted = _quotedBoard;

    _HeroEntry? next;
    _HeroEntry? prev;
    String? nextKey;
    for (final String key in _keys) {
      final DateTime? startsAt = at[key];
      if (startsAt == null) continue;
      if (startsAt.isAfter(now)) {
        next ??= _HeroEntry(_labels[key]!, startsAt);
        nextKey ??= key;
      } else {
        prev = _HeroEntry(_labels[key]!, startsAt);
      }
    }
    // Past Isha the count runs down to tomorrow's calculated Fajr — the
    // board's own Fajr Jamaat rides on card B, as it does all day.
    DateTime? nextCalc;
    if (next == null) {
      next = _HeroEntry('Fajr (tomorrow)', day.fajrTomorrow);
      nextCalc = day.fajrTomorrow;
    } else {
      nextCalc = day.times[nextKey];
    }
    // Before Fajr nothing has started today, so the prayer still in force
    // is last night's Isha — card A must not go blank for five hours.
    prev ??= _beforeFajr(now);

    // The board's own moment for the prayer due next, when it publishes
    // one: the small clock card B prints under its Awwal, and nothing
    // more.
    final DateTime? nextJamaat = quoted == null
        ? null
        : nextKey == null
            ? _jamaatOn(quoted, 'fajr', day.fajrTomorrow)
            : _jamaatOn(quoted, nextKey, now);

    // The window itself, gated to the minutes it covers: card A warns
    // *during* Makruh and falls silent once Dhuhr opens — the reader is
    // told once, at the hour it matters, not left a standing note.
    final ({DateTime start, DateTime end})? zawal = day.makruhWindow;

    setState(() {
      _next = next;
      _prev = prev;
      _nextCalc = nextCalc;
      _nextJamaat = nextJamaat;
      _makruh = zawal != null &&
              !now.isBefore(zawal.start) &&
              now.isBefore(zawal.end)
          ? zawal
          : null;
    });
  }

  /// The prayer in force between midnight and Fajr: yesterday's Isha.
  ///
  /// Computed for yesterday rather than guessed as "today's Isha minus a
  /// day" — the clock drifts a minute or two between days and this card
  /// quotes times the reader may be acting on.
  ///
  /// The answer is held against the coordinates and calendar date it was
  /// asked for: `AppSettings.compute` keeps a single slot, and re-asking it
  /// for yesterday on every tick would evict today's times in a loop.
  _HeroEntry? _beforeFajr(DateTime now) {
    final DateTime yesterday = DateTime(now.year, now.month, now.day - 1);
    final AppSettings settings = AppSettings.instance;
    final double lat = settings.customLatitude ?? widget.latitude;
    final double lng = settings.customLongitude ?? widget.longitude;
    final String key =
        '$lat|$lng|${yesterday.year}-${yesterday.month}-${yesterday.day}';
    if (key != _beforeKey) {
      _beforeIsha = settings
          .compute(latitude: lat, longitude: lng, day: yesterday)
          .times['isha'];
      _beforeKey = key;
    }
    final DateTime? isha = _beforeIsha;
    if (isha == null) return null;
    // The calculated Isha: card A runs on the official clock, so the
    // prayer "on" at 2 a.m. is last night's Isha at its own time, not a
    // board's later Jamaat for it.
    return _HeroEntry('Isha', isha);
  }

  /// The countdown in `hh:mm:ss`, clamped at zero — card A's big number.
  static String _clock(Duration d) {
    if (d.isNegative) d = Duration.zero;
    final String hh = d.inHours.toString().padLeft(2, '0');
    final String mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final String ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }

  /// Whether the board quotes its own Jamaat for the prayer due next, at
  /// least half a minute away from the calculated start.
  ///
  /// The pair card B exists to print — Awwal beside Jamaat — is only worth
  /// a card when its two clocks differ. With no board quoted, or a masjid
  /// that prays on the calculated clock, they are one and the same instant
  /// and card B would merely restate card A's clock under a second header.
  /// It then does not render at all and card A runs the full width: the
  /// pair exists to say two different things, never the same one twice.
  bool _boardQuotesAnotherTime(_HeroEntry? next) {
    final DateTime? jamaatAt = _nextJamaat;
    return next != null &&
        jamaatAt != null &&
        jamaatAt.difference(next.at).abs() >= const Duration(seconds: 30);
  }

  @override
  Widget build(BuildContext context) {
    // One instant for the whole build — the same `now` picks the prayer in
    // force, feeds both countdowns and decides whether zawal is on.
    final DateTime now = widget.debugNow ?? DateTime.now();
    final _HeroEntry? next = _next;
    final _HeroEntry? prev = _prev;
    // Card A: what is left of the prayer whose time is on *right now*. It
    // counts down to the very instant the card prints on its End line, so
    // the big number reaches zero exactly when that clock arrives.
    final DateTime? endsAt = _nextCalc ?? next?.at;
    final Duration remaining =
        endsAt == null ? Duration.zero : endsAt.difference(now);
    // How much of the running prayer's window has already passed — the
    // rail under card A's type. A countdown says what is left; this says
    // how far in the reader is, which every big prayer app puts under its
    // hero because the two facts are read together.
    final DateTime? beganAt = prev?.at;
    double progress = 0;
    if (beganAt != null &&
        endsAt != null &&
        endsAt.isAfter(beganAt)) {
      progress = now.difference(beganAt).inMilliseconds /
          endsAt.difference(beganAt).inMilliseconds;
      if (progress < 0) progress = 0;
      if (progress > 1) progress = 1;
    }
    final AppSettings settings = AppSettings.instance;

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // ------------------------------------- the makruh line, up top
          //
          // Not tucked inside a card where it reads as a footnote, and not
          // sitting in the Today card all day either: the half hour itself
          // stands above the pair — big, in the palette's one danger red —
          // for exactly the minutes it covers, then vanishes. When zawal is
          // on there is no missing it; when it is past there is no stale
          // note to ignore.
          if (_makruh != null) ...<Widget>[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: NoorColors.danger.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(NoorGlass.radius),
                border:
                    Border.all(color: NoorColors.danger.withValues(alpha: 0.30)),
              ),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 20,
                    color: NoorColors.danger,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Makruh ${settings.format(_makruh!.start)} – '
                      '${settings.format(_makruh!.end)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w700,
                        color: NoorColors.danger,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          // ---------------------------------------- the pair of cards
          //
          // Reference layout: what is running now — and what is left of
          // it — on the peach, what is due next on the white — side by
          // side, so one glance reads both.
          // IntrinsicHeight gives both cards the taller one's height: they
          // carry different lines of type and the reference wears them level.
          //
          // The white half earns its place only with a number card A does
          // not carry — a board's Jamaat elsewhere than the calculated
          // End. With nothing to add it does not render, and card A alone
          // runs the width: one fact printed once, never twice side by
          // side.
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: _nowCard(
                    prev: prev,
                    next: next,
                    remaining: remaining,
                    progress: progress,
                    settings: settings,
                  ),
                ),
                if (_boardQuotesAnotherTime(next)) ...<Widget>[
                  const SizedBox(width: 10),
                  Expanded(
                    child:
                        _nextCard(next: next, settings: settings),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),

          // ------------------------------- the three doors: Qibla, Tasbeeh,
          // Tracker. The Fajr/Iftar chips used to stand here; the reader
          // asked for the instruments instead — on Home, under the cards,
          // where the eye already is.
          Row(
            children: <Widget>[
              Expanded(
                child: _tool(
                  icon: Icons.explore_outlined,
                  label: 'Qibla',
                  onTap: widget.onOpenQibla,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _tool(
                  icon: Icons.pan_tool_alt_outlined,
                  label: 'Tasbeeh',
                  onTap: widget.onOpenTasbeeh,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _tool(
                  icon: Icons.fact_check_outlined,
                  label: 'Tracker',
                  onTap: widget.onOpenTracker,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The line glyph each prayer wears beside its name — the sun's own day
  /// arc: a moon while Fajr is still dark, twilight at the day's edges,
  /// the full sun at Dhuhr, the afternoon's high light at Asr, stars once
  /// Maghrib has landed, bedtime after Isha. Big prayer apps name the
  /// hour with a picture before the word; this is that picture, one glyph.
  static IconData _prayerIcon(String label) {
    if (label.startsWith('Fajr')) return Icons.dark_mode_outlined;
    if (label.startsWith('Sunrise')) return Icons.wb_twilight_outlined;
    if (label.startsWith('Dhuhr')) return Icons.wb_sunny_outlined;
    if (label.startsWith('Asr')) return Icons.brightness_high_outlined;
    if (label.startsWith('Maghrib')) return Icons.nights_stay_outlined;
    if (label.startsWith('Isha')) return Icons.bedtime_outlined;
    return Icons.mosque_outlined;
  }

  /// Card A — the peach one: the prayer whose time is on, what is left of
  /// it in big ticking type, and when the window it opened closes. The
  /// number counts down to the End line under it — one glance answers
  /// "how much of this namaz is still there" — and the rail at the bottom
  /// draws the same answer as distance: the window's span, filled to
  /// where the clock stands. The mosque silhouette anchors the corner,
  /// the way the reference's photograph sits under its type.
  Widget _nowCard({
    required _HeroEntry? prev,
    required _HeroEntry? next,
    required Duration remaining,
    required double progress,
    required AppSettings settings,
  }) {
    // Sunrise is not a prayer: nobody finishes a namaz at it, so "Time
    // left in Sunrise" would count down from a thing that does not exist.
    // Through the morning this card changes voice and runs the *next*
    // prayer's timer instead — the name, the big number and the line
    // below it all belong to Dhuhr then.
    final bool afterSunrise = prev != null && prev.label == 'Sunrise';
    final String shown = afterSunrise && next != null
        ? next.label
        : (prev == null ? '—' : prev.label);
    return Container(
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[NoorColors.goldSoft, NoorColors.emerald],
        ),
        borderRadius: BorderRadius.circular(NoorGlass.radius),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: NoorColors.gold.withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Stack(
        children: <Widget>[
          // The silhouette, dark on the peach exactly as the reference cuts
          // it, bleeding off the bottom-right corner behind the type.
          Positioned(
            right: -8,
            bottom: -14,
            child: Icon(
              Icons.mosque_outlined,
              size: 88,
              color: NoorColors.ink.withValues(alpha: 0.26),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                // The reference's own words: the peach card says "Now time
                // is" over the prayer that is on, and "End time - 3:54pm"
                // under the big clock. The clock stays a countdown — the
                // same fact, live — and the caption names the instant it
                // reaches zero.
                afterSunrise ? 'Next prayer in' : 'Now time is',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.outfit(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: NoorColors.ink.withValues(alpha: 0.72),
                ),
              ),
              Row(
                children: <Widget>[
                  if (prev != null)
                    Icon(
                      _prayerIcon(shown),
                      size: 17,
                      color: NoorColors.ink.withValues(alpha: 0.8),
                    ),
                  if (prev != null) const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      shown,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w700,
                        color: NoorColors.emeraldDeep,
                        height: 1.25,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              // The number the reader came for: what is left of the namaz
              // whose time is on, every second, down to the End line right
              // below it. Tabular figures so the colon never jitters as
              // the digits turn — the countdown reads as one fixed slot.
              Text(
                prev == null ? '--:--:--' : _clock(remaining),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.outfit(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: NoorColors.ink,
                  height: 1.1,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
              const SizedBox(height: 3),
              Text(
                // A prayer's official end is the *calculated* beginning of
                // the next one — never the board's Jamaat cell. A masjid
                // quoting "Fajr 6:05" does not move the moment Isha ends;
                // `_nextCalc` holds exactly that calculated figure for
                // `next`, and only falls back to the merged clock if the
                // first recompute has not landed yet. Through the morning
                // the card says the same instant as what it *begins* —
                // "End time" would end nothing for a reader waiting on
                // Dhuhr, so the line answers the voice the kicker used.
                afterSunrise && next != null
                    ? 'Begins - ${settings.format(_nextCalc ?? next.at)}'
                    : next == null
                        ? 'End time - —'
                        : 'End time - ${settings.format(_nextCalc ?? next.at)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.outfit(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: NoorColors.ink.withValues(alpha: 0.68),
                ),
              ),
              // The window's rail: the whole span from the moment this
              // prayer opened to the End above, filled to where the clock
              // stands now. Gated with the countdown — no window known,
              // no bar to draw.
              if (prev != null) ...<Widget>[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 6,
                      backgroundColor:
                          NoorColors.white.withValues(alpha: 0.55),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        NoorColors.ink,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// Card B — the white one: what is due next — its name and the pair the
  /// reader plans by: the Awwal the official clock opens the prayer at,
  /// carrying the big line, and the board's own Jamaat under it, small.
  /// Both clocks together, and nothing ticking — card A's number already
  /// counts; a second one would only compete with it. The card renders
  /// only where those two clocks are actually two (see
  /// [_boardQuotesAnotherTime]).
  ///
  /// The Awwal leads because it is the reader's own clock: the official
  /// opening is the instant the namaz begins wherever the reader stands,
  /// and it is the number the day is planned around. A favourite masjid's
  /// Jamaat is a *second* reading of the same prayer — how that one board
  /// will pray — which is why it sits under the Awwal in the small type
  /// rather than over it. Reversed, the card would answer "when does this
  /// begin?" with a time that belongs to one building.
  Widget _nextCard({
    required _HeroEntry? next,
    required AppSettings settings,
  }) {
    final DateTime? jamaatAt = _nextJamaat;
    // The Awwal — when this prayer opens on the official clock: the same
    // instant card A names the End of the prayer before it, said here in
    // the next prayer's own voice because both of its times belong
    // together on one card. It takes the big number.
    final DateTime? awwalAt = _nextCalc ?? next?.at;

    return Container(
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: NoorColors.white,
        borderRadius: BorderRadius.circular(NoorGlass.radius),
        border: Border.all(color: const Color(0x1A3A2E22)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: const Color(0x1F3A2E22),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Stack(
        children: <Widget>[
          // The same silhouette in the palest warm grey — this card's end of
          // the pair is the quieter one.
          Positioned(
            right: -8,
            bottom: -14,
            child: Icon(
              Icons.mosque_outlined,
              size: 88,
              color: NoorColors.emeraldSoft.withValues(alpha: 0.55),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'Next prayer is',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.outfit(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: NoorColors.muted,
                ),
              ),
              Row(
                children: <Widget>[
                  if (next != null)
                    Icon(
                      _prayerIcon(next.label),
                      size: 17,
                      color: NoorColors.muted,
                    ),
                  if (next != null) const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      next == null ? '—' : next.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w700,
                        color: NoorColors.ink,
                        height: 1.25,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // What the big number below *is* — the reader must never
              // wonder whether it is the opening or the Jamaat, and the
              // reference design labels its clock exactly this way.
              Text(
                'Awwal',
                maxLines: 1,
                style: GoogleFonts.outfit(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                  color: NoorColors.muted,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                awwalAt == null ? '--:--' : settings.format(awwalAt),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.outfit(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: NoorColors.ink,
                  height: 1.1,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              // The Jamaat under the Awwal — the prayer's two ends in one
              // place: it opens at the big clock wherever the reader
              // stands, and this one board prays at the small one. The
              // seconds chip is gone by request: the clock itself says
              // when, and the ticking number belongs to card A alone.
              Text(
                jamaatAt == null
                    ? 'Jamaat —'
                    : 'Jamaat ${settings.format(jamaatAt)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.outfit(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: NoorColors.ink.withValues(alpha: 0.68),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// One of the three doors under the cards — Qibla, Tasbeeh, Tracker —
  /// in the same white pill the Fajr/Iftar chips wore: a solid emerald
  /// chip with the name beside it. Tapping opens the screen; a null
  /// callback leaves the door drawn but shut, which is all a render test
  /// needs.
  Widget _tool({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
        decoration: BoxDecoration(
          color: NoorColors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0x1A3A2E22)),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: const Color(0x143A2E22),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: NoorColors.emeraldDeep,
              ),
              child: Icon(icon, size: 14, color: NoorColors.white),
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.outfit(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: NoorColors.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroEntry {
  const _HeroEntry(this.label, this.at);

  final String label;
  final DateTime at;
}
