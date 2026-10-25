// ---------------------------------------------------------------------------
//  NOOR • MASJID TIME
//  "Real Masjid, Real Time"
//
//  A community driven prayer-time app.  Walk into any masjid, take a photo of
//  the physical prayer time board, let Gemini Vision read the Jamaat times
//  (falling back to on-device ML Kit when there is no key or no network),
//  confirm them and the whole neighbourhood is updated instantly through
//  Firestore.
//
//  Architecture notes
//  ---------------------------------------------------------------------------
//  * Backend  : Cloud Firestore only (no custom REST API, no Node server).
//  * OCR      : Gemini Vision first (Jamaat column, needs GEMINI_API_KEY in
//               .env) -> google_mlkit_text_recognition on device as the
//               offline fallback.
//  * Map      : flutter_map + OpenStreetMap tiles -> 100% free, no Google Maps,
//               no billing account.
//  * Distance : Geolocator.distanceBetween (local haversine), never a map API.
//  * Auth     : Real firebase_auth + google_sign_in credential flow.
// ---------------------------------------------------------------------------

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter, PlatformDispatcher;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geocoding/geocoding.dart' as geocoding;
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hijri/hijri_calendar.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'app_settings.dart';
import 'app_look.dart';
import 'firebase_options.dart';
import 'manual_add_screen.dart';
import 'place_details_screen.dart';
import 'reading_card.dart';
import 'screens/about_screen.dart';
import 'screens/hijri_calendar_screen.dart';
import 'screens/home_extras.dart';
import 'screens/onboarding_screen.dart';
import 'screens/qibla_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/tasbeeh_screen.dart';
import 'screens/tracker_screen.dart';
import 'services/azaan_alarm.dart';
import 'services/app_config.dart';
import 'services/azan_player.dart';
import 'services/gemini_ocr_service.dart';
import 'services/islamic_calendar.dart';
import 'services/places_service.dart';
import 'services/prayer_tracker.dart';
import 'services/prayer_widget.dart';
import 'services/tasbeeh.dart';
import 'today_prayer_card.dart';
import 'screens/fix_location_map.dart';

// ===========================================================================
//  ENTRY POINT
// ===========================================================================

bool _firebaseReady = false;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Debug's default for these two is either a red box that swallows the screen
  // it landed on, or nothing at all. Both handlers print the *full* trace to
  // the console instead — so a failure is still completely diagnosable, it just
  // can no longer be mistaken for a dead app.
  //
  //   * FlutterError.onError  — everything the framework reports: assertions,
  //     overflow notices, listeners called on a disposed ChangeNotifier.
  //   * PlatformDispatcher.onError — whatever escapes a zone: a timer callback,
  //     a stream listener, a plugin result arriving after the screen is gone.
  //     Returning `true` marks it handled so the engine does not tear the
  //     isolate down underneath the rest of the app.
  FlutterError.onError = (FlutterErrorDetails details) {
    debugPrint('Noor ▸ framework error: ${details.exceptionAsString()}');
    if (details.context != null) {
      debugPrint('Noor ▸ context: ${details.context}');
    }
    debugPrintStack(stackTrace: details.stack, label: 'Noor ▸ ${details.library}');
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stackTrace) {
    debugPrint('Noor ▸ uncaught error: $error');
    debugPrintStack(stackTrace: stackTrace, label: 'Noor ▸ uncaught');
    return true;
  };

  // .env repo me ek PLACEHOLDER hai (khali key); asli key sirf us machine par
  // hai jahan se build ki gayi ho. File asset ki tarah bundle hoti hai, aur
  // khali key par Gemini "not configured" keh kar chup-chaap on-device OCR
  // par chali jaata hai. Loaded before the first frame so Gemini OCR can tell
  // "no key" apart from "not loaded yet". A missing file must never stop the
  // app — OCR simply drops to on-device.
  try {
    await dotenv.load();
    debugPrint('Noor ▸ .env loaded (Gemini '
        '${GeminiOcrService.isConfigured ? 'enabled' : 'not configured'})');
  } catch (error) {
    debugPrint('Noor ▸ .env unavailable ($error) — on-device OCR only');
  }

  await SystemChrome.setPreferredOrientations(
    <DeviceOrientation>[DeviceOrientation.portraitUp, DeviceOrientation.portraitDown],
  );
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );

  try {
    // `flutterfire configure` generates google-services.json + applies the
    // google-services gradle plugin, so no explicit options are required here.
    await Firebase.initializeApp();
    _firebaseReady = true;
  } catch (error, stackTrace) {
    debugPrint('Noor ▸ Firebase initialisation failed: $error');
    debugPrintStack(stackTrace: stackTrace);
  }

  // Preferences must be on disk before the first frame, otherwise the Today
  // card renders one frame with the default method and then visibly flips.
  //
  // They also have to land before the notification channels are built: the
  // Azaan channel carries the sound file picked in Settings, and Android
  // refuses to change a channel's sound once it exists — so creating the
  // channel first would pin every install to the default tone.
  try {
    await AppSettings.instance.load();
  } catch (error) {
    debugPrint('Noor ▸ settings unavailable: $error');
  }

  // Notifications do not depend on Firebase — initialise them either way so
  // the daily Azan reminders still arm if the network is down at boot.
  try {
    await NotificationService.initialise();
  } catch (error) {
    debugPrint('Noor ▸ notifications unavailable: $error');
  }

  runApp(const NoorApp());
}

// ===========================================================================
//  APP SHELL
// ===========================================================================

class NoorApp extends StatelessWidget {
  const NoorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Noor • Masjid Time',
      debugShowCheckedModeBanner: false,
      theme: buildNoorTheme(),
      // Noor paints its own sky — both slots resolve to the same light
      // palette, so a phone on dark mode gets the exact dusk it gets at
      // noon and no system default can flip to a colour this design never
      // chose. (With `forceDarkAllowed="false"` in the manifest the OS
      // does not repaint it either; this is the Flutter-side half.)
      darkTheme: buildNoorTheme(),
      // A fresh context that belongs to the app shell rather than to any State:
      // `MaterialApp.builder` sits below MaterialApp and above the Navigator,
      // so its element is never deactivated. That makes it the one context the
      // global handlers are allowed to hold on to — reaching for a State's
      // `context` after that State is gone is exactly what the old rename
      // crash did. (A `Builder` wrapped *around* MaterialApp would be the
      // opposite: no Material, no Theme, no Navigator above it.)
      builder: (BuildContext appContext, Widget? child) => Builder(
        builder: (_) => child ?? const SizedBox.shrink(),
      ),
      home: const RootGate(),
    );
  }
}

/// Decides between "configure firebase", "login" and "home".
class RootGate extends StatefulWidget {
  const RootGate({super.key});

  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  /// The splash gets at least this long. A logo that flashes for one frame
  /// reads as a glitch; a brand page reads as a launch.
  static const Duration _minSplash = Duration(milliseconds: 1600);

