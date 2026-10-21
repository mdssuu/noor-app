import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hijri/hijri_calendar.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../app_settings.dart';
import '../main.dart';
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
//  NAFL TIMINGS — the four times the boards print under the five
// ===========================================================================

/// Ishraq, Chasht, Zawal and Tahajjud, computed from the same day the card
/// above quotes.
class NaflTimingsCard extends StatelessWidget {
  const NaflTimingsCard({
    super.key,
    required this.latitude,
    required this.longitude,
  });

  final double latitude;
  final double longitude;

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = AppSettings.instance;
    final LocalPrayerTimes day =
        settings.compute(latitude: latitude, longitude: longitude);
    final Map<String, DateTime> nafl = NaflTimes.of(day);
    if (nafl.isEmpty) return const SizedBox.shrink();

    return GoldCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: <Widget>[
                const Icon(Icons.wb_twilight_outlined,
                    size: 16, color: NoorColors.gold),
                const SizedBox(width: 7),
                Text(
                  'Nafl timings',
                  style: GoogleFonts.outfit(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: NoorColors.onGlass,
                  ),
                ),
              ],
            ),
          ),
          for (final NaflTime t in kNaflTimes)
            if (nafl[t.key] != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: <Widget>[
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
