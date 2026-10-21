import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../app_look.dart';
import '../app_settings.dart';
import '../main.dart';
import '../services/qibla.dart';

/// The compass every Muslim app is expected to carry, and the one this app
/// did not.
///
/// The dial is driven by the magnetometer with the accelerometer undoing
/// the tilt (see [Qibla.heading]), so a phone held *up* in a mosque points
/// the same way it did flat on the table. The bearing it aims at is the
/// great-circle one, computed from wherever the app thinks the user is —
/// the pinned city if there is one, the last GPS fix otherwise — which is
/// the same location rule the prayer times on Home already follow.
class QiblaScreen extends StatefulWidget {
  const QiblaScreen({super.key, this.latitude, this.longitude});

  final double? latitude;
  final double? longitude;

  @override
  State<QiblaScreen> createState() => _QiblaScreenState();
}

class _QiblaScreenState extends State<QiblaScreen> {
  StreamSubscription<MagnetometerEvent>? _magnetometer;
  StreamSubscription<AccelerometerEvent>? _accelerometer;

  /// The last of each reading — the two go into [Qibla.heading] together.
  List<double>? _field;
  List<double>? _gravity;

  /// Smoothed heading; `null` until the sensors have spoken.
  double? _heading;

  /// Set when readings arrive but no heading can be formed from them —
  /// the phone is on its side, or the sensor is on strike.
  bool _sensorSilent = false;

  @override
  void initState() {
    super.initState();
    _startSensors();
  }

  void _startSensors() {
    try {
      _magnetometer = magnetometerEventStream().listen(
        (MagnetometerEvent e) {
          _field = <double>[e.x, e.y, e.z];
          _recompute();
        },
        onError: (Object _) => _declareSilent(),
      );
      _accelerometer = accelerometerEventStream().listen(
        (AccelerometerEvent e) {
          _gravity = <double>[e.x, e.y, e.z];
          _recompute();
        },
        onError: (Object _) => _declareSilent(),
      );
    } catch (_) {
      // No sensor hardware (a desktop run, an emulator): the screen still
      // opens and shows the bearing it *would* steer by.
      _declareSilent();
    }
  }

  void _declareSilent() {
    if (!mounted || _sensorSilent) return;
    setState(() => _sensorSilent = true);
  }

  void _recompute() {
    final List<double>? field = _field;
    final List<double>? gravity = _gravity;
    if (field == null || gravity == null) return;
    final double? raw = Qibla.heading(magnetometer: field, accelerometer: gravity);
    if (raw == null) return;

    final double previous = _heading ?? raw;
    final double next = Qibla.smooth(previous, raw);
    if (_heading == null || (next - previous).abs() > 0.4) {
      if (!mounted) return;
      setState(() {
        _heading = next;
        _sensorSilent = false;
      });
    } else {
      _heading = next;
    }
  }

  @override
  void dispose() {
    _magnetometer?.cancel();
    _accelerometer?.cancel();
    super.dispose();
  }

  /// Where the compass is steering from: the pinned city first (what the
  /// times on Home use), the app's fallback anchor otherwise.
  ({double latitude, double longitude}) get _here {
    final AppSettings settings = AppSettings.instance;
    if (widget.latitude != null && widget.longitude != null) {
      return (latitude: widget.latitude!, longitude: widget.longitude!);
    }
    if (settings.hasCustomLocation) {
      return (
        latitude: settings.customLatitude ?? 19.0760,
        longitude: settings.customLongitude ?? 72.8777,
      );
    }
    return (latitude: 19.0760, longitude: 72.8777);
  }

  @override
  Widget build(BuildContext context) {
    final ({double latitude, double longitude}) here = _here;
    final double qibla = Qibla.bearing(here.latitude, here.longitude);
    final double km = Qibla.distanceKm(here.latitude, here.longitude);
    final double? heading = _heading;

    // How far off the Qibla the phone points right now — the one number
    // the whole screen exists to deliver.
    final double? turn =
        heading == null ? null : Qibla.turnFrom(headingDegrees: heading, qiblaDegrees: qibla);
    final bool aligned = turn != null && turn.abs() < 4.0;

    return NoorScaffold(
      appBar: AppBar(title: const Text('Qibla')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
        children: <Widget>[
          Text(
            'Turn until the Ka\'aba sits under the marker',
            textAlign: TextAlign.center,
            style: GoogleFonts.outfit(
              fontSize: 12.5,
              color: NoorColors.onGlassMuted,
            ),
          ),
          const SizedBox(height: 14),
          GoldCard(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 12),
            child: Center(
              child: SizedBox(
                width: 290,
                height: 290,
                child: Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    // The dial itself: rotates against the heading, so the
                    // letters always lean the way the world actually is.
                    Transform.rotate(
                      angle: heading == null
                          ? 0
                          : -heading * math.pi / 180.0,
                      child: CustomPaint(
                        size: const Size(290, 290),
                        painter: _CompassDialPainter(qibla: qibla),
                      ),
                    ),
                    // The fixed frame: "you are here" and the golden line
                    // the Ka\u2019aba has to arrive under.
                    const CustomPaint(
                      size: Size(290, 290),
                      painter: _CompassFramePainter(),
                    ),
                    if (heading == null)
                      Text(
                        _sensorSilent ? 'No compass sensor' : 'Calibrating…',
                        style: GoogleFonts.outfit(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: NoorColors.onGlassMuted,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          GoldCard(
            child: Column(
              children: <Widget>[
                _ReadoutRow(
                  label: 'Qibla from here',
                  value: '${qibla.toStringAsFixed(1)}°',
                ),
                const Divider(height: 18),
                _ReadoutRow(
                  label: 'Phone is facing',
                  value: heading == null
                      ? '—'
                      : '${heading.toStringAsFixed(0)}°',
                ),
                const Divider(height: 18),
                _ReadoutRow(
                  label: aligned ? 'You are facing the Qibla' : 'Turn',
                  value: turn == null
                      ? '—'
                      : aligned
                          ? '✓'
                          : '${turn.abs().toStringAsFixed(0)}° '
                              '${turn > 0 ? 'right' : 'left'}',
                  highlight: aligned,
                ),
                const Divider(height: 18),
                _ReadoutRow(
                  label: 'Distance to Makkah',
                  value: '${km.toStringAsFixed(0)} km',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_sensorSilent)
            _hint(
              Icons.sensors_off_outlined,
              'This device is not reporting a compass. On a phone, move away '
              'from metal and try again — or follow the Qibla time shown on '
              'your local board.',
            )
          else
            _hint(
              Icons.explore_outlined,
              'For a steady reading hold the phone flat, away from steel '
              'tables and phone cases with magnets. Some phones ask you to '
              'move the phone in a figure-8 once to calibrate.',
            ),
        ],
      ),
    );
  }

  Widget _hint(IconData icon, String text) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, size: 16, color: NoorColors.onGlassMuted),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                text,
                style: GoogleFonts.outfit(
                  fontSize: 11.5,
                  height: 1.5,
                  color: NoorColors.onGlassMuted,
                ),
              ),
            ),
          ],
        ),
      );
}

class _ReadoutRow extends StatelessWidget {
  const _ReadoutRow({required this.label, required this.value, this.highlight = false});

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            style: GoogleFonts.outfit(
              fontSize: 13,
              fontWeight: highlight ? FontWeight.w700 : FontWeight.w500,
              color: highlight ? NoorColors.gold : NoorColors.onGlass,
            ),
          ),
        ),
        Text(
          value,
          style: GoogleFonts.outfit(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: highlight ? NoorColors.gold : NoorColors.onGlass,
          ),
        ),
      ],
    );
  }
}

