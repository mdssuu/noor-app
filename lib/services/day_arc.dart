import '../app_settings.dart';
import 'nafl_times.dart';

/// The daylight arc — the sun's own path across one day, from the moment it
/// clears the horizon to the moment it goes down.
///
/// Every desi timetable draws this as a line with the hours pinned on it,
/// and the app had the numbers for it but never the picture: sunrise and
/// sunset were computed and then thrown away. This file is the arithmetic
/// behind the picture, kept out of the widget so it can be tested without a
/// screen — [fractionOf] is the only thing the painter needs, and it is the
/// thing that must never lie.
class DayArc {
  const DayArc({
    required this.sunrise,
    required this.sunset,
    required this.marks,
  });

  /// The sun clearing the horizon — the arc's left end.
  final DateTime sunrise;

  /// The sun going down — the arc's right end. This is the *sun's* own
  /// going-down, not Maghrib: the prayer opens a minute or two later, and
  /// the two are printed as two separate things everywhere else in the app.
  final DateTime sunset;

  /// The instants pinned between the two ends — Ishraq, Zawal, Chasht.
  /// Ordered by the time they happen, always inside the arc.
  final List<DayArcMark> marks;

  /// How long the sun was up.
  Duration get daylight => sunset.difference(sunrise);

  /// The same, in hours — "12.4" reads better than "12h 24m" under a curve.
  double get daylightHours => daylight.inMinutes / 60.0;

  /// Where [moment] sits on the arc: `0` at sunrise, `1` at sunset, and
  /// anything between for the hours in between.
  ///
  /// `null` when the moment is outside the daylight hours — the sun is
  /// down, and there is no arc to place it on. The caller draws nothing
  /// rather than pinning a dot to an end it does not belong to.
  double? fractionOf(DateTime moment) {
    final int total = daylight.inSeconds;
    if (total <= 0) return null;
    final int at = moment.difference(sunrise).inSeconds;
    if (at < 0 || at > total) return null;
    return at / total;
  }

  /// The arc for [day], or `null` when the day has no sunrise or no sunset
  /// to draw between.
  ///
  /// The marks are the nafl times that fall *inside* the daylight hours.
  /// Tahajjud is the last third of the night, so it is not on this curve —
  /// it is printed underneath it instead, where the legend has room for it.
  static DayArc? of(LocalPrayerTimes day) {
    final DateTime? sunrise = day.times['sunrise'];
    final DateTime? sunset = day.times['sunset'];
    if (sunrise == null || sunset == null) return null;
    if (!sunset.isAfter(sunrise)) return null;

    final Map<String, DateTime> nafl = NaflTimes.of(day);
    final List<DayArcMark> marks = <DayArcMark>[];
    for (final NaflTime naflTime in kNaflTimes) {
      final DateTime? at = nafl[naflTime.key];
      if (at == null) continue;
      if (at.isBefore(sunrise) || at.isAfter(sunset)) continue;
      marks.add(DayArcMark(key: naflTime.key, label: naflTime.label, at: at));
    }
    marks.sort((DayArcMark a, DayArcMark b) => a.at.compareTo(b.at));

    return DayArc(sunrise: sunrise, sunset: sunset, marks: marks);
  }
}

/// One instant pinned on the arc.
class DayArcMark {
  const DayArcMark({required this.key, required this.label, required this.at});

  /// The nafl key — `ishraq`, `chasht`, `zawal` — so the legend and the
  /// curve speak about the same thing.
  final String key;

  final String label;

  final DateTime at;
}