  bool _minElapsed = false;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(_minSplash, () {
      if (mounted) setState(() => _minElapsed = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_firebaseReady) return const FirebaseSetupScreen();

    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (BuildContext context, AsyncSnapshot<User?> snapshot) {
        if (snapshot.hasError) {
          return LoginScreen(errorMessage: snapshot.error.toString());
        }
        if (snapshot.connectionState == ConnectionState.waiting ||
            !_minElapsed) {
          return const SplashScreen();
        }

        // Preferences belong to the signed-in account (or the signed-out one).
        // Firing here rather than inside HomeScreen keeps the signed-out
        // profile scoped too; the call is idempotent, so rebuilding is free.
        unawaited(AppSettings.instance.useProfile(snapshot.data?.uid));

        if (snapshot.data == null) return const LoginScreen();
        return const HomeScreen();
      },
    );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // The white page the native splash drew, carried on: the same logo on
    // the same cream — a launch that reads as one continuous surface from
    // the first OS frame to the first home frame.
    return Scaffold(
      backgroundColor: NoorColors.cream,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: Image.asset(
                'assets/logo/noor_logo.jpg',
                width: 168,
                height: 168,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 22),
            Text(
              'Noor',
              style: GoogleFonts.amiri(
                fontSize: 46,
                fontWeight: FontWeight.w700,
                color: NoorColors.emeraldDeep,
                height: 1,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Real Masjid, Real Time.',
              style: GoogleFonts.outfit(
                fontSize: 13.5,
                letterSpacing: 0.4,
                color: NoorColors.muted,
              ),
            ),
            const SizedBox(height: 30),
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: NoorColors.gold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when the project has not been connected to Firebase yet.
class FirebaseSetupScreen extends StatelessWidget {
  const FirebaseSetupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return NoorScaffold(
      sky: NoorSky.night,
      body: SafeArea(
        child: Stack(
          children: <Widget>[
            const IgnorePointer(child: CustomPaint(painter: IslamicPatternPainter())),
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(28),
                child: Column(
                  children: <Widget>[
                    const NoorBadge(size: 92),
                    const SizedBox(height: 20),
                    Text(
                      'Connect Firebase',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.outfit(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: NoorColors.ink,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'This build has not been linked to a Firebase project yet. '
                      'Run the two commands below from your project root, then '
                      're-run the app.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.outfit(fontSize: 13.5, color: NoorColors.muted, height: 1.6),
                    ),
                    const SizedBox(height: 22),
                    _CommandChip(command: 'flutter pub get'),
                    const SizedBox(height: 10),
                    _CommandChip(command: 'flutterfire configure'),
                    const SizedBox(height: 26),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: NoorColors.onGlassChip,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: NoorColors.gold.withValues(alpha: 0.4)),
                      ),
                      child: Text(
                        'While configuring, enable Google as a Sign-in provider '
                        'in the Firebase console and add your app\'s SHA-1 to the '
                        'Android app settings — both are required for real '
                        'Google Sign-In.',
                        style: GoogleFonts.outfit(fontSize: 12.5, color: NoorColors.ink, height: 1.6),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommandChip extends StatelessWidget {
  const _CommandChip({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF06382C),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NoorColors.gold.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.terminal, size: 16, color: NoorColors.gold),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              command,
              style: GoogleFonts.jetBrainsMono(fontSize: 13.5, color: NoorColors.white),
            ),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
//  DESIGN TOKENS
// ===========================================================================

class NoorColors {
  NoorColors._();

  /// THE accent. The warm apricot the reference design wears — every icon
  /// chip, active state, badge and hairline in the app is cut from it.
  static const Color emerald = Color(0xFFE9A178);
  static const Color emeraldDeep = Color(0xFFC97F52);
  static const Color emeraldSoft = Color(0xFFF7D9C1);
  static const Color gold = Color(0xFFE39A6B);

  /// The accent a shade lighter — for small type and pale chips where the
  /// full apricot would shout.
  static const Color goldSoft = Color(0xFFF6D9BE);

  /// The page itself: a warm off-white, never a sky.
  static const Color cream = Color(0xFFFAF6F0);

  /// Field fill — a warmer white than the page, so an input reads as a
  /// well even without a border.
  static const Color cardGreen = Color(0xFFF5EEE5);
  static const Color white = Color(0xFFFFFFFF);

  /// Dark type: a warm brown, the ink of the reference design — every
  /// heading, time and label on the white cards is cut from it.
  static const Color ink = Color(0xFF40352C);

  static const Color muted = Color(0xFF8B8076);
  static const Color danger = Color(0xFFB3261E);

  /// Text on the card surfaces (cards, panels, rows) — dark on white now,
  /// exactly as the reference wears it.
  static const Color onGlass = ink;

  /// Secondary text on the cards.
  static const Color onGlassMuted = Color(0xFF9C9186);

  /// Accent icon/chip on the cards.
  static const Color onGlassGold = gold;

  /// Subtle container fill used for chips inside the white cards.
  static const Color onGlassChip = Color(0xFFF5EDE4);

  static const LinearGradient emeraldGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[emeraldSoft, emerald, emeraldDeep],
  );
}

ThemeData buildNoorTheme() {
  final TextTheme base = GoogleFonts.outfitTextTheme(ThemeData.light().textTheme);

  return ThemeData(
    useMaterial3: true,
    // Pinned light on purpose: this theme is handed to MaterialApp in both
    // the light *and* the dark slot, so a phone on dark mode resolves the
    // very same palette. Noor paints its own sky — the system's night must
    // not repaint a single widget.
    brightness: Brightness.light,
    scaffoldBackgroundColor: NoorColors.cream,
    colorScheme: ColorScheme.fromSeed(
      seedColor: NoorColors.emerald,
      primary: NoorColors.emerald,
      secondary: NoorColors.gold,
      surface: NoorColors.cream,
      error: NoorColors.danger,
    ),
    textTheme: base.apply(bodyColor: NoorColors.ink, displayColor: NoorColors.ink),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: NoorColors.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: GoogleFonts.outfit(fontSize: 16.5, fontWeight: FontWeight.w600, color: NoorColors.ink),
      iconTheme: const IconThemeData(color: NoorColors.ink),
      systemOverlayStyle: SystemUiOverlayStyle.dark,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: NoorColors.white,
      hintStyle: GoogleFonts.outfit(color: NoorColors.muted, fontSize: 14),
      labelStyle: GoogleFonts.outfit(color: NoorColors.muted, fontSize: 14),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0x1A3A2E22)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0x1A3A2E22)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: NoorColors.gold, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: NoorColors.danger),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: NoorColors.danger, width: 1.6),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: NoorColors.emerald,
      foregroundColor: NoorColors.ink,
      elevation: 10,
    ),
    dividerTheme: DividerThemeData(color: NoorColors.gold.withValues(alpha: 0.35), thickness: 1, space: 1),
    // Every control the *system* hands a default palette to gets the app's
    // own colours instead. A switch, a radio, a cursor inheriting its
    // colours from the platform theme is exactly how a label ends up drawn
    // in a colour this design never chose — invisible on the card it sits
    // on — the moment the phone's mood changes.
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith<Color>(
        (Set<WidgetState> states) =>
            states.contains(WidgetState.selected) ? NoorColors.ink : NoorColors.white,
      ),
      trackColor: WidgetStateProperty.resolveWith<Color>(
        (Set<WidgetState> states) => states.contains(WidgetState.selected)
            ? NoorColors.emerald
            : NoorColors.gold.withValues(alpha: 0.40),
      ),
      trackOutlineColor: WidgetStateProperty.all<Color>(
        NoorColors.gold.withValues(alpha: 0.60),
      ),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith<Color>(
        (Set<WidgetState> states) =>
            states.contains(WidgetState.selected) ? NoorColors.emerald : NoorColors.muted,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith<Color>(
        (Set<WidgetState> states) =>
            states.contains(WidgetState.selected) ? NoorColors.emerald : NoorColors.muted,
      ),
      checkColor: WidgetStateProperty.all<Color>(NoorColors.white),
      side: BorderSide(color: NoorColors.gold.withValues(alpha: 0.6)),
    ),
    // The city-search field's cursor and selection: gold on the card, never
    // the platform default that vanishes against this palette.
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: NoorColors.emerald,
      selectionColor: NoorColors.gold.withValues(alpha: 0.35),
      selectionHandleColor: NoorColors.emerald,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: NoorColors.emerald),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: NoorColors.emerald,
      contentTextStyle: GoogleFonts.outfit(color: NoorColors.ink, fontSize: 13.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}

// ===========================================================================
//  DECORATIVE PAINTERS  (islamic geometric watermark + google logo)
// ===========================================================================

/// Repeating eight point star (khatam) lattice used as a subtle watermark.
class IslamicPatternPainter extends CustomPainter {
  const IslamicPatternPainter({
    this.color = NoorColors.gold,
    this.opacity = 0.10,
    this.tile = 74,
    this.strokeWidth = 1.1,
  });

  final Color color;
  final double opacity;
  final double tile;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color.withValues(alpha: opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    final int cols = (size.width / tile).ceil() + 1;
    final int rows = (size.height / tile).ceil() + 1;

    for (int row = 0; row < rows; row++) {
      for (int col = 0; col < cols; col++) {
        final Offset centre = Offset(col * tile + tile / 2, row * tile + tile / 2);
        final double r = tile * 0.30;

        // Two overlapping squares -> eight point star.
        canvas.drawCircle(centre, r * 0.55, paint);
        canvas.drawRect(Rect.fromCenter(center: centre, width: r * 2, height: r * 2), paint);

        canvas.save();
        canvas.translate(centre.dx, centre.dy);
        canvas.rotate(math.pi / 4);
        canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: r * 2, height: r * 2), paint);
        canvas.restore();

        // Small connecting dots at the tile corners.
        canvas.drawCircle(Offset(col * tile, row * tile), tile * 0.035, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant IslamicPatternPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.opacity != opacity ||
      oldDelegate.tile != tile ||
      oldDelegate.strokeWidth != strokeWidth;
}

/// Faithful four colour Google "G" mark, drawn without any image assets.
class GoogleLogo extends StatelessWidget {
  const GoogleLogo({super.key, this.size = 22});

  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: const _GoogleLogoPainter());
}

class _GoogleLogoPainter extends CustomPainter {
  const _GoogleLogoPainter();

  static const Color _blue = Color(0xFF4285F4);
  static const Color _red = Color(0xFFEA4335);
  static const Color _yellow = Color(0xFFFBBC05);
  static const Color _green = Color(0xFF34A853);

  static double _rad(double degree) => degree * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double stroke = w * 0.215;
    final Offset centre = Offset(w / 2, w / 2);
    final double radius = (w - stroke) / 2;
    final Rect ring = Rect.fromCircle(center: centre, radius: radius);

    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;

    // Upper right (into the bar).
    paint.color = _blue;
    canvas.drawArc(ring, _rad(-68), _rad(68), false, paint);
    // Bottom right.
    paint.color = _red;
    canvas.drawArc(ring, _rad(18), _rad(92), false, paint);
    // Bottom left / left.
    paint.color = _yellow;
    canvas.drawArc(ring, _rad(110), _rad(90), false, paint);
    // Top.
    paint.color = _green;
    canvas.drawArc(ring, _rad(200), _rad(92), false, paint);

    // Horizontal bar of the G.
    final Rect bar = Rect.fromLTRB(
      centre.dx - radius * 0.07,
      centre.dy - stroke / 2,
      centre.dx + radius + stroke / 2,
      centre.dy + stroke / 2,
    );
    canvas.drawRect(bar, Paint()..color = _blue);
  }

  @override
  bool shouldRepaint(covariant _GoogleLogoPainter oldDelegate) => false;
}

/// Circular gold medallion with the Arabic word for "light".
/// The app's own mark: the gold roundel with نور inside it.
///
/// When the owner has set a logo in the admin panel that picture takes the
/// badge's place — inside the same ring, at the same size, everywhere the
/// badge appears. It is still the badge: a logo that fails to load, or an
/// owner who has cleared it, falls back to the mark Noor has always had
/// rather than to a hole in the splash screen.
class NoorBadge extends StatefulWidget {
  const NoorBadge({super.key, this.size = 96});

  final double size;

  @override
  State<NoorBadge> createState() => _NoorBadgeState();
}

class _NoorBadgeState extends State<NoorBadge> {
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
    final double size = widget.size;
    final String logoUrl = AppConfig.instance.data.logoUrl;

    final Widget mark = Center(
      child: Padding(
        padding: EdgeInsets.only(top: size * 0.02),
        child: Text(
          'نور',
          style: GoogleFonts.amiri(
            fontSize: size * 0.40,
            fontWeight: FontWeight.w700,
            color: NoorColors.emeraldDeep,
            height: 1,
          ),
        ),
      ),
    );

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[NoorColors.goldSoft, NoorColors.gold, Color(0xFFB08F65)],
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(color: NoorColors.gold.withValues(alpha: 0.45), blurRadius: 32, spreadRadius: 2),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Container(
            margin: EdgeInsets.all(size * 0.07),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: NoorColors.emerald.withValues(alpha: 0.55), width: 1.4),
            ),
          ),
          if (logoUrl.isEmpty)
            mark
          else
            Positioned.fill(
              // Inside the ring, edge to edge within it: the same 7% inset
              // the mark itself gets, so a logo is never clipped by the
              // circle that is meant to frame it.
              child: Padding(
                padding: EdgeInsets.all(size * 0.07),
                child: ClipOval(
                  child: Image(
                    image: NetworkImage(logoUrl),
                    fit: BoxFit.cover,
                    width: size,
                    height: size,
                    errorBuilder: (_, _, _) => mark,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ===========================================================================
//  SHARED WIDGETS
// ===========================================================================

/// The standard card: blurred glass, 24dp radius, hairline edge, soft float
/// shadow and a wash of light down from the top — one family with every other
/// surface in the app.
class GoldCard extends StatelessWidget {
  const GoldCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
    this.color,
    this.radius = NoorGlass.radius,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  /// Defaults to the material of the sky the screen is wearing, so a card
  /// with nothing to say about colour is still cut from the same sheet as
  /// everything around it. Resolved in [build] rather than as a default
  /// parameter value, because that material is no longer a constant.
  final Color? color;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final BorderRadius r = BorderRadius.circular(radius);
    final Widget body = Padding(padding: padding, child: child);
    final NoorLook look = NoorGlass.of(context);

    return Container(
      decoration: BoxDecoration(borderRadius: r, boxShadow: look.shadow),
      child: ClipRRect(
        borderRadius: r,
        // The sky behind is sampled and softened, so the card borrows its
        // colour from the gradient instead of cutting a dark hole in it.
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: NoorGlass.blurSigma,
            sigmaY: NoorGlass.blurSigma,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color ?? look.fill,
              borderRadius: r,
              border: Border.all(color: look.border, width: 1),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius - 1),
              child: DecoratedBox(
                decoration: BoxDecoration(gradient: look.glow),
                child: onTap == null
                    // A Material inside the card, rather than the Scaffold's
                    // far above it: ink painted on a Material *behind* the
                    // card's own wash is ink nobody can see, which is exactly
                    // what ListTile's debug check reports — and without one,
                    // a tap inside any card leaves no splash at all.
                    ? Material(
                        type: MaterialType.transparency,
                        child: body,
                      )
                    : Material(
                        color: Colors.transparent,
                        child: InkWell(onTap: onTap, child: body),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Gradient emerald button, rounded 16px.
class GradientButton extends StatelessWidget {
  const GradientButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.busy = false,
    this.expand = true,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool busy;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onPressed != null && !busy;

    final Widget child = Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: BoxDecoration(
        gradient: enabled ? NoorColors.emeraldGradient : null,
        color: enabled ? null : const Color(0x1A3A2E22),
        borderRadius: BorderRadius.circular(16),
        boxShadow: enabled
            ? <BoxShadow>[
                BoxShadow(
                  color: NoorColors.emerald.withValues(alpha: 0.35),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: NoorColors.ink),
            )
          else if (icon != null)
            Icon(icon, size: 19, color: NoorColors.ink),
          if (busy || icon != null) const SizedBox(width: 10),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.outfit(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: enabled ? NoorColors.ink : NoorColors.muted,
              ),
            ),
          ),
        ],
      ),
    );

    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(onTap: enabled ? onPressed : null, child: child),
    );
  }
}

class DistanceBadge extends StatelessWidget {
  const DistanceBadge({super.key, required this.metres});

  final double metres;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: NoorColors.emerald.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: NoorColors.gold.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.near_me, size: 11, color: NoorColors.emerald),
          const SizedBox(width: 4),
          Text(
            formatDistance(metres),
            style: GoogleFonts.outfit(fontSize: 10.5, fontWeight: FontWeight.w600, color: NoorColors.emerald),
          ),
        ],
      ),
    );
  }
}

/// One row in the profile tab's glass panel: icon, what it opens, and where
/// it sends you next.
class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final Color tint = danger ? NoorColors.danger : NoorColors.gold;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: Row(
          children: <Widget>[
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: NoorColors.onGlassChip,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: tint.withValues(alpha: 0.5)),
              ),
              child: Icon(icon, size: 18, color: tint),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.outfit(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: NoorColors.onGlass),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.outfit(
                      fontSize: 10.5,
                      color: NoorColors.onGlassMuted,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_outlined,
                size: 20, color: NoorColors.muted),
          ],
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
      child: Row(
        children: <Widget>[
          Container(width: 4, height: 18, decoration: BoxDecoration(color: NoorColors.gold, borderRadius: BorderRadius.circular(4))),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: GoogleFonts.outfit(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: NoorColors.ink,
              ),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

// ===========================================================================
//  PRAYER HELPERS
// ===========================================================================

class PrayerInfo {
  const PrayerInfo(this.key, this.label, this.arabic, this.icon);

  final String key;
  final String label;
  final String arabic;
  final IconData icon;
}

const List<PrayerInfo> kPrayers = <PrayerInfo>[
  PrayerInfo('fajr', 'Fajr', 'فجر', Icons.dark_mode_outlined),
  PrayerInfo('dhuhr', 'Dhuhr', 'ظهر', Icons.wb_sunny_outlined),
  PrayerInfo('asr', 'Asr', 'عصر', Icons.wb_twilight_outlined),
  PrayerInfo('maghrib', 'Maghrib', 'مغرب', Icons.nights_stay_outlined),
  PrayerInfo('isha', 'Isha', 'عشاء', Icons.nights_stay_outlined),
  PrayerInfo('juma', 'Juma', 'جمعة', Icons.mosque_outlined),
];

PrayerInfo prayerByKey(String key) =>
    kPrayers.firstWhere((PrayerInfo p) => p.key == key, orElse: () => kPrayers.first);

/// Firestore sometimes hands back a lat/lng as a `String` ("19.0760") when a
/// client wrote it through a form. Coerce rather than throw — one bad
/// document must not blank out the whole nearby list.
double _toDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

/// Reads a coordinate, preferring [primary] but falling back to [alternate].
///
/// A literal `0` counts as missing: no masjid in this list sits on the
/// equator, so a zero is a field the form never filled in rather than a
/// position worth keeping.
double _coord(Map<String, dynamic> data, String primary, String alternate) {
  final double value = _toDouble(data[primary]);
  return value != 0 ? value : _toDouble(data[alternate]);
}

String formatDistance(double metres) {
  if (!metres.isFinite) return '—';
  if (metres < 1000) return '${metres.round()} m away';
  return '${(metres / 1000).toStringAsFixed(1)} km away';
}

String timeAgo(Timestamp? stamp) {
  if (stamp == null) return 'unknown';
  final Duration diff = DateTime.now().difference(stamp.toDate());
  if (diff.inSeconds < 45) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} hr ago';
  if (diff.inDays < 7) return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
  return DateFormat('d MMM yyyy').format(stamp.toDate());
}

String normaliseName(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim();

String formatPlacemark(geocoding.Placemark place) {
  final Iterable<String> parts = <String?>[
    place.subThoroughfare,
    place.thoroughfare,
    place.subLocality,
    place.locality,
    place.administrativeArea,
    place.postalCode,
    place.country,
  ]
      .whereType<String>()
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toSet();
  return parts.join(', ');
}

// ===========================================================================
//  DOMAIN MODEL
// ===========================================================================

class Masjid {
  const Masjid({
    required this.id,
    required this.name,
    required this.fajr,
    required this.dhuhr,
    required this.asr,
    required this.maghrib,
    required this.isha,
    required this.juma,
    required this.latitude,
    required this.longitude,
    required this.address,
    required this.photoProofPath,
    required this.photoProofBase64,
    required this.lastUpdated,
    required this.updatedBy,
    required this.updatedByUid,
    this.area = '',
    this.createdByUid = '',
    this.updateCount = 1,
  });

  final String id;
  final String name;
  final String fajr;
  final String dhuhr;
  final String asr;
  final String maghrib;
  final String isha;
  final String juma;
  final double latitude;
  final double longitude;
  final String address;

  /// Short locality label, set by the manual-add form.
  final String area;
  final String photoProofPath;
  final String photoProofBase64;
  final Timestamp lastUpdated;
  final String updatedBy;
  final String updatedByUid;
  final int updateCount;

  /// Who first put this masjid on the shared list — the only reliable basis
  /// for letting someone delete it.
  final String createdByUid;

  /// Whether the signed-in user may remove this masjid from the shared list.
  ///
  /// [updatedByUid] is whoever touched it last, so it cannot decide this —
  /// but documents written before [createdByUid] existed fall back to it,
  /// since the last editor is the best claim we have on them.
  bool get canDelete {
    final String uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return false;
    if (createdByUid.isNotEmpty) return createdByUid == uid;
    return updatedByUid == uid;
  }

  /// Area if we have it, otherwise the tail of the address.
  String get areaLabel {
    if (area.trim().isNotEmpty) return area.trim();
    final List<String> parts =
        address.split(',').map((String p) => p.trim()).where((String p) => p.isNotEmpty).toList();
    return parts.length > 1 ? parts[parts.length - 2] : '';
  }

  factory Masjid.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final Map<String, dynamic> data = doc.data() ?? <String, dynamic>{};

    // Everything downstream — the radius filter, the nearest-first sort, the
    // detail screen and the fix-location map — reads these two numbers, so
    // they have to be the right way round *before* any of them see them. Some
    // documents also carry them under the short `lat`/`lon` keys written by
    // older builds of the form, so fall back to those.
    final List<double> coords = LocationService.repairLatLon(
      _coord(data, 'latitude', 'lat'),
      _coord(data, 'longitude', 'lon'),
    );
    if (!LocationService.isInMumbai(coords[0], coords[1])) {
      debugPrint('Geo ▸ ${doc.id} outside the Mumbai box '
          '(${coords[0].toStringAsFixed(5)}, ${coords[1].toStringAsFixed(5)})');
    }

    return Masjid(
      id: doc.id,
      name: (data['masjidName'] as String?) ?? '',
      fajr: (data['fajr'] as String?) ?? '--:--',
      dhuhr: (data['dhuhr'] as String?) ?? '--:--',
      asr: (data['asr'] as String?) ?? '--:--',
      maghrib: (data['maghrib'] as String?) ?? '--:--',
      isha: (data['isha'] as String?) ?? '--:--',
      juma: (data['juma'] as String?) ?? '--:--',
      latitude: coords[0],
      longitude: coords[1],
      address: (data['address'] as String?) ?? '',
      area: (data['area'] as String?) ?? '',
      photoProofPath: (data['photoProofPath'] as String?) ?? '',
      photoProofBase64: (data['photoProofBase64'] as String?) ?? '',
      lastUpdated: (data['lastUpdated'] as Timestamp?) ?? Timestamp.now(),
      updatedBy: (data['updatedBy'] as String?) ?? '',
      updatedByUid: (data['updatedByUid'] as String?) ?? '',
      createdByUid: (data['createdByUid'] as String?) ?? '',
      updateCount: (data['updateCount'] as num?)?.toInt() ?? 1,
    );
  }

  String timeFor(String key) {
    switch (key) {
      case 'fajr':
        return fajr;
      case 'dhuhr':
        return dhuhr;
      case 'asr':
        return asr;
      case 'maghrib':
        return maghrib;
      case 'isha':
        return isha;
      case 'juma':
        return juma;
      default:
        return '--:--';
    }
  }

  bool get hasProof => photoProofBase64.isNotEmpty || photoProofPath.isNotEmpty;

  double distanceFrom(double lat, double lng) =>
      Geolocator.distanceBetween(lat, lng, latitude, longitude);

  Map<String, dynamic> toMap() => <String, dynamic>{
        'masjidName': name,
        'fajr': fajr,
        'dhuhr': dhuhr,
        'asr': asr,
        'maghrib': maghrib,
        'isha': isha,
        'juma': juma,
        'latitude': latitude,
        'longitude': longitude,
        'address': address,
        'area': area,
        'photoProofPath': photoProofPath,
        'photoProofBase64': photoProofBase64,
        'lastUpdated': lastUpdated,
        'updatedBy': updatedBy,
        'updatedByUid': updatedByUid,
        'createdByUid': createdByUid,
        'updateCount': updateCount,
      };

  /// A copy carrying a corrected name.
  ///
  /// The detail screen swaps its own model immediately rather than waiting for
  /// the Firestore snapshot to arrive, so the AppBar title, the list behind it
  /// and any later alert body all read the new spelling at once.
  Masjid withName(String newName) => Masjid(
        id: id,
        name: newName,
        fajr: fajr,
        dhuhr: dhuhr,
        asr: asr,
        maghrib: maghrib,
        isha: isha,
        juma: juma,
        latitude: latitude,
        longitude: longitude,
        address: address,
        photoProofPath: photoProofPath,
        photoProofBase64: photoProofBase64,
        lastUpdated: lastUpdated,
        updatedBy: updatedBy,
        updatedByUid: updatedByUid,
        area: area,
        createdByUid: createdByUid,
        updateCount: updateCount,
      );
}

// ===========================================================================
//  ON DEVICE OCR  +  PARSING ENGINE
// ===========================================================================

class OcrResult {
  const OcrResult({
    required this.times,
    required this.rawText,
    this.masjidName,
    this.lowConfidence = false,
    this.outOfOrder = false,
    this.aiRead = false,
  });

  /// prayer key -> `HH:MM` (24 hour)
  final Map<String, String> times;
  final String? masjidName;
  final String rawText;

  /// True when the times came from Gemini rather than the on-device reader.
  ///
  /// The two readers are not equally reliable, and a scan that silently fell
  /// back looks exactly like a scan the AI got wrong. The review screen shows
  /// which one produced the values below so the user knows whether to trust
  /// them, and offers another AI attempt when it did not.
  final bool aiRead;

  /// True when we had no readable prayer labels at all and simply took the
  /// five clock readings in order — the review screen must say so out loud.
  final bool lowConfidence;

  /// True when the readings do not increase through the day (an Asr later than
  /// its Maghrib, say). Prayer times are strictly ordered, so this means a
  /// label was paired with the wrong clock — invisible unless you compare the
  /// fields by eye, so the review screen has to call it out.
  final bool outOfOrder;

  bool get nameFound => masjidName != null && masjidName!.trim().isNotEmpty;

  /// Times were read but no label could be matched to them.
  bool get timesMissing => times.isEmpty && rawText.trim().isNotEmpty;

  String timeOr(String key, String fallback) => times[key] ?? fallback;
}

/// One recognised fragment: either a prayer label or a clock reading.
///
/// These are matched to each other by their order in the text, which is what
/// lets the parser cope with boards where the labels and the times sit on
/// different lines (a grid), the time precedes the label, or OCR hands back
/// the whole board as one run-on line.
class _OcrToken {
  const _OcrToken.prayer(this.prayer)
      : hour = null,
        minute = null,
        meridiem = null;

  const _OcrToken.time(this.hour, this.minute, this.meridiem) : prayer = null;

  final String? prayer;
  final int? hour;
  final int? minute;
  final String? meridiem;

  bool get isPrayer => prayer != null;
  bool get isTime => hour != null && minute != null;
}

/// Pure Dart "AI" layer: turns messy OCR text into clean prayer times.
class MasjidOcrParser {
  MasjidOcrParser._();

  static final List<MapEntry<RegExp, String>> _keywords = <MapEntry<RegExp, String>>[
    MapEntry<RegExp, String>(
      RegExp(
        r'\bFAJR\b|\bFAJAR\b|\bFAJIR\b|\bFAJR\b|\bSUBAH\b|\bSEHAR\b|\bSAHER\b',
        caseSensitive: false,
      ),
      'fajr',
    ),
    MapEntry<RegExp, String>(
      RegExp(
        r'\bZUHR\b|\bZUHAR\b|\bZOHAR\b|\bZOHR\b|\bDHUHR\b|\bDUHR\b|\bTHUHR\b|'
        r'\bDHUHAR\b|\bDHUHUR\b|\bNOON\b|\bZOHAR\b',
        caseSensitive: false,
      ),
      'dhuhr',
    ),
    MapEntry<RegExp, String>(
      RegExp(r'\bASAR\b|\bASR\b|\bASAAR\b', caseSensitive: false),
      'asr',
    ),
    MapEntry<RegExp, String>(
      RegExp(r'\bMAGHRIB\b|\bMAGRIB\b|\bMAGHREB\b|\bMAGRAB\b|\bMEHRAB\b', caseSensitive: false),
      'maghrib',
    ),
    MapEntry<RegExp, String>(
      RegExp(r'\bISHA\b|\bESHA\b|\bESHA\b|\bISHAA\b', caseSensitive: false),
      'isha',
    ),
    MapEntry<RegExp, String>(
      RegExp(r"\bJUMA\b|\bJUMMA\b|\bJUMAH\b|\bJUM['’]?A?H?\b", caseSensitive: false),
      'juma',
    ),
    // Boards across the Hindi belt label the rows in Devanagari as well as
    // English/Urdu-Roman. Kept as separate entries (never overlapping the
    // Latin ones) so each still yields exactly one token at its own offset.
    MapEntry<RegExp, String>(RegExp(r'फजर|फज्र|फ़ज्र|सुबह'), 'fajr'),
    MapEntry<RegExp, String>(RegExp(r'ज़ोहर|जोहर|जुहर|दोपहर'), 'dhuhr'),
    MapEntry<RegExp, String>(RegExp(r'असर|असार|अस्र'), 'asr'),
    MapEntry<RegExp, String>(RegExp(r'मग़रिब|मगरिब|मघरिब'), 'maghrib'),
    MapEntry<RegExp, String>(RegExp(r'इशा|ईशा'), 'isha'),
    // Not a prayer we publish — but it *is* a labelled column on most boards,
    // so it has to consume its own reading or every time after it shifts one
    // slot to the left.
    MapEntry<RegExp, String>(
      RegExp(
        r'\bSUNRISE\b|\bSUN\s?RISE\b|\bSHROOQ\b|\bSHROOK\b|\bTULU\b|\bSURAJ\b|\bROOZAN\b',
        caseSensitive: false,
      ),
      'sunrise',
    ),
  ];

  /// 05:15  ·  5.15  ·  5:15 AM  ·  18:45  ·  07.45 pm
  ///
  /// The digit classes deliberately accept the characters OCR swaps in for
  /// digits (`O→0`, `I/l→1`, `Z→2`, `S→5`, `B→8`, `G→6`, `q→9`); they are
  /// mapped back in [_toInt].
  static final RegExp _timePattern = RegExp(
    r'([0-9OIlZSBGq]{1,2})\s*[:.]\s*([0-9OIlZSBGq]{2})\s*(a\.?\s?m\.?|p\.?\s?m\.?)?',
    caseSensitive: false,
  );

  /// Used only on a line that carries a prayer label but no colon reading —
  /// catches boards where OCR dropped the colon (`FAJR 0515`).
  static final RegExp _colonlessPattern = RegExp(r'(?<!\d)(\d{1,2})(\d{2})(?!\d)');

  static final RegExp _namePattern = RegExp(
    r'\bMASJID\b|\bMASJED\b|\bMASZID\b|\bMOSQUE\b|\bMOSK\b|\bMASGID\b',
    caseSensitive: false,
  );
  static final RegExp _alPattern = RegExp(r'\bAL[-\s]?\w+', caseSensitive: false);
  static final RegExp _noisePattern = RegExp(
    r'\bPRAYER\b|\bTIMINGS?\b|\bTIMES\b|\bJAMAAT\b|\bJAMAT\b|\bSCHEDULE\b|\bIQAMAH\b|\bAZAN\b|\bADHAN\b',
    caseSensitive: false,
  );

  /// OCR look-alike -> real digit.
  static const Map<String, String> _digitFix = <String, String>{
    'o': '0',
    'l': '1',
    'i': '1',
    'z': '2',
    's': '5',
    'b': '8',
    'g': '6',
    'q': '9',
  };

  static int? _toInt(String raw) => int.tryParse(
      raw.toLowerCase().split('').map((String c) => _digitFix[c] ?? c).join());

  /// Boards in India mix scripts, so fold Devanagari (`०१२३४५६७८९`) and
  /// fullwidth (`０１２３４５６７８９`, `：`) characters down to plain ASCII
  /// before anything else looks at the text.
  static String _normaliseScript(String text) {
    final StringBuffer out = StringBuffer();
    for (final int rune in text.runes) {
      if (rune >= 0x0966 && rune <= 0x096F) {
        out.writeCharCode(rune - 0x0966 + 0x30); // Devanagari digit
      } else if (rune >= 0xFF10 && rune <= 0xFF19) {
        out.writeCharCode(rune - 0xFF10 + 0x30); // Fullwidth digit
      } else if (rune == 0xFF1A || rune == 0xFF01) {
        out.writeCharCode(0x3A); // Fullwidth "：" -> ":"
      } else {
        out.writeCharCode(rune);
      }
    }
    return out.toString();
  }

  static OcrResult parse(String recognizedText) {
    final String text = _normaliseScript(recognizedText);

    final List<String> lines = text
        .split(RegExp(r'\r?\n'))
        .map((String l) => l.trim())
        .where((String l) => l.isNotEmpty)
        .toList();

    // One pass over every label and every clock reading, in document order.
    // Grouping them into runs and pairing run-against-run covers every board
    // shape at once: "FAJR 05:15 ZUHR 13:00", "05:15 FAJR", a label row over a
    // times row, and four stacked label/time lines.
    final List<_OcrToken> tokens = _tokensFor(text);
    final Map<String, String> times = <String, String>{};
    _pair(tokens, times);

    // No labels at all (a board whose headings are in another script) but a
    // clean run of five or six readings: assume the standard order — with
    // Sunrise sitting second when there are six — and say so in the review
    // screen so the user knows to check each field.
    bool guessed = false;
    if (times.isEmpty) {
      final List<_OcrToken> readings =
          tokens.where((_OcrToken t) => t.isTime).toList();
      // How many readings we expect, and which of them are the five prayers.
      const List<(int, List<int>)> shapes = <(int, List<int>)>[
        (5, <int>[0, 1, 2, 3, 4]), // the five prayers
        (6, <int>[0, 2, 3, 4, 5]), // prayer, sunrise, then four more
      ];
      for (final (int count, List<int> index) in shapes) {
        if (readings.length != count) continue;
        const List<String> order = <String>['fajr', 'dhuhr', 'asr', 'maghrib', 'isha'];
        for (int i = 0; i < order.length; i++) {
          final _OcrToken t = readings[index[i]];
          times[order[i]] = _normalise(t.hour!, t.minute!, t.meridiem, order[i]);
        }
        guessed = true;
        break;
      }
    }

    final bool outOfOrder = _runsOutOfOrder(times);

    // Always dump what the reader actually saw — "the name came out but the
    // times did not" is only diagnosable from logcat if the raw text is there.
    debugPrint('OCR RAW (${lines.length} lines, ${times.length} times'
        '${guessed ? ', guessed' : ''}${outOfOrder ? ', OUT OF ORDER' : ''}):\n$text');

    return OcrResult(
      times: times,
      masjidName: _extractName(lines),
      rawText: recognizedText,
      lowConfidence: guessed,
      outOfOrder: outOfOrder,
    );
  }

  /// Fajr → Dhuhr → Asr → Maghrib → Isha is strictly increasing every single
  /// day, so a Maghrib earlier than its Asr can only mean a label was paired
  /// with the wrong clock. Cheap check, and it catches a silent wrong answer.
  static bool _runsOutOfOrder(Map<String, String> times) {
    const List<String> dayOrder = <String>['fajr', 'dhuhr', 'asr', 'maghrib', 'isha'];
    DateTime? previous;
    String? previousKey;
    for (final String key in dayOrder) {
      final String? raw = times[key];
      final DateTime? at = _clockOf(raw);
      if (at == null) continue;
      if (previous != null && at.isBefore(previous)) {
        debugPrint('OCR: $key $raw falls before $previousKey ${_hhmm(previous)} '
            '— a label is likely paired with the wrong clock');
        return true;
      }
      previous = at;
      previousKey = key;
    }
    return false;
  }

  static DateTime? _clockOf(String? hhmm) {
    if (hhmm == null) return null;
    final RegExpMatch? m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(hhmm.trim());
    if (m == null) return null;
    final int hour = int.tryParse(m.group(1)!) ?? -1;
    final int minute = int.tryParse(m.group(2)!) ?? -1;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return DateTime(2000, 1, 1, hour, minute);
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// Every label and every reading in the text, ordered by position.
  ///
  /// Lines are scanned individually so the colon-dropped fallback ("FAJR
  /// 0515") only ever applies to a line that already carries a prayer label,
  /// and never to a line that had a readable `05:15`.
  static List<_OcrToken> _tokensFor(String text) {
    final List<(int, _OcrToken)> found = <(int, _OcrToken)>[];

    for (final MapEntry<RegExp, String> entry in _keywords) {
      for (final RegExpMatch m in entry.key.allMatches(text)) {
        found.add((m.start, _OcrToken.prayer(entry.value)));
      }
    }

    int offset = 0;
    for (final String rawLine in text.split('\n')) {
      final String line = rawLine.replaceAll('\r', '');
      final int lineStart = offset;
      offset += rawLine.length + 1;

      bool hasReading = false;
      for (final RegExpMatch m in _timePattern.allMatches(line)) {
        final int? hour = _toInt(m.group(1)!);
        final int? minute = _toInt(m.group(2)!);
        if (hour == null || minute == null) continue;
        if (hour > 24 || minute > 59) continue;
        hasReading = true;
        found.add((lineStart + m.start, _OcrToken.time(hour, minute, m.group(3))));
      }
      if (hasReading) continue;

      // The colon was lost. Only trust a bare `0515` when the same line has a
      // prayer label proving it is a timings row rather than a phone number.
      if (!_keywords.any((MapEntry<RegExp, String> e) => e.key.hasMatch(line))) {
        continue;
      }
      for (final RegExpMatch m in _colonlessPattern.allMatches(line)) {
        final int? hour = _toInt(m.group(1)!);
        final int? minute = _toInt(m.group(2)!);
        if (hour == null || minute == null || hour > 24 || minute > 59) continue;
        found.add((lineStart + m.start, _OcrToken.time(hour, minute, null)));
      }
    }

    found.sort(((int, _OcrToken) a, (int, _OcrToken) b) => a.$1.compareTo(b.$1));
    return found.map(((int, _OcrToken) e) => e.$2).toList();
  }

  /// Walks the tokens as alternating runs of labels and runs of readings and
  /// pairs each run against the one next to it, index by index.
  static void _pair(List<_OcrToken> tokens, Map<String, String> out) {
    int i = 0;
    while (i + 1 < tokens.length) {
      final bool isPrayer = tokens[i].isPrayer;
      int j = i;
      while (j < tokens.length && tokens[j].isPrayer == isPrayer) {
        j++;
      }
      if (j >= tokens.length) break;

      int k = j;
      final bool nextIsPrayer = tokens[k].isPrayer;
      while (k < tokens.length && tokens[k].isPrayer == nextIsPrayer) {
        k++;
      }

      _indexPair(tokens.sublist(i, j), tokens.sublist(j, k), out);
      i = k;
    }
  }

  static void _indexPair(List<_OcrToken> a, List<_OcrToken> b, Map<String, String> out) {
    if (a.isEmpty || b.isEmpty) return;
    final bool prayersFirst = a.first.isPrayer;
    final List<_OcrToken> prayers = prayersFirst ? a : b;
    final List<_OcrToken> readings = prayersFirst ? b : a;

    for (int n = 0; n < prayers.length && n < readings.length; n++) {
      final String key = prayers[n].prayer!;
      // Sunrise/Shrooq is a marker column, not a prayer we publish: it still
      // has to walk the readings in lock-step so the columns after it land on
      // the right label.
      if (key == 'sunrise') continue;
      if (out.containsKey(key)) continue;
      final _OcrToken r = readings[n];
      out[key] = _normalise(r.hour!, r.minute!, r.meridiem, key);
    }
  }

  /// Normalises to strict `HH:MM` 24h, resolving missing AM/PM per prayer so
  /// that `6:30 Maghrib` becomes `18:30` and `5:15 Fajr` stays `05:15`.
  static String _normalise(int hour, int minute, String? meridiem, String prayer) {
    int h = hour;
    final String? suffix = meridiem == null
        ? null
        : (meridiem.trim().toLowerCase().startsWith('a') ? 'am' : 'pm');

    if (suffix == 'pm' && h < 12) {
      h += 12;
    } else if (suffix == 'am' && h == 12) {
      h = 0;
    } else if (suffix == null && h <= 12) {
      switch (prayer) {
        case 'maghrib':
        case 'isha':
          if (h >= 1 && h <= 11) h += 12;
          break;
        case 'asr':
          if (h >= 1 && h <= 7) h += 12;
          break;
        case 'dhuhr':
        case 'juma':
          if (h >= 1 && h <= 3) h += 12;
          break;
        case 'fajr':
          if (h == 12) h = 0;
          break;
      }
    }

    if (h > 23) h = hour % 24;
    return '${h.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  /// Boards normally print the masjid name on one of the top lines.
  static String? _extractName(List<String> lines) {
    String? best;
    int bestScore = 0;

    for (final String raw in lines.take(7)) {
      String cleaned = raw
          .replaceAll(RegExp(r'[|_/\\]+'), ' ')
          .replaceAll(RegExp(r"[^\w\s'&.-]"), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

      // "PRAYER", "TIMINGS", "JAMAAT" … are section headings, not part of the
      // masjid's name — drop them rather than throwing the whole line away,
      // so "NOOR MASJID PRAYER TIMES" still resolves to "NOOR MASJID".
      cleaned = cleaned
          .replaceAll(_noisePattern, ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

      if (cleaned.length < 5 || cleaned.length > 70) continue;
      if (_timePattern.hasMatch(cleaned)) continue;

      int score = 0;
      if (_namePattern.hasMatch(cleaned)) score += 4;
      if (_alPattern.hasMatch(cleaned)) score += 2;
      if (RegExp(r"^[A-Z][A-Z\s&.\'-]{3,}$").hasMatch(cleaned)) score += 1;
      final int words = cleaned.split(' ').length;
      if (words >= 2) score += 1;
      if (words > 7) score -= 2;
      if (RegExp(r'^[\d\s:-]+$').hasMatch(cleaned)) score -= 6;

      if (score > bestScore) {
        bestScore = score;
        best = cleaned;
      }
    }

    return bestScore >= 5 ? best : null;
  }
}

/// Result of one camera capture + OCR pass.
class ScanResult {
  const ScanResult({required this.photoPath, required this.ocr});

  final String photoPath;
  final OcrResult ocr;
}

/// How a masjid board reaches [VerificationScreen].
enum ScanSource { camera, gallery, manual }

/// Camera / gallery → on-device text recognition.
class ScanFlow {
  ScanFlow._();

  /// One photo + OCR pass from the chosen source.
  ///
  /// Returns `null` when the user backs out of the picker.
  static Future<ScanResult?> capture({ImageSource source = ImageSource.camera}) async {
    final ImagePicker picker = ImagePicker();
    // On-device OCR reads small board text far better from a big, sharp frame
    // than from a compressed thumbnail — 1280px was losing the digits.
    final XFile? shot = await picker.pickImage(
      source: source,
      preferredCameraDevice: CameraDevice.rear,
      maxWidth: 1920,
      imageQuality: 90,
    );
    if (shot == null) return null;

    // Gemini and ML Kit run side by side rather than in turn. Gemini is the
    // only one that can tell a Jamaat column from a Start column; ML Kit is
    // what survives a missing key, a dead network, or a refusal. Both are
    // always cheap enough to run, and the local text also feeds the
    // "Scanned text" expander on the review screen.
    final bytes = await shot.readAsBytes();
    final List<Object?> reads = await Future.wait<Object?>(<Future<Object?>>[
      _readOnDevice(shot),
      GeminiOcrService.extractJamaatTimes(bytes),
    ]);

    final OcrResult onDevice = MasjidOcrParser.parse((reads[0] as RecognizedText?)?.text ?? '');
    final OcrResult ocr = _mergeReads(onDevice, reads[1] as GeminiOcrResult?);

    debugPrint(
      'OCR: name=${ocr.masjidName ?? "<none>"} '
      'times=${ocr.times.length} ${ocr.times} lowConfidence=${ocr.lowConfidence}'
      '${ocr.outOfOrder ? ' OUT OF ORDER' : ''}',
    );
    return ScanResult(photoPath: shot.path, ocr: ocr);
  }

  /// On-device text recognition, or `null` if the plugin is unavailable.
  static Future<RecognizedText?> _readOnDevice(XFile shot) async {
    try {
      final TextRecognizer recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      try {
        return await recognizer.processImage(InputImage.fromFilePath(shot.path));
      } finally {
        await recognizer.close();
      }
    } catch (error) {
      debugPrint('OCR: on-device reader failed: $error');
      return null;
    }
  }

  /// Gemini wins whenever it found a usable set of Jamaat times. Anything else
  /// — no key configured, no network, a refused model, malformed JSON, or a
  /// board where the model could only pick out a couple of readings — falls
  /// through to the on-device result untouched.
  static OcrResult _mergeReads(OcrResult onDevice, GeminiOcrResult? gemini) {
    if (gemini == null || gemini.times.length < 3) {
      debugPrint('OCR: keeping on-device result (${onDevice.times.length} time(s))'
          '${gemini == null ? '' : ', Gemini returned ${gemini.times.length}'}');
      return onDevice;
    }

    // The local reader's name and raw text are kept either way: the review
    // screen's expander has to show what was actually photographed, and
    // `outOfOrder` is what tells the user a column got crossed.
    debugPrint('OCR: using Gemini Jamaat result (${gemini.times.length} time(s))');
    return OcrResult(
      times: gemini.times,
      masjidName: (gemini.masjidName?.isNotEmpty ?? false)
          ? gemini.masjidName
          : onDevice.masjidName,
      rawText: onDevice.rawText.isEmpty ? gemini.rawText : onDevice.rawText,
      // Gemini reads labels, never positions, so the "read by position"
      // warning has no meaning on this path — the ordering check does.
      lowConfidence: false,
      outOfOrder: gemini.outOfOrder,
      aiRead: true,
    );
  }

  /// No photo, no OCR — the user types every time by hand.
  ///
  /// [ScanResult.photoPath] is empty, which VerificationScreen renders as the
  /// "no photo yet" placeholder rather than an [Image.file].
  static ScanResult manual() =>
      const ScanResult(photoPath: '', ocr: OcrResult(times: <String, String>{}, rawText: ''));
}

/// Bottom sheet offering the three ways in: live camera, an existing photo,
/// or typing the times straight in.
///
/// Returns `null` if the sheet is dismissed without a choice.
Future<ScanSource?> askScanSource(BuildContext context, {bool allowManual = true}) {
  Widget option(
    BuildContext context,
    ScanSource source,
    IconData icon,
    String title,
    String subtitle,
  ) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 6),
      onTap: () => Navigator.of(context).pop(source),
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: NoorColors.onGlassChip,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: NoorColors.gold.withValues(alpha: 0.55)),
        ),
        child: Icon(icon, color: NoorColors.onGlassGold, size: 21),
      ),
      title: Text(
        title,
        style: GoogleFonts.outfit(fontSize: 14, fontWeight: FontWeight.w600, color: NoorColors.onGlass),
      ),
      subtitle: Text(
        subtitle,
        style: GoogleFonts.outfit(fontSize: 11.5, color: NoorColors.onGlassMuted, height: 1.45),
      ),
      trailing: const Icon(Icons.chevron_right_outlined, color: NoorColors.onGlassMuted),
    );
  }

