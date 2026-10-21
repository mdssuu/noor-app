import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hijri/hijri_calendar.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../app_settings.dart';
import '../main.dart';
import '../services/day_arc.dart';
import '../services/islamic_calendar.dart';
import '../services/nafl_times.dart';
import '../services/ramadan.dart';

// ===========================================================================
//  SHARE — today's times, as a message
// ===========================================================================

/// The text the share sheet carries: both calendars, the place, the five
/// calculated times and — when a board is starred — its Jamaat column.
///
/// This is the feature deen.pk and every Indian timetable site already
/// offer and WhatsApp runs on: someone forwards Fajr to the family group
/// every day, and until now that meant a screenshot.
String buildShareText({
  required double latitude,
  required double longitude,
  required String areaName,
  Masjid? board,
  DateTime? now,
}) {
  final AppSettings settings = AppSettings.instance;
  final DateTime moment = now ?? DateTime.now();
  final LocalPrayerTimes day =
      settings.compute(latitude: latitude, longitude: longitude, day: moment);

  String hijri = '';
  try {
    final HijriCalendar h =
        NoorHijri.hijriOf(moment, adjustment: settings.hijriAdjustment);
    hijri = '${h.hDay} ${h.getLongMonthName()} ${h.hYear}';
  } catch (_) {}

  final StringBuffer out = StringBuffer()
    ..writeln('🕌 Noor • Masjid Time')
    ..writeln(DateFormat('EEEE, d MMMM yyyy').format(moment) +
        (hijri.isEmpty ? '' : ' ($hijri)'))
    ..writeln(areaName.trim().isEmpty ? 'Prayer times' : areaName.trim())
    ..writeln();

  for (final String key in <String>['fajr', 'sunrise', 'dhuhr', 'asr', 'maghrib', 'isha']) {
    final DateTime? at = day.times[key];
    if (at == null) continue;
    final String label = key == 'sunrise' ? 'Sunrise' : prayerByKey(key).label;
    out.writeln('$label ${settings.format(at)}');
  }

  if (board != null) {
    out
      ..writeln()
      ..writeln('🕌 Jamaat — ${board.name}');
    for (final String key in <String>['fajr', 'dhuhr', 'asr', 'maghrib', 'isha']) {
      final String clock = board.timeFor(key);
      if (clock.isEmpty || clock == '--:--') continue;
      out.writeln('${prayerByKey(key).label} ${settings.formatClock(clock)}');
    }
    final String juma = board.juma;
    if (juma.isNotEmpty && juma != '--:--') {
      out.writeln('Jumu\'ah ${settings.formatClock(juma)}');
    }
  }

  return out.toString().trimRight();
}

/// Opens the share sheet with [buildShareText]'s message — the Android
/// sheet, which is how "share to WhatsApp" works without knowing about
/// WhatsApp.
void shareTodayTimes({
  required double latitude,
  required double longitude,
  required String areaName,
  Masjid? board,
}) {
  final String text = buildShareText(
    latitude: latitude,
    longitude: longitude,
    areaName: areaName,
    board: board,
  );
  SharePlus.instance.share(
    ShareParams(text: text, subject: 'Today\'s prayer times'),
  );
}

// ===========================================================================
//  THE DAY AT A GLANCE — sunrise to sunset, with the nafl times pinned on it
// ===========================================================================

/// The sun's own path across the day, drawn as a curve, with the nafl times
/// the boards print under the five pinned on it — Ishraq, Chasht, Zawal and
/// Tahajjud — and the clock's own position marked on the curve.
///
/// The app had the numbers for this and never the picture: sunrise and
/// sunset were computed every day and thrown away, while the four nafl
/// times were printed as a list with nothing to say *when* in the day they
/// fell. A curve says it in one glance — how much of the day is left, where
/// Dhuhr sits, that Tahajjud belongs to the night and not to this curve.
class DayArcCard extends StatefulWidget {
  const DayArcCard({
    super.key,
    required this.latitude,
    required this.longitude,
  });

  final double latitude;
  final double longitude;

  @override
  State<DayArcCard> createState() => _DayArcCardState();
}