/// The rotating half: the ring of degrees, the four letters, and the Ka\u2019aba
/// that swings round with the dial until it meets the fixed marker above.
class _CompassDialPainter extends CustomPainter {
  const _CompassDialPainter({required this.qibla});

  final double qibla;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = size.width / 2 - 6;

    final Paint tick = Paint()
      ..strokeWidth = 1.2
      ..color = NoorColors.onGlassMuted;
    final Paint major = Paint()
      ..strokeWidth = 2.2
      ..color = NoorColors.gold.withValues(alpha: 0.85);
    final Paint ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = NoorColors.gold.withValues(alpha: 0.5);

    canvas.drawCircle(center, radius, ring);

    for (int deg = 0; deg < 360; deg += 6) {
      final bool isCardinal = deg % 90 == 0;
      final bool isMajor = deg % 30 == 0;
      final double radians = (deg - 90) * math.pi / 180.0;
      final double inner = radius - (isCardinal ? 20 : isMajor ? 13 : 8);
      canvas.drawLine(
        center + Offset(math.cos(radians) * inner, math.sin(radians) * inner),
        center + Offset(math.cos(radians) * radius, math.sin(radians) * radius),
        isCardinal ? major : tick,
      );
    }

    // The letters, leaning with the dial they are printed on.
    const List<(String, double)> letters = <(String, double)>[
      ('N', 0), ('E', 90), ('S', 180), ('W', 270),
    ];
    for (final (String letter, double deg) in letters) {
      final double radians = (deg - 90) * math.pi / 180.0;
      final TextPainter tp = TextPainter(
        text: TextSpan(
          text: letter,
          style: GoogleFonts.outfit(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: deg == 0 ? NoorColors.gold : NoorColors.onGlass,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final Offset at = center +
          Offset(math.cos(radians), math.sin(radians)) * (radius - 34);
      tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
    }

    // The Ka\u2019aba itself, painted at the Qibla's bearing on the rotating
    // ring — the whole reason the dial exists.
    final double radians = (qibla - 90) * math.pi / 180.0;
    final Offset kaaba =
        center + Offset(math.cos(radians), math.sin(radians)) * (radius - 34);
    final Rect body = Rect.fromCenter(center: kaaba, width: 20, height: 16);
    canvas.drawRRect(
      RRect.fromRectAndRadius(body, const Radius.circular(3)),
      Paint()..color = NoorColors.gold,
    );
    canvas.drawLine(
      kaaba.translate(-10, -3),
      kaaba.translate(10, -3),
      Paint()
        ..strokeWidth = 1.6
        ..color = NoorColors.ink.withValues(alpha: 0.8),
    );
  }

  @override
  bool shouldRepaint(_CompassDialPainter oldDelegate) =>
      oldDelegate.qibla != qibla;
}

/// The fixed half: a small triangle at twelve o\u2019clock and a hairline the
/// Ka\u2019aba has to sit under to be "arrived".
class _CompassFramePainter extends CustomPainter {
  const _CompassFramePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = size.width / 2 - 6;

    final Path arrow = Path()
      ..moveTo(center.dx, center.dy - radius + 2)
      ..lineTo(center.dx - 7, center.dy - radius - 8)
      ..lineTo(center.dx + 7, center.dy - radius - 8)
      ..close();
    canvas.drawPath(arrow, Paint()..color = NoorColors.gold);

    canvas.drawLine(
      center.translate(0, -radius + 10),
      center.translate(0, -radius + 34),
      Paint()
        ..strokeWidth = 1.4
        ..color = NoorColors.gold.withValues(alpha: 0.45),
    );

    // The pivot: one dot, so the rotating dial has something to turn about.
    canvas.drawCircle(center, 3.4, Paint()..color = NoorColors.gold);
  }

  @override
  bool shouldRepaint(_CompassFramePainter oldDelegate) => false;
}