  return showModalBottomSheet<ScanSource>(
    context: context,
    // Light, like every other sheet in the re-skin: the rows below are cut
    // from `onGlass` (warm ink), so they need a white card under them to
    // read against — a dark fill left ink type on ink.
    backgroundColor: NoorColors.white,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    builder: (BuildContext sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0x333A2E22),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Add or update prayer times',
              style: GoogleFonts.outfit(
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
                color: NoorColors.onGlass,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Choose how you want to supply the masjid’s times.',
              style: GoogleFonts.outfit(
                  fontSize: 11.5, color: NoorColors.onGlassMuted),
            ),
            const SizedBox(height: 8),
            option(
              sheetContext,
              ScanSource.camera,
              Icons.photo_camera_outlined,
              'Take a photo',
              'Point the camera at the prayer time board — on-device AI reads it.',
            ),
            const Divider(height: 1, indent: 66),
            option(
              sheetContext,
              ScanSource.gallery,
              Icons.photo_library_outlined,
              'Upload from gallery',
              'Pick a photo of the board you already have saved.',
            ),
            if (allowManual) ...<Widget>[
              const Divider(height: 1, indent: 66),
              option(
                sheetContext,
                ScanSource.manual,
                Icons.edit_calendar_outlined,
                'Enter manually',
                'Skip the photo entirely and type each prayer time yourself.',
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

// ===========================================================================
//  SERVICES
// ===========================================================================

class NotificationService {
  NotificationService._();

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'masjid_time_updates',
    'Masjid Time Updates',
    description: 'Alerts when a favourite masjid updates its prayer times',
    importance: Importance.high,
  );

  /// Separate channel so the user can silence "Azan Reminders" without also
  /// losing favourite-masjid alerts (and vice versa).
  ///
  /// It is deliberately **silent**. The recitation belongs to the native
  /// alarm-stream player (`AzaanAlarm` → `AzaanPlaybackService`), which is the
  /// one path the volume rocker can reach: while it runs
  /// `AzaanAudio.isPlaying()` is true, and a volume key tears the playback
  /// down. When this channel also carried the mp3, a *second* copy of the
  /// Azaan arrived as notification sound on the notification stream — where
  /// no volume key could stop it, because the in-process player was not the
  /// thing making the noise. So the channel posts a banner and a vibration,
  /// and the recitation has exactly one source.
  ///
  /// The id is new (`_v2`) because Android freezes a channel's sound at the
  /// instant it is created and ignores every later attempt to change it: the
  /// old `azan_reminders*` channels are audible for good, so
  /// [applyAzanChannel] retires them instead of trying to re-tune them.
  static const String _azanChannelId = 'azan_reminders_v2';
  static const String _azanChannelName = 'Azan Reminders';
  static const String _azanChannelDescription =
      'A reminder at each of the five daily prayer times';

  /// The zawal banner's own channel, so each half can be silenced alone:
  /// a reader who has had enough of prayer reminders still wants to know the
  /// moment salah becomes prohibited, and one who wants that warning must not
  /// have to keep the Azaan ringtone on to get it.
  static const String _makruhChannelId = 'makruh_alerts';
  static const String _makruhChannelName = 'Prohibited Time';
  static const String _makruhChannelDescription =
      'Alerts when the makruh (zawal) window opens — salah is prohibited until Dhuhr';

  /// The banner is the only voice this alert has — there is no recitation
  /// behind it, so the channel's own sound is the whole notification.
  static const NotificationDetails _makruhDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      _makruhChannelId,
      _makruhChannelName,
      channelDescription: _makruhChannelDescription,
      importance: Importance.high,
      priority: Priority.high,
      color: Color(0xFFB3261E),
      enableVibration: true,
    ),
    iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
  );

  static AzanSound get _azanSound => azanSoundByKey(AppSettings.instance.azanSound);

  /// The clip [prayer]'s own bell recites — the per-prayer half of the
  /// three-state switch on Home.
  ///
  /// A bell not on `azan` gets the silent sound, which both halves of the
  /// reminder read the same way: no alarm-stream twin (no `androidRaw`)
  /// and, on iOS, a banner posted with `presentSound: false`. A bell that
  /// *is* on `azan` must actually recite even when the profile's global
  /// pick is "None (silent)" — the reader opted this prayer in, so the
  /// built-in Makkah clip stands in rather than leaving a silent azan.
  static AzanSound _bellSound(String prayer) {
    if (AppSettings.instance.bellModeFor(prayer) != kBellAzan) {
      return azanSoundByKey('silent');
    }
    final AzanSound global = _azanSound;
    return global.key == 'silent' ? azanSoundByKey('makkah') : global;
  }

  /// Whether [prayer]'s recitation card *is* its notification — so the
  /// banner must not be scheduled at all.
  ///
  /// With no advance notice the banner lands on the prayer time itself, the
  /// same minute `AzaanPlaybackService` rises with "Azaan playing" — two
  /// cards for one prayer, one of them a duplicate of the other. Something
  /// has to give, and it cannot be the playback card: a foreground service
  /// may not run without one, and it carries the only STOP AZAN handle that
  /// reaches a locked phone. So on Android, where that player exists, an
  /// armed clip stands in for the banner whenever the two would fire
  /// together ([minutesBefore] ≤ 0 means "at the prayer time").
  ///
  /// The banner still arms everywhere the card cannot speak for it:
  ///
  ///  * an advance notice — "Fajr in 10 minutes" is its own event, sent
  ///    minutes before the clip starts, so the two never collide;
  ///  * a bell on `silent` — no `androidRaw`, no recitation, and the banner
  ///    is the only thing that will appear;
  ///  * off Android — there is no Kotlin player, so the banner is the only
  ///    audible path iOS and the desktop have.
  ///
  /// [android] exists for the test host, which is never Android: production
  /// callers take the real answer from [Platform].
  @visibleForTesting
  static bool recitationIsTheCard(
    AzanSound sound,
    int minutesBefore, {
    bool? android,
  }) =>
      (android ?? Platform.isAndroid) &&
      sound.androidRaw != null &&
      minutesBefore <= 0;

  static AndroidNotificationChannel _azanChannel() => const AndroidNotificationChannel(
        _azanChannelId,
        _azanChannelName,
        description: _azanChannelDescription,
        importance: Importance.high,
        playSound: false,
        enableVibration: true,
        enableLights: true,
        ledColor: Color(0xFF0A4D3C),
      );

  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  /// Notification ids 0..4 are reserved for the five Azan reminders.
  static int _azanId(String prayer) => kNotifiablePrayers.indexOf(prayer);

  /// The one id the daily makruh (Zawal) banner owns.
  ///
  /// It sits clear of two ranges that are swept wholesale:
  ///
  ///  * **0..4** — [cancelAzan] retires the five Azaan reminders by hand on
  ///    every pass, so an id in that block would be cancelled by the very
  ///    refresh meant to re-arm it;
  ///  * **[1000, 1000000000)** — `_rebuildFavouriteAlerts` clears that whole
  ///    block on each reschedule, which is the same trap that swallowed the
  ///    test reminder when it still sat at 791900.
  ///
  /// 5 is the first id clear of both, and far under the epoch-second ids
  /// [show] hands out. Public only so a test can pin all of that down.
  @visibleForTesting
  static const int makruhId = 5;

  /// Favourite-masjid alerts are allocated from here upwards, ten ids per
  /// masjid so each of the five prayers keeps its own slot. Well clear of the
  /// 0..4 range above, and of the epoch-second ids `show()` uses. The native
  /// alarm-stream alarms reuse the same numbers so one call cancels both.
  static const int _favIdFloor = 1000;
  static const int _favIdStride = 10;

  /// Silent on Android — the recitation is the alarm-stream player's job (see
  /// [_azanChannelId]). iOS keeps the bundled clip in the banner: there is no
  /// Kotlin side there, so the notification is the only audible path it has,
  /// and `presentSound: false` stays the way to get a truly silent reminder.
  ///
  /// The optional [sound] is the per-prayer answer from [_bellSound]; the
  /// default keeps the profile's global pick for the one-shot probes that
  /// demonstrate it (the Settings "test reminder", chiefly).
  static NotificationDetails _azanDetails([AzanSound? sound]) {
    final AzanSound effective = sound ?? _azanSound;
    final bool audible = effective.key != 'silent';
    return NotificationDetails(
      android: AndroidNotificationDetails(
        _azanChannelId,
        _azanChannelName,
        channelDescription: _azanChannelDescription,
        importance: Importance.high,
        priority: Priority.high,
        color: const Color(0xFF0A4D3C),
        playSound: false,
        enableVibration: true,
        // "Not now" instead of "never": ten minutes back, from the banner
        // itself, without opening the app. One shot with a one-shot id, so
        // it can never take the place of tomorrow's copy of this prayer's
        // daily reminder.
        actions: const <AndroidNotificationAction>[
          AndroidNotificationAction('snooze', 'Snooze 10 min'),
        ],
      ),
      // iOS only honours a sound that sits in the app bundle, hence the file
      // names shipped under ios/Runner. `presentSound: false` is the only way
      // to get a truly silent reminder there — a null `sound` still plays the
      // system default.
      iOS: DarwinNotificationDetails(
        presentSound: audible,
        sound: audible ? effective.iosSound : null,
      ),
    );
  }

  /// [_azanDetails] tuned to [prayer]'s own bell: `silent` posts a quiet
  /// banner, `azan` carries that prayer's clip.
  static NotificationDetails _azanDetailsFor(String prayer) =>
      _azanDetails(_bellSound(prayer));

  /// Makes sure the silent reminder channel exists — and retires the audible
  /// ones this app used to post the mp3 through.
  ///
  /// Android ties a channel's sound to the moment it is created, so the old
  /// `azan_reminders` / `azan_reminders_<sound>` channels cannot be silenced
  /// in place: a `delete` + `create` of the *same* id is answered with the old
  /// record back, sound and all. One channel that has never carried a sound
  /// never has an old self to come back wearing, so [applyAzanChannel] creates
  /// [_azanChannelId] once and drops every other `azan_reminders*` id. Called
  /// before the first notification is posted and from Settings; a channel
  /// already in place is left alone, so an app opened ten times a day does
  /// nothing ten times.
  static Future<void> applyAzanChannel() async {
    final AndroidFlutterLocalNotificationsPlugin? android =
        _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;

    bool present = false;
    try {
      final List<AndroidNotificationChannel>? channels =
          await android.getNotificationChannels();
      for (final AndroidNotificationChannel channel in channels ?? const <AndroidNotificationChannel>[]) {
        if (channel.id == _azanChannelId) {
          present = true;
          continue;
        }
        // Anything else under this prefix is one of the old audible channels.
        if (!channel.id.startsWith('azan_reminders')) continue;
        try {
          await android.deleteNotificationChannel(channelId: channel.id);
          debugPrint('Noor ▸ retired the audible Azaan channel ${channel.id}');
        } catch (error) {
          debugPrint('Noor ▸ could not drop the old Azaan channel ${channel.id}: $error');
        }
      }
    } catch (error) {
      // A missing channel list is not proof the channel is missing — create
      // is idempotent, so fall through and ask rather than stay silent.
      debugPrint('Noor ▸ could not read the notification channels: $error');
    }

    if (present) return;
    try {
      await android.createNotificationChannel(_azanChannel());
      debugPrint('Noor ▸ Azaan channel $_azanChannelId ready (silent banner, '
          'recitation via the alarm-stream player)');
    } catch (error) {
      debugPrint('Noor ▸ could not create the Azaan channel: $error');
    }
  }

  /// Makes sure the zawal channel exists before the first banner is armed.
  ///
  /// Idempotent — Android hands back the channel that is already there — so
  /// calling it on every launch creates nothing twice. Unlike the Azaan one
  /// this channel is never retired or rebuilt: its sound is the system's own,
  /// frozen at creation or not, and there has never been a louder version of
  /// it to outlive.
  static Future<void> applyMakruhChannel() async {
    final AndroidFlutterLocalNotificationsPlugin? android =
        _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    try {
      await android.createNotificationChannel(const AndroidNotificationChannel(
        _makruhChannelId,
        _makruhChannelName,
        description: _makruhChannelDescription,
        importance: Importance.high,
        enableVibration: true,
      ));
    } catch (error) {
      debugPrint('Noor ▸ could not create the Prohibited Time channel: $error');
    }
  }

  static bool _tzReady = false;

  /// The device's UTC offset at the last schedule — the cheapest signal that
  /// a journey or a manual clock change has moved every armed instant off its
  /// wall-clock time.
  static Duration? _lastScheduleOffset;

  /// Drops the cached zone so the next pass re-reads it.
  ///
  /// Both halves of a reminder hold absolute instants: the banner inside the
  /// plugin, the recitation inside AlarmManager. Move the clock and each of
  /// them points at the wrong minute — "Fajr 4:47" ringing at 5:47 after a
  /// flight. The native side answers its own half on the same broadcast (it
  /// re-derives every alarm from its stored local time); this clears the
  /// cached zone so the next schedule pass rebuilds the banners in the new
  /// one instead of continuing to trust a zone the device has left.
  static void invalidateTimeZone() {
    _tzReady = false;
    _lastScheduleOffset = null;
  }

  /// Whether the device has moved to a different UTC offset since the last
  /// successful schedule. Cheap enough to ask on every return to the app.
  static bool get timeZoneMoved =>
      _lastScheduleOffset != null && _lastScheduleOffset != DateTime.now().timeZoneOffset;

  static Future<void> initialise() async {
    const AndroidInitializationSettings android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: android,
        iOS: ios,
      ),
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        final String? payload = response.payload;
        if (response.actionId == 'snooze') {
          if (payload != null && payload.startsWith('azan:')) {
            unawaited(snoozeAzan(payload.substring('azan:'.length)));
          }
          return;
        }
        if (payload != null && payload.startsWith('azan:')) {
          // Foreground tap: let the chosen clip actually play. Background
          // playback needs a background isolate, which audioplayers cannot
          // drive from here — the system azan tone plays either way.
          unawaited(AzanPlayer.instance.playSelected());
        }
      },
    );

    // Create the Android channels explicitly so importance is honoured. The
    // Azaan one is rebuilt from the stored sound selection — this is the
    // "before any notification" step the recitation depends on.
    final AndroidFlutterLocalNotificationsPlugin? androidPlugin =
        _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(_channel);
    await applyAzanChannel();
    await applyMakruhChannel();
    AzaanAlarm.install();
    // The fallback player's callbacks live on the same channel; registering
    // them here means a stop pressed during a recitation is answered even on
    // a launch that never opened Settings.
    AzanPlayer.instance.install();

    await _initTimeZone();
  }

  /// `zonedSchedule` works in the device's own zone, not UTC — without this
  /// every reminder lands 5 h 30 m early in India.
  static Future<void> _initTimeZone() async {
    if (_tzReady) return;
    try {
      tzdata.initializeTimeZones();
      final TimezoneInfo zone = await FlutterTimezone.getLocalTimezone();
      try {
        tz.setLocalLocation(tz.getLocation(zone.identifier));
      } catch (_) {
        // The platform handed back something the IANA database has no entry
        // for ("IST", "GMT+0530"…). Match on offset instead so the repeat time
        // is still right rather than silently falling back to UTC.
        tz.setLocalLocation(_zoneMatchingOffset());
      }
      debugPrint('Noor ▸ timezone: ${tz.local.name} (platform said ${zone.identifier})');
    } catch (error) {
      debugPrint('Noor ▸ timezone lookup failed: $error');
      try {
        tzdata.initializeTimeZones();
      } catch (_) {}
      tz.setLocalLocation(_zoneMatchingOffset());
    }
    _tzReady = true;
    _lastScheduleOffset = DateTime.now().timeZoneOffset;
  }

  /// Any zone whose offset right now equals the device's — prefers keeping the
  /// reminders on the right wall-clock minute over a hard-coded city.
  static tz.Location _zoneMatchingOffset() {
    try {
      final DateTime now = DateTime.now();
      for (final String name in tz.timeZoneDatabase.locations.keys) {
        final tz.Location candidate = tz.getLocation(name);
        if (tz.TZDateTime.from(now, candidate).timeZoneOffset == now.timeZoneOffset) {
          return candidate;
        }
      }
    } catch (_) {}
    try {
      return tz.getLocation('Asia/Kolkata');
    } catch (_) {}
    return tz.UTC;
  }

  /// Android 13+ runtime permission.
  static Future<void> requestPermission() async {
    final AndroidFlutterLocalNotificationsPlugin? android =
        _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
  }

  /// Rebuilds the five daily Azan reminders from the current settings,
  /// calculation method, madhab and location. Safe to call on every app open
  /// — prayer times drift by a minute or two a day.
  static Future<void> scheduleAzan({
    required double latitude,
    required double longitude,
  }) async {
    await _initTimeZone();
    if (!_tzReady) return;

    // Drop yesterday's schedule first so a changed offset never leaves a
    // duplicate behind.
    await cancelAzan();

    final AppSettings settings = AppSettings.instance;
    if (!settings.notificationsEnabled) {
      // The probe sits outside every id range this pass clears, so switching
      // reminders off used to leave a pending "Closed-app test" — banner and
      // recitation both — to ring after the user had said no.
      try {
        await _plugin.cancel(id: _testReminderId);
      } catch (_) {}
      await AzaanAlarm.cancel(_testReminderId);
      debugPrint('Azan ▸ master toggle off, nothing scheduled');
      return;
    }

    // A user who picked a custom city — or simply has GPS off — *sees* times
    // computed from that city: every display path applies `customLatitude`.
    // Scheduling from the raw coordinate instead is how a board reading
    // "Fajr 5:12" produced a reminder at 5:17, silently, after every restart.
    final double effectiveLatitude = settings.customLatitude ?? latitude;
    final double effectiveLongitude = settings.customLongitude ?? longitude;
    final LocalPrayerTimes day =
        settings.compute(latitude: effectiveLatitude, longitude: effectiveLongitude);
    final DateTime now = DateTime.now();

    // The zawal banner answers the master switch and nothing else. It is not
    // an Azaan: "Only at Jamaat time" speaks about when the five prayers
    // ring, and must not be read as a licence to stay quiet about the half
    // hour in which salah is prohibited — so it is armed *before* the gate
    // below, from the same window Home's red line prints.
    await _scheduleMakruh(day: day, now: now);

    // "When will the Azaan play?" — this pass arms the *calculated* (Awwal) reminders.
    // `cancelAzan()` above has already retired yesterday's copy of both this
    // block and its alarm-stream twins, so leaving here is what keeps only the
    // favourite-masjid Jamaat times ringing ("Only at Jamaat time"), and
    // what makes "Band" cancel everything.
    if (!settings.schedulesAwwal) {
      debugPrint('Azan ▸ timing "${settings.azaanTiming}": '
          'calculated (Awwal) reminders cancelled, none scheduled');
      return;
    }

    int scheduled = 0;

    for (final String key in kNotifiablePrayers) {
      if (!settings.notifyOnFor(key)) continue;
      final DateTime? prayerTime = day.times[key];
      if (prayerTime == null) continue;

      final int minutesBefore = settings.notifyOffsetFor(key);
      DateTime fire =
          prayerTime.subtract(Duration(minutes: minutesBefore < 0 ? 0 : minutesBefore));

      // A prayer earlier than "now" happens again tomorrow, but a repeating
      // schedule only fires *forward* from its anchor — with a past anchor the
      // alarm never arms until the next time the app happens to be opened.
      // Roll it forward; `matchDateTimeComponents` repeats it daily anyway.
      //
      // The roll is a loop, not a "put it on tomorrow's date" reconstruction:
      // a prayer just after midnight with an advance notice lands *yesterday*,
      // and rebuilding tomorrow from its hour and minute silently skipped a
      // whole day. This is the same loop the favourite alerts already use.
      while (!fire.isAfter(now)) {
        fire = fire.add(const Duration(days: 1));
      }
      final tz.TZDateTime when = tz.TZDateTime(
        tz.local,
        fire.year,
        fire.month,
        fire.day,
        fire.hour,
        fire.minute,
      );

      // One prayer must produce one notification. Which card speaks for it
      // is decided before anything is armed: if the recitation rises on
      // this very minute, that card is the reminder and the banner is
      // skipped rather than stacked behind it.
      final AzanSound sound = _bellSound(key);
      if (recitationIsTheCard(sound, minutesBefore)) {
        debugPrint('Azan ▸ $key: recitation card stands in for the banner '
            '(both land on the prayer time) — one prayer, one notification');
      } else {
        try {
          await _plugin.zonedSchedule(
            id: _azanId(key),
            scheduledDate: when,
            title: '${prayerByKey(key).label} • ${settings.format(prayerTime)}',
            body: minutesBefore < 0
                ? 'It is time for ${prayerByKey(key).label}.'
                : '${prayerByKey(key).label} in $minutesBefore minutes at your masjid.',
            notificationDetails: _azanDetailsFor(key),
            androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
            matchDateTimeComponents: DateTimeComponents.time,
            payload: 'azan:$key',
          );
          scheduled++;
        } catch (error) {
          // Android 14+ can revoke SCHEDULE_EXACT_ALARM — fall back to the
          // inexact alarm rather than silently never firing.
          debugPrint('Noor ▸ exact schedule failed for $key, retrying inexact: $error');
          try {
            await _plugin.zonedSchedule(
              id: _azanId(key),
              scheduledDate: when,
              title: '${prayerByKey(key).label} • ${settings.format(prayerTime)}',
              body: minutesBefore < 0
                  ? 'It is time for ${prayerByKey(key).label}.'
                  : '${prayerByKey(key).label} in $minutesBefore minutes at your masjid.',
              notificationDetails: _azanDetailsFor(key),
              androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
              matchDateTimeComponents: DateTimeComponents.time,
              payload: 'azan:$key',
            );
            scheduled++;
          } catch (secondError) {
            debugPrint('Noor ▸ azan schedule failed for $key: $secondError');
          }
        }
      }

      // The banner and the recitation are two different instants whenever an
      // advance notice is set: `fire` is the prayer time less that notice
      // and the banner fires there, while the recitation belongs to the
      // prayer time itself — "Fajr in 10 minutes" is a note, not an Azaan,
      // and playing the whole clip at the offset is what made the phone
      // recite minutes before any timetable said so. Both share this
      // prayer's id, so one `cancelAzan()` still retires the pair.
      //
      // They are one and the same instant when no notice is set — which is
      // when [recitationIsTheCard] has held the banner back above, leaving
      // exactly one card. And the clip itself is this *prayer's* bell: a
      // bell left on `silent` hands back a sound with no `androidRaw`, so no
      // twin arms at all — the banner alone is what that state promised.
      if (sound.androidRaw != null) {
        await AzaanAlarm.schedule(
          id: _azanId(key),
          at: fire.add(Duration(minutes: minutesBefore < 0 ? 0 : minutesBefore)),
          raw: sound.androidRaw!,
          title: '${prayerByKey(key).label} • ${settings.format(prayerTime)}',
        );
      }
    }

    debugPrint('Azan ▸ scheduled $scheduled reminder(s) for '
        '${settings.method.label}/${settings.isHanafi ? 'Hanafi' : 'Shafi'} at '
        '$effectiveLatitude,$effectiveLongitude');
  }

  /// The words the zawal banner carries, kept out of [_scheduleMakruh] so a
  /// test can pin them without a plugin to schedule through.
  ///
  /// "Prohibited time" is the phrase a reader already knows from the masjid's
  /// printed table, and the window is [LocalPrayerTimes.makruhWindow]'s own —
  /// Dhuhr less half an hour up to Dhuhr — so the banner and the red line on
  /// Home can never name two different half hours.
  @visibleForTesting
  static ({String title, String body}) makruhText({
    required DateTime start,
    required DateTime end,
    required AppSettings settings,
  }) =>
      (
        title:
            'Prohibited time ${settings.format(start)} – ${settings.format(end)}',
        body: 'Zawal is on — salah is prohibited until Dhuhr begins at '
            '${settings.format(end)}.',
      );

  /// Arms today's zawal banner: one notification at the minute the half hour
  /// opens, repeating daily on that wall-clock minute.
  ///
  /// Called from every [scheduleAzan] pass and retired by every [cancelAzan]
  /// one, so the banner keeps the same life the five reminders have — a day
  /// whose times have drifted a minute is corrected the moment the app is
  /// next opened, and switching notifications off takes it down with them.
  static Future<void> _scheduleMakruh({
    required LocalPrayerTimes day,
    required DateTime now,
  }) async {
    final ({DateTime start, DateTime end})? window = day.makruhWindow;
    if (window == null) return;

    // A window that has already opened today arms *tomorrow's* copy, never a
    // duplicate of the one that has just passed — the same roll the five
    // reminders make, and for the same reason: a repeating schedule only
    // fires forward from its anchor.
    DateTime fire = window.start;
    while (!fire.isAfter(now)) {
      fire = fire.add(const Duration(days: 1));
    }

    final ({String title, String body}) words = makruhText(
      start: window.start,
      end: window.end,
      settings: AppSettings.instance,
    );
    final tz.TZDateTime when = tz.TZDateTime(
      tz.local,
      fire.year,
      fire.month,
      fire.day,
      fire.hour,
      fire.minute,
    );

    try {
      await _plugin.zonedSchedule(
        id: makruhId,
        scheduledDate: when,
        title: words.title,
        body: words.body,
        notificationDetails: _makruhDetails,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: 'makruh',
      );
      debugPrint('Makruh ▸ banner armed for ${words.title}');
    } catch (error) {
      // Android 14+ can revoke SCHEDULE_EXACT_ALARM — the inexact alarm may
      // drift by a minute, which still beats never saying so at all.
      debugPrint('Noor ▸ exact schedule failed for makruh, retrying inexact: $error');
      try {
        await _plugin.zonedSchedule(
          id: makruhId,
          scheduledDate: when,
          title: words.title,
          body: words.body,
          notificationDetails: _makruhDetails,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          matchDateTimeComponents: DateTimeComponents.time,
          payload: 'makruh',
        );
      } catch (secondError) {
        debugPrint('Noor ▸ makruh schedule failed: $secondError');
      }
    }
  }

  static Future<void> cancelAzan() async {
    for (final String key in kNotifiablePrayers) {
      try {
        await _plugin.cancel(id: _azanId(key));
      } catch (_) {}
      // Same twin, same id — cancel it directly rather than trusting the
      // range below to be the only thing standing between a switched-off
      // timing and a prayer that still recites.
      await AzaanAlarm.cancel(_azanId(key));
    }
    await AzaanAlarm.cancelRange(AzaanAlarm.azanIdFloor, kNotifiablePrayers.length);
    // The zawal banner is armed by the same pass, so it is retired by the
    // same pass: a day spent with notifications off must not leave yesterday's
    // half hour ringing from a schedule nobody re-armed.
    try {
      await _plugin.cancel(id: makruhId);
    } catch (_) {}
  }

  /// One-shot id for a snoozed reminder — outside the 0..4 daily block
  /// (those ids return tomorrow) and at or above [_favIdCeiling], which is
  /// what every favourite-masjid re-arm sweeps clean. 1000000000 itself is
  /// the Settings test probe, so this sits one above it, and nowhere near
  /// the epoch-second ids [show] hands out.
  static const int _snoozeId = 1000000001;

  /// Puts one prayer's reminder back ten minutes, from the banner's own
  /// action button — no app open, no settings trip, no "I'll remember".
  ///
  /// Both halves of the reminder come back: the silent banner through the
  /// plugin, and the recitation through the alarm-stream player, so a phone
  /// on vibrate still sounds (that is the whole point of an azan over a
  /// notification). The banner can be snoozed again — its payload carries
  /// the same prayer key, and ten minutes is the plugin's *new* one-shot,
  /// replacing the pending one rather than queueing a second.
  static Future<void> snoozeAzan(String key) async {
    if (!kNotifiablePrayers.contains(key)) return;
    final DateTime at = DateTime.now().add(const Duration(minutes: 10));

    // The snoozed pair is decided the same way as the original: with the
    // clip armed, the recitation card at +10 min *is* the snoozed alert, so
    // no second banner is queued to arrive beside it.
    final AzanSound sound = _bellSound(key);
    if (recitationIsTheCard(sound, 0)) {
      debugPrint('Azan ▸ snoozed $key: recitation card stands in for the '
          'banner — one prayer, one notification');
    } else {
      try {
        await _initTimeZone();
        await _plugin.zonedSchedule(
          id: _snoozeId,
          scheduledDate: tz.TZDateTime.from(at, tz.local),
          title: 'Snoozed • ${prayerByKey(key).label}',
          body: 'Ten minutes back, as you asked.',
          notificationDetails: _azanDetailsFor(key),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          // Tapping the snoozed copy does what the original did: play the clip.
          payload: 'azan:$key',
        );
      } catch (error) {
        debugPrint('Noor ▸ snooze banner failed: $error');
      }
    }

    // The same per-prayer answer the original alarm used: a bell on
    // `silent` snoozes into silence too, never into a recitation it was
    // switched away from.
    if (sound.androidRaw == null) return; // no recitation this bell carries — banner only
    try {
      await AzaanAlarm.schedule(
        id: _snoozeId,
        at: at,
        raw: sound.androidRaw!,
        title: 'Snoozed • ${prayerByKey(key).label}',
        recurring: false,
      );
    } catch (error) {
      debugPrint('Noor ▸ snooze recitation failed: $error');
    }
  }

  /// Upper bound separating the favourite-masjid id block from the
  /// epoch-second ids [show] hands out. Nothing else lives in between: the
  /// location-based reminders own 0..4, favourites own 1000 upwards.
  static const int _favIdCeiling = 1000000000;

  /// Serialises rebuilds — a switch flipped while a pass is in flight has to
  /// be picked up by a *following* pass instead of racing the current one.
  static Future<void> _favChain = Future<void>.value();

  /// Rebuilds the reminders for masjids this account has starred.
  ///
  /// Every pass starts by clearing the whole favourite id block, using
  /// [pendingNotificationRequests] rather than any memory of its own. That is
  /// what keeps it honest across an account switch (the outgoing profile's
  /// alarms must not outlive it) and across un-starring, and it means no
  /// second source of truth has to be persisted alongside the favourites.
  static Future<void> scheduleFavouriteAlerts() {
    final Future<void> next =
        _favChain.then((_) => _rebuildFavouriteAlerts()).catchError((Object error) {
      debugPrint('Noor ▸ favourite alerts failed: $error');
    });
    _favChain = next;
    return next;
  }

  static Future<void> _rebuildFavouriteAlerts() async {
    await _initTimeZone();
    if (!_tzReady) return;

    final AppSettings settings = AppSettings.instance;

    // Whether this pass will arm anything at all — decided *before* anything
    // is cancelled. Cancelling first and fetching after is how a single
    // offline moment deleted every favourite alert and re-armed none of them:
    // the clear ran, the fetches returned null, and the range was left empty
    // until the user happened to open the app again.
    final bool armsJamaat = settings.schedulesJamaat && settings.notificationsEnabled;
    if (!settings.schedulesJamaat) {
      // "When will the Azaan play?" — this pass arms the *Jamaat* reminders,
      // so returning here is exactly the "Only at Awwal time" / "Off" half of
      // the fix: nothing in the favourite range is left scheduled.
      debugPrint('Azan ▸ timing "${settings.azaanTiming}": '
          'favourite-masjid Jamaat alerts cancelled, none scheduled');
    } else if (!settings.notificationsEnabled) {
      debugPrint('Azan ▸ favourite masjid alerts: master switch off, none scheduled');
    }

    final List<String> favourites = (await FavouriteStore.cached())..sort();

    // Read every switched-on board before touching the schedule. A doc that
    // will not come back — offline, deleted, a slow backend — aborts the pass
    // with yesterday's alerts still armed. A stale reminder beats a missing
    // one, and the next successful pass puts it right.
    final List<({int index, String masjidId, Map<String, dynamic> data})> resolved = [];
    if (armsJamaat) {
      for (int i = 0; i < favourites.length; i++) {
        final String masjidId = favourites[i];
        if (!settings.favAlertFor(masjidId)) continue;

        final ({Map<String, dynamic>? data, bool transientFailure}) read =
            await _fetchMasjid(masjidId);
        if (read.transientFailure) {
          // A read that failed says nothing about what is true. Clearing the
          // schedule on it is how one offline moment deleted every alert and
          // re-armed none — keep yesterday's plan and try again later.
          debugPrint('Azan ▸ keeping previous favourite alerts: '
              '$masjidId could not be read (offline?)');
          return;
        }
        final Map<String, dynamic>? board = read.data;
        if (board == null) {
          // The masjid itself has been deleted from Noor while still starred.
          // Skip it — it must not hold the other favourites' alerts hostage —
          // and un-star it so neither this pass nor the Favourites screen
          // chases a document that no longer exists.
          debugPrint('Azan ▸ favourite $masjidId no longer exists in Noor — '
              'un-starring it and carrying on');
          await FavouriteStore.drop(masjidId);
          continue;
        }
        resolved.add((index: i, masjidId: masjidId, data: board));
      }
    }

    try {
      final List<PendingNotificationRequest> pending =
          await _plugin.pendingNotificationRequests();
      for (final PendingNotificationRequest request in pending) {
        if (request.id < _favIdFloor || request.id >= _favIdCeiling) continue;
        try {
          await _plugin.cancel(id: request.id);
        } catch (_) {}
        // Retire the alarm-stream twin by id as well. It shares this id, and
        // an id-based cancel needs neither the native `armedIds` ledger nor
        // the range call below — so one un-starred masjid can never keep
        // reciting just because a bookkeeping path above it went missing.
        await AzaanAlarm.cancel(request.id);
      }
    } catch (error) {
      debugPrint('Noor ▸ could not clear old favourite alerts: $error');
    }

    // The native alarm-stream twins live in the same id space, so they are
    // cleared by range — an un-starred masjid must not keep reciting.
    await AzaanAlarm.cancelRange(_favIdFloor, _favIdCeiling);

    if (!armsJamaat) return;

    final DateTime now = DateTime.now();
    int armed = 0;

    for (final ({int index, String masjidId, Map<String, dynamic> data}) entry in resolved) {
      final Map<String, dynamic> data = entry.data;
      final int i = entry.index;

      final String name = ((data['masjidName'] as String?) ?? '').trim();
      final String where = name.isEmpty ? 'your masjid' : name;
      final int base = _favIdFloor + i * _favIdStride;

      for (int p = 0; p < kNotifiablePrayers.length; p++) {
        final String key = kNotifiablePrayers[p];
        if (!settings.notifyOnFor(key)) continue;

        final int? minutesOfDay = parseClockTime((data[key] as String?) ?? '');
        if (minutesOfDay == null) continue;

        // "Offset" reuses the minutes-before picked for the calculated
        // reminder; anything that means "at the time" simply fires on it.
        final int configured = settings.notifyOffsetFor(key);
        final int minutesBefore =
            settings.favModeFor(key) == kFavModeOffset && configured > 0 ? configured : 0;

        final DateTime atTime =
            DateTime(now.year, now.month, now.day, minutesOfDay ~/ 60, minutesOfDay % 60);
        DateTime fire = atTime.subtract(Duration(minutes: minutesBefore));
        // A time already past happens again tomorrow — the same roll-over the
        // calculated reminders use, so nothing sits armed in the past.
        while (!fire.isAfter(now)) {
          fire = fire.add(const Duration(days: 1));
        }

        // Same one-prayer-one-card rule as the calculated reminders: when
        // the Jamaat recitation rises on this very minute, its card is the
        // alert and the banner stays unscheduled behind it.
        final AzanSound sound = _bellSound(key);
        if (recitationIsTheCard(sound, minutesBefore)) {
          debugPrint('Azan ▸ $where/$key: recitation card stands in for the '
              'banner — one prayer, one notification');
        } else {
          try {
            await _plugin.zonedSchedule(
              id: base + p,
              scheduledDate: tz.TZDateTime(
                tz.local,
                fire.year,
                fire.month,
                fire.day,
                fire.hour,
                fire.minute,
              ),
              title: '${prayerByKey(key).label} • ${settings.format(atTime)}',
              body: minutesBefore == 0
                  ? 'Jamaat at $where.'
                  : '${prayerByKey(key).label} in $minutesBefore minutes at $where.',
              notificationDetails: _azanDetailsFor(key),
              androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
              matchDateTimeComponents: DateTimeComponents.time,
              payload: 'azan:$key',
            );
            armed++;
          } catch (error) {
            debugPrint('Noor ▸ favourite alert failed for $where/$key: $error');
          }
        }

        // The split holds whenever an advance notice is set: the banner
        // fires at `fire` (Jamaat less that notice), the recitation at the
        // Jamaat time itself — and where there is no notice, the banner was
        // held back above because this card already speaks. One id retires
        // both regardless — and it is this prayer's own bell that decides
        // whether the recitation arms at all.
        if (sound.androidRaw != null) {
          await AzaanAlarm.schedule(
            id: base + p,
            at: fire.add(Duration(minutes: minutesBefore)),
            raw: sound.androidRaw!,
            title: '${prayerByKey(key).label} • ${settings.format(atTime)}',
          );
        }
      }
    }

    debugPrint('Azan ▸ scheduled $armed favourite-masjid alert(s) '
        'for ${resolved.length} switched-on favourite(s)');
  }

  /// Reads a favourite's board, saying *how* the read ended.
  ///
  /// The two empty answers mean opposite things to the caller:
  ///
  /// * `transientFailure: true` — offline, a timeout, a rules error. The
  ///   document may well exist; the caller keeps yesterday's schedule (a
  ///   stale reminder beats a missing one).
  /// * `data: null` with no failure — the document is **gone**: a deleted
  ///   masjid still sitting in the star list. It can never arm anything, and
  ///   treating it like an outage let one dead star silence every *readable*
  ///   favourite's alerts on every pass, for ever.
  static Future<({Map<String, dynamic>? data, bool transientFailure})>
      _fetchMasjid(String id) async {
    try {
      // Offline with nothing cached, a Firestore `.get()` does not fail — it
      // waits, indefinitely, from the caller's point of view. The rebuild
      // above depends on this *finishing* in order to decide whether it may
      // safely clear the schedule, so it gets a clock.
      final DocumentSnapshot<Map<String, dynamic>> snap = await FirebaseFirestore
          .instance
          .collection('masjids')
          .doc(id)
          .get()
          .timeout(const Duration(seconds: 20));
      if (!snap.exists) return (data: null, transientFailure: false);
      // `exists` with no fields is an empty board, not a failure: every
      // cell parses to null and the loop simply arms nothing for it.
      return (data: snap.data() ?? <String, dynamic>{}, transientFailure: false);
    } catch (error) {
      debugPrint('Noor ▸ favourite alert lookup failed for $id: $error');
      return (data: null, transientFailure: true);
    }
  }

  /// Reads a masjid board's stored clock as minutes past midnight.
  ///
  /// Scanned boards are written `HH:MM`, but a hand-entered `5:30 PM` must
  /// not be scheduled as 05:30, so both spellings are read. Returns `null`
  /// for `--:--`, blanks and anything else unparseable, which callers treat
  /// as "no reminder for this prayer" rather than an error.
  static int? parseClockTime(String raw) {
    final String value = raw.trim();
    if (value.isEmpty) return null;

    final Match? meridiem =
        RegExp(r'^(\d{1,2})[:.](\d{2})\s*([PpAa])\.?[Mm]\.?$').firstMatch(value);
    if (meridiem != null) {
      final int hour = int.tryParse(meridiem.group(1)!) ?? -1;
      final int minute = int.tryParse(meridiem.group(2)!) ?? -1;
      if (hour < 1 || hour > 12 || minute > 59) return null;
      final int twelveHour = hour % 12;
      final int afternoon = meridiem.group(3)!.toLowerCase() == 'p' ? 12 : 0;
      return (twelveHour + afternoon) * 60 + minute;
    }

    final Match? clock = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value);
    if (clock == null) return null;
    final int hour = int.tryParse(clock.group(1)!) ?? -1;
    final int minute = int.tryParse(clock.group(2)!) ?? -1;
    if (hour < 0 || hour > 23 || minute > 59) return null;
    return hour * 60 + minute;
  }

  static Future<void> show({required String title, required String body}) async {
    try {
      await _plugin.show(
        id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'masjid_time_updates',
            'Masjid Time Updates',
            channelDescription: 'Alerts when a favourite masjid updates its prayer times',
            importance: Importance.high,
            priority: Priority.high,
            color: Color(0xFF0A4D3C),
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    } catch (error) {
      debugPrint('Noor ▸ notification failed: $error');
    }
  }

  /// Reserved id for the "Send test reminder" probe, so a second tap replaces
  /// the first instead of stacking.
  ///
  /// It has to sit **outside** the favourite block, because
  /// `_rebuildFavouriteAlerts` cancels that whole range on every reschedule.
  /// The original value, 791900, was picked on the assumption that the block
  /// was a small 1000-and-up run — it is not: the ceiling is [_favIdCeiling],
  /// a billion. So the probe's second notification (the closed-app one, the
  /// half that actually proves anything) was armed and then cancelled a
  /// moment later by an unrelated rebuild, which is indistinguishable from an
  /// alarm that simply never fired.
  ///
  /// Sitting exactly on [_favIdCeiling] excludes it through the half-open
  /// `[floor, ceiling)` test itself, and stays clear of the 0..4 prayer ids
  /// and the epoch-second ids `show()` uses (~1.79e9).
  static const int _testReminderId = _favIdCeiling;

  /// Public only so a test can pin [testReminderId] outside the block that
  /// `_rebuildFavouriteAlerts` clears — that range is [1000, 1000000000), and
  /// an id inside it gets cancelled the moment any favourite alert rebuilds.
  @visibleForTesting
  static int get testReminderId => _testReminderId;

  /// Posts one reminder on the Azaan channel now, and a second a minute later.
  ///
  /// The second is the half that matters. The Settings screen tells the user
  /// to swipe the app away first, so it only lands if Android is willing to
  /// wake a closed app — precisely the condition every real prayer time has
  /// to survive, and the one a "Test Azaan" button can never reach because
  /// that plays in-process with the app open. What lands is what a prayer
  /// now shows: the recitation card when the clip is armed — one card, the
  /// same [recitationIsTheCard] rule Fajr obeys — and the banner only for
  /// a bell with no clip behind it.
  static Future<void> testReminder() async {
    try {
      await applyAzanChannel();
      await _plugin.show(
        id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title: 'Test reminder',
        body: '${_azanSound.label} is set — a prayer reminder looks like this.',
        notificationDetails: _azanDetails(),
      );
    } catch (error) {
      debugPrint('Noor ▸ immediate test reminder failed: $error');
    }

    try {
      await _initTimeZone();
      if (!_tzReady) return;
      await _plugin.cancel(id: _testReminderId);
      final tz.TZDateTime when =
          tz.TZDateTime.now(tz.local).add(const Duration(seconds: 60));
      final AzanSound sound = _azanSound;
      // The probe shows what a prayer shows — one card. Where the clip will
      // speak for it, the banner is held back exactly as it is held back at
      // Fajr; a probe firing two cards would be demonstrating a screen the
      // reader no longer gets.
      if (recitationIsTheCard(sound, 0)) {
        debugPrint('Noor ▸ closed-app test: recitation card stands in for '
            'the banner — one test, one notification');
      } else {
        try {
          await _plugin.zonedSchedule(
            id: _testReminderId,
            scheduledDate: when,
            title: 'Closed-app test',
            body: 'This fired with Noor shut — exactly what a prayer time does.',
            notificationDetails: _azanDetails(),
            androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          );
        } catch (error) {
          // Android 14+ can revoke SCHEDULE_EXACT_ALARM; an inexact minute is
          // still a perfectly good answer to "can my phone wake the app?".
          debugPrint('Noor ▸ exact test reminder failed, retrying inexact: $error');
          await _plugin.zonedSchedule(
            id: _testReminderId,
            scheduledDate: when,
            title: 'Closed-app test',
            body: 'This fired with Noor shut — exactly what a prayer time does.',
            notificationDetails: _azanDetails(),
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          );
        }
      }

      // The recitation at the same minute, on the same id. The banner alone
      // no longer proves anything audible: it carries no sound, by design —
      // the clip is the alarm-stream player's job, and this is the one button
      // that puts that exact path to work with the app shut.
      await AzaanAlarm.cancel(_testReminderId);
      if (sound.androidRaw != null) {
        await AzaanAlarm.schedule(
          id: _testReminderId,
          at: when,
          raw: sound.androidRaw!,
          title: 'Closed-app test',
          // Not recurring: a diagnostic that resurrects itself every morning
          // would be indistinguishable from the bug it exists to test for.
          recurring: false,
        );
      }
    } catch (error) {
      debugPrint('Noor ▸ scheduled test reminder failed: $error');
    }
  }
}

