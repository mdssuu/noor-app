import '../app_settings.dart';

/// The prayer-adjacent times every desi timetable prints under the main five
/// — Ishraq, Chasht, Zawal, Tahajjud — derived from the same calculated day
/// the Today card quotes, never from a second opinion.
///
/// These are *popular* timings, not obligations, and where they begin is a
/// matter of fiqh that differs between schools and masjids. What this file
/// offers is the arithmetic every Indian board uses (a quarter of the day to
/// Chasht, a fifth of the night… none of that — only the four above), each
/// one labelled with the rule it follows so a reader who follows a different
/// rule can see *why* the number is what it is. They are informational:
/// nothing in the app alarms on them.
class NaflTimes {
  NaflTimes._();

  /// "Ishraq" is commonly taken as twenty minutes after sunrise, once the
  /// sun has cleared the horizon. The wait exists so the prayer is not said
  /// inside the sunrise window itself.
  static Duration afterSunrise = const Duration(minutes: 20);

  /// Zawal — the minutes around solar zenith when a prayer is not offered.
  /// Shown from ten minutes before Dhuhr, which is the conservative start
  /// used across the subcontinent; the window closes at Dhuhr itself.
  static Duration beforeDhuhr = const Duration(minutes: 10);

  /// Derives the four times from one calculated day.
  ///
  /// [day] must carry `sunrise`, `dhuhr`, `isha` and the next day's `Fajr`
  /// (as [LocalPrayerTimes.fajrTomorrow]) — Tahajjud is the last third of
  /// the night between Isha and Fajr, so the night cannot be measured from
  /// one day's times alone.
  static Map<String, DateTime> of(LocalPrayerTimes day) {
    final DateTime? sunrise = day.times['sunrise'];
    final DateTime? dhuhr = day.times['dhuhr'];
    final DateTime? isha = day.times['isha'];
    if (sunrise == null || dhuhr == null || isha == null) {
      return const <String, DateTime>{};
    }

    final Duration daylight = dhuhr.difference(sunrise);
    final DateTime rise = sunrise;
    final DateTime noon = dhuhr;
    final DateTime night = isha;
    return <String, DateTime>{
      'ishraq': rise.add(afterSunrise),
      // A quarter of the time from sunrise to Dhuhr — the Chasht rule used
      // on Indian boards ("charwaqt"), measured rather than hardcoded to a
      // two-hour guess, so it stays honest at every latitude.
      'chasht': rise.add(daylight ~/ 4),
      'zawal': noon.subtract(beforeDhuhr),
      // The last third of the night: Isha plus two thirds of the way to
      // tomorrow's Fajr. `fajrTomorrow` is what makes this the *last*
      // third rather than the first.
      'tahajjud': night.add(
        day.fajrTomorrow.difference(night) * 2 ~/ 3,
      ),
    };
  }
}

/// One nafl time as the user meets it: the word, the clock, and the rule.
class NaflTime {
  const NaflTime(this.key, this.label, this.hint);

  final String key;

  /// Exactly the wording on the card.
  final String label;

  /// The rule, in one line, underneath the time.
  final String hint;
}

/// Display order, matching the row order on the card.
const List<NaflTime> kNaflTimes = <NaflTime>[
  NaflTime('ishraq', 'Ishraq', '20 minutes after sunrise'),
  NaflTime('chasht', 'Chasht', 'a quarter of the way from sunrise to Dhuhr'),
  NaflTime('zawal', 'Zawal begins', 'the minutes before Dhuhr — no prayer then'),
  NaflTime('tahajjud', 'Tahajjud', 'the last third of the night, after Isha'),
];

NaflTime naflByKey(String key) => kNaflTimes.firstWhere(
      (NaflTime t) => t.key == key,
      orElse: () => kNaflTimes.first,
    );