class _DayArcCardState extends State<DayArcCard> {
  /// The dot that says "now" has to move as the day moves, so the card wakes
  /// once a minute — the same quiet ticker the Today card runs. A minute is
  /// plenty: the dot moves a fraction of a millimetre in that time.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = AppSettings.instance;
    final LocalPrayerTimes day = settings.compute(
      latitude: widget.latitude,
      longitude: widget.longitude,
    );
    final DayArc? arc = DayArc.of(day);
    final Map<String, DateTime> nafl = NaflTimes.of(day);
    if (arc == null || nafl.isEmpty) return const SizedBox.shrink();

    final Duration light = arc.daylight;

    return GoldCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              children: <Widget>[
                const Icon(Icons.wb_sunny_outlined,
                    size: 16, color: NoorColors.gold),
                const SizedBox(width: 7),
                Text(
                  'The day at a glance',
                  style: GoogleFonts.outfit(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: NoorColors.onGlass,
                  ),
                ),
                const Spacer(),
                Text(
                  '${light.inHours}h ${(light.inMinutes % 60).toString().padLeft(2, '0')}m of daylight',
                  style: GoogleFonts.outfit(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: NoorColors.onGlassMuted,
                  ),
                ),
              ],
            ),
          ),

          // The curve itself, with sunrise and sunset at its two ends.
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              _arcEnd('Sunrise', settings.format(arc.sunrise),
                  CrossAxisAlignment.start),
              Expanded(
                child: SizedBox(
                  height: 72,
                  child: CustomPaint(
                    painter: _DayArcPainter(arc: arc, now: DateTime.now()),
                  ),
                ),
              ),
              _arcEnd('Sunset', settings.format(arc.sunset),
                  CrossAxisAlignment.end),
            ],
          ),

          const SizedBox(height: 6),
          Divider(height: 1, color: NoorColors.gold.withValues(alpha: 0.22)),

          // The four times the boards print under the five.
          for (final NaflTime t in kNaflTimes)
            if (nafl[t.key] != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _markColour(t.key),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        t.label,
                        style: GoogleFonts.outfit(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: NoorColors.onGlass,
                        ),
                      ),
                    ),
                    Text(
                      settings.format(nafl[t.key]!),
                      style: GoogleFonts.outfit(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: NoorColors.gold,
                      ),
                    ),
                  ],
                ),
              ),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 2),
            child: Text(
              kNaflTimes.map((NaflTime t) => t.hint).join(' · '),
              style: GoogleFonts.outfit(
                fontSize: 9.5,
                height: 1.4,
                color: NoorColors.onGlassMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// One end of the arc: the word and the clock under it.
  Widget _arcEnd(String label, String time, CrossAxisAlignment align) =>
      Column(
        crossAxisAlignment: align,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            style: GoogleFonts.outfit(
              fontSize: 9.5,
              fontWeight: FontWeight.w600,
              color: NoorColors.onGlassMuted,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            time,
            style: GoogleFonts.outfit(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: NoorColors.onGlass,
            ),
          ),
        ],
      );
}

/// The colour a mark on the curve wears — the same colour its legend dot
/// wears, so the eye can carry one from the curve to the list.
Color _markColour(String key) {
  switch (key) {
    case 'ishraq':
      return NoorColors.gold;
    case 'chasht':
      return NoorColors.emeraldDeep;
    case 'zawal':
      return NoorColors.danger;
    default:
      return NoorColors.muted;
  }
}

/// Draws the sun's path: a curve from the sunrise end to the sunset end,
/// the nafl times pinned on it, and the clock's own place on the curve.
class _DayArcPainter extends CustomPainter {
  const _DayArcPainter({required this.arc, required this.now});

  final DayArc arc;
  final DateTime now;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    if (w <= 0 || h <= 0) return;

    final Path curve = Path()
      ..moveTo(0, h)
      ..quadraticBezierTo(w / 2, -0.35 * h, w, h);