class LocationService {
  LocationService._();

  /// Fallback anchor used for distance sorting before GPS is granted.
  static const math.Point<double> fallbackAnchor = math.Point<double>(19.0760, 72.8777); // Mumbai

  /// Last position obtained on this device, shared by every screen so that
  /// distance sorting is identical across the app.
  static Position? lastPosition;

  static double get anchorLatitude => lastPosition?.latitude ?? fallbackAnchor.x;
  static double get anchorLongitude => lastPosition?.longitude ?? fallbackAnchor.y;

  /// Floor applied to every reading.
  ///
  /// Anything under this is two documents describing the same place, and a
  /// badge reading "0 m away" looks like a bug rather than a fact. It also
  /// keeps the top of the list from jittering between values that are
  /// indistinguishable in the real world.
  static const double minDistanceMetres = 50;

  /// Local haversine — no map API, no network call.
  static double distanceTo(double latitude, double longitude) {
    final double metres = Geolocator.distanceBetween(
      anchorLatitude,
      anchorLongitude,
      latitude,
      longitude,
    );
    if (!metres.isFinite) return metres;
    return metres < minDistanceMetres ? minDistanceMetres : metres;
  }

  /// Great-circle distance between two arbitrary points, with no floor.
  ///
  /// The floor in [distanceTo] exists so a *reported* reading stays readable;
  /// "Moved by" on the fix-location screen wants the raw figure, so a
  /// four-metre correction has to read as four metres.
  static double between(double lat1, double lon1, double lat2, double lon2) =>
      Geolocator.distanceBetween(lat1, lon1, lat2, lon2);

  /// The box every masjid in this list is expected to fall in.
  ///
  /// A pair outside it is either transposed (see [repairLatLon]) or plain
  /// wrong — and either way it should be visible, because a coordinate in the
  /// Arabian Sea makes the masjid look tens of thousands of kilometres away
  /// and drops it out of the radius filter entirely.
  static bool isInMumbai(double latitude, double longitude) =>
      latitude >= 18.8 &&
      latitude <= 19.4 &&
      longitude >= 72.7 &&
      longitude <= 73.0;

  /// Puts a lat/lon pair back the right way round.
  ///
  /// Latitude stops at 90°, so a value above 50 in the *latitude* slot cannot
  /// be a Mumbai latitude at all — it is the longitude (72.x) written into the
  /// wrong field. The swap is therefore exact rather than a guess: no
  /// heuristics, no tolerance, just the only reading that can be true.
  static List<double> repairLatLon(double latitude, double longitude) =>
      latitude > 50 ? <double>[longitude, latitude] : <double>[latitude, longitude];

  /// Why the last attempt did not get a fresh satellite fix; empty when it
  /// did. Lets the caller say what actually happened instead of guessing
  /// "permission denied or timeout" at every failure.
  static String gpsIssue = '';

  /// Permission as of the last check, so the caller can offer a route back
  /// into system settings even when a cached fix saved the launch.
  static LocationPermission permissionState = LocationPermission.denied;

  /// Whether the OS location switch itself is on.
  ///
  /// Refreshed on every fix by [currentPosition], and by `HomeScreen` from
  /// `Geolocator.getServiceStatusStream` plus every return to the foreground —
  /// so flipping location off in the quick-settings panel is noticed here
  /// without restarting the app.
  static bool serviceEnabled = false;

  /// True only while a distance printed on screen would be true.
  ///
  /// [distanceTo] deliberately falls back to Mumbai when there is no fix: the
  /// right behaviour for sorting a cold start, and the wrong behaviour for
  /// anything a person reads, because it confidently prints "11.4 km away"
  /// for a masjid down the street while location is switched off. Every
  /// distance the UI shows is gated on this, and it drops out the instant the
  /// switch goes off — see `LocationOffBanner` for how that is explained.
  static bool get distanceAvailable =>
      serviceEnabled &&
      (permissionState == LocationPermission.whileInUse ||
          permissionState == LocationPermission.always) &&
      lastPosition != null;

  /// Broadcast whenever [distanceAvailable] flips.
  ///
  /// A badge living underneath the screen that noticed the change still has to
  /// redraw, so the gate is pushed out rather than only read during `build`.
  static final ValueNotifier<bool> distanceGate = ValueNotifier<bool>(false);

  /// Publishes the current gate state; returns true when it just changed.
  static bool syncDistanceGate() {
    final bool next = distanceAvailable;
    if (distanceGate.value == next) return false;
    distanceGate.value = next;
    return true;
  }

  static Future<Position?> currentPosition({bool ask = true}) async {
    gpsIssue = '';

    try {
      serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        gpsIssue = 'location services are switched off';
        debugPrint('Noor ▸ GPS: $gpsIssue');
        return await _lastKnown();
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied && ask) {
        permission = await Geolocator.requestPermission();
      }
      permissionState = permission;
      debugPrint('Noor ▸ GPS: permission = $permission');

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        gpsIssue = permission == LocationPermission.deniedForever
            ? 'permission blocked in system settings'
            : 'permission not granted';
        debugPrint('Noor ▸ GPS: $gpsIssue — falling back to the cached fix');
        return await _lastKnown();
      }

      try {
        final Position fresh = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 20),
          ),
        );
        lastPosition = fresh;
        return fresh;
      } on TimeoutException catch (_) {
        gpsIssue = 'satellite fix timed out after 20s';
        debugPrint('Noor ▸ GPS: $gpsIssue — falling back to the cached fix');
        return await _lastKnown();
      }
    } catch (error) {
      gpsIssue = 'failed ($error)';
      debugPrint('Noor ▸ GPS: $gpsIssue — falling back to the cached fix');
      return _lastKnown();
    } finally {
      // Every exit — fresh fix, cached fix, permission refused, service off —
      // has to republish the gate, because each of them changes the answer.
      syncDistanceGate();
    }
  }

  /// Whatever the OS cached from an earlier session.
  ///
  /// Stale coordinates still put a real place name in the header, real metres
  /// on the list badges and real times on the prayer card, instead of
  /// collapsing everything to "Near You" while the phone hunts for satellites.
  static Future<Position?> _lastKnown() async {
    try {
      final Position? cached = await Geolocator.getLastKnownPosition();
      if (cached != null) {
        lastPosition = cached;
        debugPrint('Noor ▸ GPS: cached fix ${cached.latitude},${cached.longitude}');
      }
      return cached;
    } catch (error) {
      debugPrint('Noor ▸ GPS: no cached fix ($error)');
      return null;
    }
  }

  static Future<String> reverseGeocode(double latitude, double longitude) async {
    try {
      final List<geocoding.Placemark> places =
          await geocoding.Geocoding().placemarkFromCoordinates(latitude, longitude);
      if (places.isEmpty) return '';
      return formatPlacemark(places.first);
    } catch (error) {
      debugPrint('Noor ▸ reverse geocode failed: $error');
      return '';
    }
  }

  static String localityOf(geocoding.Placemark place) {
    final String value = (place.locality ??
            place.subAdministrativeArea ??
            place.administrativeArea ??
            place.country ??
            '')
        .trim();
    return value;
  }
}

/// Favourite masjid ids -> Firestore `users/{uid}/favourites` + a local cache
/// that is scoped to the same account.
class FavouriteStore {
  FavouriteStore._();

  /// Per-account cache key (`anon` while signed out).
  ///
  /// This used to be one global key shared by everyone who used the phone, so
  /// signing in as anyone showed the previous account's favourites — and
  /// `_syncFavouritesFromCloud` then merged that foreign list back into the
  /// same key, which is what made the leak stick. Firestore was always
  /// `users/{uid}/favourites`; only the local cache was shared.
  /// Per-account cache key (`anon` while signed out).
  @visibleForTesting
  static String cacheKeyFor(String? uid) => 'noor_favourite_ids::${uid ?? 'anon'}';

  /// The single un-scoped key written by builds before this fix. Its contents
  /// are ambiguous — they may belong to any account that used this device — so
  /// they are handed to the signed-out profile and the key is dropped. No
  /// signed-in account can inherit someone else's list; signed-in users get
  /// their real favourites back from Firestore on the next sync.
  @visibleForTesting
  static const String legacyCacheKey = 'noor_favourite_ids';

  static String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  static CollectionReference<Map<String, dynamic>>? _collection() {
    final String? uid = _uid;
    if (uid == null) return null;
    return FirebaseFirestore.instance.collection('users').doc(uid).collection('favourites');
  }

  @visibleForTesting
  static Future<void> retireLegacyCacheKey(SharedPreferences prefs) async {
    if (!prefs.containsKey(legacyCacheKey)) return;

    final List<String> legacy = prefs.getStringList(legacyCacheKey) ?? <String>[];
    if (legacy.isNotEmpty) {
      final String anonKey = cacheKeyFor(null);
      final List<String> anon = prefs.getStringList(anonKey) ?? <String>[];
      await prefs.setStringList(anonKey, <String>{...anon, ...legacy}.toList());
    }
    await prefs.remove(legacyCacheKey);
    debugPrint('Noor ▸ favourites cache re-scoped per account '
        '(${legacy.length} legacy id(s) kept for the signed-out profile)');
  }

  static Future<List<String>> cached() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await retireLegacyCacheKey(prefs);
    return (prefs.getStringList(cacheKeyFor(_uid)) ?? <String>[]).toList();
  }

  static Future<void> cache(List<String> ids) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await retireLegacyCacheKey(prefs);
    await prefs.setStringList(cacheKeyFor(_uid), ids);
  }

  static Future<void> toggle(String masjidId) async {
    final CollectionReference<Map<String, dynamic>>? collection = _collection();
    final List<String> ids = await cached();
    final bool isFav = ids.contains(masjidId);

    if (isFav) {
      ids.remove(masjidId);
    } else {
      ids.add(masjidId);
    }
    await cache(ids);

    if (collection == null) return;
    final DocumentReference<Map<String, dynamic>> doc = collection.doc(masjidId);
    if (isFav) {
      await doc.delete();
    } else {
      await doc.set(<String, dynamic>{
        'masjidId': masjidId,
        'createdAt': Timestamp.now(),
      });
    }
  }

  /// Un-stars a masjid whose document no longer exists.
  ///
  /// The cached list is the one the alert scheduler reads, so that half is
  /// awaited — it is local and fast. The account copy is fired and forgotten:
  /// this runs from a schedule pass that must never wait on the network (an
  /// offline write future pends until the server acknowledges it), and a
  /// failed mirror of an already-dead star costs nothing.
  static Future<void> drop(String masjidId) async {
    final List<String> ids = await cached();
    if (!ids.remove(masjidId)) return;
    await cache(ids);

    final CollectionReference<Map<String, dynamic>>? collection = _collection();
    if (collection == null) return;
    unawaited(
      collection.doc(masjidId).delete().catchError((Object error) {
        debugPrint('Noor ▸ could not drop the account copy of $masjidId: $error');
      }),
    );
  }
}

/// Listens to every favourite masjid and fires a local notification whenever
/// one of its prayer times changes.
class FavouriteWatcher {
  FavouriteWatcher._();

  static final Map<String, StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>> _subs =
      <String, StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>>{};
  static final Set<String> _pending = <String>{};

  static void watch(List<String> ids) {
    final Set<String> wanted = ids.toSet();

    _subs.removeWhere((String id, StreamSubscription<DocumentSnapshot<Map<String, dynamic>>> sub) {
      if (wanted.contains(id)) return false;
      unawaited(sub.cancel());
      return true;
    });

    for (final String id in wanted) {
      if (_subs.containsKey(id)) continue;
      final StreamSubscription<DocumentSnapshot<Map<String, dynamic>>> sub = FirebaseFirestore
          .instance
          .collection('masjids')
          .doc(id)
          .snapshots()
          .listen(
            (DocumentSnapshot<Map<String, dynamic>> snap) => _onChange(id, snap),
            onError: (Object error) => debugPrint('Noor ▸ favourite stream: $error'),
          );
      _subs[id] = sub;
    }
  }

  static Future<void> _onChange(String id, DocumentSnapshot<Map<String, dynamic>> snap) async {
    if (!snap.exists) return;
    if (_pending.contains(id)) return;
    _pending.add(id);
    try {
      final Map<String, dynamic> data = snap.data() ?? <String, dynamic>{};
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      // Baseline is per account: otherwise the first account to see a change
      // marks it read and the other account never hears about it.
      final String key =
          'noor_last_seen::${FirebaseAuth.instance.currentUser?.uid ?? 'anon'}::$id';
      final String? previousRaw = prefs.getString(key);

      final Map<String, String> current = <String, String>{
        for (final PrayerInfo p in kPrayers) p.key: (data[p.key] as String?) ?? '',
      };
      final int currentStamp = ((data['lastUpdated'] as Timestamp?)?.millisecondsSinceEpoch) ?? 0;

      if (previousRaw == null) {
        await prefs.setString(
          key,
          jsonEncode(<String, dynamic>{'times': current, 'lastUpdated': currentStamp}),
        );
        return;
      }

      final Map<String, dynamic> previous = jsonDecode(previousRaw) as Map<String, dynamic>;
      final int previousStamp = (previous['lastUpdated'] as num?)?.toInt() ?? 0;
      if (previousStamp == currentStamp) return;

      final Map<String, dynamic> previousTimes =
          (previous['times'] as Map<String, dynamic>?) ?? <String, dynamic>{};

      // Never notify the person who made the change.
      final String author = (data['updatedByUid'] as String?) ?? '';
      final String self = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (author.isNotEmpty && author == self) {
        await prefs.setString(
          key,
          jsonEncode(<String, dynamic>{'times': current, 'lastUpdated': currentStamp}),
        );
        return;
      }

      final List<String> messages = <String>[];
      for (final PrayerInfo prayer in kPrayers) {
        final String now = current[prayer.key] ?? '';
        final String before = (previousTimes[prayer.key] as String?) ?? '';
        if (now.isNotEmpty && now != before) {
          messages.add('${prayer.label}: $now');
        }
      }

      if (messages.isNotEmpty) {
        final String name = (data['masjidName'] as String?)?.trim().isNotEmpty == true
            ? (data['masjidName'] as String)
            : 'Masjid';
        await NotificationService.show(
          title: '$name • Prayer time updated',
          body: '$name ka ${messages.first.split(':').first.trim()} time update hua: '
              '${messages.first.split(':').last.trim()}',
        );
        // The board moved, so so did the alerts aimed at it.
        unawaited(NotificationService.scheduleFavouriteAlerts());
      }

      await prefs.setString(
        key,
        jsonEncode(<String, dynamic>{'times': current, 'lastUpdated': currentStamp}),
      );
    } catch (error, stack) {
      // One unreadable document must not take the whole watcher with it: the
      // `finally` below releases the id, and the next snapshot gets a fresh
      // attempt. Before this, the throw left an unhandled async error in the
      // zone — and because `snap.data()` is hard-cast on the way in, a doc
      // where `fajr` is the number 530 instead of "5:30" was enough to
      // produce one every time the stream emitted.
      debugPrint('Noor ▸ favourite change for $id could not be processed: '
          '$error\n$stack');
    } finally {
      _pending.remove(id);
    }
  }

  static void dispose() {
    for (final StreamSubscription<DocumentSnapshot<Map<String, dynamic>>> sub in _subs.values) {
      unawaited(sub.cancel());
    }
    _subs.clear();
  }
}

// ===========================================================================
//  LOGIN
// ===========================================================================

/// One shared [GoogleSignIn] client.
///
/// [serverClientId] must be the OAuth *Web* client ID (client_type 3) from
/// `google-services.json`. `google_sign_in_android` only calls
/// `requestIdToken` when this is non-empty, and Firebase Auth needs that ID
/// token to complete the credential exchange. Passing it explicitly also
/// overrides the `default_web_client_id` string resource, so the value stays
/// correct if the generated resource ever drifts.
///
/// NOTE: this project resolves `google_sign_in` 6.3.0, whose API is the
/// constructor + `.signIn()`. The `GoogleSignIn.instance` /
/// `authenticate()` singleton only exists in google_sign_in 7.x, so it is
/// deliberately not used here — switching to it would require a breaking
/// upgrade of the whole google_sign_in family.
final GoogleSignIn _googleSignIn = GoogleSignIn(
  serverClientId: DefaultFirebaseOptions.android.androidClientId,
);

/// Turns raw plugin errors into a message that names the actual fix.
///
/// `Api10` / `DEVELOPER_ERROR` is almost always a package-name + SHA-1
/// mismatch between the APK actually installed on the device and the
/// fingerprints registered in Firebase Console.
String _googleSignInErrorMessage(Object error) {
  final String raw = error.toString();

  // PlatformException(sign_in_failed, Api10, ...)
  final bool isSigninFailed = raw.contains('sign_in_failed');
  final bool mentionsApi10 =
      raw.contains('Api10') || raw.contains('Api 10') || raw.contains('10:');
  final bool isDeveloperError =
      raw.toUpperCase().contains('DEVELOPER_ERROR') || raw.contains('Api 10');

  if (isSigninFailed && (mentionsApi10 || isDeveloperError)) {
    return 'Google Sign-In failed (Api10 / DEVELOPER_ERROR).\n\n'
        'Cause: the SHA-1 fingerprint of the key that signed this build is not '
        'registered for package "com.sunesra_app" in Firebase Console.\n\n'
        'Debug SHA-1 to add:\n'
        '9A:6C:77:10:16:C0:75:9F:19:D3:48:F2:D7:56:9B:44:EA:9A:EA:8A\n\n'
        'After adding it, fully stop and re-run the app (a rebuild is required).';
  }

  if (isSigninFailed) {
    return 'Google Sign-In failed: $raw\n\n'
        'Check that SHA-1 is registered in Firebase Console and that the app was '
        'rebuilt afterwards.';
  }

  if (raw.contains('sign_in_canceled') || raw.contains('kSignInCanceledError')) {
    return 'Sign-in was cancelled.';
  }

  if (raw.contains('network_error')) {
    return 'No network connection. Check your internet and try again.';
  }

  return raw.replaceFirst('Exception: ', '');
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, this.errorMessage});

  final String? errorMessage;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _signInWithGoogle() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = widget.errorMessage;
    });

    try {
      // 1. Real Google account picker.
      final GoogleSignInAccount? account = await _googleSignIn.signIn();
      if (account == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }

      // 2. Real OAuth tokens.
      final GoogleSignInAuthentication auth = await account.authentication;

      if (auth.idToken == null) {
        // No idToken means serverClientId was not accepted — Api10 follows.
        throw StateError(
          'sign_in_failed: Google returned no idToken. '
          'serverClientId=${DefaultFirebaseOptions.android.androidClientId} '
          'was not used for the token request.',
        );
      }

      // 3. Real Firebase credential exchange.
      final AuthCredential credential = GoogleAuthProvider.credential(
        accessToken: auth.accessToken,
        idToken: auth.idToken,
      );
      await FirebaseAuth.instance.signInWithCredential(credential);
    } on FirebaseAuthException catch (error) {
      _error = error.message ?? error.code;
    } catch (error) {
      _error = _googleSignInErrorMessage(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return NoorScaffold(
      sky: NoorSky.night,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          const IgnorePointer(child: CustomPaint(painter: IslamicPatternPainter(tile: 86, opacity: 0.13))),

          // Soft gold glow
          Positioned(
            top: -140,
            right: -90,
            child: Container(
              width: 320,
              height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: <Color>[NoorColors.gold.withValues(alpha: 0.35), Colors.transparent],
                ),
              ),
            ),
          ),

          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 26),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Center(child: NoorBadge(size: 116)),
                    const SizedBox(height: 22),
                    Text(
                      'Noor',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.amiri(
                        fontSize: 56,
                        fontWeight: FontWeight.w700,
                        color: NoorColors.gold,
                        height: 1,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'نُور',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.amiri(fontSize: 26, color: NoorColors.gold, height: 1.4),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                      decoration: BoxDecoration(
                        color: NoorColors.onGlassChip,
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(color: NoorColors.gold.withValues(alpha: 0.5)),
                      ),
                      child: Text(
                        'Real Masjid, Real Time',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.outfit(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.4,
                          color: NoorColors.ink,
                        ),
                      ),
                    ),
                    const SizedBox(height: 34),

                    _FeatureRow(
                      icon: Icons.document_scanner_outlined,
                      title: 'Scan the masjid board',
                      subtitle: 'On-device AI reads the prayer times from a photo',
                    ),
                    const SizedBox(height: 14),
                    _FeatureRow(
                      icon: Icons.groups_2_outlined,
                      title: 'Updated for everyone nearby',
                      subtitle: 'Community verified times, synced live for all users',
                    ),

                    const SizedBox(height: 34),

                    Semantics(
                      button: true,
                      label: 'Continue with Google',
                      child: GestureDetector(
                        onTap: _busy ? null : _signInWithGoogle,
                        child: Container(
                          height: 56,
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          decoration: BoxDecoration(
                            color: NoorColors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: NoorColors.gold, width: 1.2),
                            boxShadow: <BoxShadow>[
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.18),
                                blurRadius: 24,
                                offset: const Offset(0, 12),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              if (_busy)
                                const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    color: NoorColors.emeraldDeep,
                                  ),
                                )
                              else
                                const GoogleLogo(size: 22),
                              const SizedBox(width: 14),
                              Text(
                                'Continue with Google',
                                style: GoogleFonts.outfit(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: const Color(0xFF1F1F1F),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    if (_error != null) ...<Widget>[
                      const SizedBox(height: 18),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: NoorColors.danger.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: NoorColors.danger.withValues(alpha: 0.5)),
                        ),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.outfit(fontSize: 12.5, color: NoorColors.danger, height: 1.5),
                        ),
                      ),
                    ],

                    const SizedBox(height: 26),
                    Text(
                      'Any logged-in member can update any masjid’s time.\n'
                      'Every update is saved with photo proof.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.outfit(fontSize: 11.5, color: NoorColors.muted, height: 1.7),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({required this.icon, required this.title, required this.subtitle});

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: NoorColors.onGlassChip,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: NoorColors.gold.withValues(alpha: 0.45)),
          ),
          child: Icon(icon, size: 19, color: NoorColors.gold),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: GoogleFonts.outfit(fontSize: 14, fontWeight: FontWeight.w600, color: NoorColors.ink),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: GoogleFonts.outfit(fontSize: 12, color: NoorColors.muted, height: 1.5),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ===========================================================================
//  HOME
// ===========================================================================

/// Orders the nearby list: every starred masjid first, then the rest.
///
/// A favourite is a *choice*, not a measurement, so it holds the top of the
/// list even when there is no GPS fix to sort the remainder by. Inside each
/// band the incoming order survives untouched — nearest first when distance
/// is honest, otherwise the order the list arrived in.
///
/// This is deliberately a partition rather than a comparison sort: two starred
/// masjids with nothing to measure between them must not be able to swap
/// places from one rebuild to the next.
List<MapEntry<Masjid, double>> favouritesFirst(
  List<MapEntry<Masjid, double>> entries,
  List<String> favouriteIds,
) {
  final List<MapEntry<Masjid, double>> starred = <MapEntry<Masjid, double>>[];
  final List<MapEntry<Masjid, double>> rest = <MapEntry<Masjid, double>>[];

  for (final MapEntry<Masjid, double> entry in entries) {
    (favouriteIds.contains(entry.key.id) ? starred : rest).add(entry);
  }
  return starred + rest;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();

  String _locality = 'Near Mumbai';
  String _query = '';
  bool _scanning = false;
  List<String> _favourites = <String>[];
  bool _favouritesLoaded = false;

  /// Only masjids within this range are shown as "nearby".
  static const double _radiusMetres = 10000; // 10 km

  /// True while the GPS fix is in flight — drives the shimmer skeleton so the
  /// screen never flashes "No masjids yet" before we know where we are.
  bool _locating = true;
  Position? _position;

  /// Firestore snapshot owned here so the list and the search dropdown read
  /// exactly the same data.
  final List<Masjid> _all = <Masjid>[];
  bool _listLoading = true;
  Object? _listError;

  /// Ends the "still loading" state if the first snapshot never arrives.
  Timer? _listFallback;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subscription;

  /// Provider section of the search dropdown (OpenStreetMap today).
  List<MasjidSearchResult> _placeResults = <MasjidSearchResult>[];
  bool _placesLoading = false;
  bool _placesSearched = false;
  int _placesToken = 0;

  /// Mosques OpenStreetMap knows about around the user. Shown under the shared
  /// Firestore list so places nobody has contributed times for yet are still
  /// discoverable — one tap away from "Add Jamaat Time for this Masjid".
  bool _osmLoading = false;
  final List<MasjidSearchResult> _osmNearby = <MasjidSearchResult>[];

  /// Kept current from the OS, not from the last fix we happened to take.
  StreamSubscription<ServiceStatus>? _serviceSubscription;

  /// Which of the four tabs the bar at the bottom is showing — home,
  /// nearby, favourites, profile. All four are one screen's worth of state,
  /// so the list, the location and the favourites stay warm while you move
  /// between them.
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppSettings.instance.addListener(_settingsChanged);
    // The owner's notice and wallpaper live in the same document the admin
    // panel writes; without this listener an edit reaches Firestore but not
    // the screen that is already open.
    AppConfig.instance.addListener(_settingsChanged);
    _watchLocationService();
    // `_bootstrap` fans out into settings, favourites, the GPS fix and the
    // first schedule pass. Any throw in there used to abort everything after
    // it, silently: the app would come up looking entirely fine with no
    // reminders armed and no favourites loaded.
    unawaited(_bootstrap().catchError((Object error, StackTrace stack) {
      debugPrint('Noor ▸ bootstrap failed: $error\n$stack');
    }));
    _subscribeToMasjids();
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_settingsChanged);
    AppConfig.instance.removeListener(_settingsChanged);
    WidgetsBinding.instance.removeObserver(this);
    _listFallback?.cancel();
    _serviceSubscription?.cancel();
    _subscription?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// Settings reach this screen as well as the widgets that listen on their
  /// own: the Today card's chooser writes `today_board_pref` from inside a
  /// bottom sheet, where no pop comes back to refresh anything.
  void _settingsChanged() {
    if (mounted) setState(() {});
  }

  /// Live answer to "may we show a distance right now?".
  ///
  /// Reads the gate instead of a cached flag, so every widget that asks agrees
  /// with the stream that keeps it current.
  bool get _gpsLive => LocationService.distanceAvailable;

  /// Follows the OS location switch, from boot and from any other app.
  ///
  /// Switching location off in the quick-settings panel has to make the
  /// distances disappear right here — no restart, no wait for the next fix.
  void _watchLocationService() {
    _serviceSubscription?.cancel();
    _serviceSubscription = Geolocator.getServiceStatusStream().listen(
          (ServiceStatus _) => unawaited(_syncLocationGate()),
          onError: (Object _) {},
        );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The switch or the permission may have been changed in system settings
    // while Noor was in the background — re-read both on the way back in.
    if (state != AppLifecycleState.resumed) return;
    unawaited(_syncLocationGate());
    unawaited(_resyncReminders());
    // Coming back is also when the home-screen widget's picture is most
    // likely stale — the "next prayer" line moves with the clock whether
    // or not the app was open to notice.
    _refreshHomeWidget();
  }

  /// Feeds the home-screen widget its picture of the day.
  ///
  /// Every failure is swallowed inside [PrayerWidget.push]: a widget that
  /// misses a refresh is stale, and being stale beats an exception taking
  /// the resume path down over a decoration.
  void _refreshHomeWidget() {
    final AppSettings settings = AppSettings.instance;
    unawaited(PrayerWidget.push(
      latitude: _position?.latitude ?? LocationService.fallbackAnchor.x,
      longitude: _position?.longitude ?? LocationService.fallbackAnchor.y,
      areaName: settings.hasCustomLocation
          ? settings.customCity
          : (_locality.isEmpty ? 'Prayer times' : _locality),
    ));
  }

  /// The calendar day the reminders were last derived for.
  DateTime? _lastReminderSyncDay;

  /// The notice last dismissed, so closing one does not bring it straight
  /// back — while a *new* notice from the owner does appear.
  String _dismissedAnnouncement = '';

  /// Whether the revoked exact-alarm permission has been reported this run.
  bool _warnedExactAlarmLost = false;

  /// Whether the missing overlay permission has been reported this run.
  bool _warnedOverlayMissing = false;

  /// Names the MIUI switch that decides whether a recitation can put itself up
  /// when the phone is unlocked.
  ///
  /// Two routes reach a window, and only one of them survives an unlocked
  /// phone: the full-screen intent on the playback notification carries the
  /// card over the *lock* screen, while a direct background launch — gated on
  /// MIUI's "Display pop-up windows while running in the background" — is what
  /// covers Noor sitting behind another app. MIUI refuses that second route
  /// silently, at the exact second the alarm fires: the recitation is already
  /// sounding, the card never appears, and a volume key has nothing to land
  /// on.
  ///
  /// The permission cannot be granted from here, so the next best thing is to
  /// name the setting once and take the user to it — on MIUI to
  /// SecurityCenter's own permission editor, where that toggle actually
  /// lives, rather than the AOSP overlay page that does not hold it. The
  /// platform side reads both switches ([AzaanAlarm.canDrawOverlays]), so this
  /// fires only while the setting the message names is genuinely off, and
  /// stops the moment it is turned on.
  Future<void> _warnIfOverlayMissing() async {
    if (_warnedOverlayMissing) return;
    try {
      if (!await AzaanAlarm.needsOverlayPermission()) return;
      if (await AzaanAlarm.canDrawOverlays()) return;
    } catch (_) {
      return;
    }
    _warnedOverlayMissing = true;
    if (!mounted) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
      content: const Text(
        'This phone blocks the Azaan screen unless “Display pop-up windows '
        'while running in the background” is allowed for Noor. The Azaan '
        'still sounds — only the screen that stops it is lost.',
      ),
      action: SnackBarAction(
        label: 'Allow',
        onPressed: () => unawaited(AzaanAlarm.requestOverlayPermission()),
      ),
    ));
  }

  /// Puts the reminders back in step with the device after a spell away.
  ///
  /// Three things move under a schedule without anything in the app
  /// noticing: the clock or the zone — armed instants keep their epoch and
  /// silently change wall-clock minute; the calendar day — the repeating
  /// banners carry the titles they were created with; and the exact-alarm
  /// permission, which Android 12+ lets the user (or an OEM battery manager)
  /// take back at any moment. One re-arm answers all three, and costs
  /// nothing at all when none of them happened.
  Future<void> _resyncReminders() async {
    unawaited(_warnIfOverlayMissing());

    final DateTime today = DateTime.now();
    final bool dayRolled = _lastReminderSyncDay != null &&
        !DateUtils.isSameDay(_lastReminderSyncDay, today);
    final bool moved = NotificationService.timeZoneMoved;

    if (!dayRolled && !moved) {
      // Still worth watching for a revoked permission: the alarms fall back to
      // inexact on their own, so nothing *breaks* — the drift is the part the
      // user has to be told about.
      if (!await AzaanAlarm.canScheduleExact()) _warnExactAlarmLost();
      return;
    }

    if (moved) {
      debugPrint('Azan ▸ clock or zone changed while away — re-arming in the new zone');
      NotificationService.invalidateTimeZone();
    }
    debugPrint('Azan ▸ a new day while away — refreshing the reminders');

    final Position? position = _position ?? LocationService.lastPosition;
    await NotificationService.scheduleAzan(
      latitude: position?.latitude ?? LocationService.fallbackAnchor.x,
      longitude: position?.longitude ?? LocationService.fallbackAnchor.y,
    );
    await NotificationService.scheduleFavouriteAlerts();
    _lastReminderSyncDay = DateTime.now();

    if (!await AzaanAlarm.canScheduleExact()) _warnExactAlarmLost();
  }

  /// Says so, once, when the permission that keeps reminders on the minute has
  /// been taken back since the app last looked.
  void _warnExactAlarmLost() {
    if (_warnedExactAlarmLost || !mounted) return;
    _warnedExactAlarmLost = true;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
      content: const Text(
        "Android withdrew Noor's permission to set precise alarms — "
        'reminders may now arrive late. Tap to restore it.',
      ),
      action: SnackBarAction(
        label: 'Restore',
        onPressed: () => unawaited(AzaanAlarm.requestExactAlarm()),
      ),
    ));
  }

  /// Re-reads the OS-level location state and, when it has just become usable,
  /// takes a fresh fix.
  ///
  /// The position we are holding predates the switch, so keeping it would mean
  /// reporting a distance measured from before the user turned location back
  /// on. The gate is published first either way: coming back on should not wait
  /// on a satellite fix.
  Future<void> _syncLocationGate() async {
    // `_bootstrap` owns the first fix — don't race it.
    if (_locating) return;

    final bool enabled =
        await Geolocator.isLocationServiceEnabled().catchError((_) => false);
    final LocationPermission permission = await Geolocator.checkPermission()
        .catchError((_) => LocationService.permissionState);

    LocationService.serviceEnabled = enabled;
    LocationService.permissionState = permission;

    final bool wasLive = LocationService.distanceGate.value;
    final bool usable = enabled &&
        (permission == LocationPermission.whileInUse ||
            permission == LocationPermission.always);

    if (LocationService.syncDistanceGate() && mounted) setState(() {});

    // Two reasons to go looking: the switch has just come back on, or we have
    // never had a fix at all despite the system being willing to give one.
    if (usable && (!wasLive || LocationService.lastPosition == null)) {
      final Position? position =
          await LocationService.currentPosition(ask: false);
      if (mounted) await _applyPosition(position);
      LocationService.syncDistanceGate();
      if (mounted) setState(() {});
    }
  }

  /// Why the distances are hidden right now; empty while they are shown.
  String get _locationHiddenReason {
    if (LocationService.distanceAvailable) return '';
    if (!LocationService.serviceEnabled) {
      return 'Location is off — distances are hidden';
    }
    final LocationPermission permission = LocationService.permissionState;
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return 'No location permission — distances are hidden';
    }
    return 'Waiting for a GPS fix — distances are hidden';
  }

  /// Offers the one action that actually brings the distances back.
  ///
  /// Three failure modes need three different doors — the system location
  /// panel, the app's permission page, or a fresh permission dialog — and
  /// routing them wrongly turns "Turn on" into a tap that does nothing.
  Future<void> _turnOnLocation() async {
    if (!LocationService.serviceEnabled) {
      // Nothing in-app can flip this; only the system panel can.
      await Geolocator.openLocationSettings();
      if (mounted) setState(() {});
      return;
    }

    if (LocationService.permissionState == LocationPermission.denied) {
      LocationService.permissionState = await Geolocator.requestPermission();
    } else if (LocationService.permissionState ==
        LocationPermission.deniedForever) {
      await Geolocator.openAppSettings();
      if (mounted) setState(() {});
      return;
    }

    // Permission and service are settled, so what is missing is the fix itself.
    if (!LocationService.distanceAvailable) {
      final Position? position =
          await LocationService.currentPosition(ask: false);
      if (mounted) await _applyPosition(position);
    }

    LocationService.syncDistanceGate();
    if (mounted) setState(() {});
  }

  void _subscribeToMasjids() {
    // A first launch with no network emits nothing at all: the listener never
    // fires, and both tabs would sit on their skeletons forever with no way to
    // tell "empty collection" from "unreachable backend". Give the first
    // snapshot a clock; a real one cancels it.
    _listFallback?.cancel();
    _listFallback = Timer(const Duration(seconds: 8), () {
      if (!mounted || !_listLoading) return;
      debugPrint('Firestore ▸ no snapshot in 8s — assuming offline');
      setState(() {
        _listLoading = false;
        _listError = TimeoutException(
          'No connection yet. Whatever is saved on this phone is shown below; '
          'open Noor again once you are back online.',
        );
      });
    });

    _subscription = FirebaseFirestore.instance.collection('masjids').snapshots().listen(
      (QuerySnapshot<Map<String, dynamic>> snapshot) {
        if (!mounted) return;
        _listFallback?.cancel();
        // "0 masjids" in the header is almost always an empty collection, not
        // a filter bug — make that visible in logcat before anything else.
        debugPrint('Firestore ▸ masjids fetched: ${snapshot.docs.length} '
            '(before radius filter)');
        // One malformed document must not take the list with it. `fromDoc`
        // coerces coordinates but hard-casts the rest, so a single doc where
        // `fajr` holds the number 530 instead of "5:30" threw inside this
        // callback — after the clear, before the loading flag came down — and
        // left Nearby on a skeleton list until somebody edited that doc by
        // hand. The promise at the top of this file is that one bad row is
        // skipped, not that it is fatal.
        final List<Masjid> parsed = <Masjid>[];
        int malformed = 0;
        for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in snapshot.docs) {
          try {
            parsed.add(Masjid.fromDoc(doc));
          } catch (error) {
            malformed++;
            debugPrint('Firestore ▸ skipping malformed masjid ${doc.id}: $error');
          }
        }
        setState(() {
          _all
            ..clear()
            ..addAll(parsed);
          _listLoading = false;
          _listError = null;
        });
        if (malformed > 0) {
          debugPrint('Firestore ▸ $malformed of ${snapshot.docs.length} '
              'masjid document(s) unreadable, skipped');
        }
      },
      onError: (Object error) {
        if (!mounted) return;
        _listFallback?.cancel();
        debugPrint('Firestore ▸ masjids listener error: $error');
        setState(() {
          _listLoading = false;
          _listError = error;
        });
      },
    );
  }

  /// Shows a plain-language rationale the first time we ask for GPS — without
  /// it users on MIUI tap "Deny" and every distance silently reads as Mumbai.
  /// Explains the permission once, and reports whether to go on and ask for it.
  ///
  /// Deliberately does **not** call `requestPermission()` itself: _bootstrap
  /// passes the answer straight into `currentPosition(ask:)`, so there is one
  /// system prompt rather than two back to back. Returns `false` when the user
  /// declines or when Android has the permission blocked, so nothing nags.
  Future<bool> _explainThenRequest() async {
    if (!mounted) return false;
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return false;

    try {
      final LocationPermission existing = await Geolocator.checkPermission();
      if (existing == LocationPermission.whileInUse || existing == LocationPermission.always) {
        return true;
      }
      if (existing == LocationPermission.deniedForever) {
        // Asking again does nothing — the settings snackbar is the way back in.
        return false;
      }
    } catch (_) {
      // Fall through to the dialog and let the permission layer answer.
    }

    if (!mounted) return false;

    final bool? proceed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: NoorColors.cream,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text(
          'Use your location?',
          style: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        content: Text(
          'Noor uses GPS to sort masjids by distance and show “800m away” '
          'badges and your local prayer times. '
          'Your location never leaves this device.',
          style: GoogleFonts.outfit(fontSize: 13, height: 1.55),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Not now',
                style: GoogleFonts.outfit(color: NoorColors.muted, fontWeight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Continue',
                style: GoogleFonts.outfit(color: NoorColors.emeraldDeep, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    return proceed == true;
  }

  /// Device-level flag, not an account one: this is about the phone, and it
  /// must only ever fire once.
  static const String _kAlarmPermissionsAsked = 'azaanAlarmPermissionsAsked';

  /// First open only: an exact alarm is worthless if Android can still revoke
  /// it, and Doze will happily swallow one that is not exempt from battery
  /// optimisation. One rationale, then the two system screens it unlocks.
  Future<void> _promptAlarmPermissions() async {
    if (!Platform.isAndroid) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_kAlarmPermissionsAsked) == true) return;
    } catch (_) {
      return;
    }

    if (!mounted) return;
    // The Android 13 notification prompt is already on its way from
    // _bootstrap — never stack a second dialog on top of the first.
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;

    final bool proceed = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            backgroundColor: NoorColors.cream,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
            title: Text(
              'Let the Azaan arrive on time?',
              style: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            content: Text(
              'Three system settings decide whether the Azaan actually sounds '
              'and can be stopped:\n\n'
              '• Alarms & reminders — lets Noor wake on the exact minute.\n'
              '• Battery optimisation off — stops the phone dozing through it.\n'
              '• Full-screen alerts — puts the Azaan screen over your lock '
              'screen, where the volume keys can stop it.\n\n'
              'You can change any of them later in system settings.',
              style: GoogleFonts.outfit(fontSize: 13, height: 1.6),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text('Not now',
                    style: GoogleFonts.outfit(
                        color: NoorColors.muted, fontWeight: FontWeight.w600)),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text('Continue',
                    style: GoogleFonts.outfit(
                        color: NoorColors.emeraldDeep, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ) ??
        false;

    // The question is spent the moment it has been on screen — "Not now" is
    // an answer — but a launch that dies *during* the dialog leaves the flag
    // unset, so it asks again next time rather than never asking at all.
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAlarmPermissionsAsked, true);
    } catch (_) {}

    if (!proceed || !mounted) return;

    if (!await AzaanAlarm.canScheduleExact()) {
      await AzaanAlarm.requestExactAlarm();
      // The exact-alarm screen is a full activity; let the system settle
      // before the battery prompt tries to appear over it.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
    await AzaanAlarm.requestNoBatteryOptimisation();

    // Android 14+ made the recitation screen a switch of its own. Without it
    // the Azaan still sounds — but nothing of ours is over the lock screen for
    // the volume keys to reach, which is the exact gap this flow exists to
    // close. Pre-14 the manifest declaration is enough and this reports true.
    if (!await AzaanAlarm.canUseFullScreenIntent()) {
      await AzaanAlarm.requestFullScreenIntent();
    }
  }

  Future<void> _bootstrap() async {
    unawaited(NotificationService.requestPermission());
    unawaited(_promptAlarmPermissions());

    // Settings are per account and the Azan reminders are armed further down
    // from them — wait for the profile to be on disk first, otherwise a fresh
    // account would be scheduled against the previous account's offsets.
    await AppSettings.instance.useProfile(FirebaseAuth.instance.currentUser?.uid);

    // The owner's control document, and the one moment it can still change a
    // profile: loading it brings the wallpaper, the notice and the clips in
    // line with what the panel says, and seeding must happen *while* the
    // profile still counts as one that has never stored a setting — which
    // stops being true the moment anything at all is written to it.
    await AppConfig.instance.load();
    AppConfig.instance.seedNewProfile();

    // The tasbeeh's beads and the prayer log are local and per profile —
    // they share the scope the line above has just put in place, so they
    // load here, once, before either screen that reads them can open.
    unawaited(Tasbeeh.instance.load());
    unawaited(PrayerTracker.instance.load());

    // Local cache first so favourites show instantly, then reconcile with the
    // Firestore sub-collection so they follow the user across devices.
    final List<String> cachedFavourites = await FavouriteStore.cached();
    if (mounted) {
      setState(() {
        _favourites = cachedFavourites;
        // An empty cache on a signed-in account usually means "not seen this
        // account on this phone yet" — hold the stars neutral until the cloud
        // reply instead of flashing "not a favourite" for a frame.
        _favouritesLoaded = cachedFavourites.isNotEmpty;
      });
    }
    FavouriteWatcher.watch(cachedFavourites);
    unawaited(_syncFavouritesFromCloud(cachedFavourites));
    // The starred masjids are known now (cache first, cloud may add more),
    // so arm their Jamaat-time alerts alongside the calculated reminders.
    unawaited(NotificationService.scheduleFavouriteAlerts());

    try {
      final bool explained = await _explainThenRequest();
      final Position? position =
          await LocationService.currentPosition(ask: explained);
      if (!mounted) return;

      await _applyPosition(position);
      if (mounted) _showLocationHelp(position);
    } catch (error) {
      debugPrint('Noor ▸ location failed: $error');
      if (mounted) setState(() => _locating = false);
    }

    // A profile that has never finished the setup wizard meets it once,
    // here, on top of a Home that has already seeded the owner's defaults
    // and armed the reminders — so the wizard only ever collects a *user's*
    // choices, and can re-arm from whatever they land on. Checked twice:
    // once before the frame that settles, once again right before the push,
    // so a double `useProfile` or a rapid sign-out cannot stack two.
    //
    // The re-arm rides the pop, not the wizard: every route change is
    // silent to the lifecycle observer below, and the wizard itself closes
    // synchronously — one frame, no awaits — so nothing about the schedule
    // rebuild stands between the user and Home.
    if (!AppSettings.instance.onboarded) {
      await Future<void>.delayed(Duration.zero);
      if (!mounted || AppSettings.instance.onboarded) return;
      unawaited(
        Navigator.of(context)
            .push<bool>(MaterialPageRoute<bool>(
              builder: (_) => const OnboardingScreen(),
            ))
            .then((_) {
              if (mounted) _rearmAfterWizard();
            }),
      );
    }
  }

  /// The wizard has just closed — every answer it collected moved something
  /// the schedule depends on (the city, the method, the madhab, the offsets,
  /// the master switch), and no lifecycle event fires when a *route* pops,
  /// so the re-arm has to be asked for directly rather than waited for.
  void _rearmAfterWizard() {
    final Position? position = _position ?? LocationService.lastPosition;
    unawaited(() async {
      try {
        await NotificationService.scheduleAzan(
          latitude: position?.latitude ?? LocationService.fallbackAnchor.x,
          longitude: position?.longitude ?? LocationService.fallbackAnchor.y,
        );
        await NotificationService.scheduleFavouriteAlerts();
      } catch (error) {
        debugPrint('Noor ▸ post-wizard re-arm failed: $error');
      }
    }());
    _refreshHomeWidget();
  }

  /// Everything that follows from knowing where the phone is: the nearby
  /// radius, the OpenStreetMap extras, the Azan schedule and the area name.
  ///
  /// Split out of `_bootstrap` because it runs again every time location comes
  /// back on — the second time without the permission prompt.
  Future<void> _applyPosition(Position? position) async {
    if (!mounted) return;

    debugPrint(
      position == null
          ? 'Noor ▸ GPS: no fix (${LocationService.gpsIssue})'
          : 'Noor ▸ GPS: ${position.latitude},${position.longitude}'
              '${LocationService.gpsIssue.isEmpty ? '' : ' (cached: ${LocationService.gpsIssue})'}',
    );

    setState(() {
      _position = position;
      _locating = false;
    });

    if (position != null) {
      // Free OSM nearby search — runs in the background, never blocks the UI.
      unawaited(_loadNearbyPlaces(position));
      unawaited(NotificationService.scheduleAzan(
        latitude: position.latitude,
        longitude: position.longitude,
      ));
      // The widget and the lock-screen card need only the coordinates, not
      // the resolved place name — and the name costs a network call that
      // can pend or fail. Hand the picture over now so a fresh install is
      // never blank while a reverse-geocode is in the air; the tail call
      // after `_lastReminderSyncDay` re-pushes once the name is known.
      _refreshHomeWidget();
      final String locality = await _resolveLocality(position);
      if (mounted) setState(() => _locality = locality.isEmpty ? 'Near You' : locality);
    } else {
      if (mounted) setState(() => _locality = 'Near You');
      unawaited(NotificationService.scheduleAzan(
        latitude: LocationService.fallbackAnchor.x,
        longitude: LocationService.fallbackAnchor.y,
      ));
    }

    // From here the "did the day roll over while I was away?" check on the
    // next resume has something to compare against.
    _lastReminderSyncDay = DateTime.now();

    // Coordinates settled → the home-screen widget's picture of the day is
    // now derivable, so hand it over.
    _refreshHomeWidget();
  }

  /// Says what actually went wrong with location, and offers a route back when
  /// the only remedy is a trip into system settings. Silent on a plain timeout,
  /// which a log line already covers and a banner would only add noise.
  void _showLocationHelp(Position? position) {
    if (!mounted) return;

    final bool servicesOff = LocationService.gpsIssue.contains('services are switched off');
    final bool blocked = LocationService.permissionState == LocationPermission.deniedForever;
    final bool denied = LocationService.permissionState == LocationPermission.denied;

    if (!servicesOff && !blocked && !denied) return;

    final String headline = servicesOff
        ? 'Location services are off'
        : blocked
            ? 'Location permission is blocked for Noor'
            : 'Location permission not granted';

    final String tail = position == null
        ? 'Nearby masjids and distances are using Mumbai — turn location on '
            'to see the ones around you.'
        : 'Showing your last known location — turn location on for the '
            'masjids around you.';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: Text('$headline. $tail'),
        action: SnackBarAction(
          label: 'Open',
          onPressed: () {
            if (servicesOff) {
              Geolocator.openLocationSettings();
            } else {
              Geolocator.openAppSettings();
            }
          },
        ),
      ),
    );
  }

  /// Requirement 2: after the GPS fix, ask OpenStreetMap for the masjids
  /// around the user and keep them distance-sorted. Never throws.
  Future<void> _loadNearbyPlaces(Position position) async {
    setState(() => _osmLoading = true);
    final List<MasjidSearchResult> found = await nearbyMasjids(
      lat: position.latitude,
      lon: position.longitude,
      radiusMetres: _radiusMetres,
      limit: 20,
    );
    debugPrint('OSM ▸ nearby(${position.latitude},${position.longitude}) -> '
        '${found.length} mosque(s)');
    if (!mounted) return;
    setState(() {
      _osmNearby
        ..clear()
        ..addAll(found);
      _osmLoading = false;
    });
  }

  // ------------------------------------------------------------- geo / list

  double _distanceTo(Masjid m) => LocationService.distanceTo(m.latitude, m.longitude);

  /// Firestore matches for the current query, nearest first (search section A).
  List<Masjid> get _searchMatches {
    if (_query.isEmpty) return const <Masjid>[];
    final List<String> parts =
        _query.toLowerCase().split(' ').where((String p) => p.isNotEmpty).toList();

    final List<Masjid> hits = _all.where((Masjid m) {
      final String haystack = '${m.name} ${m.address} ${m.areaLabel}'.toLowerCase();
      return parts.every((String part) => haystack.contains(part));
    }).toList();

    // Sorting by distance is only meaningful while there *is* a distance.
    // From the Mumbai fallback it would shuffle a list the user cannot explain.
    if (LocationService.distanceAvailable) {
      hits.sort((Masjid a, Masjid b) => _distanceTo(a).compareTo(_distanceTo(b)));
    }
    return hits.take(4).toList();
  }

  /// Nearby + search filtered list: within 10 km, starred first, then nearest.
  List<MapEntry<Masjid, double>> get _nearby {
    final List<String> parts =
        _query.toLowerCase().split(' ').where((String p) => p.isNotEmpty).toList();

    // Both the radius and the ordering are distance facts, so both stand down
    // when there is no honest distance to work from — see
    // `LocationService.distanceAvailable`.
    final bool live = LocationService.distanceAvailable;

    final List<MapEntry<Masjid, double>> out = <MapEntry<Masjid, double>>[];
    for (final Masjid m in _all) {
      final String haystack = '${m.name} ${m.address} ${m.areaLabel}'.toLowerCase();
      if (parts.isNotEmpty && !parts.every((String part) => haystack.contains(part))) continue;

      final double metres = _distanceTo(m);
      // Only apply the radius once we have a real fix — before that the anchor
      // is a fallback and the filter would hide everything incorrectly.
      if (live && metres > _radiusMetres) continue;

      out.add(MapEntry<Masjid, double>(m, metres));
    }
    if (live) {
      out.sort((MapEntry<Masjid, double> a, MapEntry<Masjid, double> b) =>
          a.value.compareTo(b.value));
    }
    // Distance only settles the order *within* each half — the starred half is
    // laid on top of the list by [favouritesFirst].
    return favouritesFirst(out, _favourites);
  }

  /// Every starred masjid, nearest first while there is an honest distance to
  /// measure by and otherwise in the order the collection gave us — the same
  /// order the nearby list lines them up in.
  List<Masjid> get _starred {
    if (_favourites.isEmpty) return const <Masjid>[];

    final List<Masjid> starred =
        _all.where((Masjid m) => _favourites.contains(m.id)).toList();
    if (LocationService.distanceAvailable) {
      starred.sort(
          (Masjid a, Masjid b) => _distanceTo(a).compareTo(_distanceTo(b)));
    }
    return starred;
  }

  /// The masjid whose Jamaat column the Today card quotes: the explicit pick
  /// from the card's chooser while that masjid is still starred, otherwise
  /// the starred one nearest to you.
  ///
  /// Unstarring the chosen masjid is enough to drop the card back to the
  /// automatic answer — the stored id is only ever a preference, never a
  /// promise. `null` while nothing is starred at all, in which case the card
  /// keeps showing the calculated times on their own.
  Masjid? get _favouriteBoard {
    final List<Masjid> starred = _starred;
    if (starred.isEmpty) return null;

    final String chosen = AppSettings.instance.todayBoardId;
    if (chosen.isNotEmpty) {
      for (final Masjid m in starred) {
        if (m.id == chosen) return m;
      }
    }
    return starred.first;
  }

  bool get _showDropdown =>
      _query.isNotEmpty &&
      (_searchMatches.isNotEmpty ||
          _placeResults.isNotEmpty ||
          _placesLoading ||
          _placesSearched);

  /// Total masjids within range — Firestore contributors **plus** the
  /// OpenStreetMap ones that have no times yet, so the header never reads
  /// "0 masjids" while mosques are plainly around you.
  int get _nearbyCount => _nearby.length + (_query.isEmpty ? _osmExtra.length : 0);

  Future<void> _openSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          gpsLatitude: _position?.latitude,
          gpsLongitude: _position?.longitude,
          locality: _locality,
        ),
      ),
    );
    // Settings can pin a city or flip the madhab — the Today card listens to
    // AppSettings itself, but the header area name is ours to refresh.
    if (mounted) setState(() {});
  }

  /// The About page — version, the developer's details and how to reach him.
  Future<void> _openAbout() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const AboutScreen()),
    );
  }

  /// The profile photo — the one in the top bar and the big portrait on the
  /// Profile page — is a single button: it always leads to the Profile page,
  /// exactly like the Profile tab does. Settings is reached from the Profile
  /// page's own "Prayer calculation & Azan" row, so nothing is lost.
  void _goProfile() {
    if (_tab != 3) setState(() => _tab = 3);
  }

  /// Profile → edit name and photo.
  ///
  /// The name is stored locally (per account) because Firebase's
  /// `updateDisplayName` needs a network round trip and can fail silently;
  /// the photo is kept as a local path because `photoURL` is read-only from
  /// the client. Either edit wins over the Firebase value from then on.
  Future<void> _editProfile() async {
    final User? user = FirebaseAuth.instance.currentUser;
    final AppSettings settings = AppSettings.instance;

    final TextEditingController controller = TextEditingController(
      text: settings.profileDisplayName.isNotEmpty
          ? settings.profileDisplayName
          : (user?.displayName ?? ''),
    );

    // Start from whatever is currently showing, so "remove photo" can be
    // offered even when the visible one came from Firebase.
    String? pickedPath = settings.profilePhotoPath.isNotEmpty
        ? settings.profilePhotoPath
        : null;
    bool hasNetworkPhoto =
        pickedPath == null && (user?.photoURL?.isNotEmpty ?? false);

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (BuildContext ctx, void Function(void Function()) setLocal) {
            return AlertDialog(
              backgroundColor: NoorColors.cream,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
              ),
              title: Text(
                'Edit profile',
                style: GoogleFonts.outfit(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w700,
                    color: NoorColors.ink),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    // ---- avatar preview ----
                    PerfectCircleAvatar(
                      size: 84,
                      image: pickedPath != null && pickedPath!.isNotEmpty
                          ? FileImage(File(pickedPath!))
                          : (hasNetworkPhoto
                              ? NetworkImage(user!.photoURL!)
                              : null),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        TextButton.icon(
                          onPressed: () async {
                            final XFile? file = await ImagePicker()
                                .pickImage(source: ImageSource.gallery);
                            if (file == null) return;
                            setLocal(() {
                              pickedPath = file.path;
                              hasNetworkPhoto = false;
                            });
                          },
                          icon: const Icon(Icons.photo_library_outlined,
                              size: 18, color: NoorColors.emerald),
                          label: Text(
                            'Change',
                            style: GoogleFonts.outfit(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: NoorColors.emerald),
                          ),
                        ),
                        if (pickedPath != null || hasNetworkPhoto)
                          TextButton.icon(
                            onPressed: () => setLocal(() {
                              pickedPath = null;
                              hasNetworkPhoto = false;
                            }),
                            icon: const Icon(Icons.delete_outline,
                                size: 18, color: NoorColors.danger),
                            label: Text(
                              'Remove',
                              style: GoogleFonts.outfit(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: NoorColors.danger),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // ---- name field ----
                    TextField(
                      controller: controller,
                      maxLength: 40,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(
                        counterText: '',
                        labelText: 'Display name',
                        labelStyle: GoogleFonts.outfit(
                            fontSize: 13.5, color: NoorColors.muted),
                        hintText: 'e.g. Abdul Rahman',
                        hintStyle: GoogleFonts.outfit(
                            fontSize: 13.5, color: NoorColors.muted),
                        filled: true,
                        fillColor: NoorColors.white,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 13),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide:
                              const BorderSide(color: Color(0xFFE4E9E6)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide:
                              const BorderSide(color: Color(0xFFE4E9E6)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(
                              color: NoorColors.gold, width: 1.6),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(
                    'Cancel',
                    style:
                        GoogleFonts.outfit(fontSize: 13, color: NoorColors.muted),
                  ),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: NoorColors.emerald,
                    foregroundColor: NoorColors.ink,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    final String newName = controller.text.trim();

                    // Persist locally so the Profile tab reflects the change
                    // even while Firebase is unreachable.
                    settings.setProfileName(newName);
                    settings.setProfilePhoto(pickedPath ?? '');

                    // Best-effort mirror to Firebase — a failure here must not
                    // undo what the user just typed locally.
                    unawaited(() async {
                      try {
                        if (newName.isNotEmpty) {
                          await user?.updateDisplayName(newName);
                        }
                      } catch (_) {
                        // Offline or unauthenticated — local copy stands.
                      }
                    }());

                    Navigator.of(dialogContext).pop();
                    if (mounted) setState(() {});
                  },
                  child: Text(
                    'Save',
                    style: GoogleFonts.outfit(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    // `showDialog`'s future resolves as soon as the route leaves the history,
    // but its elements stay mounted until the *next* frame finishes. The
    // keyboard sliding away re-queries MediaQuery and the still-mounted
    // TextField updates — touching the controller here would throw "A
    // TextEditingController was used after being disposed", which cascades
    // into the `_dependents.isEmpty` red screen. Same reason as
    // `showRenameDialog`.
    await WidgetsBinding.instance.endOfFrame;
    controller.dispose();
    if (mounted) setState(() {});
  }

  void _onQueryChanged(String value) {
    final String q = value.trim();
    setState(() => _query = q);

    if (q.length < 3 || !kPlacesEnabled) {
      setState(() {
        _placeResults = <MasjidSearchResult>[];
        _placesLoading = false;
        _placesSearched = false;
      });
      return;
    }

    // 500 ms debounce — Nominatim rate-limits hard, and one request per
    // keystroke gets an app flagged within minutes.
    final int token = ++_placesToken;
    setState(() => _placesLoading = true);
    Future<void>.delayed(const Duration(milliseconds: 500), () async {
      if (!mounted || token != _placesToken || _query != q) return;
      debugPrint('Searching $kProviderLabel for: $q');
      final List<MasjidSearchResult> found = await searchMasjid(
        query: q,
        lat: _position?.latitude,
        lon: _position?.longitude,
        limit: 6,
      );
      if (!mounted || token != _placesToken) return;
      debugPrint('$kProviderLabel returned ${found.length} result(s) for "$q"');
      setState(() {
        _placeResults = found;
        _placesLoading = false;
        _placesSearched = true;
      });
    });
  }

  void _clearQuery() {
    _searchController.clear();
    _placesToken++;
    setState(() {
      _query = '';
      _placeResults = <MasjidSearchResult>[];
      _placesLoading = false;
      _placesSearched = false;
    });
  }

  Future<void> _openSearchResult(MasjidSearchResult result) async {
    _clearQuery();
    FocusScope.of(context).unfocus();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PlaceDetailsScreen(result: result),
      ),
    );
  }

  Future<void> _syncFavouritesFromCloud(List<String> known) async {
    try {
      final String? uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;

      final QuerySnapshot<Map<String, dynamic>> snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('favourites')
          .get();

      final List<String> cloud =
          snap.docs.map((DocumentSnapshot<Map<String, dynamic>> d) => d.id).toList();
      final List<String> merged = <String>{...known, ...cloud}.toList();
      final bool changed = merged.length != known.length;
      if (changed) await FavouriteStore.cache(merged);

      if (!mounted) return;
      setState(() {
        _favourites = merged;
        // The cloud answered, so this really is the account's list — even when
        // it matches the cache exactly or is empty. Returning early on
        // `merged == known` used to leave the stars permanently neutral once
        // the cache was re-scoped to an account with no local history.
        _favouritesLoaded = true;
      });
      FavouriteWatcher.watch(merged);
      // The cloud may have added starred masjids the cache had never seen.
      unawaited(NotificationService.scheduleFavouriteAlerts());
    } catch (error) {
      debugPrint('Noor ▸ favourites sync failed: $error');
      // A failed network must not strand the UI waiting forever.
      if (mounted) setState(() => _favouritesLoaded = true);
    }
  }

  Future<String> _resolveLocality(Position position) async {
    try {
      final List<geocoding.Placemark> places =
          await geocoding.Geocoding().placemarkFromCoordinates(position.latitude, position.longitude);
      if (places.isEmpty) return '';
      return LocationService.localityOf(places.first);
    } catch (error) {
      // Reverse geocoding is best-effort — never let it break the header.
      debugPrint('Noor ▸ reverse geocode failed, using "Near You": $error');
      return '';
    }
  }

  Future<void> _toggleFavourite(String id) async {
    // The tap answers immediately and the write follows. `FavouriteStore`
    // commits to disk *before* it goes to Firestore, so a failure out there
    // is a sync problem, not a lost star — but it used to surface as an
    // unhandled error that left the list re-sorting under the finger while
    // the star itself stayed where it was, which reads as "the tap did
    // nothing".
    final bool nowFavourite = !_favourites.contains(id);
    if (mounted) {
      setState(() {
        _favourites = nowFavourite
            ? <String>[..._favourites, id]
            : (_favourites.toList()..remove(id));
      });
    }
    FavouriteWatcher.watch(_favourites);
    unawaited(NotificationService.scheduleFavouriteAlerts());

    try {
      await FavouriteStore.toggle(id);
    } catch (error) {
      debugPrint('Noor ▸ favourite not synced yet: $error');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          nowFavourite
              ? 'Starred on this phone — it will sync when you are back online.'
              : 'Un-starred on this phone — it will sync when you are back online.',
        ),
      ));
    }
  }

  Future<void> _runScan(ScanSource choice) async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final ScanResult? result = choice == ScanSource.manual
          ? ScanFlow.manual()
          : await ScanFlow.capture(
              source: choice == ScanSource.gallery ? ImageSource.gallery : ImageSource.camera,
            );
      if (result == null || !mounted) return;

      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => VerificationScreen(scan: result),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open ${choice.name}: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _openManualAdd() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const ManualAddScreen()),
    );
  }

  /// The one way in to add a masjid, opened by the "+" on the Nearby tab.
  ///
  /// The sheet is the same one the masjid page already uses, so "take a
  /// photo", "upload from gallery" and "enter manually" mean the same thing
  /// wherever they turn up. Manual lands on the hand-entry screen — the same
  /// door the old Home row had.
  Future<void> _openAddOptions() async {
    final ScanSource? choice = await askScanSource(context);
    if (choice == null || !mounted) return;

    if (choice == ScanSource.manual) {
      await _openManualAdd();
    } else {
      await _runScan(choice);
    }
  }

  /// The "+" itself: bottom-right of Nearby, floating over the list it feeds.
  ///
  /// Colour comes from the app's FAB theme — one gold circle, one glyph, no
  /// label. There is deliberately no counterpart on Home or Profile any more.
  Widget _addFab() => FloatingActionButton(
        tooltip: 'Add a masjid',
        onPressed: _scanning ? null : () => unawaited(_openAddOptions()),
        child: const Icon(Icons.add, size: 30),
      );

  Future<void> _signOut() async {
    FavouriteWatcher.dispose();
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
  }

  /// The picture behind every circular avatar in the app.
  ///
  /// A portrait picked in the edit dialog wins over whatever Firebase holds,
  /// because it was a deliberate choice made on this phone.
  ImageProvider? _avatarImage() {
    final String local = AppSettings.instance.profilePhotoPath;
    if (local.isNotEmpty && File(local).existsSync()) {
      return FileImage(File(local));
    }
    final String? url = FirebaseAuth.instance.currentUser?.photoURL;
    if (url != null && url.isNotEmpty) {
      return NetworkImage(url);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final ImageProvider? avatarImage = _avatarImage();

    return NoorScaffold(
      appBar: AppBar(
        titleSpacing: 16,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('Noor • Masjid Time', style: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
              _locating
                  ? '$_locality • locating…'
                  : '$_locality • $_nearbyCount masjid${_nearbyCount == 1 ? '' : 's'}',
              style: GoogleFonts.outfit(fontSize: 10.5, color: NoorColors.muted),
            ),
          ],
        ),
        // The corner photo is only shown where the Profile page is not: on
        // that tab the big portrait in the body is the photo, so a second one
        // in the top right — and the sign-out icon beside it — would be a
        // duplicate. Every other tab keeps its one photo, which leads to the
        // Profile page.
        actions: <Widget>[
          if (_tab != 3)
            IconButton(
              tooltip: 'Profile',
              padding: EdgeInsets.zero,
              onPressed: _goProfile,
              icon: PerfectCircleAvatar(
                size: 34,
                borderWidth: 1.4,
                image: avatarImage,
              ),
            ),
        ],
      ),
      body: Column(
        children: <Widget>[
          // ---------------------------------------------------------- home
          if (_tab == 0) _homeBody(),

          // -------------------------------------------------------- nearby
          if (_tab == 1) _nearbyBody(),

          // ---------------------------------------------------- favourites
          if (_tab == 2) _favouritesBody(),

          // ------------------------------------------------------- profile
          if (_tab == 3) _profileBody(),
        ],
      ),

      // Adding a masjid is the Nearby tab's job now: the "+" floats over the
      // bottom-right of the list it adds to, and nowhere else.
      floatingActionButton: _tab == 1 ? _addFab() : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,

      bottomNavigationBar: NoorBottomBar(
        index: _tab,
        onChanged: (int i) => setState(() => _tab = i),
      ),
    );
  }

  /// Tab 0 — the screen the mockup opens on: the greeting, the countdown and
  /// today's times. Adding a masjid is not this tab's job any more; the "+"
  /// on the Nearby tab owns that.
  /// The line Muslim Pro opens every home screen with: the greeting, the
  /// reader's own name, and where the times below are being calculated for.
  Widget _greetingHeader() {
    final User? user = FirebaseAuth.instance.currentUser;
    final String localName = AppSettings.instance.profileDisplayName;
    final String firebaseName = (user?.displayName ?? '').trim();
    final String name = localName.isNotEmpty
        ? localName
        : (firebaseName.isEmpty ? '' : firebaseName.split(' ').first);

    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 8),
      child: Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[NoorColors.goldSoft, NoorColors.gold],
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: NoorColors.gold.withValues(alpha: 0.4),
                  blurRadius: 14,
                ),
              ],
            ),
            child: const Icon(Icons.wb_twilight_outlined,
                size: 20, color: NoorColors.ink),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  name.isEmpty
                      ? 'Assalamu Alaikum'
                      : 'Assalamu Alaikum, $name',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.outfit(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: NoorColors.ink,
                  ),
                ),
                // The date under the greeting is the door to the Hijri
                // calendar: the app had the whole month grid built and
                // never showed it, while the onboarding page promised it.
                InkWell(
                  onTap: _openHijriCalendar,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: <Widget>[
                        const Icon(Icons.calendar_month_outlined,
                            size: 12, color: NoorColors.emeraldDeep),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            _greetingSub(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.outfit(
                              fontSize: 11,
                              color: NoorColors.muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: NoorColors.onGlassChip,
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: NoorColors.gold.withValues(alpha: 0.45)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.location_on_outlined,
                    size: 13, color: NoorColors.emeraldDeep),
                const SizedBox(width: 4),
                Text(
                  AppSettings.instance.hasCustomLocation
                      ? AppSettings.instance.customCity
                      : _locality,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.outfit(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: NoorColors.ink,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Under the greeting: what today is, in both calendars when the Hijri one
  /// is available.
  ///
  /// The conversion is [NoorHijri]'s, not a second one written here: the
  /// calendar screen and the Ramadan banner read the same table, so the
  /// date under the greeting and the date in the grid can never disagree.
  String _greetingSub() {
    final DateTime now = DateTime.now();
    String hijri = '';
    try {
      final HijriCalendar h = NoorHijri.hijriOf(
        now,
        adjustment: AppSettings.instance.hijriAdjustment,
      );
      hijri = '${h.hDay} ${h.getLongMonthName()} ${h.hYear}';
    } catch (_) {
      hijri = '';
    }
    final String greg = DateFormat('EEEE, d MMMM').format(now);
    return hijri.isEmpty ? greg : '$hijri • $greg';
  }

  /// The owner's notice, at the top of Home — one line of admin-owned text
  /// that reaches every phone holding the config.
  ///
  /// This is the difference between "Jumu'ah time has moved" needing an app
  /// update and needing nothing but a save in the panel. Empty means nothing
  /// is being said, and then nothing at all is drawn: no empty card, no
  /// reserved gap above the countdown. Dismissing hides *that* notice until
  /// the owner writes a different one, which is what makes the close button
  /// a pause rather than a mute.
  Widget _announcement() {
    final String text = AppConfig.instance.data.announcement.trim();
    if (text.isEmpty || text == _dismissedAnnouncement) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GoldCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Icon(Icons.campaign_outlined,
                size: 20, color: NoorColors.gold),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                text,
                style: GoogleFonts.outfit(
                  fontSize: 12.5,
                  color: NoorColors.onGlass,
                  height: 1.45,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close, size: 17),
              color: NoorColors.onGlassMuted,
              onPressed: () => setState(() => _dismissedAnnouncement = text),
            ),
          ],
        ),
      ),
    );
  }

  /// One tap from the hero's row: each tool opens full-screen and comes
  /// back, which is why none of them needs a tab of its own.
  void _openTool(Widget screen) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
  }

  /// The Hijri calendar: the month grid with both calendars on every cell,
  /// the occasions that fall on it, and the times of any day the reader
  /// taps — calculated for the same place the Home card uses.
  void _openHijriCalendar() {
    _openTool(HijriCalendarScreen(
      latitude:
          _position?.latitude ?? LocationService.fallbackAnchor.x,
      longitude:
          _position?.longitude ?? LocationService.fallbackAnchor.y,
    ));
  }

  Widget _homeBody() => Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 20),
          children: <Widget>[
            _greetingHeader(),

            _announcement(),

            // For the whole of Ramadan — and for no other day of the year:
            // which day of the fast it is, when Sehri ends, when the fast
            // breaks. The card draws nothing at all outside the month.
            RamadanBannerCard(
              latitude:
                  _position?.latitude ?? LocationService.fallbackAnchor.x,
              longitude:
                  _position?.longitude ?? LocationService.fallbackAnchor.y,
            ),

            NextPrayerHero(
              latitude:
                  _position?.latitude ?? LocationService.fallbackAnchor.x,
              longitude:
                  _position?.longitude ?? LocationService.fallbackAnchor.y,
              areaName: AppSettings.instance.hasCustomLocation
                  ? AppSettings.instance.customCity
                  : _locality,
              // The big countdown runs to this board's Jamaat time, the same
              // board the Today card quotes underneath it.
              board: _favouriteBoard,
              // The three doors that used to stand at the bottom of Home —
              // they move under the cards, where the eye already is.
              onOpenQibla: () => _openTool(QiblaScreen(
                latitude:
                    _position?.latitude ?? LocationService.fallbackAnchor.x,
                longitude:
                    _position?.longitude ?? LocationService.fallbackAnchor.y,
              )),
              onOpenTasbeeh: () => _openTool(const TasbeehScreen()),
              onOpenTracker: () => _openTool(const TrackerScreen()),
            ),

            // Always present — even with zero masjids in the collection.
            TodayPrayerCard(
              latitude:
                  _position?.latitude ?? LocationService.fallbackAnchor.x,
              longitude:
                  _position?.longitude ?? LocationService.fallbackAnchor.y,
              areaName: AppSettings.instance.hasCustomLocation
                  ? AppSettings.instance.customCity
                  : _locality,
              board: _favouriteBoard,
              boards: _starred,
            ),

            const SizedBox(height: 14),

            // One ayah or one hadith through this prayer's own window —
            // Arabic on top, the translation in whichever of the three the
            // reader picked, and the reference attached underneath.
            PrayerReadingCard(
              latitude:
                  _position?.latitude ?? LocationService.fallbackAnchor.x,
              longitude:
                  _position?.longitude ?? LocationService.fallbackAnchor.y,
            ),

            const SizedBox(height: 14),

            // The sun's own path across the day — sunrise to sunset, with
            // the nafl times the boards print under the five pinned on it.
            DayArcCard(
              latitude:
                  _position?.latitude ?? LocationService.fallbackAnchor.x,
              longitude:
                  _position?.longitude ?? LocationService.fallbackAnchor.y,
            ),

            // The three doors onto adding a masjid — camera, gallery, typing
            // — used to be a row here. They now live behind the "+" on the
            // Nearby tab, next to the list they actually feed, so there is
            // one place to go instead of three scattered ones.
          ],
        ),
      );

  /// Tab 1 — the search box, the dropdown it owns, and the list itself.
  Widget _nearbyBody() => Expanded(
        child: Column(
          children: <Widget>[
            // ---------------------------------------------------------- search
            Container(
              color: Colors.transparent,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: TextField(
              controller: _searchController,
              onChanged: _onQueryChanged,
              style: GoogleFonts.outfit(fontSize: 14, color: NoorColors.ink),
              decoration: InputDecoration(
                hintText: 'Search masjid, area...',
                prefixIcon: const Icon(Icons.search_outlined, color: NoorColors.muted),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close_outlined, size: 18, color: NoorColors.muted),
                        onPressed: _clearQuery,
                      ),
                filled: true,
                fillColor: NoorColors.white,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(color: NoorColors.gold, width: 1.4),
                ),
              ),
            ),
          ),

          // ------------------------------------------- two-source dropdown
          //
          // The dropdown owns the rest of the screen while it is open. Before
          // this it stacked on top of the Today card + action row and pushed
          // the Column past the viewport by a couple of pixels (and a lot more
          // once the keyboard was up).
          if (_showDropdown)
            Flexible(
              fit: FlexFit.loose,
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                constraints: const BoxConstraints(maxHeight: 300),
                decoration: BoxDecoration(
                  color: NoorGlass.of(context).fill,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: NoorColors.gold.withValues(alpha: 0.75)),
                  boxShadow: <BoxShadow>[
                    BoxShadow(color: Colors.black.withValues(alpha: 0.20), blurRadius: 20),
                  ],
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      // (a) already added to Noor
                      if (_searchMatches.isNotEmpty) ...<Widget>[
                        _dropLabel('In Noor • ${_searchMatches.length} saved nearby'),
                        for (final Masjid m in _searchMatches)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.mosque_outlined,
                                size: 18, color: NoorColors.emerald),
                            title: Text(
                              m.name.isEmpty ? 'Unnamed Masjid' : m.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.outfit(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: NoorColors.onGlass),
                            ),
                            subtitle: Text(
                              m.address.isEmpty ? m.areaLabel : m.address,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  GoogleFonts.outfit(fontSize: 11, color: NoorColors.onGlassMuted),
                            ),
                            trailing: _gpsLive
                                ? Text(
                                    formatDistance(_distanceTo(m)),
                                    style: GoogleFonts.outfit(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w600,
                                        color: NoorColors.emerald),
                                  )
                                : null,
                            onTap: () {
                              final double metres = _distanceTo(m);
                              _clearQuery();
                              FocusScope.of(context).unfocus();
                              Navigator.of(context).push<void>(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      MasjidDetailScreen(masjid: m, metres: metres),
                                ),
                              );
                            },
                          ),
                      ],

                      // (b) from the map provider (OpenStreetMap — no key needed)
                      if (kPlacesEnabled &&
                          (_placesLoading ||
                              _placeResults.isNotEmpty ||
                              _placesSearched)) ...<Widget>[
                        if (_searchMatches.isNotEmpty)
                          Divider(height: 1, color: NoorColors.gold.withValues(alpha: 0.3)),
                        _dropLabel('From $kProviderLabel • not in Noor yet'),
                        if (_placesLoading)
                          const Padding(
                            padding: EdgeInsets.all(14),
                            child: Center(
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: NoorColors.emerald),
                              ),
                            ),
                          )
                        else if (_placeResults.isEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                            child: Row(
                              children: <Widget>[
                                const Icon(Icons.location_off_outlined,
                                    size: 18, color: NoorColors.onGlassMuted),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        'No mosques found for “$_query”',
                                        style: GoogleFonts.outfit(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w600,
                                            color: NoorColors.onGlass),
                                      ),
                                      Text(
                                        'Add it yourself and the next person searching will find it.',
                                        style: GoogleFonts.outfit(
                                            fontSize: 11, color: NoorColors.onGlassMuted, height: 1.45),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                TextButton(
                                  onPressed: () {
                                    _clearQuery();
                                    FocusScope.of(context).unfocus();
                                    _openManualAdd();
                                  },
                                  child: Text('Add manually',
                                      style: GoogleFonts.outfit(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                          color: NoorColors.emerald)),
                                ),
                              ],
                            ),
                          )
                        else
                          for (final MasjidSearchResult s in _placeResults)
                            ListTile(
                              dense: true,
                              leading: const Icon(Icons.search_outlined,
                                  size: 18, color: NoorColors.gold),
                              title: Text(
                                s.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.outfit(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: NoorColors.onGlass),
                              ),
                              subtitle: Text(
                                s.address,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.outfit(
                                    fontSize: 11, color: NoorColors.onGlassMuted),
                              ),
                              trailing: s.distanceMetres == null || !_gpsLive
                                  ? null
                                  : Text(
                                      formatDistance(s.distanceMetres!),
                                      style: GoogleFonts.outfit(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w600,
                                          color: NoorColors.gold),
                                    ),
                              onTap: () => _openSearchResult(s),
                            ),
                      ],
                    ],
                  ),
                ),
              ),
            )
          else
            // ------------------------------------------------------ masjid list
            Expanded(
              child: _buildNearbyList(),
            ),
          ],
        ),
      );

  /// Tab 2 — every masjid this account has starred, nearest first.
  ///
  /// Unstarring the last one empties the tab, so the card list and the count
  /// in the header are read from the same place the nearby list reads them.
  Widget _favouritesBody() {
    if (_listLoading) return Expanded(child: const _SkeletonList());

    if (_listError != null) {
      return Expanded(
        child: _MessageState(
          icon: Icons.cloud_off_outlined,
          title: 'Could not load masjids',
          subtitle: '$_listError',
        ),
      );
    }

    final List<Masjid> starred = _starred;
    if (starred.isEmpty) {
      return Expanded(
        child: _MessageState(
          icon: Icons.favorite_border_outlined,
          title: 'No favourites yet',
          subtitle: 'Tap the heart on any card under Nearby — the masjids you '
              'star wait for you here, nearest first.',
        ),
      );
    }

    return Expanded(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: <Widget>[
          SectionHeader(
            title: 'Favourites',
            action: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: NoorColors.onGlassChip,
                borderRadius: BorderRadius.circular(30),
                border:
                    Border.all(color: NoorColors.gold.withValues(alpha: 0.6)),
              ),
              child: Text(
                _gpsLive
                    ? '${starred.length} starred • nearest first'
                    : '${starred.length} starred',
                style: GoogleFonts.outfit(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: NoorColors.onGlassGold),
              ),
            ),
          ),
          for (final Masjid m in starred)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: MasjidCard(
                masjid: m,
                metres: _distanceTo(m),
                isFavourite: true,
                favouritesLoaded: _favouritesLoaded,
                onFavourite: () => _toggleFavourite(m.id),
              ),
            ),
        ],
      ),
    );
  }

  /// Tab 3 — who is signed in, and the doors out of the app.
  Widget _profileBody() {
    final User? user = FirebaseAuth.instance.currentUser;
    final AppSettings settings = AppSettings.instance;

    // The user's own edits win over whatever Firebase holds — a locally
    // picked portrait or typed name is a deliberate choice, the network
    // values are only defaults.
    final String localName = settings.profileDisplayName;

    final String firebaseName = (user?.displayName ?? '').trim();
    final String name = localName.isNotEmpty
        ? localName
        : (firebaseName.isEmpty ? 'Noor user' : firebaseName);
    final String email = (user?.email ?? '').trim();

    return Expanded(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 26),
        children: <Widget>[
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    // The portrait itself is a button too — it lands on the
                    // Profile page, the same destination as the top-bar photo.
                    Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _goProfile,
                        child: PerfectCircleAvatar(
                          size: 88,
                          image: _avatarImage(),
                          shadow: <BoxShadow>[
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.28),
                              blurRadius: 18,
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Pencil badge — the tap target for editing name/photo.
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Material(
                        color: NoorColors.gold,
                        shape: const CircleBorder(),
                        elevation: 3,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: _editProfile,
                          child: const Padding(
                            padding: EdgeInsets.all(7),
                            child: Icon(Icons.edit_outlined,
                                size: 15, color: NoorColors.ink),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.outfit(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: NoorColors.ink),
                ),
                if (email.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    email,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.outfit(
                        fontSize: 11.5,
                        color: NoorColors.muted),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 18),

          GlassPanel(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Column(
              children: <Widget>[
                _ProfileRow(
                  icon: Icons.manage_accounts_outlined,
                  title: 'Edit profile',
                  subtitle: 'Change your name and photo',
                  onTap: _editProfile,
                ),
                Divider(height: 1, color: NoorColors.gold.withValues(alpha: 0.25)),
                _ProfileRow(
                  icon: Icons.calculate_outlined,
                  title: 'Prayer calculation & Azan',
                  subtitle: 'Method, madhab, time format, which Azaan plays',
                  onTap: _openSettings,
                ),
                // Adding a masjid used to be offered here too — "Scan a
                // prayer board" and "Add a masjid by hand". Both moved to the
                // "+" on the Nearby tab, so the profile is only about the
                // reader again.
                Divider(height: 1, color: NoorColors.gold.withValues(alpha: 0.25)),
                _ProfileRow(
                  icon: Icons.calendar_month_outlined,
                  title: 'Hijri calendar',
                  subtitle: 'The month grid, the occasions and each day\'s times',
                  onTap: _openHijriCalendar,
                ),
                Divider(height: 1, color: NoorColors.gold.withValues(alpha: 0.25)),
                _ProfileRow(
                  icon: Icons.info_outline,
                  title: 'About Noor',
                  subtitle: 'Version, developer & how to get help',
                  onTap: _openAbout,
                ),
                Divider(height: 1, color: NoorColors.gold.withValues(alpha: 0.25)),
                _ProfileRow(
                  icon: Icons.logout_outlined,
                  title: 'Sign out',
                  subtitle: 'Favourites and settings stay on this profile',
                  danger: true,
                  onTap: _signOut,
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),
          Center(
            child: Text(
              'Noor • Masjid Time',
              style: GoogleFonts.outfit(
                  fontSize: 11,
                  color: NoorColors.muted),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ list states

  Widget _dropLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(
          text.toUpperCase(),
          style: GoogleFonts.outfit(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: NoorColors.muted,
          ),
        ),
      );

  /// Mosques OpenStreetMap found nearby that are NOT already in the shared
  /// Firestore list (anything within 60 m is the same building).
  List<MasjidSearchResult> get _osmExtra {
    final List<MasjidSearchResult> out = <MasjidSearchResult>[];
    for (final MasjidSearchResult r in _osmNearby) {
      if (r.distanceMetres != null && r.distanceMetres! > _radiusMetres) continue;

      bool duplicate = false;
      for (final Masjid m in _all) {
        final double gap = Geolocator.distanceBetween(
            r.latitude, r.longitude, m.latitude, m.longitude);
        if (gap < 60) {
          duplicate = true;
          break;
        }
      }
      if (!duplicate) out.add(r);
    }
    return out;
  }

  Widget _buildNearbyList() {
    // Shimmer while we are still getting a fix — never flash an empty state.
    if (_locating) return const _SkeletonList();

    final Widget body = _nearbyListBody();

    // Distances only exist while the OS location switch is on. Say so rather
    // than dropping them silently, and keep the way back within reach.
    final String hidden = _locationHiddenReason;
    if (hidden.isEmpty) return body;

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: LocationOffBanner(reason: hidden, onTurnOn: _turnOnLocation),
        ),
        Expanded(child: body),
      ],
    );
  }

  Widget _nearbyListBody() {
    if (_listError != null) {
      return _MessageState(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load masjids',
        subtitle: '$_listError',
      );
    }

    if (_listLoading) return const _SkeletonList();

    final List<MapEntry<Masjid, double>> sorted = _nearby;
    final bool showMapSection = _query.isEmpty;
    final List<MasjidSearchResult> extra = showMapSection ? _osmExtra : const <MasjidSearchResult>[];
    final bool mapPending = showMapSection && _osmLoading;

    if (sorted.isEmpty && extra.isEmpty && !mapPending) {
      final String addHint = 'Tap the + button to add one — the search box '
          'also looks up mosques on $kProviderLabel.';
      return _MessageState(
        icon: _query.isEmpty ? Icons.mosque_outlined : Icons.search_off_outlined,
        title: _query.isEmpty
            ? (_gpsLive ? 'No masjids in range' : 'No masjids yet')
            : 'No match found',
        subtitle: _query.isEmpty
            ? (_gpsLive
                ? 'Nothing within ${formatDistance(_radiusMetres)} of you yet. '
                    '$addHint'
                : 'No masjids have been added yet. $addHint')
            : 'Try another masjid or area name, or clear the search.',
      );
    }

    final String updatedLabel = sorted.isEmpty
        ? ''
        : timeAgo(
            sorted.map((MapEntry<Masjid, double> e) => e.key.lastUpdated).reduce(
                (Timestamp a, Timestamp b) => a.millisecondsSinceEpoch >
                        b.millisecondsSinceEpoch
                    ? a
                    : b),
          );

    return ListView(
      // Room at the bottom for the "+" — the last card must not hide under it.
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 84),
      children: <Widget>[
        if (sorted.isNotEmpty) ...<Widget>[
          SectionHeader(
            title: 'Nearby Masjids',
            action: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: NoorColors.onGlassChip,
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: NoorColors.gold.withValues(alpha: 0.6)),
              ),
              child: Text(
                _gpsLive
                    ? '${sorted.length} Nearby • $updatedLabel'
                    : '${sorted.length} masjid${sorted.length == 1 ? '' : 's'}'
                        ' • $updatedLabel',
                style: GoogleFonts.outfit(
                    fontSize: 10.5, fontWeight: FontWeight.w600, color: NoorColors.emerald),
              ),
            ),
          ),
          for (final MapEntry<Masjid, double> entry in sorted)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: MasjidCard(
                masjid: entry.key,
                metres: entry.value,
                isFavourite: _favourites.contains(entry.key.id),
                favouritesLoaded: _favouritesLoaded,
                onFavourite: () => _toggleFavourite(entry.key.id),
              ),
            ),
        ],

        // --- OpenStreetMap: real mosques around you with no times yet -------
        if (showMapSection) ...<Widget>[
          if (mapPending)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: NoorColors.gold),
                ),
              ),
            )
          else if (extra.isNotEmpty) ...<Widget>[
            SectionHeader(
              title: 'More on the map',
              action: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: NoorColors.onGlassChip,
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: NoorColors.gold.withValues(alpha: 0.6)),
                ),
                child: Text(
                  '${extra.length} • $kProviderLabel',
                  style: GoogleFonts.outfit(
                      fontSize: 10.5, fontWeight: FontWeight.w600, color: NoorColors.emeraldDeep),
                ),
              ),
            ),
            for (final MasjidSearchResult r in extra)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _MapResultCard(result: r, onTap: () => _openSearchResult(r)),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 6),
              child: Text(
                _gpsLive
                    ? 'Distances from your location • $kProviderLabel • '
                        'tap a masjid to contribute its Jamaat times.'
                    : 'From $kProviderLabel • tap a masjid to contribute its '
                        'Jamaat times.',
                style: GoogleFonts.outfit(
                  fontSize: 11,
                  color: NoorColors.muted,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }
}