    // The body of the day — a warm wash under the curve.
    final Path body = Path.from(curve)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(
      body,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            NoorColors.gold.withValues(alpha: 0.20),
            NoorColors.gold.withValues(alpha: 0.02),
          ],
        ).createShader(Rect.fromLTWH(0, 0, w, h)),
    );

    // The path itself.
    canvas.drawPath(
      curve,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          colors: <Color>[NoorColors.goldSoft, NoorColors.emeraldDeep],
        ).createShader(Rect.fromLTWH(0, 0, w, h)),
    );

    // The nafl times, pinned where they fall.
    for (final DayArcMark mark in arc.marks) {
      final double? at = arc.fractionOf(mark.at);
      if (at == null) continue;
      final Offset p = _pointAt(at, w, h);
      final Color colour = _markColour(mark.key);
      canvas.drawCircle(
        p,
        5.5,
        Paint()..color = colour.withValues(alpha: 0.22),
      );
      canvas.drawCircle(p, 3.2, Paint()..color = colour);
    }

    // Where the clock stands now — the one dot that has to be true.
    final double? standing = arc.fractionOf(now);
    if (standing != null) {
      final Offset p = _pointAt(standing, w, h);
      canvas.drawCircle(
        p,
        7.5,
        Paint()..color = NoorColors.ink.withValues(alpha: 0.14),
      );
      canvas.drawCircle(p, 4.6, Paint()..color = NoorColors.ink);
      canvas.drawCircle(p, 1.7, Paint()..color = NoorColors.white);
    }
  }

  /// The point on the curve a fraction of the way along it.
  ///
  /// The curve is a quadratic Bézier from (0, h) through (w/2, -0.35h) to
  /// (w, h), so its x runs linearly with the parameter — which is why the
  /// sunrise-to-sunset fraction of a time *is* the parameter.
  static Offset _pointAt(double t, double w, double h) {
    final double x = w * t;
    final double y = h *
        ((1 - t) * (1 - t) - 0.7 * t * (1 - t) + t * t);
    return Offset(x, y);
  }

  @override
  bool shouldRepaint(covariant _DayArcPainter old) =>
      old.now != now || old.arc != arc;
}

// ===========================================================================
//  RAMADAN — the season's card
// ===========================================================================

/// The banner that appears on Home for the whole of Ramadan: which day of
/// the fast it is, when Sehri ends, when the fast breaks, and a one-tap
/// way into the tracker for logging the day.
///
/// Draws nothing at all on the other ~330 days of the year — no empty card,
/// no reserved gap.
class RamadanBannerCard extends StatelessWidget {
  const RamadanBannerCard({
    super.key,
    required this.latitude,
    required this.longitude,
  });

  final double latitude;
  final double longitude;

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = AppSettings.instance;
    final RamadanInfo? ramadan = ramadanAround(
      DateTime.now(),
      adjustment: settings.hijriAdjustment,
    );
    if (ramadan == null) return const SizedBox.shrink();

    final LocalPrayerTimes day =
        settings.compute(latitude: latitude, longitude: longitude);
    final DateTime? fajr = day.times['fajr'];
    final DateTime? maghrib = day.times['maghrib'];
    final Duration fast = (fajr != null && maghrib != null)
        ? maghrib.difference(fajr)
        : Duration.zero;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GoldCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.nights_stay_outlined,
                    size: 19, color: NoorColors.gold),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    'Ramadan Mubarak — day ${ramadan.dayNumber} of ${ramadan.length}',
                    style: GoogleFonts.outfit(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: NoorColors.onGlass,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: _fastTime(
                    'Sehri ends',
                    fajr == null ? '—' : settings.format(fajr),
                    Icons.dark_mode_outlined,
                  ),
                ),
                Container(
                  width: 1,
                  height: 30,
                  color: NoorColors.onGlassChip,
                ),
                Expanded(
                  child: _fastTime(
                    'Iftar',
                    maghrib == null ? '—' : settings.format(maghrib),
                    Icons.wb_sunny_outlined,
                  ),
                ),
                Container(
                  width: 1,
                  height: 30,
                  color: NoorColors.onGlassChip,
                ),
                Expanded(
                  child: _fastTime(
                    'Fast',
                    fast == Duration.zero
                        ? '—'
                        : '${fast.inHours}h ${fast.inMinutes % 60}m',
                    Icons.hourglass_bottom,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _fastTime(String label, String value, IconData icon) => Column(
        children: <Widget>[
          Icon(icon, size: 15, color: NoorColors.gold),
          const SizedBox(height: 3),
          Text(
            value,
            style: GoogleFonts.outfit(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: NoorColors.onGlass,
            ),
          ),
          Text(
            label,
            style: GoogleFonts.outfit(
              fontSize: 10,
              color: NoorColors.onGlassMuted,
            ),
          ),
        ],
      );
}