/// Explains a distance figure that has just disappeared, and offers the one
/// action that brings it back.
///
/// Without this the change reads as a bug: the cards silently lose their chips
/// and nothing says why, or that flipping location back on fixes it.
class LocationOffBanner extends StatelessWidget {
  const LocationOffBanner({super.key, required this.reason, required this.onTurnOn});

  /// Already a complete sentence — `Location is off — distances are hidden`.
  final String reason;
  final VoidCallback onTurnOn;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: NoorGlass.of(context).fill,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NoorColors.gold.withValues(alpha: 0.7)),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: NoorColors.emerald.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child:
                const Icon(Icons.location_off_outlined, size: 16, color: NoorColors.emerald),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              reason,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.outfit(
                  fontSize: 11.5, color: NoorColors.onGlass, height: 1.35),
            ),
          ),
          const SizedBox(width: 6),
          TextButton(
            onPressed: onTurnOn,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              'Turn on',
              style: GoogleFonts.outfit(
                  fontSize: 12, fontWeight: FontWeight.w700, color: NoorColors.emerald),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({required this.icon, required this.title, required this.subtitle});

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    // The long "Nothing within 10 km of you yet…" copy used to push this
    // Column past its slot (1.4 px on a small phone) — scrolling costs
    // nothing when the content already fits.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: NoorColors.onGlassChip,
                shape: BoxShape.circle,
                border: Border.all(color: NoorColors.gold.withValues(alpha: 0.6)),
              ),
              child: Icon(icon, size: 36, color: NoorColors.gold),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: GoogleFonts.outfit(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: NoorColors.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: GoogleFonts.outfit(
                fontSize: 13,
                color: NoorColors.muted,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
//  MASJID CARD
// ===========================================================================

class MasjidCard extends StatelessWidget {
  const MasjidCard({
    super.key,
    required this.masjid,
    required this.metres,
    required this.isFavourite,
    required this.onFavourite,
    this.favouritesLoaded = true,
  });

  final Masjid masjid;
  final double metres;
  final bool isFavourite;
  final bool favouritesLoaded;
  final VoidCallback onFavourite;

  void _openDetail(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MasjidDetailScreen(masjid: masjid, metres: metres),
      ),
    );
  }

  void _openProof(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => PhotoProofViewer(masjid: masjid),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GoldCard(
      onTap: () => _openDetail(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const MasjidLogo(),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      masjid.name.isEmpty ? 'Unnamed Masjid' : masjid.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: NoorColors.onGlass,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      masjid.address.isEmpty ? 'Address not available yet' : masjid.address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(fontSize: 11, color: NoorColors.onGlassMuted),
                    ),
                  ],
                ),
              ),
              if (LocationService.distanceAvailable) ...<Widget>[
                const SizedBox(width: 8),
                DistanceBadge(metres: metres),
              ],
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              for (final PrayerInfo prayer in kPrayers.take(5))
                Expanded(child: _TimeChip(prayer: prayer, time: masjid.timeFor(prayer.key))),
            ],
          ),
          const SizedBox(height: 12),
          Container(height: 1, color: NoorColors.gold.withValues(alpha: 0.3)),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              GestureDetector(
                onTap: masjid.hasProof ? () => _openProof(context) : null,
                child: ProofThumbnail(masjid: masjid, size: 40),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Last updated ${timeAgo(masjid.lastUpdated)}',
                      style: GoogleFonts.outfit(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: NoorColors.emeraldDeep,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      masjid.hasProof ? 'Tap photo for proof' : 'No photo proof yet',
                      style: GoogleFonts.outfit(fontSize: 10, color: NoorColors.onGlassMuted),
                    ),
                  ],
                ),
              ),
              // No name or pin editing here: a list card is for reading and
              // starring. Both corrections live one level down, inside
              // `MasjidDetailScreen`'s meta card, reached by tapping the card.
              IconButton(
                tooltip: isFavourite ? 'Remove favourite' : 'Add favourite',
                onPressed: onFavourite,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  transitionBuilder: (Widget child, Animation<double> animation) =>
                      ScaleTransition(scale: animation, child: child),
                  child: Icon(
                    isFavourite ? Icons.favorite_outlined : Icons.favorite_border,
                    key: ValueKey<bool>(isFavourite),
                    size: 24,
                    color: isFavourite ? const Color(0xFFE0574F) : NoorColors.gold,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One prayer on a nearby card: icon, name, and the board's own time.
///
/// [time] arrives exactly as Firestore stored it (`17:45`); the chip, not the
/// card, decides how that reads on screen — see `AppSettings.formatClockShort`.
class _TimeChip extends StatelessWidget {
  const _TimeChip({required this.prayer, required this.time});

  final PrayerInfo prayer;
  final String time;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 3),
      decoration: BoxDecoration(
        color: NoorColors.onGlassChip,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: NoorColors.gold.withValues(alpha: 0.35)),
      ),
      child: Column(
        children: <Widget>[
          Icon(prayer.icon, size: 14, color: NoorColors.onGlassGold),
          const SizedBox(height: 4),
          Text(
            prayer.label,
            style: GoogleFonts.outfit(fontSize: 8.5, color: NoorColors.onGlassMuted),
          ),
          const SizedBox(height: 1),
          Text(
            AppSettings.instance.formatClockShort(time),
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: GoogleFonts.outfit(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: NoorColors.onGlass,
            ),
          ),
        ],
      ),
    );
  }
}

class ProofThumbnail extends StatelessWidget {
  const ProofThumbnail({super.key, required this.masjid, this.size = 40});

  final Masjid masjid;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NoorColors.gold, width: 1.2),
        color: NoorColors.onGlassChip,
      ),
      child: buildProofImage(masjid, fit: BoxFit.cover),
    );
  }
}

Widget buildProofImage(Masjid masjid, {BoxFit fit = BoxFit.cover}) {
  final String encoded = masjid.photoProofBase64;
  if (encoded.isNotEmpty) {
    try {
      final Uint8List bytes = base64Decode(encoded);
      return Image.memory(bytes, fit: fit, gaplessPlayback: true);
    } catch (_) {
      // fall through to the local file
    }
  }

  final String path = masjid.photoProofPath;
  if (path.isNotEmpty) {
    try {
      final File file = File(path);
      if (file.existsSync()) return Image.file(file, fit: fit);
    } catch (_) {}
  }

  return const Center(
    child: Icon(Icons.image_outlined, size: 20, color: NoorColors.onGlassMuted),
  );
}

class PhotoProofViewer extends StatelessWidget {
  const PhotoProofViewer({super.key, required this.masjid});

  final Masjid masjid;

  @override
  Widget build(BuildContext context) {
    return NoorScaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_outlined, color: NoorColors.ink, size: 30),
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: InteractiveViewer(
                  maxScale: 5,
                  child: buildProofImage(masjid, fit: BoxFit.contain),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: <Widget>[
                  Text(
                    masjid.name,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.outfit(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: NoorColors.ink,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Photo proof • updated ${timeAgo(masjid.lastUpdated)}'
                    '${masjid.updatedBy.isEmpty ? '' : ' by ${masjid.updatedBy}'}',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.outfit(fontSize: 12, color: NoorColors.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
//  VERIFICATION (after OCR)
// ===========================================================================

class VerificationScreen extends StatefulWidget {
  const VerificationScreen({super.key, required this.scan, this.existing});

  final ScanResult scan;
  final Masjid? existing;

  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _controllers;
  late final TextEditingController _nameController;
  late final List<FocusNode> _focusNodes;

  bool _saving = false;
  bool _rescanning = false;
  bool _nameRequired = false;
  String? _photoPath;

  /// Which reader produced the times below, and (when it was not the AI) why.
  bool _aiRead = false;
  String? _aiNote;

  @override
  void initState() {
    super.initState();

    final OcrResult ocr = widget.scan.ocr;
    // '' means "manual entry, no photo" — show the placeholder, not Image.file('').
    _photoPath = widget.scan.photoPath.isEmpty ? null : widget.scan.photoPath;
    _nameRequired = !ocr.nameFound && widget.existing == null;
    _aiRead = ocr.aiRead;
    _aiNote = GeminiOcrService.lastFailureReason;

    _controllers = <String, TextEditingController>{
      for (final PrayerInfo prayer in kPrayers)
        prayer.key: TextEditingController(text: ocr.timeOr(prayer.key, widget.existing?.timeFor(prayer.key) ?? '')),
    };
    _focusNodes = List<FocusNode>.generate(kPrayers.length, (_) => FocusNode());

    final String initialName = widget.existing?.name.isNotEmpty == true
        ? widget.existing!.name
        : (ocr.masjidName ?? '');
    _nameController = TextEditingController(text: initialName);
  }

  @override
  void dispose() {
    for (final TextEditingController c in _controllers.values) {
      c.dispose();
    }
    for (final FocusNode node in _focusNodes) {
      node.dispose();
    }
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _scanAgain() async {
    if (_rescanning) return;

    // Manual is already what this screen is for, so only offer photo sources.
    final ScanSource? choice = await askScanSource(context, allowManual: false);
    if (choice == null || choice == ScanSource.manual || !mounted) return;

    setState(() => _rescanning = true);
    try {
      final ScanResult? result = await ScanFlow.capture(
        source: choice == ScanSource.gallery ? ImageSource.gallery : ImageSource.camera,
      );
      if (result == null || !mounted) return;
      await Navigator.of(context).pushReplacement<void, void>(
        MaterialPageRoute<void>(
          builder: (_) => VerificationScreen(scan: result, existing: widget.existing),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Scan failed: $error')));
      }
    } finally {
      if (mounted) setState(() => _rescanning = false);
    }
  }

  /// Second attempt at the AI on the photo already taken.
  ///
  /// This exists because the cloud read fails for reasons the user cannot
  /// influence — Google answers 503 under load, or a slow connection outruns
  /// the deadline — and the fallback that used to happen silently is exactly
  /// what made the feature look unreliable. Retrying here is the difference
  /// between "the AI is broken" and "the AI needed one more try".
  Future<void> _retryAi() async {
    if (_rescanning || _photoPath == null) return;

    setState(() => _rescanning = true);
    try {
      final Uint8List bytes = await File(_photoPath!).readAsBytes();
      final GeminiOcrResult? gem = await GeminiOcrService.extractJamaatTimes(bytes);

      if (gem == null || gem.times.length < 3) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'AI still could not read it: '
                '${GeminiOcrService.lastFailureReason ?? 'no usable times found'}',
              ),
            ),
          );
        }
        return;
      }

      if (!mounted) return;
      setState(() {
        for (final MapEntry<String, String> entry in gem.times.entries) {
          final TextEditingController? controller = _controllers[entry.key];
          if (controller != null) controller.text = entry.value;
        }
        // Only fill the name if the field is still blank — the user may have
        // typed one already, and their spelling wins.
        final String? name = gem.masjidName;
        if (name != null && name.trim().isNotEmpty && _nameController.text.trim().isEmpty) {
          _nameController.text = name;
          _nameRequired = false;
        }
        _aiRead = true;
        _aiNote = null;
      });
      debugPrint('Noor ▸ AI retry filled ${gem.times.length} time(s)');
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('AI retry failed: $error')));
      }
    } finally {
      if (mounted) setState(() => _rescanning = false);
    }
  }

  /// Says which reader produced the times below.
  ///
  /// Without it a cloud failure is indistinguishable from the AI reading the
  /// board wrong: the values are simply different and nothing explains why.
  /// This is the card that turns "kabhi kabhi gadbad" into something the user
  /// can act on — read it carefully, or press retry.
  Widget _aiStatusCard() {
    if (_photoPath == null) return const SizedBox.shrink();

    if (_aiRead) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: GoldCard(
          padding: const EdgeInsets.all(13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(Icons.auto_awesome, size: 18, color: NoorColors.onGlassGold),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'AI read the Jamaat times from this photo',
                      style: GoogleFonts.outfit(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: NoorColors.onGlass,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Gemini chose the Jamaat column, not the Start / Azan one.',
                      style: GoogleFonts.outfit(
                        fontSize: 10.5,
                        height: 1.4,
                        color: NoorColors.onGlassMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: NoorColors.goldSoft,
          borderRadius: BorderRadius.circular(NoorGlass.radius),
          border: Border.all(color: NoorColors.danger.withValues(alpha: 0.45)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Icon(Icons.error_outline, size: 18, color: NoorColors.danger),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'AI did not read this photo',
                    style: GoogleFonts.outfit(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: NoorColors.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _aiNote == null
                        ? 'The times below came from the on-device reader — '
                            'check every one of them before saving.'
                        : '$_aiNote. The times below came from the on-device '
                            'reader, so check every one before saving.',
                    style: GoogleFonts.outfit(
                      fontSize: 10.5,
                      height: 1.4,
                      color: NoorColors.ink.withValues(alpha: 0.72),
                    ),
                  ),
                  const SizedBox(height: 9),
                  OutlinedButton.icon(
                    onPressed: _rescanning ? null : _retryAi,
                    icon: _rescanning
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome_outlined, size: 15),
                    label: Text(_rescanning ? 'Asking AI…' : 'Try AI again'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: NoorColors.ink,
                      side: BorderSide(color: NoorColors.ink.withValues(alpha: 0.35)),
                      visualDensity: VisualDensity.compact,
                      textStyle: GoogleFonts.outfit(fontSize: 11.5, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? _validateTime(String? value) {
    final String raw = (value ?? '').trim();
    final RegExpMatch? match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(raw);
    if (match == null) return 'Format: HH:MM (24h)';
    final int hour = int.parse(match.group(1)!);
    final int minute = int.parse(match.group(2)!);
    if (hour > 23 || minute > 59) return 'Invalid time';
    return null;
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final String name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _nameRequired = true);
      _formKey.currentState?.validate();
      return;
    }

    setState(() => _saving = true);

    try {
      double latitude = widget.existing?.latitude ?? 0;
      double longitude = widget.existing?.longitude ?? 0;
      String address = widget.existing?.address ?? '';

      final Position? position = await LocationService.currentPosition();
      if (position != null) {
        latitude = position.latitude;
        longitude = position.longitude;
      }

      if (latitude == 0 && longitude == 0) {
        // Without a fix we still allow saving — but keep the coordinates empty.
        latitude = LocationService.fallbackAnchor.x;
        longitude = LocationService.fallbackAnchor.y;
      }

      final String resolvedAddress = await LocationService.reverseGeocode(latitude, longitude);
      if (resolvedAddress.isNotEmpty) address = resolvedAddress;

      String photoPath = _photoPath ?? '';
      String photoBase64 = '';
      if (photoPath.isNotEmpty) {
        try {
          final Uint8List bytes = await File(photoPath).readAsBytes();
          if (bytes.lengthInBytes <= 450000) photoBase64 = base64Encode(bytes);
        } catch (error) {
          debugPrint('Noor ▸ could not encode proof: $error');
        }
      }

      // De-duplicate: same (normalised) name within 200 m updates that document.
      String? targetId = widget.existing?.id;
      if (targetId == null) {
        final QuerySnapshot<Map<String, dynamic>> existing =
            await FirebaseFirestore.instance.collection('masjids').get();
        for (final DocumentSnapshot<Map<String, dynamic>> doc in existing.docs) {
          final Masjid other = Masjid.fromDoc(doc);
          if (normaliseName(other.name) != normaliseName(name)) continue;
          final double distance = Geolocator.distanceBetween(
            latitude,
            longitude,
            other.latitude,
            other.longitude,
          );
          if (distance <= 200) {
            targetId = doc.id;
            break;
          }
        }
      }

      final User? user = FirebaseAuth.instance.currentUser;
      final Map<String, dynamic> payload = <String, dynamic>{
        'masjidName': name,
        'fajr': _controllers['fajr']!.text.trim(),
        'dhuhr': _controllers['dhuhr']!.text.trim(),
        'asr': _controllers['asr']!.text.trim(),
        'maghrib': _controllers['maghrib']!.text.trim(),
        'isha': _controllers['isha']!.text.trim(),
        'juma': _controllers['juma']!.text.trim(),
        'latitude': latitude,
        'longitude': longitude,
        'address': address,
        'photoProofPath': photoPath,
        'photoProofBase64': photoBase64,
        'lastUpdated': Timestamp.now(),
        'updatedBy': user?.displayName ?? user?.email ?? 'Anonymous',
        'updatedByUid': user?.uid ?? '',
        'updateCount': FieldValue.increment(1),
      };

      final CollectionReference<Map<String, dynamic>> collection =
          FirebaseFirestore.instance.collection('masjids');

      if (targetId != null) {
        await collection.doc(targetId).set(payload, SetOptions(merge: true));
      } else {
        // Recorded on create only — an update must never re-attribute the
        // document, or whoever edits it next would inherit the delete button.
        payload['createdByUid'] = user?.uid ?? '';
        payload['createdAt'] = FieldValue.serverTimestamp();
        await collection.add(payload);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            targetId != null
                ? '$name updated for everyone nearby ✅'
                : '$name added for everyone nearby ✅',
          ),
        ),
      );
      Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final int found =
        kPrayers.where((PrayerInfo p) => (_controllers[p.key]?.text ?? '').isNotEmpty).length;

    return NoorScaffold(
      appBar: AppBar(
        title: const Text('Verify scanned times'),
        actions: <Widget>[
          Container(
            margin: const EdgeInsets.only(right: 16, top: 12, bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: NoorColors.onGlassChip,
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: NoorColors.gold.withValues(alpha: 0.7)),
            ),
            child: Text(
              '$found/${kPrayers.length} read',
              style: GoogleFonts.outfit(fontSize: 11, fontWeight: FontWeight.w600, color: NoorColors.ink),
            ),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: <Widget>[
            // ------------------------------------------------ scanned photo
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SizedBox(
                    width: 108,
                    height: 108,
                    child: _photoPath == null
                        ? Container(
                            color: NoorColors.onGlassChip,
                            child: const Icon(Icons.image_outlined, color: NoorColors.onGlassMuted),
                          )
                        : Image.file(File(_photoPath!), fit: BoxFit.cover),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _photoPath == null
                            ? 'No photo — times entered by hand'
                            : 'Photo of the masjid board',
                        style: GoogleFonts.outfit(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: NoorColors.ink,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _photoPath == null
                            ? 'Enter each prayer time below. Nothing was read '
                                'automatically, so please type them exactly as '
                                'shown at the masjid.'
                            : 'On-device OCR read $found of ${kPrayers.length} prayers. '
                                'Please check each time against the board before saving.',
                        style: GoogleFonts.outfit(
                          fontSize: 11.5,
                          color: NoorColors.muted,
                          height: 1.55,
                        ),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _rescanning ? null : _scanAgain,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: NoorColors.ink,
                          side: const BorderSide(color: Color(0x333A2E22), width: 1.3),
                          visualDensity: VisualDensity.compact,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        icon: _rescanning
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: NoorColors.emeraldDeep),
                              )
                            : Icon(
                                _photoPath == null
                                    ? Icons.add_a_photo_outlined
                                    : Icons.photo_camera_outlined,
                                size: 16,
                              ),
                        label: Text(
                          _rescanning
                              ? 'Opening…'
                              : (_photoPath == null ? 'Add a photo' : 'Change photo'),
                          style: GoogleFonts.outfit(fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // ------------------------------------------------ masjid name
            TextFormField(
              controller: _nameController,
              textCapitalization: TextCapitalization.words,
              validator: (String? value) {
                if (!_nameRequired) return null;
                if (value == null || value.trim().isEmpty) {
                  return 'Masjid ka naam kya hai? e.g. Masjid Al-Falah';
                }
                return null;
              },
              decoration: InputDecoration(
                labelText: 'Masjid ka naam kya hai? e.g. Masjid Al-Falah',
                // This field is filled white by the theme, so the light accent
                // glyphs would vanish against it — the deepened shade shows.
                prefixIcon: const Icon(Icons.mosque_outlined, color: NoorColors.emeraldDeep),
                suffixIcon: const Icon(Icons.edit_outlined, size: 18, color: NoorColors.emeraldDeep),
              ),
            ),
            if (!_nameRequired) ...<Widget>[
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  const Icon(Icons.verified_outlined, size: 14, color: NoorColors.onGlassGold),
                  const SizedBox(width: 6),
                  Text(
                    'Name detected from the photo — you can still edit it.',
                    style: GoogleFonts.outfit(
                      fontSize: 11,
                      color: NoorColors.muted,
                    ),
                  ),
                ],
              ),
            ],

            // ---------------------------------- OCR outcome + raw text panel
            if (widget.scan.ocr.timesMissing && _photoPath != null) ...<Widget>[
              const SizedBox(height: 14),
              _OcrNotice(
                icon: Icons.error_outline,
                color: NoorColors.danger,
                title: 'Could not extract times, please enter manually',
                body: 'No prayer time was recognised, so every field below is '
                    'blank — please enter them manually. For a clearer read, '
                    'move closer to the board, avoid glare, and keep the camera '
                    'straight. Urdu/Hindi-only boards cannot be read in Latin '
                    'script.',
              ),
            ] else if (widget.scan.ocr.outOfOrder && _photoPath != null) ...<Widget>[
              const SizedBox(height: 14),
              _OcrNotice(
                icon: Icons.swap_vert_outlined,
                color: NoorColors.danger,
                title: 'Some times came back out of order',
                body: 'Prayer times must rise through the day, so at least one '
                    'field is earlier than the one before it — usually a label '
                    'read as the wrong clock. Compare every value against the '
                    'board before saving.',
              ),
            ] else if (widget.scan.ocr.lowConfidence && _photoPath != null) ...<Widget>[
              const SizedBox(height: 14),
              _OcrNotice(
                icon: Icons.lightbulb_outline,
                color: NoorColors.gold,
                title: 'Times read by position, not by label',
                body: 'The prayer names on this board were not readable, so the '
                    'five readings were assigned in the standard order '
                    '(Fajr, Dhuhr, Asr, Maghrib, Isha). Please check each one.',
              ),
            ],

            if (widget.scan.ocr.rawText.trim().isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: NoorColors.onGlassChip,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: NoorColors.gold.withValues(alpha: 0.5)),
                ),
                child: Theme(
                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                    childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                    dense: true,
                    iconColor: NoorColors.onGlassGold,
                    collapsedIconColor: NoorColors.onGlassMuted,
                    title: Text(
                      'Scanned text (${widget.scan.ocr.rawText.split('\n').length} lines)',
                      style: GoogleFonts.outfit(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: NoorColors.onGlass,
                      ),
                    ),
                    subtitle: Text(
                      'Exactly what the on-device reader saw.',
                      style: GoogleFonts.outfit(fontSize: 10.5, color: NoorColors.onGlassMuted),
                    ),
                    children: <Widget>[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          widget.scan.ocr.rawText,
                          style: GoogleFonts.outfit(
                            fontSize: 11.5,
                            height: 1.55,
                            color: NoorColors.onGlass,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],

            const SizedBox(height: 18),
            _aiStatusCard(),
            SectionHeader(title: 'Prayer times (24h)'),

            for (int i = 0; i < kPrayers.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: PrayerTimeField(
                  prayer: kPrayers[i],
                  controller: _controllers[kPrayers[i].key]!,
                  focusNode: _focusNodes[i],
                  validator: _validateTime,
                ),
              ),

            const SizedBox(height: 6),
            GoldCard(
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Icon(Icons.info_outline, size: 18, color: NoorColors.onGlassGold),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Your location and the photo will be saved as proof so other '
                      'users can trust these timings. Any member can update them later.',
                      style: GoogleFonts.outfit(fontSize: 11.5, color: NoorColors.onGlass, height: 1.55),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 14),
        child: Builder(
          builder: (BuildContext context) {
            final double scanWidth =
                (MediaQuery.sizeOf(context).width * 0.30).clamp(96.0, 116.0);

            return Row(
              children: <Widget>[
                SizedBox(
                  width: scanWidth,
                  child: OutlinedButton(
                    onPressed: _saving ? null : _scanAgain,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: NoorColors.ink,
                      side: const BorderSide(color: Color(0x333A2E22), width: 1.3),
                      minimumSize: const Size.fromHeight(54),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      visualDensity: VisualDensity.compact,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: Text(
                      'Scan Again',
                      maxLines: 1,
                      style: GoogleFonts.outfit(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GradientButton(
                    label: 'Save & Confirm for All',
                    busy: _saving,
                    onPressed: _save,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Amber/red call-out used on the verification screen when OCR came back
/// with nothing usable, or with only a positional guess.
class _OcrNotice extends StatelessWidget {
  const _OcrNotice({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    // This notice floats straight on the cream page (no card behind it), so
    // its type is the page's own ink — the tinted fill is only a whisper of
    // colour and the border does the announcing.
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 19, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: GoogleFonts.outfit(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: NoorColors.ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: GoogleFonts.outfit(
                    fontSize: 11.5,
                    height: 1.5,
                    color: NoorColors.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class PrayerTimeField extends StatefulWidget {
  const PrayerTimeField({
    super.key,
    required this.prayer,
    required this.controller,
    required this.focusNode,
    required this.validator,
  });

  final PrayerInfo prayer;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String? Function(String?) validator;

  @override
  State<PrayerTimeField> createState() => _PrayerTimeFieldState();
}

class _PrayerTimeFieldState extends State<PrayerTimeField> {
  bool _filled = false;

  @override
  void initState() {
    super.initState();
    _filled = widget.controller.text.trim().isNotEmpty;
    widget.controller.addListener(_listener);
  }

  void _listener() {
    final bool next = widget.controller.text.trim().isNotEmpty;
    if (next != _filled && mounted) setState(() => _filled = next);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      validator: widget.validator,
      keyboardType: const TextInputType.numberWithOptions(decimal: false),
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.allow(RegExp(r'[0-9:]')),
        LengthLimitingTextInputFormatter(5),
      ],
      // The field is filled white by the theme, so a *dark* value is the only
      // spelling a reader can actually see — the accent beige (#D7B899) reads
      // as blank on white, which is how a saved time looked like an empty box.
      style: GoogleFonts.outfit(
        fontSize: 15,
        fontWeight: FontWeight.w700,
        color: _filled ? NoorColors.ink : NoorColors.muted,
        letterSpacing: 0.6,
      ),
      decoration: InputDecoration(
        labelText: '${widget.prayer.label} • ${widget.prayer.arabic}',
        hintText: 'HH:MM',
        // Same rule for the glyphs: the light accent vanishes on the white
        // fill, so they take the deepened shade of it instead.
        prefixIcon: Icon(widget.prayer.icon, color: NoorColors.emeraldDeep, size: 20),
        suffixIcon: IconButton(
          tooltip: 'Edit ${widget.prayer.label}',
          onPressed: () {
            widget.focusNode.requestFocus();
            widget.controller.selection = TextSelection(
              baseOffset: 0,
              extentOffset: widget.controller.text.length,
            );
          },
          icon: const Icon(Icons.edit_outlined, size: 18, color: NoorColors.emeraldDeep),
        ),
      ),
    );
  }
}

// ===========================================================================
//  DETAIL
// ===========================================================================

/// "Suggest correct name" — the modal *and* the Firestore write behind it.
///
/// The dialog owns the whole flow so the page underneath never rebuilds while
/// it is open. Two rules keep it from tearing a widget down under itself:
///
///   * only [dialogContext] is ever used to pop — the caller's context is
///     touched solely for the success snackbar, and only after a `mounted`
///     check;
///   * the [TextEditingController] outlives `showDialog`'s future by a frame,
///     because that future resolves in the microtask after the route leaves
///     the history while its elements are still mounted until the *next*
///     frame finishes.
///
/// Returns the spelling that was actually written, or `null` when the user
/// backed out or the write failed (the failure comes back as a snackbar and
/// the dialog stays up so it can be retried).
Future<String?> showRenameDialog(BuildContext parentContext, Masjid masjid) async {
  final TextEditingController controller = TextEditingController(text: masjid.name);
  bool isSaving = false;
  String? saved;

  try {
    await showDialog<void>(
      context: parentContext,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, void Function(void Function()) setStateDialog) {
          Future<void> save() async {
            if (isSaving) return;

            final String newName = controller.text.trim();
            if (newName.isEmpty || newName == masjid.name.trim()) {
              if (dialogContext.mounted) Navigator.of(dialogContext).pop();
              return;
            }

            setStateDialog(() => isSaving = true);
            try {
              final String? uid = FirebaseAuth.instance.currentUser?.uid;
              if (uid == null || uid.isEmpty) {
                throw StateError('Sign in to correct a masjid name.');
              }

              // Keep the *first* spelling that ever existed, not merely the
              // last one — otherwise two corrections in a row make the
              // original unrecoverable.
              String original = masjid.name.trim();
              try {
                final DocumentSnapshot<Map<String, dynamic>> snap = await FirebaseFirestore
                    .instance
                    .collection('masjids')
                    .doc(masjid.id)
                    .get();
                final String stored = ((snap.data()?['originalName'] as String?) ?? '').trim();
                if (stored.isNotEmpty) original = stored;
              } catch (_) {
                // Offline or a rule that denies the read: fall back to the
                // name the dialog was opened with — correct on the very first
                // rename, which is the only time this branch matters.
              }

              await FirebaseFirestore.instance.collection('masjids').doc(masjid.id).update(
                <String, Object?>{
                  // `masjidName`, not `name`: that is the key `Masjid.fromDoc`
                  // reads, and the rules demand it on every write.
                  'masjidName': newName,
                  'originalName': original,
                  'nameEditedBy': uid,
                  'nameEditedAt': FieldValue.serverTimestamp(),
                  // `request.resource.data.updatedByUid == request.auth.uid`
                  // — without this the update is rejected outright.
                  'updatedByUid': uid,
                  // `lastUpdated` is deliberately absent: a rename is not a
                  // prayer-time verification and must not reset "Updated 4
                  // min ago".
                },
              );
              saved = newName;

              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop();

              if (!parentContext.mounted) return;
              ScaffoldMessenger.of(parentContext).showSnackBar(
                const SnackBar(content: Text('Name updated! Thank you ❤️')),
              );
            } catch (error) {
              if (!dialogContext.mounted) return;
              setStateDialog(() => isSaving = false);
              ScaffoldMessenger.of(dialogContext).showSnackBar(
                SnackBar(
                  content: Text(
                    'Could not update the name: $error',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              );
            }
          }

          return AlertDialog(
            backgroundColor: NoorColors.cream,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
            title: Text(
              'Suggest correct name',
              style: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'If this masjid’s name is wrong or incomplete, correct it below. '
                  'Everyone nearby sees the fix straight away.',
                  style: GoogleFonts.outfit(fontSize: 12.5, height: 1.55),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: controller,
                  autofocus: true,
                  maxLength: 60,
                  enabled: !isSaving,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => save(),
                  decoration: InputDecoration(
                    counterText: '',
                    labelText: 'Masjid name',
                    hintText: 'e.g. Noor Masjid',
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: NoorColors.gold),
                    ),
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: isSaving ? null : () => Navigator.of(dialogContext).pop(),
                child: Text('Cancel',
                    style: GoogleFonts.outfit(
                        color: NoorColors.muted, fontWeight: FontWeight.w600)),
              ),
              ElevatedButton(
                onPressed: isSaving ? null : save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: NoorColors.emerald,
                  foregroundColor: NoorColors.ink,
                  disabledBackgroundColor: const Color(0xFF9AA8A3),
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: isSaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text('Save',
                        style:
                            GoogleFonts.outfit(fontWeight: FontWeight.w700, fontSize: 13.5)),
              ),
            ],
          );
        },
      ),
    );
  } finally {
    // `showDialog`'s future resolves as soon as the route is taken out of the
    // history, but the route's elements are only deactivated when the *next*
    // frame builds and are unmounted at the end of it. Disposing here — in the
    // microtask — is what produced "A TextEditingController was used after
    // being disposed": the keyboard sliding away re-queries MediaQuery, the
    // still-mounted TextField updates, and its listener registration lands on
    // a dead ChangeNotifier. That throw is what then cascaded into the
    // RenderFlex overflow and the `_dependents.isEmpty` red screen.
    await WidgetsBinding.instance.endOfFrame;
    controller.dispose();
  }

  return saved;
}

class MasjidDetailScreen extends StatefulWidget {
  const MasjidDetailScreen({super.key, required this.masjid, required this.metres});

  final Masjid masjid;
  final double metres;

  @override
  State<MasjidDetailScreen> createState() => _MasjidDetailScreenState();
}

class _MasjidDetailScreenState extends State<MasjidDetailScreen> {
  late Masjid _masjid;
  late double _metres;

  /// Whether *this account* has starred the masjid. Until that is known the
  /// alert switch stays disabled rather than guessing at an off state.
  bool _favourite = false;
  bool _favouriteKnown = false;

  @override
  void initState() {
    super.initState();
    _masjid = widget.masjid;
    _metres = widget.metres;
    _loadFavouriteState();
  }

  Future<void> _loadFavouriteState() async {
    final List<String> ids = await FavouriteStore.cached();
    if (!mounted) return;
    setState(() {
      _favourite = ids.contains(_masjid.id);
      _favouriteKnown = true;
    });
  }

  /// The alert switch itself: one preference per masjid, then re-arm.
  Future<void> _setAlert(bool enabled) async {
    AppSettings.instance.setFavAlert(_masjid.id, enabled);
    await NotificationService.scheduleFavouriteAlerts();
    if (mounted) setState(() {});
  }

  /// Prayers this masjid can actually alert for: switched on in Settings
  /// *and* carrying a readable time on the board.
  List<String> _armedPrayers() {
    final AppSettings settings = AppSettings.instance;
    return <String>[
      for (final String key in kNotifiablePrayers)
        if (settings.notifyOnFor(key) &&
            NotificationService.parseClockTime(_masjid.timeFor(key)) != null)
          prayerByKey(key).label,
    ];
  }

  /// All three ways in — live camera, a gallery photo, or typing the times by
  /// hand — land on the same document, so they share one refresh afterwards.
  Future<void> _update() async {
    final ScanSource? choice = await askScanSource(context);
    if (choice == null || !mounted) return;

    if (choice == ScanSource.manual) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => ManualAddScreen(existing: _masjid)),
      );
    } else {
      final ScanResult? scan = await ScanFlow.capture(
        source: choice == ScanSource.gallery ? ImageSource.gallery : ImageSource.camera,
      );
      if (scan == null || !mounted) return;

      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => VerificationScreen(scan: scan, existing: _masjid),
        ),
      );
    }

    if (!mounted) return;
    await _refresh();
  }

  Future<void> _refresh() async {
    // Refresh after the caller may have written new data.
    try {
      final DocumentSnapshot<Map<String, dynamic>> snap = await FirebaseFirestore.instance
          .collection('masjids')
          .doc(_masjid.id)
          .get();
      if (snap.exists && mounted) {
        setState(() {
          _masjid = Masjid.fromDoc(snap);
          _metres = LocationService.distanceTo(_masjid.latitude, _masjid.longitude);
        });
      }
    } catch (_) {}
  }

  /// True while the rename dialog is open, so a double tap cannot stack two
  /// of them. The dialog is modal anyway — this is belt and braces, and it
  /// keeps the "Edit" chip honest while the write is in flight.
  bool _renaming = false;

  /// Opens the pin editor from inside the meta card and folds whatever comes
  /// back into this screen.
  ///
  /// The write itself happens in [FixLocationMapScreen]; `_refresh` then pulls
  /// the new coordinates straight from Firestore, so the map and the badge
  /// above change here without waiting for the next snapshot.
  Future<void> _openFixLocation() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => FixLocationMapScreen(masjid: _masjid)),
    );
    if (mounted) await _refresh();
  }

  /// Corrects a wrong name — a board filed as "Aqsa Masjid Road" that should
  /// read "Noor Masjid".
  ///
  /// The writing lives in [showRenameDialog]; all this screen does is swap its
  /// own model once the dialog reports success, so the meta card reads the new
  /// spelling before the Firestore snapshot arrives. That `setState` happens
  /// *after* the dialog has closed — never from inside it.
  Future<void> _rename() async {
    if (_renaming) return;
    setState(() => _renaming = true);

    String? renamed;
    try {
      renamed = await showRenameDialog(context, _masjid);
    } finally {
      // A rejected write already reported itself inside the dialog; this only
      // has to make sure the "Edit" chip comes back whether the dialog closed
      // cleanly or threw on the way out — and never on a State that is gone.
      if (mounted) {
        setState(() {
          _renaming = false;
          if (renamed != null) _masjid = _masjid.withName(renamed);
        });
      }
    }

    if (renamed != null) {
      // Every scheduled alert spells the masjid's name in its body.
      unawaited(NotificationService.scheduleFavouriteAlerts());
    }
  }

  /// Removes a masjid this account put on the shared list.
  ///
  /// Firestore rules decide for real whether this is allowed; the button only
  /// shows for a document that looks like ours, so a rule that still says
  /// `allow delete: if false` surfaces as an explained failure rather than a
  /// hidden one.
  Future<void> _delete() async {
    final String name = _masjid.name.isEmpty ? 'this masjid' : _masjid.name;

    final bool? proceed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: NoorColors.cream,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text(
          'Delete this masjid?',
          style: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        content: Text(
          '$name will be removed from the shared list for everyone nearby. '
          'This cannot be undone.',
          style: GoogleFonts.outfit(fontSize: 13, height: 1.55),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel',
                style: GoogleFonts.outfit(color: NoorColors.muted, fontWeight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Delete',
                style: GoogleFonts.outfit(
                    color: Colors.red.shade700, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;

    try {
      await FirebaseFirestore.instance.collection('masjids').doc(_masjid.id).delete();

      // Take it out of this account's favourites as well, cloud copy first —
      // otherwise the next sync would union the dead id straight back in.
      final List<String> ids = await FavouriteStore.cached();
      if (ids.remove(_masjid.id)) {
        await FavouriteStore.cache(ids);
        FavouriteWatcher.watch(ids);
        final String? uid = FirebaseAuth.instance.currentUser?.uid;
        if (uid != null) {
          try {
            await FirebaseFirestore.instance
                .collection('users')
                .doc(uid)
                .collection('favourites')
                .doc(_masjid.id)
                .delete();
          } catch (error) {
            debugPrint('Noor ▸ could not drop favourite doc: $error');
          }
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$name removed from the shared list')),
      );
      // Its Jamaat-time alerts must go down with the favourite.
      unawaited(NotificationService.scheduleFavouriteAlerts());
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not delete $name: $error\n\nIf it says permission-denied, the '
            'Firestore rules still read `allow delete: if false` — paste the '
            'updated rule shown in lib/main.dart.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return NoorScaffold(
      body: CustomScrollView(
        slivers: <Widget>[
          SliverAppBar(
            pinned: true,
            expandedHeight: 250,
            backgroundColor: Colors.transparent,
            foregroundColor: NoorColors.ink,
            surfaceTintColor: Colors.transparent,
            stretch: true,
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              title: Text(
                _masjid.name.isEmpty ? 'Masjid' : _masjid.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.outfit(fontSize: 14.5, fontWeight: FontWeight.w700, color: NoorColors.ink),
              ),
              background: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  const DecoratedBox(
                    decoration: BoxDecoration(gradient: NoorColors.emeraldGradient),
                    child: IgnorePointer(child: CustomPaint(painter: IslamicPatternPainter(tile: 66, opacity: 0.16))),
                  ),
                  Positioned(
                    right: -40,
                    bottom: -40,
                    child: Icon(Icons.mosque_outlined, size: 190, color: NoorColors.ink.withValues(alpha: 0.12)),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // -------------------------------------------------- meta card
                  GoldCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        // The name and the pin, each with the way to correct
                        // it — see `_rename` and `_openFixLocation`.
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                _masjid.name.isEmpty ? 'Masjid' : _masjid.name,
                                style: GoogleFonts.outfit(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: NoorColors.onGlass,
                                  height: 1.3,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Semantics(
                              button: true,
                              label: 'Edit masjid name',
                              child: InkWell(
                                onTap: _renaming ? null : _rename,
                                borderRadius: BorderRadius.circular(10),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 9, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: NoorColors.onGlassChip,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                        color: NoorColors.gold
                                            .withValues(alpha: 0.6)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      const Icon(Icons.edit_outlined,
                                          size: 13, color: NoorColors.emeraldDeep),
                                      const SizedBox(width: 4),
                                      Text(
                                        _renaming ? 'Saving…' : 'Edit',
                                        style: GoogleFonts.outfit(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: NoorColors.emeraldDeep,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Semantics(
                              button: true,
                              label: 'Fix masjid location',
                              child: InkWell(
                                borderRadius: BorderRadius.circular(10),
                                onTap: () => unawaited(_openFixLocation()),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 9, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: NoorColors.onGlassChip,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                        color: NoorColors.gold
                                            .withValues(alpha: 0.6)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      const Icon(Icons.edit_location_alt,
                                          size: 13, color: NoorColors.emeraldDeep),
                                      const SizedBox(width: 4),
                                      Text(
                                        'Location',
                                        style: GoogleFonts.outfit(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: NoorColors.emeraldDeep,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: <Widget>[
                            // Listening to the gate means a location switch
                            // flipped while this screen is open still removes
                            // the badge, not just the next one you open.
                            ValueListenableBuilder<bool>(
                              valueListenable: LocationService.distanceGate,
                              builder: (BuildContext context, bool live, Widget? child) =>
                                  !live
                                      ? const SizedBox.shrink()
                                      : Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: <Widget>[
                                            DistanceBadge(metres: _metres),
                                            const SizedBox(width: 8),
                                          ],
                                        ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                              decoration: BoxDecoration(
                                color: NoorColors.onGlassChip,
                                borderRadius: BorderRadius.circular(30),
                                border: Border.all(color: NoorColors.gold.withValues(alpha: 0.6)),
                              ),
                              child: Text(
                                'Updated ${timeAgo(_masjid.lastUpdated)}',
                                style: GoogleFonts.outfit(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                  color: NoorColors.emeraldDeep,
                                ),
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '#${_masjid.updateCount} update',
                              style: GoogleFonts.outfit(fontSize: 10.5, color: NoorColors.onGlassMuted),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (_masjid.address.isNotEmpty)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              const Icon(Icons.place_outlined, size: 15, color: NoorColors.emerald),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _masjid.address,
                                  style: GoogleFonts.outfit(fontSize: 12.5, color: NoorColors.onGlass, height: 1.5),
                                ),
                              ),
                            ],
                          ),
                        const SizedBox(height: 8),
                        Row(
                          children: <Widget>[
                            const Icon(Icons.person_outline, size: 15, color: NoorColors.emerald),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _masjid.updatedBy.isEmpty
                                    ? 'Updated by the community'
                                    : 'Last verified by ${_masjid.updatedBy}',
                                style: GoogleFonts.outfit(fontSize: 12, color: NoorColors.onGlassMuted),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),
                  SectionHeader(title: 'Prayer times'),
                  GoldCard(
                    child: Column(
                      children: <Widget>[
                        for (int i = 0; i < kPrayers.length; i++) ...<Widget>[
                          if (i > 0) Divider(height: 14, color: NoorColors.gold.withValues(alpha: 0.25)),
                          Row(
                            children: <Widget>[
                              Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  color: NoorColors.onGlassChip,
                                  borderRadius: BorderRadius.circular(11),
                                ),
                                child: Icon(kPrayers[i].icon, size: 17, color: NoorColors.emerald),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      kPrayers[i].label,
                                      style: GoogleFonts.outfit(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: NoorColors.onGlass,
                                      ),
                                    ),
                                    Text(
                                      kPrayers[i].arabic,
                                      style: GoogleFonts.amiri(fontSize: 13, color: NoorColors.onGlassMuted),
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                AppSettings.instance
                                    .formatClock(_masjid.timeFor(kPrayers[i].key)),
                                style: GoogleFonts.outfit(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  color: NoorColors.ink,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),
                  SectionHeader(title: 'Prayer alerts'),
                  GoldCard(
                    padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SwitchListTile(
                          value: _favourite && AppSettings.instance.favAlertFor(_masjid.id),
                          onChanged: _favourite ? _setAlert : null,
                          activeThumbColor: NoorColors.emerald,
                          title: Text(
                            'Alert me at this masjid',
                            style: GoogleFonts.outfit(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                                color: NoorColors.onGlass),
                          ),
                          subtitle: Text(
                            !_favouriteKnown
                                ? 'Checking your favourites…'
                                : !_favourite
                                    ? 'Star this masjid first — then Noor can remind you '
                                        'at the Jamaat times shown above.'
                                    : AppSettings.instance.favAlertFor(_masjid.id)
                                        ? 'A reminder at every Jamaat time on this board.'
                                        : 'Off for this masjid.',
                            style: GoogleFonts.outfit(
                                fontSize: 11.5, color: NoorColors.onGlassMuted, height: 1.45),
                          ),
                        ),
                        if (_favourite && AppSettings.instance.favAlertFor(_masjid.id)) ...<Widget>[
                          Divider(height: 1, color: NoorColors.gold.withValues(alpha: 0.3)),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                            child: Text(
                              _armedPrayers().isEmpty
                                  ? 'Nothing armed yet — switch on at least one prayer in '
                                      'Settings, and make sure this board has that time.'
                                  : 'Armed for ${_armedPrayers().join(', ')}. '
                                      'Which prayers fire, and whether they fire exactly on '
                                      'the Jamaat time or minutes before, is set in Settings.',
                              style: GoogleFonts.outfit(
                                  fontSize: 11.5, color: NoorColors.onGlassMuted, height: 1.5),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),
                  SectionHeader(title: 'Location'),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Container(
                      height: 220,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: NoorColors.gold.withValues(alpha: 0.6)),
                      ),
                      child: _masjid.latitude == 0 && _masjid.longitude == 0
                          ? const _MessageState(
                              icon: Icons.place_outlined,
                              title: 'No coordinates yet',
                              subtitle: 'Re-scan the board to attach this masjid to the map.',
                            )
                          : FlutterMap(
                              options: MapOptions(
                                initialCenter: LatLng(_masjid.latitude, _masjid.longitude),
                                initialZoom: 16.5,
                              ),
                              children: <Widget>[
                                TileLayer(
                                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                  userAgentPackageName: 'com.sunesra_app',
                                ),
                                MarkerLayer(
                                  markers: <Marker>[
                                    Marker(
                                      point: LatLng(_masjid.latitude, _masjid.longitude),
                                      width: 54,
                                      height: 54,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: NoorColors.emeraldDeep,
                                          border: Border.all(color: NoorColors.gold, width: 2),
                                          boxShadow: <BoxShadow>[
                                            BoxShadow(
                                              color: Colors.black.withValues(alpha: 0.3),
                                              blurRadius: 12,
                                            ),
                                          ],
                                        ),
                                        child: const Icon(Icons.mosque_outlined, color: NoorColors.white, size: 26),
                                      ),
                                    ),
                                  ],
                                ),
                                const SimpleAttributionWidget(
                                  source: Text('© OpenStreetMap contributors'),
                                ),
                              ],
                            ),
                    ),
                  ),

                  const SizedBox(height: 18),
                  SectionHeader(title: 'Photo proof'),
                  GoldCard(
                    onTap: _masjid.hasProof
                        ? () => showDialog<void>(
                              context: context,
                              barrierColor: Colors.black87,
                              builder: (_) => PhotoProofViewer(masjid: _masjid),
                            )
                        : null,
                    padding: EdgeInsets.zero,
                    child: SizedBox(
                      height: 230,
                      width: double.infinity,
                      child: buildProofImage(_masjid, fit: BoxFit.cover),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _masjid.hasProof
                        ? 'Tap to zoom — this is the original board photo saved with the update.'
                        : 'No photo proof was attached to this update.',
                    style: GoogleFonts.outfit(
                      fontSize: 11.5,
                      color: NoorColors.muted,
                      height: 1.5,
                    ),
                  ),

                  // Only the account that put it here sees this — see
                  // `Masjid.canDelete`. Everyone else can still edit the times.
                  if (_masjid.canDelete) ...<Widget>[
                    const SizedBox(height: 22),
                    SectionHeader(title: 'Your submission'),
                    const SizedBox(height: 6),
                    InkWell(
                      onTap: _delete,
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                        decoration: BoxDecoration(
                          color: NoorGlass.of(context).fill,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.red.withValues(alpha: 0.5)),
                        ),
                        child: Row(
                          children: <Widget>[
                            Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: Colors.red.withValues(alpha: 0.09),
                                borderRadius: BorderRadius.circular(11),
                              ),
                              child: Icon(Icons.delete_outline,
                                  size: 17, color: Colors.red.shade700),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    'Delete this masjid',
                                    style: GoogleFonts.outfit(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.red.shade800,
                                    ),
                                  ),
                                  Text(
                                    'Remove it from the shared list for everyone nearby.',
                                    style: GoogleFonts.outfit(
                                        fontSize: 11.5,
                                        color: NoorColors.onGlassMuted,
                                        height: 1.4),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right_outlined, color: NoorColors.onGlassMuted),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 14),
        child: GradientButton(
          label: 'Update Time',
          icon: Icons.edit_outlined,
          onPressed: _update,
        ),
      ),
    );
  }
}

// ===========================================================================
//  HOME WIDGET HELPERS
// ---------------------------------------------------------------------------

/// Pulsing placeholder shown while the GPS fix or the Firestore list is still
/// loading — so the screen never flashes "No masjids yet" prematurely.
class _SkeletonList extends StatefulWidget {
  const _SkeletonList();

  @override
  State<_SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<_SkeletonList>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (BuildContext context, Widget? _) {
        final double alpha = 0.30 + 0.35 * _pulse.value;

        return ListView(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
          children: <Widget>[
            Text(
              'Finding masjids near you…',
              style: GoogleFonts.outfit(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: NoorColors.muted,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              height: 16,
              width: 150,
              decoration: BoxDecoration(
                color: NoorColors.gold.withValues(alpha: alpha),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            const SizedBox(height: 14),
            for (int i = 0; i < 4; i++) ...<Widget>[
              Container(
                height: 146,
                decoration: BoxDecoration(
                  color: NoorColors.emeraldSoft.withValues(alpha: alpha),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: NoorColors.gold.withValues(alpha: alpha)),
                ),
              ),
              const SizedBox(height: 14),
            ],
          ],
        );
      },
    );
  }
}

/// A mosque OpenStreetMap knows about that nobody has contributed times for.
class _MapResultCard extends StatelessWidget {
  const _MapResultCard({required this.result, required this.onTap});

  final MasjidSearchResult result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final double? metres = result.distanceMetres;

    return Material(
      color: NoorGlass.of(context).fill,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: NoorColors.gold.withValues(alpha: 0.7)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: NoorColors.onGlassChip,
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: const Icon(Icons.place_outlined,
                        size: 20, color: NoorColors.emeraldDeep),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          result.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.outfit(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                            color: NoorColors.onGlass,
                          ),
                        ),
                        if (result.address.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 3),
                          Text(
                            result.address,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.outfit(
                                fontSize: 11.5, color: NoorColors.onGlassMuted, height: 1.4),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (metres != null && LocationService.distanceAvailable) ...<Widget>[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                      decoration: BoxDecoration(
                        color: NoorColors.emerald,
                        borderRadius: BorderRadius.circular(30),
                      ),
                      child: Text(
                        formatDistance(metres),
                        style: GoogleFonts.outfit(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: NoorColors.ink,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Icon(Icons.add_circle_outline, size: 15, color: NoorColors.emeraldDeep),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Not in Noor yet — tap to add Jamaat time',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: NoorColors.emeraldDeep,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right_outlined, size: 18, color: NoorColors.onGlassMuted),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
//  NOTE
// ---------------------------------------------------------------------------
//  Firestore rules. The same text ships in `firestore.rules`, so either paste
//  this block into the Firebase console (Rules tab) or run
//  `firebase deploy --only firestore:rules`.
//
//  rules_version = '2';
//  service cloud.firestore {
//    match /databases/{database}/documents {
//      match /masjids/{doc} {
//        allow read: if request.auth != null;
//        allow create, update: if request.auth != null
//          && request.resource.data.keys().hasAll([
//               'masjidName','fajr','dhuhr','asr','maghrib','isha','juma',
//               'latitude','longitude','address','lastUpdated','updatedByUid'])
//          && request.resource.data.updatedByUid == request.auth.uid;
//        // Deleting is only for the account that put the masjid on the list.
//        // `createdByUid` is stamped on create — never on update, so editing
//        // someone else's entry cannot transfer it. Documents older than that
//        // field fall back to whoever last updated them.
//        // NOTE: `createdByUid` is deliberately NOT in the hasAll list above:
//        // adding it would reject updates to documents that predate it.
//        allow delete: if request.auth != null
//          && (resource.data.get('createdByUid', '') == request.auth.uid
//              || (resource.data.get('createdByUid', '') == ''
//                  && resource.data.get('updatedByUid', '') == request.auth.uid));
//      }
//      match /users/{uid}/favourites/{doc} {
//        allow read, write: if request.auth != null && request.auth.uid == uid;
//      }
//    }
//  }
// ---------------------------------------------------------------------------
